#!/bin/sh
# ccwhere.sh — Claude Code 활성 세션 라이브 모니터 (macOS / jq)
#
# 사용법:
#   chmod +x ccwhere.sh
#   ./ccwhere.sh
#   DEBUG=1 ./ccwhere.sh           # jq 에러 메시지 표시
#   MSG_MAX=120 ./ccwhere.sh       # LAST_MSG 폭 직접 지정
#
# 의존성: jq, BSD stat/find (macOS 기본)
#
# 환경변수:
#   CUTOFF_MIN   표시 윈도우 (기본 1440 = 24h)
#   ACTIVE_SEC   active 기준 (기본 60s)
#   RECENT_SEC   recent 기준 (기본 600s = 10m)
#   REFRESH_SEC  갱신 주기 (기본 5s)
#   TAIL_LINES   각 세션 파일에서 읽을 마지막 줄 수 (기본 300)
#   MSG_MAX      LAST_MSG 최대 폭 (기본: 자동 = 터미널 폭 기반)
#   DEBUG        1이면 jq 에러를 stderr로 노출

set -u

ROOT="$HOME/.claude/projects"
CUTOFF_MIN=${CUTOFF_MIN:-1440}
ACTIVE_SEC=${ACTIVE_SEC:-60}
RECENT_SEC=${RECENT_SEC:-600}
REFRESH_SEC=${REFRESH_SEC:-5}
TAIL_LINES=${TAIL_LINES:-300}

RST=$(printf '\033[0m')
BLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
GRN=$(printf '\033[32m')
YLW=$(printf '\033[33m')
GRY=$(printf '\033[90m')

if ! command -v jq >/dev/null 2>&1; then
  printf 'Error: jq가 필요합니다. brew install jq\n' >&2
  exit 1
fi

TAB=$(printf '\t')
WIN_HOURS=$((CUTOFF_MIN / 60))

# ---------------------------------------------------------------------------
# jq 스크립트 분리 (shell expansion 회피)
# ★ jq는 16진수 리터럴(0x7F 등)을 지원하지 않으므로 십진수만 사용한다.
#    Codepoint 256 이상이면 display width 2칸으로 추정한다
#    (ASCII + Latin-1 = 1칸, 한글/한자/일본어/이모지 등 = 2칸).
# ---------------------------------------------------------------------------
JQ_LAST_MSG=$(mktemp -t ccwhere-jq-msg.XXXXXX) || exit 1
JQ_MODEL=$(mktemp -t ccwhere-jq-model.XXXXXX) || exit 1

cat > "$JQ_LAST_MSG" <<'JQEOF'
def cw: if . > 255 then 2 else 1 end;

def trunc_w($max):
  . as $orig
  | ([$orig | explode[] | cw] | add // 0) as $tw
  | if $tw <= $max then $orig
    else
      ($orig | explode
       | reduce .[] as $c ({c: [], w: 0, d: false};
           if .d then .
           else (($c | cw) as $cw
                 | if .w + $cw > ($max - 1)
                   then .d = true
                   else {c: (.c + [$c]), w: (.w + $cw), d: false}
                   end)
           end)
       | (.c | implode) + "…")
    end;

[ .[]
  | select(.type == "user")
  | (.message? // {}) | .content
  | if   . == null      then ""
    elif type == "string" then .
    elif type == "array"  then ([.[] | select(.type? == "text") | .text? // ""] | join(" "))
    else "" end
]
| map(select(. != null and . != ""))
| map(gsub("[[:space:]]+"; " "))
| map(select(
    (startswith("<command-")            | not) and
    (startswith("<local-command-")      | not) and
    (startswith("<system-")             | not) and
    (startswith("<bash-")               | not) and
    (startswith("[Request interrupted") | not) and
    (startswith("Caveat:")              | not)
  ))
| if length > 0
  then (.[-1] | trunc_w($max))
  else ""
  end
JQEOF

cat > "$JQ_MODEL" <<'JQEOF'
[ .[] | select(.type == "assistant" and (.message?.model // empty)) ]
| if length > 0 then .[-1].message.model else "?" end
JQEOF

# ---------------------------------------------------------------------------
# 정리
# ---------------------------------------------------------------------------
cleanup() {
  rm -f "$JQ_LAST_MSG" "$JQ_MODEL"
  printf '\033[?25h'
  printf '\n  %s종료%s\n' "$DIM" "$RST"
}
trap 'exit 130' INT TERM
trap cleanup EXIT

printf '\033[2J\033[H\033[?25l'

jq_run() {
  if [ "${DEBUG:-0}" = "1" ]; then
    jq "$@"
  else
    jq "$@" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# 터미널 크기 측정 — command substitution 안에서도 안전하게 동작하려면
# tput보다 stty size < /dev/tty가 더 견고하다.
# ---------------------------------------------------------------------------
get_term_size() {
  _sz=$(stty size < /dev/tty 2>/dev/null) || _sz=""
  if [ -z "$_sz" ]; then
    _sz="30 120"
  fi
  rows=${_sz% *}
  cols=${_sz#* }
  # 숫자 sanity check
  case "$rows" in (*[!0-9]*|"") rows=30 ;; esac
  case "$cols" in (*[!0-9]*|"") cols=120 ;; esac
}

# ---------------------------------------------------------------------------
# 한 프레임 빌드
# ---------------------------------------------------------------------------
build_frame() {
  now=$(date +%s)

  get_term_size  # rows, cols 변수 갱신

  if [ "${MSG_MAX:-0}" -gt 0 ] 2>/dev/null; then
    msg_max=$MSG_MAX
  else
    msg_max=$((cols - 50))
    [ "$msg_max" -lt 20 ] && msg_max=20
    [ "$msg_max" -gt 200 ] && msg_max=200
  fi

  # 헤더(2줄) + 푸터(2줄) = 4줄 차감, 잘림 표시 여유 1줄
  max_data=$((rows - 5))
  [ "$max_data" -lt 3 ] && max_data=3

  printf '  %sClaude Code Sessions%s  %s·  %s  ·  최근 %dh%s\033[K\n\033[K\n' \
    "$BLD" "$RST" "$DIM" "$(date '+%H:%M')" "$WIN_HOURS" "$RST"

  TMP=$(mktemp -t ccwhere.XXXXXX) || return 1

  find "$ROOT" -name '*.jsonl' -mmin "-$CUTOFF_MIN" -type f 2>/dev/null | \
  while IFS= read -r f; do
    mtime=$(stat -f %m "$f" 2>/dev/null) || continue
    age=$((now - mtime))

    proj=$(basename "$(dirname "$f")")
    proj=${proj#-}
    proj=$(printf '%s' "$proj" | sed 's|-|/|g')
    proj=$(basename "$proj")
    [ -z "$proj" ] && proj=' '

    msgs=$(wc -l < "$f" | tr -d ' ')

    if   [ "$age" -lt "$ACTIVE_SEC" ]; then status='● active'
    elif [ "$age" -lt "$RECENT_SEC" ]; then status='◐ recent'
    else                                    status='○ idle'
    fi

    if   [ "$age" -lt 60 ];    then last="${age}s ago"
    elif [ "$age" -lt 3600 ];  then last="$((age/60))m ago"
    elif [ "$age" -lt 86400 ]; then last="$((age/3600))h ago"
    else                            last="$((age/86400))d ago"
    fi

    model=$(tail -n "$TAIL_LINES" "$f" | jq_run -rs -f "$JQ_MODEL")
    [ -z "$model" ] && model='?'
    model=$(printf '%s' "$model" | sed -E '
      s|^claude-||
      s|-20[0-9]+.*||
    ')

    last_msg=$(tail -n "$TAIL_LINES" "$f" | \
      jq_run -rs --argjson max "$msg_max" -f "$JQ_LAST_MSG")
    last_msg=$(printf '%s' "${last_msg:-}" | tr '\t' ' ')

    printf '%010d%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$age" "$TAB" \
      "$proj"     "$TAB" \
      "$status"   "$TAB" \
      "$last"     "$TAB" \
      "$model"    "$TAB" \
      "$msgs"     "$TAB" \
      "$last_msg" >> "$TMP"
  done

  total=$(wc -l < "$TMP" 2>/dev/null | tr -d ' ')
  total=${total:-0}

  if [ "$total" -eq 0 ]; then
    printf '  %s(최근 %dh 활성 세션 없음)%s\033[K\n' "$DIM" "$WIN_HOURS" "$RST"
  else
    {
      printf 'PROJECT%sSTATUS%sLAST%sMODEL%sMSGS%sLAST_MSG\n' \
        "$TAB" "$TAB" "$TAB" "$TAB" "$TAB"
      sort -k1 -n "$TMP" | cut -f2- | head -n "$max_data"
    } | column -t -s "$TAB" \
      | sed -e "s/● active/${GRN}● active${RST}/" \
            -e "s/◐ recent/${YLW}◐ recent${RST}/" \
            -e "s/○ idle/${GRY}○ idle${RST}/" \
      | awk -v BLD="$BLD" -v RST="$RST" '
          NR==1 { print "  " BLD $0 RST "\033[K"; next }
                { print "  " $0 "\033[K" }
        '

    if [ "$total" -gt "$max_data" ]; then
      printf '  %s… +%d more (창을 더 키우면 모두 보입니다)%s\033[K\n' \
        "$DIM" "$((total - max_data))" "$RST"
    fi
  fi

  rm -f "$TMP"

  printf '\033[K  %s%dx%d · Ctrl+C 종료 · %ds 갱신%s\033[K\n' \
    "$DIM" "$rows" "$cols" "$REFRESH_SEC" "$RST"
}

while true; do
  frame=$(build_frame)
  printf '\033[H%s\033[J' "$frame"
  sleep "$REFRESH_SEC"
done
