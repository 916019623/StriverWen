---
name: myheartbeat
description: OpenClaw 核心服务状态检查 — 检查钉钉通道、模型连接、系统资源、定时任务状态，并将结果推送到钉钉群。当用户要求检查 OpenClaw 运行状态、执行心跳检测、健康检查、自检、状态汇报时使用。
metadata:
  {
    "openclaw":
      {
        "emoji": "❤️‍🔥",
        "requires": {},
        "install": [],
      },
  }
---

# OpenClaw 心跳检测

执行 OpenClaw 核心服务状态检查，汇总结果后推送到钉钉群。

## 检查项目

1. **钉钉通道状态** — `openclaw channels status` 检查钉钉在线状态
2. **模型连接测试** — `openclaw models list` 检查默认模型可用性
3. **系统资源概览** — 检查内存、磁盘、CPU 使用情况
4. **定时任务状态** — `openclaw cron runs` 检查最近执行结果

## 执行方式

直接执行脚本：
```bash
~/.openclaw/workspace/skills/myheartbeat/scripts/heartbeat.sh
```

## 系统 Crontab 定时任务

已配置每天 8:00-22:00 每小时执行一次：
```bash
0 8-22 * * * ~/.openclaw/workspace/skills/myheartbeat/scripts/heartbeat.sh
```

查看 crontab：
```bash
crontab -l
```

## 报告格式

```
✅ OpenClaw 心跳检测正常
🕐 2026-03-26 23:40:06
━━━━━━━━━━━━━━
📊 系统状态
  💬 钉钉  ✅ 在线
  🤖 模型  ✅ minimax/MiniMax-M2.5
  💾 内存  51.3%
  💿 磁盘  41% (27G used / 69G total)
  ⚙️ CPU  15分钟负载: 1.70 · 使用率: 76.2%
━━━━━━━━━━━━━━
⏰ 定时任务
  国家金融监督管理总局数据获取 ✅ (23:30:00)
```

## 钉钉推送

检查结果通过钉钉 Webhook 推送。需要配置环境变量：
```bash
export DINGTALK_WEBHOOK_URL="https://oapi.dingtalk.com/robot/send?access_token=YOUR_TOKEN"
```

建议在 `~/.bashrc` 中配置，或在 systemd 服务文件中设置。
