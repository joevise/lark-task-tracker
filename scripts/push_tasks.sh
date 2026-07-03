#!/usr/bin/env bash
# push_tasks.sh — 早间推送：今日日程 + 待办清单（私信）
# 先扫最新消息入表 + 同步本周行程，再把「今日日程」和「未完成任务」整理成一条私信推给本人
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

lark-cli profile use "$LARK_PROFILE" >/dev/null 2>&1 || true

# 1) 先扫一遍最新消息（把昨晚到现在新 @我的 也纳入）
echo "[push] 先扫描最新消息..."
bash "$SKILL_DIR/scripts/scan.sh" "$SCAN_DAYS" || echo "[push] 扫描出错，继续推送已有任务"

# 2) 同步本周行程（append：新约的会加进行程表，不动已有行→保留你手动改的状态）
if [ -n "${SCHEDULE_TABLE_ID:-}" ]; then
  echo "[push] 同步本周行程..."
  bash "$SKILL_DIR/scripts/sync_schedule.sh" append || echo "[push] 行程同步出错，继续"
fi

# 3) 拉今日日程（从日历实时读，最准）
TODAY_YMD=$(date '+%Y-%m-%d')
lark-cli calendar +agenda --as user \
  --start "${TODAY_YMD}T00:00:00+08:00" --end "${TODAY_YMD}T23:59:59+08:00" \
  --format json 2>/dev/null > /tmp/tasktracker_sched_$$.json || echo '{}' > /tmp/tasktracker_sched_$$.json
SCHED_CNT=$(jq -r '(.data // []) | length' /tmp/tasktracker_sched_$$.json 2>/dev/null || echo 0)
SCHED_TXT=$(jq -r '
  (.data // [])
  | sort_by(.start_time.datetime)
  | map("• " + (.start_time.datetime|split("T")[1][0:5]) + " " + (.summary // "(无主题)") + (if .vchat.meeting_url then " 🎥" else "" end))
  | .[]
' /tmp/tasktracker_sched_$$.json 2>/dev/null) || SCHED_TXT=""
rm -f /tmp/tasktracker_sched_$$.json

# 4) 读取未完成任务：状态 = 待办 或 进行中（select 字段用 intersects + 数组）
echo "[push] 读取未完成任务..."
lark-cli base +record-list \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --filter-json '{"logic":"and","conditions":[["状态","intersects",["待办","进行中"]]]}' \
  --limit 200 --format json --as user 2>/dev/null > /tmp/tasktracker_open_$$.json || echo '{}' > /tmp/tasktracker_open_$$.json

RECJSON="/tmp/tasktracker_open_$$.json"
COUNT=$(jq -r '.data.record_id_list | length' "$RECJSON" 2>/dev/null || echo "0")

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

# 日程板块
if [ "${SCHED_CNT:-0}" -gt 0 ] && [ -n "${SCHED_TXT:-}" ]; then
  SCHED_BLOCK="📅 **今日日程**（${SCHED_CNT} 场）\n${SCHED_TXT}\n\n"
else
  SCHED_BLOCK="📅 **今日日程**：今天没排日程，清清爽爽 🌞\n\n"
fi

if [ "$COUNT" = "0" ] || [ -z "$LIST" ]; then
  MSG="☀️ 早上好，${MY_NAME}！\n\n📆 **${DATE_CN} ${WEEK}**\n\n${SCHED_BLOCK}📋 待办：目前没有待办任务，清清爽爽～\n\n📊 本周行程表 & 任务: ${BASE_URL}"
else
  MSG="☀️ 早上好，${MY_NAME}！\n\n📆 **${DATE_CN} ${WEEK}**\n\n${SCHED_BLOCK}📋 **待办清单**（共 ${COUNT} 项）\n\n${LIST}\n\n📊 本周行程表 & 任务: ${BASE_URL}"
fi

echo "[push] 发送清单（日程 $SCHED_CNT 场 · 待办 $COUNT 项）..."
printf '%b' "$MSG" > /tmp/tasktracker_push_$$.txt
lark-cli im +messages-send \
  --user-id "$MY_OPEN_ID" \
  --markdown "$(cat /tmp/tasktracker_push_$$.txt)" \
  --as user 2>&1 | head -5
rm -f /tmp/tasktracker_push_$$.txt "$RECJSON"
echo "[push] ✅ 完成"
