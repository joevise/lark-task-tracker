#!/usr/bin/env bash
# scan.sh — 扫描近 N 天「@我的」+「我承诺的」消息，AI 二次筛选后写入多维表格
# 用法: scan.sh [days]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

DAYS="${1:-$SCAN_DAYS}"
mkdir -p "$STATE_DIR"
SEEN_FILE="$STATE_DIR/seen_message_ids.txt"
touch "$SEEN_FILE"

START=$(date -d "${DAYS} days ago" '+%Y-%m-%dT%H:%M:%S%:z')
END=$(date '+%Y-%m-%dT%H:%M:%S%:z')
TODAY=$(date '+%Y-%m-%d %H:%M:%S')

echo "[scan] profile=$LARK_PROFILE 窗口: $START → $END | AI筛选=${AI_FILTER:-false}"
lark-cli profile use "$LARK_PROFILE" >/dev/null 2>&1 || true

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------- 1. 拉「@我的」消息 ----------
echo "[scan] 拉取 @我的 消息..."
lark-cli im +messages-search --is-at-me \
  --start "$START" --end "$END" \
  --page-all --page-size 50 --as user \
  --no-reactions 2>/dev/null \
  | jq -c '.data.messages[]? | select(.deleted==false)' > "$TMP/at_me.jsonl" || true
echo "[scan] @我的 命中 $(wc -l < "$TMP/at_me.jsonl" | tr -d ' ') 条"

# ---------- 2. 拉「我承诺的」= 我发出的含承诺语气的消息 ----------
echo "[scan] 拉取 我发出的 消息（筛承诺）..."
lark-cli im +messages-search \
  --sender "$MY_OPEN_ID" --sender-type user \
  --start "$START" --end "$END" \
  --page-all --page-size 50 --as user \
  --no-reactions 2>/dev/null \
  | jq -c '.data.messages[]? | select(.deleted==false)' > "$TMP/by_me_all.jsonl" || true

PROMISE_RE='我来|我去|我跟进|我处理|我负责|我搞定|我明天|我后天|我下周|我这周|我今天|我这边|我安排|我推进|我催|我确认|我落实|我准备|我整理|我发给|我发个|我给你|我出个|我做个|我写个|我对接|我约|我联系|我盯|我复盘|我总结|我更新|我补充|我核实|会尽快|尽快给|马上给|待会给|回头给'
jq -c 'select((.content // "") | test("'"$PROMISE_RE"'"))' "$TMP/by_me_all.jsonl" > "$TMP/by_me.jsonl" || true
echo "[scan] 我承诺的 命中 $(wc -l < "$TMP/by_me.jsonl" | tr -d ' ') 条"

# ---------- 3. 收集候选（去重 + 去噪音），存元数据 ----------
clean_content() { echo "$1" | sed -E 's/<[^>]+>//g' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g'; }

META="$TMP/meta.jsonl"        # 每行：候选完整元数据 + 临时序号 i
CAND="$TMP/candidates.jsonl"  # 每行：喂给 AI 的 {i,chat,from,text}
: > "$META"; : > "$CAND"
IDX=0

collect() {
  local line="$1" src_type="$2"
  local mid msg_type chat_id chat_name content applink sender_name stripped
  mid=$(echo "$line" | jq -r '.message_id')
  grep -qxF "$mid" "$SEEN_FILE" && return
  msg_type=$(echo "$line" | jq -r '.msg_type // "text"')
  case "$msg_type" in image|sticker|audio|media) echo "$mid" >> "$SEEN_FILE"; return ;; esac
  content=$(clean_content "$(echo "$line" | jq -r '.content // ""')")
  stripped=$(echo "$content" | sed -E 's/!\[[Ii]mage\]\([^)]*\)//g; s/!\[[^]]*\]//g; s/\[图片\]//g; s/img_v[0-9a-z_-]*//g; s/[[:space:]]//g')
  [ -z "$stripped" ] && { echo "$mid" >> "$SEEN_FILE"; return; }

  chat_id=$(echo "$line" | jq -r '.chat_id // ""')
  chat_name=$(echo "$line" | jq -r '.chat_name // "私聊"')
  # 直达单条消息的 applink（openChatId + openMessageId，官方支持 3.9.0+）
  if [ -n "$chat_id" ]; then
    applink="https://applink.feishu.cn/client/chat/open?openChatId=${chat_id}&openMessageId=${mid}"
  else
    applink=$(echo "$line" | jq -r '.message_app_link // ""')
  fi
  if [ "$src_type" = "@我的" ]; then sender_name=$(echo "$line" | jq -r '.sender.name // "未知"'); else sender_name="$MY_NAME"; fi

  jq -cn --argjson i "$IDX" --arg mid "$mid" --arg src "$src_type" --arg chat "$chat_name" \
    --arg sender "$sender_name" --arg raw "$content" --arg link "$applink" \
    '{i:$i,mid:$mid,src:$src,chat:$chat,sender:$sender,raw:$raw,link:$link}' >> "$META"
  jq -cn --argjson i "$IDX" --arg chat "$chat_name" --arg from "$sender_name" --arg text "$content" \
    '{i:$i,chat:$chat,from:$from,text:$text}' >> "$CAND"
  IDX=$((IDX+1))
}

while IFS= read -r l; do [ -n "$l" ] && collect "$l" "@我的"; done < "$TMP/at_me.jsonl"
while IFS= read -r l; do [ -n "$l" ] && collect "$l" "我承诺的"; done < "$TMP/by_me.jsonl"
echo "[scan] 去重去噪后候选 $IDX 条"

if [ "$IDX" -eq 0 ]; then echo "[scan] 无新候选，结束"; exit 0; fi

# ---------- 4. AI 二次筛选（决定 keep + clean_title + due_hint + project）----------
DECISION="$TMP/decision.json"   # {i: {keep,title,due,uncertain,project}}
if [ "${AI_FILTER:-false}" = "true" ]; then
  echo "[scan] 调用 MiniMax 筛选..."
  FILTER_OUT=$(cat "$CAND" | bash "$SKILL_DIR/scripts/ai_filter.sh" 2>>"$TMP/ai_err.log") || FILTER_OUT="[]"
  # 转成 map: i -> 决策
  echo "$FILTER_OUT" | jq -c '
    map({(.i|tostring): {keep:(.is_task==true), title:(.clean_title // ""), due:(.due_hint // ""), uncertain:(.uncertain==true), project:(.project // "")}}) | add // {}
  ' > "$DECISION" 2>/dev/null || echo '{}' > "$DECISION"
  DEC_N=$(jq 'length' "$DECISION" 2>/dev/null || echo 0)
  if [ "$DEC_N" -eq 0 ]; then
    echo "[scan][WARN] AI 筛选无有效返回，降级为全量入表。错误: $(cat "$TMP/ai_err.log" 2>/dev/null | head -2)"
    echo '{}' > "$DECISION"
    AI_FILTER="fallback"
  fi
else
  echo '{}' > "$DECISION"
fi

# 加载项目白名单（用于校验 AI 返回的 project，不在名单里的一律置空，避免 M3 自创项目）
VALID_PROJECTS="[]"
if [ "${AUTO_PROJECT:-false}" = "true" ] && [ -n "${PROJECT_WHITELIST:-}" ]; then
  VALID_PROJECTS=$(printf '%s' "$PROJECT_WHITELIST" | jq -Rc 'split(";") | map(select(length>0))' 2>/dev/null) || VALID_PROJECTS="[]"
  [ -z "$VALID_PROJECTS" ] && VALID_PROJECTS="[]"
fi

# ---------- 5. 组装入表行（按决策）----------
utf8cut() { jq -rn --arg s "$1" '$s[0:40]'; }
ROWS="$TMP/rows.jsonl"; : > "$ROWS"
KEEP=0; DROP=0
# 是否开启项目列（影响 FIELDS 和每行长度）
if [ "${AUTO_PROJECT:-false}" = "true" ]; then
  FIELDS='["任务","状态","来源类型","来源群聊","提出人","原始消息","消息链接","录入日期","截止日期","'"${PROJECT_FIELD:-所属项目}"'"]'
else
  FIELDS='["任务","状态","来源类型","来源群聊","提出人","原始消息","消息链接","录入日期","截止日期"]'
fi

while IFS= read -r m; do
  [ -z "$m" ] && continue
  i=$(echo "$m" | jq -r '.i'); mid=$(echo "$m" | jq -r '.mid')
  raw=$(echo "$m" | jq -r '.raw'); src=$(echo "$m" | jq -r '.src')
  chat=$(echo "$m" | jq -r '.chat'); sender=$(echo "$m" | jq -r '.sender'); link=$(echo "$m" | jq -r '.link')

  keep="true"; title=""; due=""; uncertain="false"; project=""
  if [ "${AI_FILTER:-false}" = "true" ]; then
    d=$(jq -c --arg k "$i" '.[$k] // empty' "$DECISION")
    if [ -n "$d" ]; then
      keep=$(echo "$d" | jq -r '.keep'); title=$(echo "$d" | jq -r '.title')
      due=$(echo "$d" | jq -r '.due'); uncertain=$(echo "$d" | jq -r '.uncertain')
      project=$(echo "$d" | jq -r '.project // ""')
    else
      keep="true"; uncertain="true"   # AI 漏判的，保守留下并标待确认
    fi
  fi

  # 标记已处理（无论留不留，都不再重复扫）
  echo "$mid" >> "$SEEN_FILE"

  if [ "$keep" != "true" ]; then DROP=$((DROP+1)); continue; fi

  # 标题：优先 AI 提炼，否则截断原文
  if [ -n "$title" ] && [ "$title" != "null" ]; then
    [ "$uncertain" = "true" ] && title="❓$title"
  else
    title=$(utf8cut "$raw"); [ -z "$title" ] && title="(空消息)"
    [ "$uncertain" = "true" ] && title="❓$title"
  fi

  # 截止日期：把 due_hint 转成具体日期（今天/明天/后天）
  due_date=""
  case "$due" in
    *今天*|*today*) due_date=$(date '+%Y-%m-%d %H:%M:%S') ;;
    *明天*|*tomorrow*) due_date=$(date -d 'tomorrow' '+%Y-%m-%d %H:%M:%S') ;;
    *后天*) due_date=$(date -d '2 days' '+%Y-%m-%d %H:%M:%S') ;;
    *) due_date="" ;;
  esac

  # 项目归档：校验 AI 返回的 project 是否在有效选项里，不是就置空
  if [ "${AUTO_PROJECT:-false}" = "true" ] && [ -n "$project" ] && [ "$project" != "null" ]; then
    ok_proj=$(echo "$VALID_PROJECTS" | jq --arg p "$project" 'index($p) != null')
    [ "$ok_proj" != "true" ] && project=""
  else
    project=""
  fi

  if [ "${AUTO_PROJECT:-false}" = "true" ]; then
    jq -cn --arg task "$title" --arg status "待办" --arg src "$src" --arg chat "$chat" \
      --arg sender "$sender" --arg raw "$raw" --arg link "$link" --arg entered "$TODAY" --arg due "$due_date" --arg proj "$project" \
      '[$task,$status,$src,$chat,$sender,$raw,$link,$entered,(if $due=="" then null else $due end),(if $proj=="" then null else $proj end)]' >> "$ROWS"
  else
    jq -cn --arg task "$title" --arg status "待办" --arg src "$src" --arg chat "$chat" \
      --arg sender "$sender" --arg raw "$raw" --arg link "$link" --arg entered "$TODAY" --arg due "$due_date" \
      '[$task,$status,$src,$chat,$sender,$raw,$link,$entered,(if $due=="" then null else $due end)]' >> "$ROWS"
  fi
  KEEP=$((KEEP+1))
done < "$META"

echo "[scan] AI 判定：保留 $KEEP 条，丢弃 $DROP 条"
if [ "$KEEP" -eq 0 ]; then echo "[scan] 无任务需入表，结束"; exit 0; fi

# ---------- 6. 批量写入 ----------
ROWS_JSON=$(jq -s '.' "$ROWS")
PAYLOAD=$(jq -cn --argjson fields "$FIELDS" --argjson rows "$ROWS_JSON" '{fields:$fields,rows:$rows}')
echo "[scan] 写入多维表格..."
RESULT=$(lark-cli base +record-batch-create --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --json "$PAYLOAD" --as user 2>&1) \
  || { echo "[scan][ERROR] 写入失败: $RESULT"; exit 1; }
CREATED=$(echo "$RESULT" | jq -r '.data.record_id_list | length' 2>/dev/null || echo "?")
echo "[scan] ✅ 成功写入 $CREATED 条任务"
