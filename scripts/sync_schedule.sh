#!/usr/bin/env bash
# sync_schedule.sh — 同步「本周行程」到多维表格
# 用法:
#   sync_schedule.sh append   （默认）当天增量：把本周新出现的日程追加进表，不动已有行（保留你改的状态）
#   sync_schedule.sh refresh   每周一全量刷新：清空本周表，重新拉本周全部日程
#
# 设计：
# - 一行一个日程，event_id 做去重键
# - append 模式：只加表里没有的 event_id（新约的会/新加的日程），已有行原样保留 → 你手动改的「已完成」不会被覆盖
# - refresh 模式：清空重灌（周一换周用），状态回到「待办」
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

MODE="${1:-append}"
SCHED_TABLE_ID="${SCHEDULE_TABLE_ID:-}"
if [ -z "$SCHED_TABLE_ID" ]; then
  echo "[sched][ERROR] config.env 里没配 SCHEDULE_TABLE_ID"; exit 1
fi

lark-cli profile use "$LARK_PROFILE" >/dev/null 2>&1 || true

# ---------- 本周日期范围（周一~周日，含今天所在周）----------
TODAY=$(date '+%Y-%m-%d'); DOW=$(date '+%u')   # 1=周一..7=周日
MON=$(date -d "$TODAY -$((DOW-1)) days" '+%Y-%m-%d')
SUN=$(date -d "$MON +6 days" '+%Y-%m-%d')
echo "[sched] 模式=$MODE  本周: $MON ~ $SUN"

WD_CN=(周一 周二 周三 周四 周五 周六 周日)

# ---------- 拉本周全部日程 ----------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
lark-cli calendar +agenda --as user \
  --start "${MON}T00:00:00+08:00" --end "${SUN}T23:59:59+08:00" \
  --format json 2>/dev/null > "$TMP/week.json" || echo '{}' > "$TMP/week.json"

EVENT_N=$(jq -r '(.data // []) | length' "$TMP/week.json" 2>/dev/null || echo 0)
echo "[sched] 本周日程 $EVENT_N 个"

# ---------- refresh 模式：先清空本周表 ----------
if [ "$MODE" = "refresh" ]; then
  echo "[sched] refresh：清空「本周行程」表..."
  lark-cli base +record-list --base-token "$BASE_TOKEN" --table-id "$SCHED_TABLE_ID" \
    --limit 200 --format json --as user 2>/dev/null > "$TMP/old.json" || echo '{}' > "$TMP/old.json"
  OLD_IDS=$(jq -r '(.data.record_id_list // [])[]' "$TMP/old.json" 2>/dev/null || true)
  if [ -n "$OLD_IDS" ]; then
    # 拼接可重复的 --record-id 参数
    DEL_ARGS=()
    while IFS= read -r rid; do [ -n "$rid" ] && DEL_ARGS+=(--record-id "$rid"); done <<< "$OLD_IDS"
    lark-cli base +record-delete --base-token "$BASE_TOKEN" --table-id "$SCHED_TABLE_ID" \
      "${DEL_ARGS[@]}" --yes --as user >/dev/null 2>&1 \
      || echo "[sched][WARN] 清空可能未完全成功，继续"
    echo "[sched] 已清空旧行 $(echo "$OLD_IDS" | wc -l | tr -d ' ') 条"
  fi
  SEEN_EVENTS=""   # 清空后全部视为新
else
  # append 模式：读现有 event_id，避免重复
  lark-cli base +record-list --base-token "$BASE_TOKEN" --table-id "$SCHED_TABLE_ID" \
    --limit 200 --format json --as user 2>/dev/null > "$TMP/exist.json" || echo '{}' > "$TMP/exist.json"
  SEEN_EVENTS=$(jq -r '
    .data.fields as $cols | (.data.data // [])
    | map(([$cols, .] | transpose | map({(.[0]):.[1]}) | add) | .["event_id"] // empty)
    | .[]
  ' "$TMP/exist.json" 2>/dev/null || true)
fi

# ---------- 组装行 ----------
# 类型粗分类（按标题关键词）
classify() {
  case "$1" in
    *面试*|*沟通*Go*|*后端*|*招聘*|*述职*) echo "面试" ;;
    *需求*|*复星*|*客户*) echo "需求沟通" ;;
    *会*|*对齐*|*排期*|*评审*) echo "会议" ;;
    *CHK*|*内部*|*复盘*|*总结*) echo "内部" ;;
    *) echo "其他" ;;
  esac
}

FIELDS='["日程主题","日期","星期","时间","类型","状态","视频","日程链接","event_id"]'
ROWS="$TMP/rows.jsonl"; : > "$ROWS"
: > "$TMP/addcount"; : > "$TMP/skipcount"
ADD=0; SKIP=0

# 逐条处理
jq -c '(.data // [])[]' "$TMP/week.json" 2>/dev/null | while IFS= read -r ev; do
  eid=$(echo "$ev" | jq -r '.event_id // ""')
  [ -z "$eid" ] && continue
  # append 模式跳过已存在
  if [ "$MODE" != "refresh" ] && echo "$SEEN_EVENTS" | grep -qxF "$eid"; then
    echo "SKIP" >> "$TMP/skipcount"; continue
  fi

  summary=$(echo "$ev" | jq -r '.summary // "(无标题)"')
  sdt=$(echo "$ev" | jq -r '.start_time.datetime // ""')      # 2026-07-03T14:00:00+08:00
  edt=$(echo "$ev" | jq -r '.end_time.datetime // ""')
  sdate=$(echo "$sdt" | cut -dT -f1)                          # 2026-07-03
  stime=$(echo "$sdt" | cut -dT -f2 | cut -c1-5)              # 14:00
  etime=$(echo "$edt" | cut -dT -f2 | cut -c1-5)
  timerange="${stime}-${etime}"
  # 星期
  wdnum=$(date -d "$sdate" '+%u' 2>/dev/null || echo 1)
  weekcn="${WD_CN[$((wdnum-1))]}"
  # 日期写成 datetime 字符串（当天 00:00）
  datestr="${sdate} 00:00:00"
  # 视频
  has_vc=$(echo "$ev" | jq -r 'if .vchat.meeting_url then "true" else "false" end')
  vc_url=$(echo "$ev" | jq -r '.vchat.meeting_url // ""')
  # 链接：优先视频会议链接，否则日程 app_link
  applink=$(echo "$ev" | jq -r '.app_link // ""')
  link="$applink"
  ctype=$(classify "$summary")

  jq -cn --arg t "$summary" --arg d "$datestr" --arg w "$weekcn" --arg tr "$timerange" \
    --arg ct "$ctype" --arg st "待办" --argjson vc "$has_vc" --arg link "$link" --arg eid "$eid" \
    '[$t,$d,$w,$tr,$ct,$st,$vc,$link,$eid]' >> "$ROWS"
  echo "ADD" >> "$TMP/addcount"
done

ADD=$(wc -l < "$TMP/addcount" 2>/dev/null | tr -d ' ' || echo 0)
SKIP=$(wc -l < "$TMP/skipcount" 2>/dev/null | tr -d ' ' || echo 0)
echo "[sched] 新增 $ADD 条，跳过已存在 $SKIP 条"

if [ "$ADD" -eq 0 ]; then echo "[sched] 无新日程需写入"; exit 0; fi

# ---------- 批量写入 ----------
ROWS_JSON=$(jq -s '.' "$ROWS")
PAYLOAD=$(jq -cn --argjson fields "$FIELDS" --argjson rows "$ROWS_JSON" '{fields:$fields,rows:$rows}')
RESULT=$(lark-cli base +record-batch-create --base-token "$BASE_TOKEN" --table-id "$SCHED_TABLE_ID" --json "$PAYLOAD" --as user 2>&1) \
  || { echo "[sched][ERROR] 写入失败: $RESULT"; exit 1; }
CREATED=$(echo "$RESULT" | jq -r '.data.record_id_list | length' 2>/dev/null || echo "?")
echo "[sched] ✅ 写入 $CREATED 条日程"
