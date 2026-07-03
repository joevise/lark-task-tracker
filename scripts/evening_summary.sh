#!/usr/bin/env bash
# evening_summary.sh — 每晚总结：扫全天 @我的/我承诺的入表 + 同步本周行程，推送当日日报 + 明日日程预览
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

lark-cli profile use "$LARK_PROFILE" >/dev/null 2>&1 || true

echo "[summary] 扫描全天新消息入表..."
bash "$SKILL_DIR/scripts/scan.sh" "$SCAN_DAYS" || echo "[summary] 扫描出错，继续总结"

# 同步本周行程（append）
if [ -n "${SCHEDULE_TABLE_ID:-}" ]; then
  echo "[summary] 同步本周行程..."
  bash "$SKILL_DIR/scripts/sync_schedule.sh" append || echo "[summary] 行程同步出错，继续"
fi

DATE_CN=$(date '+%m月%d日')
TODAY_DATE=$(date '+%Y-%m-%d')

# 明日日程预览（从日历实时读）
TOMO_YMD=$(date -d 'tomorrow' '+%Y-%m-%d')
TOMO_CN=$(date -d 'tomorrow' '+%m月%d日')
TOMO_WD=$(date -d 'tomorrow' '+%u'); WD_CN=(周一 周二 周三 周四 周五 周六 周日); TOMO_WEEK="${WD_CN[$((TOMO_WD-1))]}"
lark-cli calendar +agenda --as user \
  --start "${TOMO_YMD}T00:00:00+08:00" --end "${TOMO_YMD}T23:59:59+08:00" \
  --format json 2>/dev/null > /tmp/tasktracker_tomo_$$.json || echo '{}' > /tmp/tasktracker_tomo_$$.json
TOMO_CNT=$(jq -r '(.data // []) | length' /tmp/tasktracker_tomo_$$.json 2>/dev/null || echo 0)
TOMO_TXT=$(jq -r '
  (.data // [])
  | sort_by(.start_time.datetime)
  | map("• " + (.start_time.datetime|split("T")[1][0:5]) + " " + (.summary // "(无主题)") + (if .vchat.meeting_url then " 🎥" else "" end))
  | .[]
' /tmp/tasktracker_tomo_$$.json 2>/dev/null) || TOMO_TXT=""
rm -f /tmp/tasktracker_tomo_$$.json

echo "[summary] 拉取全部任务统计..."
lark-cli base +record-list \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --limit 200 --format json --as user 2>/dev/null > /tmp/tasktracker_all_$$.json || echo '{}' > /tmp/tasktracker_all_$$.json
ALLJSON="/tmp/tasktracker_all_$$.json"

jq -c '
  .data.fields as $cols
  | (.data.data // [])
  | map(([$cols, .] | transpose | map({(.[0]): .[1]}) | add))
' "$ALLJSON" > /tmp/tasktracker_objs_$$.json 2>/dev/null || echo '[]' > /tmp/tasktracker_objs_$$.json
OBJS="/tmp/tasktracker_objs_$$.json"

norm_status='(.["状态"] | if type=="array" then .[0] else . end)'
get_count() { jq -r "[.[] | select($norm_status==\"$1\")] | length" "$OBJS" 2>/dev/null || echo 0; }
TODO=$(get_count "待办")
DOING=$(get_count "进行中")
DONE=$(get_count "已完成")

TODAY_NEW=$(jq -r --arg d "$TODAY_DATE" '[.[] | select((.["录入日期"]//""|tostring)|startswith($d))] | length' "$OBJS" 2>/dev/null || echo 0)
NEW_LIST=$(jq -r --arg d "$TODAY_DATE" '
  [.[] | select((.["录入日期"]//""|tostring)|startswith($d))]
  | .[:10]
  | map("• 【\((.["来源类型"]|if type=="array" then .[0] else . end)//"?")】\(.["任务"]//"")")
  | .[]
' "$OBJS" 2>/dev/null) || NEW_LIST=""

MSG="🌙 晚上好，${MY_NAME}！\n\n📊 **${DATE_CN} 任务日报**\n\n今日新增: **${TODAY_NEW}** 项"
if [ -n "$NEW_LIST" ]; then
  MSG="${MSG}\n${NEW_LIST}"
fi
MSG="${MSG}\n\n──────────\n📌 当前总览:\n⏳ 待办 ${TODO} · 🔵 进行中 ${DOING} · ✅ 已完成 ${DONE}"

# 明日日程预览板块
MSG="${MSG}\n\n──────────\n📅 **明日日程预览**（${TOMO_CN} ${TOMO_WEEK}）"
if [ "${TOMO_CNT:-0}" -gt 0 ] && [ -n "${TOMO_TXT:-}" ]; then
  MSG="${MSG}\n共 ${TOMO_CNT} 场\n${TOMO_TXT}"
else
  MSG="${MSG}\n明天暂无日程安排 🎉"
fi

MSG="${MSG}\n\n📋 明早我会把今日日程+待办清单推给你。\n📊 表格: ${BASE_URL}"

echo "[summary] 发送日报（明日 $TOMO_CNT 场）..."
printf '%b' "$MSG" > /tmp/tasktracker_sum_$$.txt
lark-cli im +messages-send \
  --user-id "$MY_OPEN_ID" \
  --markdown "$(cat /tmp/tasktracker_sum_$$.txt)" \
  --as user 2>&1 | head -5
rm -f /tmp/tasktracker_sum_$$.txt "$ALLJSON" "$OBJS"
echo "[summary] ✅ 完成"
