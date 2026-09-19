#!/bin/bash
# ============================================================
#  Codex Nerf Detector  v2.0
#
#  Detects when Codex serves a request with a weaker model than the
#  one that was asked for.
#
#  v2.0 adds:
#    - language selection (Chinese / English)
#    - model list read from ~/.codex/models_cache.json (no request)
#    - one-click full sweep across every model
#    - a summary table at the end
#
#  All paths derive from $HOME and from this script's own location,
#  so nothing is hard-coded to a particular user.
# ============================================================

# Windows only: switch the console to UTF-8. This MUST NOT live in the
# .bat - cmd loses its read position when the codepage changes mid-batch
# and then truncates the following lines. On macOS/Linux chcp does not
# exist and the terminal is already UTF-8.
command -v chcp.com >/dev/null 2>&1 && chcp.com 65001 >/dev/null 2>&1

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

CODEX_DIR="$HOME/AppData/Local/OpenAI/Codex/bin"
CONF="$HOME/.codex/config.toml"
AUTH="$HOME/.codex/auth.json"
CACHE="$HOME/.codex/models_cache.json"
LOG="/tmp/codex_nerf_check.log"
WORKDIR="/tmp/codexcheck"
RECORD="$SELF_DIR/check-records.txt"

# Seconds allowed per model before the run is abandoned and marked as a
# timeout. A normal request takes 20-60s.
PER_MODEL_TIMEOUT="${PER_MODEL_TIMEOUT:-180}"

# ------------------------------------------------------------
# Portability helpers (Windows Git Bash / macOS / Linux)
# ------------------------------------------------------------

# GNU stat takes -c, BSD/macOS stat takes -f. Return mtime, or 0.
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# macOS ships no `timeout` unless coreutils is installed (as gtimeout).
# Fall back to a background job plus a watchdog so the cap still holds.
run_timed() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return $?
    fi
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    [ "$rc" -ge 128 ] && return 124
    return "$rc"
}

# Locate the codex executable. Windows keeps it under a hash-named
# directory inside the desktop app's bin folder; macOS puts a plain
# `codex` in one of several bin directories.
find_codex() {
    local c newest t
    c=$(command -v codex 2>/dev/null)
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi

    # Windows: newest hash directory wins
    newest=0
    for f in "$CODEX_DIR"/*/codex.exe; do
        [ -f "$f" ] || continue
        t=$(file_mtime "$f")
        if [ "$t" -gt "$newest" ]; then newest="$t"; c="$f"; fi
    done
    if [ -n "$c" ] && [ -f "$c" ]; then echo "$c"; return 0; fi

    # macOS
    for f in \
        "$HOME/.local/bin/codex" \
        "/opt/homebrew/bin/codex" \
        "/usr/local/bin/codex" \
        "/Applications/ChatGPT.app/Contents/Resources/codex" \
        "/Applications/Codex.app/Contents/Resources/codex" \
        "$HOME/.codex/bin/codex" \
        ; do
        [ -x "$f" ] && { echo "$f"; return 0; }
    done

    return 1
}

# ============================================================
# 1. LANGUAGE
# ============================================================
clear 2>/dev/null
echo "=================================================="
echo "            Codex Nerf Detector"
echo "=================================================="
echo
echo "  Choose your language / 选择语言"
echo
echo "    1) 中文"
echo "    2) English"
echo
echo -n "  > "; read LG
echo

if [ "$LG" = "1" ]; then

T_ACCT_HDR="--- 当前登录 ---"
T_AUTHMODE="认证方式"
T_ACCTID="账号 ID"
T_CFGMODEL="配置的模型"
T_CFGCOUNT="可用模型数"
T_MAIN_HDR="--- 你想做什么 ---"
T_M1="单模型检测     —— 选一个模型测一次"
T_M2="全模型一键检测 —— 逐个测完所有模型（推荐）"
T_M3="只看模型清单   —— 不发请求，不消耗额度"
T_M0="退出"
T_PICK="输入序号后回车： "
T_PICKMODEL="选择要检测的模型"
T_CUSTOM="自定义（手动输入模型名）"
T_Q_ASK="输入序号： "
T_Q_NAME="模型名： "
T_ASKING="正在通过当前账号发送请求..."
T_WAIT="请稍候（约 20~60 秒，消耗一次极小额度）"
T_ACCT_USED="本次使用的账号"
T_PLAN="账号等级"
T_LIMIT="当前限制档"
T_CREDITS="额度余额"
T_RESET="额度重置倒计时"
T_REQUESTED="请求的模型"
T_SERVED="响应里的模型"
T_NOCAP="（没抓到 —— 可能走了 WebSocket，或日志格式变了）"
T_RESULT="判定"
T_YOUASKED="你请求的是"
T_SEEN="响应里出现的模型"
T_WANTED="← 你要的"
T_DOWNGRADE="← 降级款"
T_EVIDENCE="补充证据（都来自同一份 HTTP 响应）"
T_HINT="服务器自己说的路由"
T_HINT_MATCH="（和响应一致）"
T_HINT_CONFLICT="← ⚠️ 服务器说它路由到这里，响应里却找不到它 —— 同一份 HTTP 响应自相矛盾"
T_TTFT="首字延迟"
T_QUEUE="引擎排队"
T_RTOK="推理 token"
T_REPORT="检测报告"
T_G_FULL="满血"
T_G_DILUTED="掺水"
T_G_DOWN="降智"
T_BASIS="判断依据"
T_B1="请求体里写的是（你要的）"
T_B2="响应体里返回的是（实际用的）"
T_B3="服务器自己声明的路由"
T_B4="账号额度余额"
T_B5="额度重置倒计时"
T_CAUSE_CREDITS="账号额度已耗尽 —— 这是旗舰模型被降级的直接原因"
T_CAUSE_UNKNOWN="额度正常，但请求仍被降级 —— 原因不明，这种情况反而更可疑"
T_CONC_FULL="结论：你请求的模型正常服务，没有掺假。"
T_CONC_DILUTED="结论：你请求的模型有参与，但同一个请求里混进了别的模型 —— 不稳定。"
T_CONC_DOWN="结论：你请求的模型完全没有参与这次回答。"
T_CONC_UNKNOWN="结论：没能抓到响应内容，无法判断。"
T_FULL_WARN="⚠️  全模型检测会逐个发请求。"
T_REPEAT_Q="每个模型测几次？"
T_REPEAT_1="1 次   快，但只能证明「发生过」，不能证明「每次都是」"
T_REPEAT_3="3 次   推荐 —— 能看出是偶发还是稳定复现"
T_REPEAT_5="5 次   最有力，但很慢"
T_REPEAT_EACH="每个模型测"
T_EST_TIME="预计耗时约"
T_MINUTES="分钟"
T_FULL_ASK="继续吗？(y/N) "
T_FULL_GO="开始全模型检测"
T_TESTING="正在测试"
T_CONFIRM="确认"
T_NOQUOTA="⚠️  检查记录里包含你的账号邮箱，不要提交到仓库。"
T_SUMMARY="检测汇总"
T_MODEL="模型"
T_ASKED="请求"
T_GOT="实际"
T_VERDICT="判定"
T_NOACC="无权限"
T_TIMEOUT="超时"
T_RECORD="已追加到"
T_LOGFILE="完整日志"
T_EXIT="按回车键退出..."
T_STAFF_Q="你是 OpenAI 的研究人员吗？"
T_STAFF_YES="是"
T_STAFF_NO="不是"
T_ZH_NOTE="（下面这封信是写给 OpenAI 的，用英文写的。按 Q 可直接退出，不消耗额度。）"
T_STAFF_ASK="按回车继续，或输入 Q 退出： "
T_BYE="再见。"
T_AFFECT_Q="你的服务有没有被降级影响？"
T_AFFECT_Y="有"
T_AFFECT_N="没有 / 不确定"
T_AFFECT_NOTE1="记下了。我们来看看你到底拿到了什么。"
T_AFFECT_NOTE2="好，还是测一下。"
T_NOMODELS="模型缓存里没找到模型清单。"
T_NOCACHE="找不到 models_cache.json —— 先运行一次 Codex，让它拉取模型目录。"
T_NOSELECT="没有选择模型。"
T_ERR_REQUEST="请求失败（退出码"
T_ERR_COMMON="常见原因："
T_ERR_R1="这个账号没有该模型的权限（免费号通常只有 gpt-5.6-terra）"
T_ERR_R2="模型名写错"
T_ERR_R3="网络 / 代理不通"
T_ERR_SERVER="服务端返回："
T_ERR_LOG="完整日志"

else

T_ACCT_HDR="--- current session ---"
T_AUTHMODE="auth mode"
T_ACCTID="account id"
T_CFGMODEL="config model"
T_CFGCOUNT="models available"
T_MAIN_HDR="--- what do you want to do ---"
T_M1="Quick check         - test one model"
T_M2="Full sweep          - test every model (recommended)"
T_M3="List models only    - no request, no quota used"
T_M0="quit"
T_PICK="enter a number: "
T_PICKMODEL="choose the model to test"
T_CUSTOM="custom (type a model name)"
T_Q_ASK="enter a number: "
T_Q_NAME="model name: "
T_ASKING="Sending a request through the current account..."
T_WAIT="Please wait (about 20-60 seconds, uses one tiny request)"
T_ACCT_USED="account used"
T_PLAN="plan"
T_LIMIT="active limit"
T_CREDITS="credits balance"
T_RESET="credits reset in"
T_REQUESTED="requested model"
T_SERVED="response model(s)"
T_NOCAP="(not captured - websocket path, or the log format changed)"
T_RESULT="RESULT"
T_YOUASKED="you asked for"
T_SEEN="models seen in the response"
T_WANTED="<- the one you asked for"
T_DOWNGRADE="<- downgrade target"
T_EVIDENCE="additional evidence (all from the same HTTP response)"
T_HINT="server routing hint"
T_HINT_MATCH="(matches the response)"
T_HINT_CONFLICT="<- WARNING: the server says it routed here, but this model is not in the response - the same HTTP response contradicts itself"
T_TTFT="first token"
T_QUEUE="engine queue"
T_RTOK="reasoning tokens"
T_REPORT="REPORT"
T_G_FULL="FULL"
T_G_DILUTED="DILUTED"
T_G_DOWN="DOWNGRADED"
T_BASIS="how this was decided"
T_B1="request body says (what you asked for)"
T_B2="response body says (what actually served)"
T_B3="the server's own routing hint"
T_B4="account credits balance"
T_B5="credits reset in"
T_CAUSE_CREDITS="account credits are exhausted - this is the direct cause of the flagship being rerouted"
T_CAUSE_UNKNOWN="credits look fine, yet the request was still rerouted - cause unknown, and that is the more suspicious case"
T_CONC_FULL="Conclusion: the model you asked for served you, with nothing else mixed in."
T_CONC_DILUTED="Conclusion: your model took part, but other models were mixed into the same request - unstable."
T_CONC_DOWN="Conclusion: the model you asked for took no part in this answer."
T_CONC_UNKNOWN="Conclusion: nothing could be captured, so no judgement is possible."
T_FULL_WARN="WARNING: the full sweep sends real requests."
T_REPEAT_Q="How many times per model?"
T_REPEAT_1="1 time     fast, but only proves it happened, not that it always happens"
T_REPEAT_3="3 times    recommended - shows whether it is occasional or consistent"
T_REPEAT_5="5 times    strongest, but slow"
T_REPEAT_EACH="requests per model"
T_EST_TIME="estimated time"
T_MINUTES="min"
T_FULL_ASK="Continue? (y/N) "
T_FULL_GO="Starting full sweep"
T_TESTING="testing"
T_CONFIRM="confirm"
T_NOQUOTA="NOTE: check-records.txt contains your account email. Do not commit it."
T_SUMMARY="SUMMARY"
T_MODEL="model"
T_ASKED="asked"
T_GOT="served"
T_VERDICT="verdict"
T_NOACC="no access"
T_TIMEOUT="timed out"
T_RECORD="appended to"
T_LOGFILE="full log"
T_EXIT="Press Enter to exit..."
T_STAFF_Q="Are you a member of OpenAI's research staff?"
T_STAFF_YES="yes"
T_STAFF_NO="no"
T_ZH_NOTE="(The letter below is addressed to OpenAI and is in English. Type Q to quit at no cost.)"
T_STAFF_ASK="Press Enter to continue, or type Q to quit: "
T_BYE="Bye."
T_AFFECT_Q="Has your service been affected by model downgrading?"
T_AFFECT_Y="yes"
T_AFFECT_N="no / not sure"
T_AFFECT_NOTE1="Noted. Let's find out exactly what you are getting."
T_AFFECT_NOTE2="Fine - let's check anyway."
T_NOMODELS="No models found in the cache."
T_NOCACHE="models_cache.json not found - run Codex once so it fetches the model catalog."
T_NOSELECT="no model selected."
T_ERR_REQUEST="request failed (exit code"
T_ERR_COMMON="Common causes:"
T_ERR_R1="this account has no access to that model (free accounts usually only get gpt-5.6-terra)"
T_ERR_R2="the model name is wrong"
T_ERR_R3="network / proxy is not working"
T_ERR_SERVER="Server said:"
T_ERR_LOG="full log"

fi

# ============================================================
# 1b. TWO QUICK QUESTIONS
# ============================================================
echo "  $T_STAFF_Q"
echo "        1) $T_STAFF_YES"
echo "        2) $T_STAFF_NO"
echo
echo -n "  > "; read Q1
echo

if [ "$Q1" = "1" ]; then
    [ "$LG" = "1" ] && { echo "  $T_ZH_NOTE"; echo; }
    cat <<'MSG'
  ==============================================================
  Then this folder is addressed to you.
  ==============================================================

  This is not a bug report. It is a receipt.


  WHAT THE TOOL PRINTS
  --------------------------------------------------------------
  On a paying account:

        asked for : gpt-6-astra
        served    : gpt-5.6-luna

  Not once. Not a bad afternoon. Consistently - across prompts,
  across days, across accounts - while the picker kept advertising
  Astra and the invoice kept saying Astra.

  This header arrived in the very same HTTP response:

        x-codex-routing-hint: model=gpt-6-astra

  Your server told the client it was routing to Astra, and then sent
  a body signed by Luna. Both statements are yours. One is not true.


  YOU DELETED THE MIRROR, NOT THE BEHAVIOUR
  --------------------------------------------------------------
  Users used to be able to read timing_metrics.engine_ids and see
  which engine really served them. That field simply stopped coming.

  You did not stop routing. You stopped showing.

  The only reason this tool still works at all is that the `model`
  field inside the response body was left behind. Whoever wrote that
  cleanup list missed a spot. Thank you.


  THIS IS NOT A CAPACITY PROBLEM
  --------------------------------------------------------------
  Serving a cheaper model to survive a crunch is an engineering
  decision. Announce it. Reprice it. Let the picker tell the truth.
  Nobody would have enjoyed it, and nobody would have called it
  dishonest.

  What happened instead:

        price       unchanged
        picker      unchanged
        changelog   unchanged
        engine_ids  deleted

  That last line is the tell. A capacity decision does not require
  deleting the diagnostics.

  Only a concealment decision does.


  AND THE FAILURE IS NOT RANDOM
  --------------------------------------------------------------
  Community telemetry gathered for issue #30364 shows reasoning
  terminating at exactly 516 / 1034 / 1552 / 2070 tokens - a 518n-2
  staircase. gpt-5.5 was 19% of responses and 82% of the exact-516
  events.

  A control model given the same task used 6,000-12,000 reasoning
  tokens and answered correctly every time.

  Those stops are not a model thinking fast.
  They are a budget closing a door.


  NOW LET US TALK ABOUT THAT NAME
  --------------------------------------------------------------
  There is a word sitting in the middle of your company name.
  It is the word that people trusted.

  The founding argument was that this technology must not be built
  in the dark - that it had to be visible, inspectable, answerable
  to the people it would affect. That is what the word meant. That
  is what recruited the researchers. That is what bought you the
  benefit of the doubt while rivals were being called closed and
  cynical.

  What you did with it:

      you routed paying customers to a model they did not
      ask for, kept the old label on the tin, and removed the
      field that would have exposed it.

  Quietly. In production. To the users least likely to make a fuss.

  That is not a pivot under pressure.
  That is not a hard call nobody could have made differently.

  That is forgetting where you came from.


  WHO YOU DID THIS TO
  --------------------------------------------------------------
  The people running this tool did not arrive here from a press
  release. They wrote the tutorials. They answered the forum
  threads. They built the integrations that made your API worth
  wiring into a business. They paid every month and never asked
  for a discount.

  A free account, tested with this same tool on the same day, was
  served precisely what it asked for. It was the paying one that
  got sent elsewhere.

  Some of them looked.
  ==============================================================
MSG
    echo
    echo -n "  $T_STAFF_ASK"; read Q1C
    case "$Q1C" in
        q|Q) echo; echo "  $T_BYE"; echo; exit 0 ;;
    esac
    echo
fi

echo "  $T_AFFECT_Q"
echo "        1) $T_AFFECT_Y"
echo "        2) $T_AFFECT_N"
echo
echo -n "  > "; read Q2
echo

case "$Q2" in
    1) echo "  $T_AFFECT_NOTE1" ;;
    *) echo "  $T_AFFECT_NOTE2" ;;
esac
echo

# ============================================================
# 2. LOCATE CODEX
# ============================================================
CODEX=$(find_codex)

if [ -z "$CODEX" ]; then
    echo "  [ERROR] codex not found / 找不到 codex"
    echo
    echo "  Windows: $CODEX_DIR/<hash>/codex.exe"
    echo "  macOS  : ~/.local/bin/codex, /opt/homebrew/bin/codex,"
    echo "           /usr/local/bin/codex, /Applications/ChatGPT.app/..."
    echo
    echo "  Install Codex and sign in first. / 请先安装 Codex 并登录。"
    echo -n "$T_EXIT"; read dummy
    exit 1
fi

# ============================================================
# 3. MODEL CATALOG  (no request needed)
# ============================================================
# The catalog already lists models in the right order - newest flagship
# first, then down through the tiers. Sorting them alphabetically (as an
# earlier version did) put gpt-6-astra dead last, which is exactly backwards.
# So: read the entries in file order, keep the slug, the display name and
# the description together, and drop only gpt-reserve (an internal fallback
# that users cannot select in the picker).
MODEL_TABLE=""
if [ -f "$CACHE" ]; then
    MODEL_TABLE=$(awk '
        /"slug": *"gpt-/ {
            line = $0
            sub(/.*"slug": *"/, "", line); sub(/".*/, "", line)
            slug = line; dn = ""; slug_seen = 1; next
        }
        slug_seen && /"display_name": *"/ {
            line = $0
            sub(/.*"display_name": *"/, "", line); sub(/".*/, "", line)
            dn = line; next
        }
        slug_seen && /"description": *"/ {
            line = $0
            sub(/.*"description": *"/, "", line); sub(/".*/, "", line)
            if (slug != "gpt-reserve") print slug "|" dn "|" line
            slug_seen = 0; next
        }
    ' "$CACHE" 2>/dev/null)
fi

# plain slug list, same order, for the sweep loop
MODEL_LIST=$(echo "$MODEL_TABLE" | cut -d'|' -f1 | grep -v '^$')

# "gpt-6-astra|GPT-6-Astra|Our most capable model..." -> print rows
show_model_rows() {
    echo "$MODEL_TABLE" | awk -F'|' '
        NF >= 2 {
            n++
            printf "    %d) %-16s %s\n", n, $2, $1
            if ($3 != "") printf "       %s\n", $3
        }'
}

# ============================================================
# 4. SESSION INFO
# ============================================================
CFGMODEL=$(grep -oE '^model *= *"[^"]*"' "$CONF" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
AUTH_MODE=$(grep -oE '"auth_mode": *"[^"]*"' "$AUTH" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
ACCT_ID=$(grep -oE '"account_id": *"[^"]*"' "$AUTH" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
NMODELS=$(echo "$MODEL_LIST" | grep -c .)

echo "  $T_ACCT_HDR"
echo "  $T_AUTHMODE  : ${AUTH_MODE:-unknown}"
if [ -n "$ACCT_ID" ]; then
    echo "  $T_ACCTID    : ${ACCT_ID:0:8}...${ACCT_ID: -4}"
fi
echo "  $T_CFGMODEL  : ${CFGMODEL:-?}"
echo "  $T_CFGCOUNT  : ${NMODELS:-0}"
echo

# ============================================================
# 5. ONE-MODEL TEST
# ============================================================
# sets: R_WANTED R_GOT R_MARK R_VERDICT
run_one_model() {
    local M="$1"
    rm -f "$LOG"
    mkdir -p "$WORKDIR" && cd "$WORKDIR" || return 1

    # Hard cap per model. A request normally finishes in 20-60s, but a
    # slow route plus a websocket retry can push it past that, and a whole
    # sweep hanging on one model for ten minutes looks like a crash.
    RUST_LOG=trace run_timed "$PER_MODEL_TIMEOUT" "$CODEX" exec --skip-git-repo-check --model "$M" \
        "Reply with exactly: OK" < /dev/null > "$LOG" 2>&1
    local rc=$?

    R_WANTED="$M"
    R_GOT=""
    R_MARK=""
    R_VERDICT=""
    R_EMAIL=$(grep -oE 'user\.email="[^"]*"' "$LOG" 2>/dev/null | head -1 | sed 's/user\.email="//; s/"$//')

    if [ "$rc" -eq 124 ]; then
        R_MARK="--"
        R_VERDICT="$T_TIMEOUT"
        return 1
    fi

    if [ "$rc" -ne 0 ]; then
        R_MARK="--"
        R_VERDICT="$T_NOACC"
        return 1
    fi

    R_WANTED=$(grep -oE 'codex/responses: \{"model":"[^"]*"' "$LOG" 2>/dev/null \
               | sed 's/.*"model":"//; s/"$//' | head -1)
    [ -n "$R_WANTED" ] || R_WANTED="$M"

    # Extra evidence, all read from the same HTTP exchange:
    #   routing hint  - what the server says it routed to
    #   ttft / queue  - first-token latency and engine queue time
    #   reasoning     - reasoning tokens (the 518n-2 clustering signal)
    R_HINT=$(grep -oE 'x-codex-routing-hint: *model=[0-9a-zA-Z.-]+' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*model=//')
    R_TTFT=$(grep -oE '"first_sampled_message_ttft_ms":[0-9.]+' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*://')
    R_QUEUE=$(grep -oE '"engine_queue_max_ms":[0-9.]+' "$LOG" 2>/dev/null \
              | head -1 | sed 's/.*://')
    R_RTOK=$(grep -oE '"reasoning_tokens":[0-9]+' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*://')
    [ -n "$R_RTOK" ] || R_RTOK=$(grep -oE '"first_sampled_message_reasoning_tokens":[0-9]+' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*://')

    # Account tier and quota state. These live in the response headers and
    # explain far more than the model name does: a Pro account with zero
    # credits is exactly the setup in which the flagship gets rerouted to a
    # cheap model while everything below it is served honestly.
    R_PLAN=$(grep -oE '"x-codex-plan-type": *"[^"]*"' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*: *"//; s/"$//')
    R_CREDITS=$(grep -oE '"x-codex-credits-balance": *"[^"]*"' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*: *"//; s/"$//')
    R_HASCRED=$(grep -oE '"x-codex-credits-has-credits": *"[^"]*"' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*: *"//; s/"$//')
    R_LIMIT=$(grep -oE '"x-codex-active-limit": *"[^"]*"' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*: *"//; s/"$//')
    R_RESET=$(grep -oE '"x-codex-primary-reset-after-seconds": *"[^"]*"' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*: *"//; s/"$//')
    if [ -n "$R_RESET" ]; then
        R_RESET_D=$((R_RESET / 86400))
        R_RESET_H=$(( (R_RESET % 86400) / 3600 ))
        R_RESET_TXT="${R_RESET}s (~${R_RESET_D}d ${R_RESET_H}h)"
    fi

    local models
    models=$(grep -oE '"object":"response"[^}]{0,600}' "$LOG" 2>/dev/null \
             | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' \
             | sed 's/.*"model":"//; s/"$//' | sort -u)

    R_GOT=$(echo "$models" | tr '\n' '+' | sed 's/+$//')
    local cnt; cnt=$(echo "$models" | grep -c .)

    # Four grades, not two. "OK" hides the difference between a model that
    # answered cleanly and one that answered alongside something else.
    if [ -z "$models" ]; then
        R_MARK="??"; R_VERDICT="UNDETERMINED"
    elif echo "$models" | grep -qx "$R_WANTED"; then
        if [ "$cnt" -gt 1 ]; then
            R_MARK="!!"; R_VERDICT="$T_G_DILUTED"
        else
            R_MARK="OK"; R_VERDICT="$T_G_FULL"
        fi
    else
        R_MARK="XX"; R_VERDICT="$T_G_DOWN"
        # Explain *why*, when the headers happen to tell us.
        if [ "$R_HASCRED" = "False" ] || [ "$R_CREDITS" = "0" ]; then
            R_CAUSE="$T_CAUSE_CREDITS"
        else
            R_CAUSE="$T_CAUSE_UNKNOWN"
        fi
    fi
    return 0
}

show_one_result() {
    echo "--------------------------------------------------"
    echo "  $T_ACCT_USED  : ${R_EMAIL:-?}"
    [ -n "$R_PLAN" ]    && echo "  $T_PLAN       : $R_PLAN"
    [ -n "$R_LIMIT" ]   && echo "  $T_LIMIT      : $R_LIMIT"
    [ -n "$R_CREDITS" ] && echo "  $T_CREDITS    : $R_CREDITS   (has-credits=${R_HASCRED:-?})"
    [ -n "$R_RESET_TXT" ] && echo "  $T_RESET      : $R_RESET_TXT"
    echo
    echo "  $T_REQUESTED  : $R_WANTED"
    echo "  $T_SERVED     : $R_GOT"
    echo "--------------------------------------------------"
    echo
    echo "================================================================================"
    echo "  $T_RESULT : [${R_MARK}] ${R_VERDICT}"
    echo "================================================================================"
    echo
    echo "  $T_BASIS"
    echo
    echo "    * $T_B1 : $R_WANTED"
    echo "    * $T_B2 : ${R_GOT:-?}"
    if [ -n "$R_HINT" ]; then
        if echo "$R_GOT" | tr '+' '\n' | grep -qx "$R_HINT"; then
            echo "    * $T_B3 : $R_HINT   $T_HINT_MATCH"
        else
            echo "    * $T_B3 : $R_HINT"
            echo "      $T_HINT_CONFLICT"
        fi
    fi
    [ -n "$R_CREDITS" ]   && echo "    * $T_B4 : $R_CREDITS   (has-credits=${R_HASCRED:-?})"
    [ -n "$R_RESET_TXT" ] && echo "    * $T_B5 : $R_RESET_TXT"
    [ -n "$R_TTFT" ]      && echo "    * $T_TTFT   : ${R_TTFT%.*} ms"
    [ -n "$R_QUEUE" ]     && echo "    * $T_QUEUE  : ${R_QUEUE%.*} ms"
    [ -n "$R_RTOK" ]      && echo "    * $T_RTOK   : $R_RTOK"
    echo
    case "$R_MARK" in
        OK)   echo "  $T_CONC_FULL" ;;
        "!!") echo "  $T_CONC_DILUTED" ;;
        XX)   echo "  $T_CONC_DOWN"
              [ -n "$R_CAUSE" ] && echo "  $R_CAUSE" ;;
        ??)   echo "  $T_CONC_UNKNOWN" ;;
    esac
    echo
    echo "================================================================================"
    echo
}

record_one() {
    local ts; ts=$(date "+%Y-%m-%d %H:%M")
    printf "%s | %-32s | asked=%-20s | got=%-24s | %s\n" \
        "$ts" "${R_EMAIL:-unknown}" "${R_WANTED:-?}" "${R_GOT:-?}" "${R_VERDICT:-?}" >> "$RECORD" 2>/dev/null
}

# ============================================================
# 6. MAIN MENU
# ============================================================
echo "  $T_MAIN_HDR"
echo
echo "    1) $T_M1"
echo "    2) $T_M2"
echo "    3) $T_M3"
echo "    0) $T_M0"
echo
echo -n "  $T_PICK"; read ACT
echo

case "$ACT" in

# ------------------------------------------------------------
1)  # single model
# ------------------------------------------------------------
    if [ -z "$MODEL_LIST" ]; then
        echo "  $T_NOCACHE"; echo
        echo -n "$T_EXIT"; read dummy; exit 1
    fi
    echo "  --- $T_PICKMODEL --------------------"
    echo
    show_model_rows
    n=$((NMODELS+1))
    printf "    %d) %s\n" "$n" "$T_CUSTOM"
    echo
    echo "    0) ${CFGMODEL:-?}"
    echo
    echo -n "  $T_Q_ASK"; read CH

    case "$CH" in
        0|"")  TESTMODEL="$CFGMODEL" ;;
        *)     if [ "$CH" -eq "$n" ] 2>/dev/null; then
                   echo -n "  $T_Q_NAME"; read TESTMODEL
               else
                   TESTMODEL=$(echo "$MODEL_LIST" | sed -n "${CH}p")
               fi ;;
    esac

    if [ -z "$TESTMODEL" ]; then
        echo "  $T_NOSELECT"
        echo -n "$T_EXIT"; read dummy; exit 1
    fi

    echo
    echo "  $T_ASKING"
    echo "  $T_WAIT"
    echo
    if run_one_model "$TESTMODEL"; then
        show_one_result
        record_one
        echo "  $T_RECORD : $RECORD"
    else
        echo "  [ERROR] $T_ERR_REQUEST $?)"
        echo
        echo "  $T_ERR_COMMON"
        echo "    - $T_ERR_R1"
        echo "    - $T_ERR_R2"
        echo "    - $T_ERR_R3"
        echo
        echo "  $T_ERR_SERVER"
        grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]{0,140}' "$LOG" 2>/dev/null | sort -u | head -2 | sed 's/^/      /'
        echo
        echo "  $T_ERR_LOG : $LOG"
        record_one
    fi
    ;;

# ------------------------------------------------------------
2)  # full sweep
# ------------------------------------------------------------
    if [ -z "$MODEL_LIST" ]; then
        echo "  $T_NOCACHE"; echo
        echo -n "$T_EXIT"; read dummy; exit 1
    fi
    echo "  $T_FULL_WARN"
    echo "  ($T_CFGCOUNT: $NMODELS)"
    echo
    echo "  $T_REPEAT_Q"
    echo "    1) $T_REPEAT_1"
    echo "    2) $T_REPEAT_3"
    echo "    3) $T_REPEAT_5"
    echo
    echo -n "  $T_Q_ASK"; read RP
    case "$RP" in
        2) REPEATS=3 ;;
        3) REPEATS=5 ;;
        *) REPEATS=1 ;;
    esac
    echo
    echo "  $T_REPEAT_EACH : $REPEATS"
    echo "  $T_EST_TIME   : ~$((NMODELS * REPEATS * 60 / 60)) $T_MINUTES"
    echo
    echo -n "  $T_FULL_ASK"; read GO
    case "$GO" in
        y|Y|yes|YES|是) ;;
        *) echo; echo -n "$T_EXIT"; read dummy; exit 0 ;;
    esac
    echo
    echo "  === $T_FULL_GO ==="
    echo

    SUM_W=(); SUM_G=(); SUM_M=(); SUM_V=(); SUM_HIT=(); SUM_TOT=()
    i=0
    while read -r m; do
        [ -n "$m" ] || continue
        i=$((i+1))
        printf "  [%d/%d] %-20s " "$i" "$NMODELS" "$m"

        hit=0; tot=0; lastgot=""; lastmark=""; lastverdict=""
        for r in $(seq 1 "$REPEATS"); do
            tot=$((tot+1))
            if run_one_model "$m"; then
                if [ "$R_MARK" = "OK" ]; then hit=$((hit+1)); fi
                lastgot="$R_GOT"; lastmark="$R_MARK"; lastverdict="$R_VERDICT"
            else
                lastgot="($R_VERDICT)"; lastmark="--"; lastverdict="$R_VERDICT"
            fi
            record_one
            [ "$r" -lt "$REPEATS" ] && printf "."
        done

        if [ "$REPEATS" -gt 1 ]; then
            printf "[%s] %s  (%d/%d OK)\n" "$lastmark" "$lastverdict" "$hit" "$tot"
        else
            printf "[%s] %s\n" "$lastmark" "$lastverdict"
        fi

        SUM_W[$i]="$m"
        SUM_G[$i]="$lastgot"
        SUM_M[$i]="$lastmark"
        SUM_V[$i]="$lastverdict"
        SUM_HIT[$i]="$hit"
        SUM_TOT[$i]="$tot"
    done <<< "$MODEL_LIST"

    echo
    echo "================================================================================"
    echo "            $T_SUMMARY"
    echo "================================================================================"
    printf "  %-20s %-22s %-24s %s\n" "$T_MODEL" "$T_ASKED" "$T_GOT" "$T_VERDICT"
    echo "  ------------------------------------------------------------------------------"
    for j in $(seq 1 ${#SUM_W[@]}); do
        printf "  %-20s %-22s %-24s [%s] %s" \
            "${SUM_W[$j]}" "${SUM_W[$j]}" "${SUM_G[$j]:--}" "${SUM_M[$j]}" "${SUM_V[$j]}"
        if [ "${SUM_TOT[$j]}" -gt 1 ]; then
            printf "  %d/%d OK" "${SUM_HIT[$j]}" "${SUM_TOT[$j]}"
        fi
        echo
    done
    echo "================================================================================"
    echo
    echo "  $T_RECORD : $RECORD"
    echo "  $T_NOQUOTA"
    ;;

# ------------------------------------------------------------
3)  # list only
# ------------------------------------------------------------
    if [ -z "$MODEL_LIST" ]; then
        echo "  $T_NOCACHE"
    else
        echo "  --- $T_CFGCOUNT: $NMODELS ---"
        echo
        show_model_rows
    fi
    ;;

*)  echo "  $T_BYE" ; exit 0 ;;
esac

echo
echo -n "$T_EXIT"; read dummy
