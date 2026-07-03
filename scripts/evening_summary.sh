#!/usr/bin/env bash
# evening_summary.sh — 每晚总结：扫全天 @我的/我承诺的入表，再推送当日汇总
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

lark-cli profile use "$LARK_PROFILE" >/dev/null 2>&1 || true

echo "[summary] 扫描全天新消息入表..."
bash "$SKILL_DIR/scripts/scan.sh" "$SCAN_DAYS" || echo "[summary] 扫描出错，继续总结"

DATE_CN=$(date '+%m月%d日')
TODAY_DATE=$(date '+%Y-%m-%d')

echo "[summary] 拉取全部任务统计..."
lark-cli base +record-list \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --limit 200 --format json --as user 2>/dev/null > /tmp/tasktracker_all_$$.json || echo '{}' > /tmp/tasktracker_all_$$.json
ALLJSON="/tmp/tasktracker_all_$$.json"

# 列式→对象数组，落到临时文件复用
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

# 今天新录入（录入日期以 YYYY-MM-DD 开头）
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
MSG="${MSG}\n\n──────────\n📌 当前总览:\n⏳ 待办 ${TODO} · 🔵 进行中 ${DOING} · ✅ 已完成 ${DONE}\n\n📋 明早我会把待办清单推给你。\n📊 表格: ${BASE_URL}"

echo "[summary] 发送日报..."
printf '%b' "$MSG" > /tmp/tasktracker_sum_$$.txt
lark-cli im +messages-send \
  --user-id "$MY_OPEN_ID" \
  --markdown "$(cat /tmp/tasktracker_sum_$$.txt)" \
  --as user 2>&1 | head -5
rm -f /tmp/tasktracker_sum_$$.txt "$ALLJSON" "$OBJS"
echo "[summary] ✅ 完成"
