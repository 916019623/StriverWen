#!/usr/bin/env bash
set -euo pipefail

# OpenClaw 心跳检测脚本 v8
# 触发 OpenClaw 内置心跳检查，收集状态推送到钉钉群

DINGTALK_WEBHOOK_URL="${DINGTALK_WEBHOOK_URL:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

trap 'rm -rf /tmp/openclaw-heartbeat-*' EXIT

send_dingtalk() {
    local message="$1"
    if [[ -z "$DINGTALK_WEBHOOK_URL" ]]; then
        echo "[WARN] DINGTALK_WEBHOOK_URL not set"
        echo "$message"
        return 0
    fi
    curl -s -X POST "$DINGTALK_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d '{"msgtype": "text", "text": {"content": "'"$message"'"}}' > /dev/null
    echo "[OK] DingTalk notification sent"
}

filter_output() {
    grep -vE "Config warnings|duplicate plugin|plugins\.allow|dingtalk failed|Require stack|adp-openclaw|Tool adp|Registering tool|registration complete|^\s*$|openclaw@|node_modules|\.openclaw-install"
}

echo "=== OpenClaw 心跳检测 ==="
echo ""

# 1. 触发心跳检查
echo "[1/6] 触发心跳检查..."
EVENT_OUTPUT=$(openclaw system event --text "heartbeat" --mode now 2>&1) || true
echo "  完成"

# 2. 获取心跳结果
echo "[2/6] 获取心跳结果..."
sleep 3

HEARTBEAT_OUTPUT=$(openclaw system heartbeat last 2>&1) || true
PREVIEW=$(echo "$HEARTBEAT_OUTPUT" | grep '"preview"' | sed 's/.*"preview": "//' | sed 's/".*//' | tr -d '\\n' || echo "")
REASON=$(echo "$HEARTBEAT_OUTPUT" | grep '"reason"' | sed 's/.*"reason": "//' | sed 's/".*//' || echo "")

echo "  原因: ${REASON:-无}"

IS_ERROR=false
if echo "$REASON" | grep -qE "error|fail|abort"; then
    IS_ERROR=true
fi

# 3. 收集系统资源
echo "[3/6] 收集系统资源..."

NOW=$(date "+%Y-%m-%d %H:%M:%S")
MEM_USAGE=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%.1f%%", $3/$2 * 100}' || echo "未知")
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s (%s used / %s total)", $5, $3, $2}' || echo "未知")
# CPU 详情：15分钟负载 + 当前使用率
LOAD_15M=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | awk -F',' '{print $3}' | xargs || echo "未知")
CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' || echo "未知")
if [[ "$CPU_USAGE" =~ ^[0-9]+\.[0-9]$ ]]; then
    CPU_DETAIL="15分钟负载: ${LOAD_15M} · 使用率: ${CPU_USAGE}%"
else
    CPU_DETAIL="15分钟负载: ${LOAD_15M}"
fi

# 模型连接检查
echo "[4/6] 检查模型连接..."
MODELS_OUTPUT=$(timeout 10 openclaw models list 2>&1 | filter_output || echo "")
if echo "$MODELS_OUTPUT" | grep -qi "error\|fail\|unavailable"; then
    MODEL_STATUS="❌ 不可用"
    MODEL_ERR=true
elif echo "$MODELS_OUTPUT" | grep -q "default"; then
    MODEL_NAME=$(echo "$MODELS_OUTPUT" | awk '/default/ {print $1; exit}' || echo "未知")
    MODEL_STATUS="✅ ${MODEL_NAME:-可用}"
    MODEL_ERR=false
else
    MODEL_LINE=$(echo "$MODELS_OUTPUT" | grep "/" | head -1 | awk '{print $1}' || echo "")
    if [[ -n "$MODEL_LINE" ]]; then
        MODEL_STATUS="✅ $MODEL_LINE"
    else
        MODEL_STATUS="⚠️ 未知"
    fi
    MODEL_ERR=false
fi

$MODEL_ERR && IS_ERROR=true

# 钉钉通道状态检查
echo "[5/6] 检查钉钉通道..."
CHANNEL_OUTPUT=$(timeout 20 openclaw channels status 2>&1 | filter_output || echo "")

# 提取 DingTalk 行（格式：- DingTalk default: ...）
DINGTALK_LINE=$(echo "$CHANNEL_OUTPUT" | grep -E "^- DingTalk " | head -1 || echo "")

if echo "$DINGTALK_LINE" | grep -qiE "running|configured"; then
    CHANNEL_STATUS="✅ 在线"
    CHANNEL_ERR=false
elif echo "$DINGTALK_LINE" | grep -qiE "error|fail|stopped|not configured|disabled"; then
    CHANNEL_STATUS="❌ 异常"
    CHANNEL_ERR=true
elif [[ -n "$DINGTALK_LINE" ]]; then
    CHANNEL_STATUS="⚠️ $DINGTALK_LINE"
    CHANNEL_ERR=false
else
    CHANNEL_STATUS="⚠️ 超时"
    CHANNEL_ERR=false
fi

$CHANNEL_ERR && IS_ERROR=true

# Cron 定时任务检查
echo "[6/6] 检查定时任务..."
CRON_OUTPUT=$(timeout 10 openclaw cron runs --id "6b9694e3-96c1-4614-8987-48e0b2a787e6" --limit 1 2>&1 | filter_output || echo "")

if echo "$CRON_OUTPUT" | grep -q '"status"'; then
    CRON_STATUS=$(echo "$CRON_OUTPUT" | grep -o '"status": *"[^"]*"' | head -1 | sed 's/.*: *"\([^"]*\)"/\1/')
    # 将换行合并后再提取 summary（按字符截断100字，兼容中文）
    CRON_SUMMARY=$(echo "$CRON_OUTPUT" | tr '\n' ' ' | sed 's/.*"summary": *"\([^"]*\)".*/\1/' | python3 -c "import sys; print(sys.stdin.read()[:100])")
    CRON_DURATION=$(echo "$CRON_OUTPUT" | grep -o '"durationMs": *[0-9]*' | head -1 | grep -o '[0-9]*')
    CRON_RUN_TIME=$(echo "$CRON_OUTPUT" | grep -o '"runAtMs": *[0-9]*' | head -1 | grep -o '[0-9]*')

    if [[ -n "$CRON_DURATION" && "$CRON_DURATION" =~ ^[0-9]+$ ]]; then
        CRON_DURATION="$((CRON_DURATION / 1000))秒"
    else
        CRON_DURATION="未知"
    fi

    if [[ -n "$CRON_RUN_TIME" && "$CRON_RUN_TIME" =~ ^[0-9]+$ ]]; then
        CRON_RUN_TIME=$(date -d "@$((CRON_RUN_TIME / 1000))" "+%H:%M:%S" 2>/dev/null || echo "$CRON_RUN_TIME")
    else
        CRON_RUN_TIME="未知"
    fi

    if [[ "$CRON_STATUS" == "ok" ]]; then
        CRON_DISPLAY="国家金融监督管理总局数据获取 ✅ (${CRON_RUN_TIME})"
        CRON_ERR=false
    else
        CRON_DISPLAY="❌ ${CRON_STATUS} (${CRON_RUN_TIME})"
        CRON_ERR=true
    fi
    # 截取摘要前100字（按字符，兼容中文）
    CRON_SUMMARY=$(echo "$CRON_SUMMARY" | python3 -c "import sys; print(sys.stdin.read()[:100])")
else
    CRON_DISPLAY="⚠️ 无记录"
    CRON_ERR=false
    CRON_SUMMARY=""
fi

$CRON_ERR && IS_ERROR=true

# 构建报告
SEPARATOR="━━━━━━━━━━━━━━"

if $IS_ERROR; then
    REPORT="🔴 OpenClaw 心跳检测异常"$'\n'
    REPORT+="🕐 $NOW"$'\n'
    REPORT+="$SEPARATOR"$'\n'
    REPORT+="📊 系统状态"$'\n'
    REPORT+="  💬 钉钉  $CHANNEL_STATUS"$'\n'
    REPORT+="  🤖 模型  $MODEL_STATUS"$'\n'
    REPORT+="  💾 内存  $MEM_USAGE"$'\n'
    REPORT+="  💿 磁盘  $DISK_USAGE"$'\n'
    REPORT+="  ⚙️ CPU  $CPU_DETAIL"$'\n'
    REPORT+="$SEPARATOR"$'\n'
    REPORT+="⏰ 定时任务"$'\n'
    REPORT+="  $CRON_DISPLAY"$'\n'
    if [[ -n "$CRON_SUMMARY" ]]; then
        REPORT+="  $CRON_SUMMARY"$'\n'
    fi
    echo -e "${RED}检测到异常${NC}"
else
    REPORT="✅ OpenClaw 心跳检测正常"$'\n'
    REPORT+="🕐 $NOW"$'\n'
    REPORT+="$SEPARATOR"$'\n'
    REPORT+="📊 系统状态"$'\n'
    REPORT+="  💬 钉钉  $CHANNEL_STATUS"$'\n'
    REPORT+="  🤖 模型  $MODEL_STATUS"$'\n'
    REPORT+="  💾 内存  $MEM_USAGE"$'\n'
    REPORT+="  💿 磁盘  $DISK_USAGE"$'\n'
    REPORT+="  ⚙️ CPU  $CPU_DETAIL"$'\n'
    REPORT+="$SEPARATOR"$'\n'
    REPORT+="⏰ 定时任务"$'\n'
    REPORT+="  $CRON_DISPLAY"$'\n'
    # if [[ -n "$CRON_SUMMARY" ]]; then
    #     REPORT+="  $CRON_SUMMARY"$'\n'
    # fi
    echo -e "${GREEN}所有检查正常${NC}"
fi

echo ""
echo "=== 检测报告 ==="
echo "$REPORT"

send_dingtalk "$REPORT"

$IS_ERROR && exit 1 || exit 0
