---
name: lark-task-tracker
version: 1.0.0
description: "飞书任务追踪：自动扫描「@我的」和「我承诺的」飞书消息，去重后写入多维表格，每晚推送任务日报、每早推送待办清单。适合想让 AI 自动从聊天里收集待办、沉淀到可勾选的多维表格并定时提醒的人。依赖飞书官方 lark-cli。"
metadata:
  requires:
    bins: ["lark-cli", "jq"]
  cliHelp: "lark-cli im +messages-search --help"
---

# lark-task-tracker

从飞书聊天里**自动收集待办**，落到一张多维表格，并**每天定时提醒**。

## 它做什么

1. **扫描**：每次扫近 N 天（默认 7 天）里
   - 「**@我的**」消息（别人 @ 我、或 @所有人 且我在群里）
   - 「**我承诺的**」消息（我自己发的、含承诺语气的话，如"我来跟进""我明天给你""尽快给"）
2. **AI 二次筛选**（MiniMax M3，中等力度）：判断每条是否**真需要我行动**
   - 明确要行动的 → 留，并提炼成简洁任务标题 + 识别截止时间
   - 通知/汇报/闭环/寒暄 → 丢
   - 模棱两可 → 留，标题前加 `❓` 标记待确认
3. **去重入表**：按 `message_id` 去重，只把新消息写进多维表格（状态默认「待办」）
4. **每晚总结**（晚上跑）：扫全天 → 推送当日任务日报（今日新增 + 待办/进行中/已完成总览）
5. **每早清单**（早上跑）：扫最新 → 推送今天的待办清单私信，我打开表格就能勾选管理

数据全部落在一张**多维表格**里，随时打开即可看到每天哪些完成、哪些没完成。

## 快速开始

### 1. 前置

- 已安装飞书官方 `lark-cli`，且已授权（`lark-cli auth status` 显示 user: ready）
- 需要的 scope：`search:message`、`im:message:readonly`、`im:message`、`base:record:create/read`、`base:app:create`
- 已安装 `jq`

### 2. 配置

编辑 [`config.env`](config.env)，改成你自己的：

```bash
LARK_PROFILE="william"      # 你的 lark-cli profile 名
BASE_TOKEN="..."            # 任务多维表格 token（见下方建表）
TABLE_ID="tbl..."           # 表 id
MY_OPEN_ID="ou_..."         # 你的 open_id（收清单私信 + 识别"我承诺的"）
MY_NAME="大Joe"
SCAN_DAYS="7"               # 扫描窗口天数
```

拿自己的 open_id：`lark-cli auth status --json | jq -r '.identities.user.openId'`

### 3. 建表（首次）

如果还没有任务表，用下面命令一键建（建完把返回的 base_token / table_id 填进 config.env）：

```bash
lark-cli base +base-create \
  --name "任务清单" --time-zone "Asia/Shanghai" --table-name "任务" \
  --fields '[
    {"name":"任务","type":"text"},
    {"name":"状态","type":"select","multiple":false,"options":[{"name":"待办"},{"name":"进行中"},{"name":"已完成"},{"name":"已取消"}]},
    {"name":"来源类型","type":"select","multiple":false,"options":[{"name":"@我的"},{"name":"我承诺的"}]},
    {"name":"来源群聊","type":"text"},
    {"name":"提出人","type":"text"},
    {"name":"原始消息","type":"text"},
    {"name":"消息链接","type":"url"},
    {"name":"录入日期","type":"date"},
    {"name":"截止日期","type":"date"},
    {"name":"完成日期","type":"date"}
  ]' --as user
```

### 4. 手动跑一次

```bash
bash scripts/scan.sh            # 只扫描入表
bash scripts/push_tasks.sh      # 扫 + 推早间清单
bash scripts/evening_summary.sh # 扫 + 推晚间日报
```

### 5. 定时（cron）

在 OpenClaw 里用 `cron` 工具挂两个 isolated agentTurn 任务（或直接系统 crontab）：

- **每晚 22:00**：`bash ~/.agents/skills/lark-task-tracker/scripts/evening_summary.sh`
- **每早 08:30**：`bash ~/.agents/skills/lark-task-tracker/scripts/push_tasks.sh`

## 脚本

| 脚本 | 作用 |
|------|------|
| [`scripts/scan.sh`](scripts/scan.sh) | 扫描近 N 天 @我的/我承诺的，AI 筛选后去重写入多维表格 |
| [`scripts/ai_filter.sh`](scripts/ai_filter.sh) | MiniMax M3 二次筛选（分块处理），判断是否真任务+提炼标题+识别截止 |
| [`scripts/push_tasks.sh`](scripts/push_tasks.sh) | 先扫最新，再把未完成任务整理成清单私信推给本人（早间） |
| [`scripts/evening_summary.sh`](scripts/evening_summary.sh) | 先扫全天，再推送当日任务日报（晚间） |

## 关键实现要点（给维护者）

- **扫 @我的**：`lark-cli im +messages-search --is-at-me --start ... --end ... --page-all`（`--is-at-me` 是官方内置能力，直接返回所有 @我 的消息）
- **扫我承诺的**：`--sender <my_open_id> --sender-type user` 拉自己发的消息，再用承诺关键词正则过滤
- **去重**：`state/seen_message_ids.txt` 存已处理 message_id，`grep -qxF` 判重
- **写表**：`lark-cli base +record-batch-create --json '{"fields":[...],"rows":[[...]]}'`（列序 = fields 顺序；select 直接写选项名字符串；datetime 写 `YYYY-MM-DD HH:mm:ss`）
- **读未完成任务**：`lark-cli base +record-list --filter-json '{"logic":"and","conditions":[["状态","intersects",["待办","进行中"]]]}'`（**select 字段必须用 `intersects` + 数组**，`==` 不匹配）
- **返回格式是列式**：`record-list`/`record-search` 返回 `.data.data`（行数组）+ `.data.fields`（列名）+ `.data.record_id_list`（并行 id 数组）；用 `[$cols, $row]|transpose|map({(.[0]):.[1]})|add` 转对象
- **标题截断**：中文用 `jq -rn --arg s "$c" '$s[0:40]'` 按字符切，**不要用 `cut -c`（会按字节切出乱码）**
- **过滤噪音**：跳过 msg_type=image/sticker/audio/media，以及内容只有 `![Image](...)` 图片占位的消息
- **删除记录**：`+record-delete` 是 high-risk，必须加 `--yes`

## 消息直达链接（已验证可用）

- 每条任务存的是「直达单条消息」的 applink，一点就跳到那条具体消息并高亮（官方支持 3.9.0+）：
  ```
  https://applink.feishu.cn/client/chat/open?openChatId=<chat_id>&openMessageId=<message_id>
  ```
- **为什么不用 message_app_link**：搜索 API 返回的 `message_app_link` 是 `chat/open?...&position=N`（打开群聊到某位置），position 会因新消息进来而漂移，不精准。用 `openMessageId` 直接定位到消息本体。
- **字段类型坡**：lark-cli 建不了原生 URL 字段（`type:"url"/"URL"/"hyperlink"` 均被静默降级成 text；`text→url` 转换也不在允许列表）。但**文本字段里写纯 URL 字符串，飞书客户端会自动识别成可点链接**，所以直接存 URL 字符串到 `消息链接`（text）即可。
- record cell 写入：`{text,link}` 对象和 markdown link 都会被 text 字段拒（"does not match any supported shape"），直接存纯 URL 字符串最稳。

## AI 筛选 + 自动归档（方向 A，已实现）

- 引擎：MiniMax **M3**（`config.env` 里 `AI_FILTER=true` 开关，`MINIMAX_MODEL` 可换）
- 力度：中等 —— 明确要行动的留，通知/寒暄丢，拿不准的留并标 `❓`
- **分块处理**：`ai_filter.sh` 每 15 条一批喂给 M3，避免单次输出超 token 被截断
- **降级保护**：AI 无有效返回时，`scan.sh` 自动降级为全量入表（宁可多收不丢任务）
- `max_tokens=8000`（M3 推理占用大，给足）

### 自动归档项目（AUTO_PROJECT）
- 开关：`config.env` 里 `AUTO_PROJECT=true`
- M3 在筛选的同时，顺手判断每条任务属于哪个项目，自动写「所属项目」字段
- **白名单机制**：`PROJECT_WHITELIST`（分号隔开）列出允许的项目，M3 只能从里面选；scan.sh 写表前校验，不在白名单里的一律置空
- **为什么用白名单而不是读字段选项**：飞书 select 字段写入未知值时会**自动新建选项**，如果直接拿字段选项做校验，M3 自创的项目会被 Feishu 自动落地，造成项目增生。用 config 里固定的白名单才能真正挡住。
- **新增项目时**：把名字加到 `PROJECT_WHITELIST`（同时建议在项目总表加一行），下次 scan 就能自动归入
- 实测：41/41 任务 100% 自动归档，字段保持 11 选项无增生

## 项目化结构（方向 A 产出）
- **任务表**加「所属项目」单选字段 + 「按项目分组」视图（group by 所属项目）
- **项目总表**（另一张表 `PROJECT_TABLE_ID`）：每项目一行，字段项目名称/状态/优先级/负责人/进度/描述/关键节点/备注


## 已知限制 / 可改进

- 「完成」状态目前靠手动在多维表格里改；未来可加：识别我回复"已完成/搞定了"自动标记完成
- 承诺关键词是正则硬编码，可按个人说话习惯在 scan.sh 里调 `PROMISE_RE`
- AI 筛选每天约 5 次 M3 调用（分块），成本可控；若想更省可调大 `AI_FILTER_CHUNK`
