# lark-task-tracker

> 自动把飞书里「@我的消息」和「我承诺要做的事」变成一张可管理的任务多维表格，AI 筛掉噪音、自动归档到项目，每早推待办清单、每晚推日报。

一个基于飞书官方 [lark-cli](https://github.com/larksuite/cli) + MiniMax M3 的个人任务追踪 skill。装好、改个配置，就能用自己的飞书账号跑起来。

## 它做什么

1. **扫描**（默认近 7 天）
   - 「**@我的**」消息（别人 @ 我、或 @所有人 且我在群里）
   - 「**我承诺的**」消息（我自己发的、带承诺语气的话，如"我来跟进""我明天给你""尽快给"）
2. **AI 二次筛选**（MiniMax M3，中等力度）：判断每条是否**真需要我行动**
   - 要行动的留下，提炼成简洁任务标题 + 识别截止时间
   - 通知/汇报/闭环/寒暄 → 丢
   - 拿不准的 → 留下并标 `❓`
3. **自动归档项目**：AI 顺手判断每条任务属于哪个项目，写进「所属项目」字段（白名单约束，不乱建项目）
4. **落多维表格**：按 `message_id` 去重，只写新消息；每条带**一点直达原消息**的链接
5. **每早 08:30** 推今日待办清单私信；**每晚 22:00** 推任务日报（今日新增 + 待办/进行中/已完成总览）

## 效果

- 任务标题干净：`确认火炬智能体需求细节`（而不是照抄一长串聊天原文）
- 消息链接一点直达：跳到那条具体消息并高亮
- 100% 自动归档到项目，可按项目分组查看全局
- 早晚定时推送，不用自己惦记

## 依赖

- [飞书官方 lark-cli](https://github.com/larksuite/cli)（已授权 user 身份）
- `jq`、`curl`、`bash`
- 一个 [MiniMax](https://platform.minimaxi.com) API Key（用 M3 做筛选/归档，成本很低）
- （可选）OpenClaw / 任意 cron 来跑定时

## 快速开始

```bash
# 1. 放到 skill 目录（或任意目录）
git clone https://github.com/joevise/lark-task-tracker.git ~/.agents/skills/lark-task-tracker
cd ~/.agents/skills/lark-task-tracker

# 2. 建多维表格（字段清单见 SKILL.md「建表」章节）
#    也可以先手动建好，把 base_token / table_id 填进配置

# 3. 配置
cp config.env.example config.env
vim config.env   # 填自己的 profile / base_token / open_id / MiniMax key / 项目白名单

# 4. 首次扫描入表
bash scripts/scan.sh

# 5. 手动测推送
bash scripts/push_tasks.sh        # 早间清单
bash scripts/evening_summary.sh   # 晚间日报
```

## 定时（OpenClaw cron 示例）

```
早间清单：cron "30 8 * * *"  tz Asia/Shanghai → bash scripts/push_tasks.sh
晚间日报：cron "0 22 * * *"  tz Asia/Shanghai → bash scripts/evening_summary.sh
```

也可以用系统 crontab，指向 `scripts/scan.sh` 定时扫描增量。

## 文件

| 文件 | 作用 |
|------|------|
| `SKILL.md` | 完整实现文档（建表命令、字段设计、踩过的坑） |
| `config.env.example` | 配置模板，复制成 `config.env` 用 |
| `scripts/scan.sh` | 扫描 + AI 筛选 + 自动归档 + 去重入表 |
| `scripts/ai_filter.sh` | MiniMax M3 分块筛选（判断真任务 + 提炼标题 + 归档项目） |
| `scripts/push_tasks.sh` | 早间待办清单私信 |
| `scripts/evening_summary.sh` | 晚间任务日报 |

## 设计要点（详见 SKILL.md）

- **只扫「@我的」+「我承诺的」**，其他消息不纳入，避免噪音
- **AI 分块处理**：每 15 条一批喂 M3，避免单次输出超 token 被截断
- **降级保护**：AI 挂了自动退回全量入表，宁可多收不丢任务
- **项目白名单**：飞书 select 字段写未知值会自动新建选项，所以用 config 里固定白名单校验，防止模型自创项目增生
- **消息直达链接**：用 `openChatId + openMessageId` 而非 `position`（position 会随新消息漂移）

## 安全

- `config.env` 含密钥，已在 `.gitignore` 里，**永不提交**
- 只用你自己授权的飞书身份操作，数据都在你自己的多维表格里

## License

MIT
