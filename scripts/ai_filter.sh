#!/usr/bin/env bash
# ai_filter.sh — 用 MiniMax M3 对候选消息做"是否真任务"二次筛选（中等力度）+ 自动归档项目
# 输入：stdin 读 JSONL，每行 {"i":int,"chat":str,"from":str,"text":str}
# 输出：stdout 一个 JSON 数组 [{"i","is_task","uncertain","clean_title","due_hint","project"}]
# 分块处理（每块 CHUNK 条），避免单次输出超 token 被截断
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.env"
export PATH="$HOME/.npm-global/bin:$PATH"

: "${MINIMAX_API_KEY:?需要在环境或 config.env 里设置 MINIMAX_API_KEY}"
API_HOST="${MINIMAX_API_HOST:-api.minimax.chat}"
MODEL="${MINIMAX_MODEL:-MiniMax-M3}"
MY="${MY_NAME:-我}"
CHUNK="${AI_FILTER_CHUNK:-15}"
AUTO_PROJECT="${AUTO_PROJECT:-false}"
PROJECT_FIELD="${PROJECT_FIELD:-所属项目}"

INPUT=$(jq -sc '.' 2>/dev/null) || INPUT="[]"
N=$(echo "$INPUT" | jq 'length')
if [ "$N" -eq 0 ]; then echo "[]"; exit 0; fi

# 项目白名单（从 config 的 PROJECT_WHITELIST 读，分号分隔）—— AI 只能从这里选
PROJECTS_JSON="[]"
if [ "$AUTO_PROJECT" = "true" ] && [ -n "${PROJECT_WHITELIST:-}" ]; then
  PROJECTS_JSON=$(printf '%s' "$PROJECT_WHITELIST" | jq -Rc 'split(";") | map(select(length>0))' 2>/dev/null) || PROJECTS_JSON="[]"
  [ -z "$PROJECTS_JSON" ] && PROJECTS_JSON="[]"
fi
PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')

# 根据是否开启自动归档，动态拼 system prompt
PROJ_INSTR=""
OUT_SHAPE='[{"i":0,"is_task":true,"uncertain":false,"clean_title":"...","due_hint":""}]'
if [ "$AUTO_PROJECT" = "true" ] && [ "$PROJ_COUNT" -gt 0 ]; then
  PROJ_LIST=$(echo "$PROJECTS_JSON" | jq -r 'join("、")')
  PROJ_INSTR="
- project：从以下项目列表里选一个最匹配的填入（必须原样照抄列表里的名字，不要自创）；实在无法归类就填空串。
  项目列表：${PROJ_LIST}"
  OUT_SHAPE='[{"i":0,"is_task":true,"uncertain":false,"clean_title":"...","due_hint":"","project":""}]'
fi

SYS="你是任务筛选助手。判断每条飞书消息是否需要\"${MY}\"本人采取行动（需要TA回复/决策/执行/跟进/确认）。

判定力度=中等：
- 明确需要${MY}行动的 → is_task=true, uncertain=false
- 明显是通知/汇报/发布/闭环结果/寒暄/表情 → is_task=false
- 模棱两可、拿不准的 → is_task=true, uncertain=true

对每条还要：
- clean_title：提炼成简洁任务，≤25字，动词开头，别照抄原文
- due_hint：时间提示（今天/明天/本周/周五/日期），没有就空串${PROJ_INSTR}

严格只输出JSON数组，不要markdown，不要解释。必须覆盖输入的每个i。"

process_chunk() {
  local chunk_json="$1"
  local user="待判断消息（JSON数组，i是序号）：
${chunk_json}

严格按格式：${OUT_SHAPE}"
  local payload resp content clean parsed
  payload=$(jq -cn --arg m "$MODEL" --arg s "$SYS" --arg u "$user" \
    '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],max_tokens:8000,temperature:0.1}')
  resp=$(curl -s -m 120 -X POST "https://${API_HOST}/v1/text/chatcompletion_v2" \
    -H "Authorization: Bearer $MINIMAX_API_KEY" -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || { echo "[ai_filter] curl 失败" >&2; echo "[]"; return; }
  content=$(echo "$resp" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
  if [ -z "$content" ]; then
    echo "[ai_filter] chunk 无返回: $(echo "$resp" | jq -c '.base_resp,.choices[0].finish_reason' 2>/dev/null)" >&2
    echo "[]"; return
  fi
  clean=$(echo "$content" | sed -E 's/^```json//; s/^```//; s/```$//' | tr -d '\r')
  parsed=$(echo "$clean" | jq -c '.' 2>/dev/null) || parsed=""
  if [ -z "$parsed" ]; then
    parsed=$(echo "$clean" | grep -ozP '(?s)\[.*\]' | tr -d '\0' | jq -c '.' 2>/dev/null) || parsed="[]"
  fi
  echo "$parsed"
}

# 分块 + 合并
ALL="[]"
OFFSET=0
while [ "$OFFSET" -lt "$N" ]; do
  CHUNK_JSON=$(echo "$INPUT" | jq -c ".[$OFFSET:$((OFFSET+CHUNK))]")
  echo "[ai_filter] 处理 $OFFSET..$((OFFSET+CHUNK)) / $N" >&2
  PART=$(process_chunk "$CHUNK_JSON")
  # 合并（PART 里的 i 是全局序号，因为切片没重编号）
  ALL=$(jq -cn --argjson a "$ALL" --argjson b "$PART" '$a + ($b // [])')
  OFFSET=$((OFFSET+CHUNK))
done

echo "$ALL"
