#!/usr/bin/env bash
# push_tasks.sh — 推送当前待办清单给本人（私信）
# 早上跑：先扫一遍最新的，再把所有未完成任务整理成清单推送
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

lark-cli profile use "$LARK_PROFILE" >/dev/null 2>&1 || true

# 先扫一遍最新消息（把昨晚到现在新 @我的 也纳入）
echo "[push] 先扫描最新消息..."
bash "$SKILL_DIR/scripts/scan.sh" "$SCAN_DAYS" || echo "[push] 扫描出错，继续推送已有任务"

echo "[push] 读取未完成任务..."
# 拉未完成任务：状态 = 待办 或 进行中（select 字段用 intersects + 数组）
lark-cli base +record-list \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --filter-json '{"logic":"and","conditions":[["状态","intersects",["待办","进行中"]]]}' \
  --limit 200 --format json --as user 2>/dev/null > /tmp/tasktracker_open_$$.json || echo '{}' > /tmp/tasktracker_open_$$.json

RECJSON="/tmp/tasktracker_open_$$.json"
COUNT=$(jq -r '.data.record_id_list | length' "$RECJSON" 2>/dev/null || echo "0")

# 列式→清单文本：.data.fields 是列名，.data.data 是行数组
LIST=$(jq -r '
  .data.fields as $cols
  | (.data.data // [])
  | to_entries
  | map(
      . as $row
      | ([$cols, $row.value] | transpose | map({(.[0]): .[1]}) | add) as $o
      | ($o["来源类型"] | if type=="array" then .[0] else . end) as $st
      | "\($row.key+1). 【\($st // "?")】\($o["任务"] // "(无标题)")"
        + (if ($o["来源群聊"] // "") != "" then "  —— \($o["来源群聊"])" else "" end)
        + (if ($o["提出人"] // "") != "" then " (\($o["提出人"]))" else "" end)
    )
  | .[]
' "$RECJSON" 2>/dev/null) || LIST=""

DATE_CN=$(date '+%m月%d日')
WEEKDAY=$(date '+%u'); WD_CN=(周一 周二 周三 周四 周五 周六 周日); WEEK="${WD_CN[$((WEEKDAY-1))]}"

if [ "$COUNT" = "0" ] || [ -z "$LIST" ]; then
  MSG="☀️ 早上好，${MY_NAME}！\n\n📋 **${DATE_CN} ${WEEK} 任务清单**\n\n目前没有待办任务，清清爽爽～\n\n📊 查看完整表格: ${BASE_URL}"
else
  MSG="☀️ 早上好，${MY_NAME}！\n\n📋 **${DATE_CN} ${WEEK} 任务清单**（共 ${COUNT} 项待办）\n\n${LIST}\n\n📊 打开表格勾选/管理: ${BASE_URL}"
fi

echo "[push] 发送清单（$COUNT 项）..."
printf '%b' "$MSG" > /tmp/tasktracker_push_$$.txt
lark-cli im +messages-send \
  --user-id "$MY_OPEN_ID" \
  --markdown "$(cat /tmp/tasktracker_push_$$.txt)" \
  --as user 2>&1 | head -5
rm -f /tmp/tasktracker_push_$$.txt "$RECJSON"
echo "[push] ✅ 完成"
