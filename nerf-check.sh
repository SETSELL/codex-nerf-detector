#!/bin/bash
# ============================================================
#  Codex Nerf Detector
#
#  Detects when Codex serves a request with a weaker model than the
#  one that was asked for.
#
#  Asks every model a reasoning task, then reads back what the response
#  says actually served it, how many reasoning tokens it spent, what the
#  account's two quota pools look like, and what that adds up to.
#
#  All paths derive from $HOME and from this script's own location,
#  so nothing is hard-coded to a particular user.
#
#  Both launchers - nerf-check-windows.bat and nerf-check-macos.command -
#  only locate a bash and run this file. All behaviour lives here, so the
#  two platforms cannot drift apart.
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
WORKDIR="/tmp/codexcheck"
RECORD="$SELF_DIR/check-records.txt"

# Trace logs go in a folder next to this script, one file per request.
# A single fixed name in the system temp directory was fine while nothing
# asked the user to produce one - it is useless for that: they cannot find
# it, and the next run overwrites it. Falls back to the temp directory if
# the script's own folder is not writable.
LOGDIR="$SELF_DIR/logs"
if ! mkdir -p "$LOGDIR" 2>/dev/null; then
    LOGDIR="${TMPDIR:-/tmp}/codex-nerf-logs"
    mkdir -p "$LOGDIR" 2>/dev/null
fi
LOG="$LOGDIR/latest.log"

# A full sweep at ten repeats writes fifty multi-megabyte traces, so the
# folder is trimmed to the newest few. Override with LOG_KEEP=0 to keep
# everything.
LOG_KEEP="${LOG_KEEP:-20}"
prune_logs() {
    [ -d "$LOGDIR" ] || return 0
    ls -1t "$LOGDIR"/*.log 2>/dev/null \
        | tail -n +$(( LOG_KEEP + 1 )) \
        | while read -r f; do rm -f "$f"; done
}

# Seconds allowed per model before the run is abandoned and marked as a
# timeout. A reasoning prompt takes noticeably longer than a trivial one.
PER_MODEL_TIMEOUT="${PER_MODEL_TIMEOUT:-300}"

# The prompt every model is asked.
#
# It has to make the model actually think. The reasoning-token count is the
# strength signal, and a prompt with nothing to reason about never produces
# one - the old "Reply with exactly: OK" came back with 0 reasoning tokens
# on every run, so the 518n-2 staircase this tool talks about could never
# appear in its own output.
#
# Tune this to taste; a harder task uses more tokens and separates a capped
# model from a healthy one more clearly. Override without editing:
#   PROBE_PROMPT="your own task" ./nerf-check.sh
DEFAULT_PROMPT='Think step by step, showing every intermediate step.
Find the smallest positive integer n such that all three hold:
  n mod 7  = 3
  n mod 11 = 5
  n mod 13 = 9
Reply with only n.'
PROBE_PROMPT="${PROBE_PROMPT:-$DEFAULT_PROMPT}"

# ------------------------------------------------------------
# Colour
# ------------------------------------------------------------
# Only on a terminal, and never when NO_COLOR is set - the escape codes
# would otherwise land in piped output and in the record file.
#   https://no-color.org
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'      # full strength
    C_WARN=$'\033[33m'    # diluted
    C_BAD=$'\033[31m'     # downgraded
    C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_BAD=""; C_OFF=""
fi

# Colour for a grade code. The codes themselves are not shown to the user
# any more - the word alone is clearer than "[XX] 降智" - but they are what
# the verdict is keyed on internally and in check-records.txt.
grade_colour() {
    case "$1" in
        OK)   echo "$C_OK" ;;
        "!!") echo "$C_WARN" ;;
        XX)   echo "$C_BAD" ;;
        *)    echo "" ;;
    esac
}

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
# Only clear when stdout is a real terminal. Piped or redirected output
# would otherwise start with the clear escape sequences.
[ -t 1 ] && clear 2>/dev/null
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
T_BACK="按回车回到菜单..."
T_UNKNOWN="请输入 1、2 或 3；输入 0 退出。"
T_PICK="输入序号后回车： "
T_PICKMODEL="选择要检测的模型"
T_CUSTOM="自定义（手动输入模型名）"
T_ENTER_DEFAULT="直接回车 = 用配置的模型"
T_Q_ASK="输入序号： "
T_Q_NAME="模型名： "
T_ASKING="正在通过当前账号发送请求..."
T_WAIT="请稍候（推理需要 1~3 分钟，会消耗真实额度）"
T_ACCT_USED="本次使用的账号"
T_PLAN="账号等级"
T_LIMIT="当前限制档"
T_CREDITS="付费额度余额"
T_PLANQUOTA="套餐额度"
T_REMAIN="剩余"
T_MIN="分钟"
T_RESET="额度重置倒计时"
T_RESULT="判定"
T_SEEN="响应里出现的模型"
T_WANTED="← 你要的"
T_DOWNGRADE="← 降级款"
T_HINT="服务器自己说的路由"
T_HINT_MATCH="（和响应一致）"
T_HINT_CONFLICT="← ⚠️ 这个头和响应内容对不上：头里点名了这个模型，响应里却没有它"
T_TTFT="首字延迟"
T_QUEUE="引擎排队"
T_RTOK="推理 token"
T_TIER="模型档次"
T_TIER_F="旗舰"
T_TIER_H="高档"
T_TIER_M="中档"
T_TIER_L="低档"
T_TIER_C="廉价"
T_TIER_X="未知"
T_STRENGTH="推理"
T_ELAPSED="耗时"
T_TOK="tok"
T_STAIR="← 命中 518n-2 阶梯"
T_STRONG="← 推理充分"
T_SEC="秒"
T_DROP="↓ 掉"
T_UP="↑ 高"
T_TIERS="档"
T_STG_START="启动中"
T_STG_CONN="已连接"
T_STG_SENT="请求已发出"
T_STG_ROUTED="已收到响应头，服务端路由到"
T_EFFORT="思考强度"
T_EFFORT_Q="思考强度范围："
T_EFFORT_ONE="只测配置档"
T_EFFORT_ALL="全部强度"
T_EFFORT_TIMES="次请求"
T_G_FULL="自述一致"
T_G_DILUTED="掺水"
T_G_DOWN="降智"
T_G_UNDET="未确定"
T_BASIS="判断依据"
T_B1="你请求的模型"
T_B2="响应体里返回的是（实际用的）"
T_B3="服务器自己声明的路由"
T_B4="付费额度余额"
T_B5="额度重置倒计时"
T_CAUSE_CREDITS="套餐额度已耗尽 —— 这是旗舰模型被降级的直接原因"
T_CAUSE_NOCREDITS="套餐额度还有余量，但付费额度余额为 0 —— 旗舰模型可能只认付费额度，这一档被挡在外面"
T_CAUSE_UNKNOWN="额度正常，但请求仍被降级 —— 原因不明，这种情况反而更可疑"
T_CONC_FULL="结论：接口自述的模型与你请求的一致 —— 仅此而已，见下方「不能证明什么」。"
T_CONC_DILUTED="结论：你请求的模型有参与，但同一个请求里混进了别的模型 —— 不稳定。"
T_CONC_DOWN="结论：你请求的模型完全没有参与这次回答。"
T_CONC_UNKNOWN="结论：没能抓到响应内容，无法判断。"
T_LIMITS="这个结果不能证明什么"
T_LIM1="它只说明接口自述的是哪个模型，不说明实际回答的权重是什么"
T_LIM2="服务端自述的模型名不能当作「没被换」的证据 —— 换模型的本质就是说没换"
T_LIM3="单次结果不算结论。要下判断，请重复多次、并换账号对比"
T_DIAG="为什么会「未确定」"
T_DIAG_LOG="日志文件"
T_DIAG_SIZE="日志大小"
T_DIAG_BYTES="字节"
T_DIAG_HINT="日志里没有响应体。常见原因：RUST_LOG 没生效（Codex 没写 trace 日志）、走了未预期的新传输方式、或请求中途被中断。"
T_DIAG_SHARE="报 issue 时请附上这份日志，并写明系统和 Codex 版本 —— 只写「显示未确定」查不出原因。"
T_DIAG_MAIL="⚠️ 日志里有你的账号邮箱。发出去之前先打开看一眼，或先把邮箱删掉。"
T_LOGDIR="日志文件夹"
T_FULL_WARN="⚠️  全模型检测会逐个发请求。"
T_REPEAT_Q="每个模型测几次？"
T_REPEAT_1="1 次    快，但只能证明「发生过」，不能证明「每次都是」"
T_REPEAT_3="3 次    推荐 —— 能看出是偶发还是稳定复现"
T_REPEAT_5="5 次    有力 —— 比例开始有意义"
T_REPEAT_10="10 次   最彻底 —— 能给出稳定的降级比例，但很慢"
T_REQ_SHORT="次请求"
T_REPEAT_EACH="每个模型测"
T_TOTAL_REQ="本次共发出请求"
T_EST_TIME="预计耗时约"
T_MINUTES="分钟"
T_FULL_ASK="继续吗？(y/N) "
T_FULL_GO="开始全模型检测"
T_NOQUOTA="检查记录里存的是账号哈希，不是邮箱 —— 可以安全分享或提交。"
T_SUMMARY="检测汇总"
T_MODEL="模型"
T_GOT="实际"
T_VERDICT="判定"
T_NOACC="无权限"
T_TIMEOUT="超时"
T_RECORD="已追加到"
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
T_NOCACHE="找不到 models_cache.json —— 先运行一次 Codex，让它拉取模型目录。"
T_NOSELECT="没有选择模型。"
T_ERR_REQUEST="请求失败（退出码"
T_ERR_CLOSE="）"
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
T_BACK="Press Enter to return to the menu..."
T_UNKNOWN="Enter 1, 2 or 3, or 0 to quit."
T_PICK="enter a number: "
T_PICKMODEL="choose the model to test"
T_CUSTOM="custom (type a model name)"
T_ENTER_DEFAULT="press Enter = use the config model"
T_Q_ASK="enter a number: "
T_Q_NAME="model name: "
T_ASKING="Sending a request through the current account..."
T_WAIT="Please wait (reasoning takes 1-3 minutes; this spends real quota)"
T_ACCT_USED="account used"
T_PLAN="plan"
T_LIMIT="active limit"
T_CREDITS="credit balance"
T_PLANQUOTA="plan window"
T_REMAIN="left"
T_MIN="min"
T_RESET="credits reset in"
T_RESULT="RESULT"
T_SEEN="models seen in the response"
T_WANTED="<- the one you asked for"
T_DOWNGRADE="<- downgrade target"
T_HINT="server routing hint"
T_HINT_MATCH="(matches the response)"
T_HINT_CONFLICT="<- WARNING: this header and the response disagree - the header names this model, the response does not contain it"
T_TTFT="first token"
T_QUEUE="engine queue"
T_RTOK="reasoning tokens"
T_TIER="tier"
T_TIER_F="flagship"
T_TIER_H="high"
T_TIER_M="mid"
T_TIER_L="low"
T_TIER_C="cheap"
T_TIER_X="unknown"
T_STRENGTH="reasoning"
T_ELAPSED="elapsed"
T_TOK="tok"
T_STAIR="<- on the 518n-2 staircase"
T_STRONG="<- reasoning ran freely"
T_SEC="s"
T_DROP="down"
T_UP="up"
T_TIERS="tier(s)"
T_STG_START="starting"
T_STG_CONN="connected"
T_STG_SENT="request sent"
T_STG_ROUTED="headers in, server routing to"
T_EFFORT="effort"
T_EFFORT_Q="Reasoning effort:"
T_EFFORT_ONE="config level only"
T_EFFORT_ALL="every effort"
T_EFFORT_TIMES="requests"
T_G_FULL="SELF-REPORT"
T_G_DILUTED="DILUTED"
T_G_DOWN="DOWNGRADED"
T_G_UNDET="UNDETERMINED"
T_BASIS="how this was decided"
T_B1="the model you asked for"
T_B2="response body says (what actually served)"
T_B3="the server's own routing hint"
T_B4="credit balance"
T_B5="credits reset in"
T_CAUSE_CREDITS="the plan window is exhausted - this is the direct cause of the flagship being rerouted"
T_CAUSE_NOCREDITS="the plan window still has room, but the credit balance is 0 - the flagship may draw only on credits, and that is what it is being kept out of"
T_CAUSE_UNKNOWN="credits look fine, yet the request was still rerouted - cause unknown, and that is the more suspicious case"
T_CONC_FULL="Conclusion: the model the interface names matches the one you asked for - and that is all it shows. See below."
T_CONC_DILUTED="Conclusion: your model took part, but other models were mixed into the same request - unstable."
T_CONC_DOWN="Conclusion: the model you asked for took no part in this answer."
T_CONC_UNKNOWN="Conclusion: nothing could be captured, so no judgement is possible."
T_LIMITS="What this does not prove"
T_LIM1="It shows what the interface says about itself, not which weights answered"
T_LIM2="A server naming the model you asked for is not evidence it served it - a silent swap is precisely a claim that nothing was swapped"
T_LIM3="One run is not a conclusion. Repeat it, and compare across accounts"
T_DIAG="Why this came out UNDETERMINED"
T_DIAG_LOG="log file"
T_DIAG_SIZE="log size"
T_DIAG_BYTES="bytes"
T_DIAG_HINT="The log holds no response body. Usual causes: RUST_LOG did not take effect so Codex never wrote trace output, the response came over a transport this script does not know, or the request was cut off partway."
T_DIAG_SHARE="If you report this, attach that log and say which OS and Codex version - \"it shows UNDETERMINED\" on its own cannot be diagnosed."
T_DIAG_MAIL="WARNING: the log contains your account email. Open it before sending, or strip that line."
T_LOGDIR="log folder"
T_FULL_WARN="WARNING: the full sweep sends real requests."
T_REPEAT_Q="How many times per model?"
T_REPEAT_1="1 time     fast, but only proves it happened, not that it always happens"
T_REPEAT_3="3 times    recommended - shows whether it is occasional or consistent"
T_REPEAT_5="5 times    strong - a ratio starts to mean something"
T_REPEAT_10="10 times   most thorough - a stable downgrade rate, but slow"
T_REQ_SHORT="req"
T_REPEAT_EACH="requests per model"
T_TOTAL_REQ="requests this run"
T_EST_TIME="estimated time"
T_MINUTES="min"
T_FULL_ASK="Continue? (y/N) "
T_FULL_GO="Starting full sweep"
T_NOQUOTA="check-records.txt labels each account by hash, not by address - safe to share or commit."
T_SUMMARY="SUMMARY"
T_MODEL="model"
T_GOT="served"
T_VERDICT="verdict"
T_NOACC="no access"
T_TIMEOUT="timed out"
T_RECORD="appended to"
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
T_NOCACHE="models_cache.json not found - run Codex once so it fetches the model catalog."
T_NOSELECT="no model selected."
T_ERR_REQUEST="request failed (exit code"
T_ERR_CLOSE=")"
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

  For a while, this appeared too:

        x-codex-routing-hint: model=gpt-6-astra

  A hint naming Astra, in a run whose body was signed by Luna.

  We are not going to tell you which direction that header travelled -
  we never confirmed it, and we are not going to assert something we
  cannot show. What we can show is that it is gone: it is absent from
  every recent capture, including the runs where the swap is confirmed,
  while every other x-codex-* field is still being sent.

  That is the second time. engine_ids went first.


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

# Which reasoning efforts each model accepts. They are not the same across
# the catalog - gpt-5.5 stops at xhigh, the newer ones go to max, and only
# some offer ultra - so the list is read per model rather than assumed.
EFFORT_TABLE=$(awk '
    /"slug": *"/ {
        line = $0; sub(/.*"slug": *"/, "", line); sub(/".*/, "", line)
        slug = line; lv = ""; next
    }
    slug != "" && /"effort": *"/ {
        line = $0; sub(/.*"effort": *"/, "", line); sub(/".*/, "", line)
        lv = (lv == "" ? line : lv " " line); next
    }
    slug != "" && lv != "" && /^[[:space:]]*\]/ {
        print slug "|" lv; slug = ""; lv = ""
    }
' "$CACHE" 2>/dev/null)

# "low medium high xhigh max" for one model, or empty if it is not listed.
model_efforts() {
    echo "$EFFORT_TABLE" | awk -F'|' -v s="$1" '$1 == s { print $2; exit }'
}

# "gpt-6-astra|GPT-6-Astra|Our most capable model..." -> print rows
show_model_rows() {
    echo "$MODEL_TABLE" | awk -F'|' '
        NF >= 2 {
            n++
            printf "    %d) %-16s %s\n", n, $2, $1
            if ($3 != "") printf "       %s\n", $3
        }'
}

# ------------------------------------------------------------
# Tier: a positional ranking, "L5" = top of the catalog.
# ------------------------------------------------------------
# The catalog is already ordered flagship-first (see the comment above), so
# how far a model sits from the top is the only strength ranking available
# here. It is relative to whatever the catalog currently lists: add a model
# and every number below it shifts.
tier_rank() {
    local pos
    pos=$(echo "$MODEL_LIST" | grep -nxF "$1" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$pos" ] || return 0
    echo "L$((NMODELS - pos + 1))"
}

tier_name() {
    local pos l
    pos=$(echo "$MODEL_LIST" | grep -nxF "$1" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$pos" ] || { echo "$T_TIER_X"; return 0; }
    l=$((NMODELS - pos + 1))
    if   [ "$l" -ge "$NMODELS" ];     then echo "$T_TIER_F"
    elif [ "$l" -le 1 ];              then echo "$T_TIER_C"
    elif [ "$l" -ge $((NMODELS - 1)) ]; then echo "$T_TIER_H"
    elif [ "$l" -le 2 ];              then echo "$T_TIER_L"
    else                                   echo "$T_TIER_M"
    fi
}

# The community data behind this tool shows reasoning terminating in a
# 518n-2 staircase: 516, 1034, 1552, 2070. Landing exactly on one of those
# is the shape of a budget closing a door, not a model finishing its
# thought - so it is flagged rather than reported as a plain number.
on_staircase() {
    case "$1" in
        516|1034|1552|2070) return 0 ;;
        *) return 1 ;;
    esac
}

# Is the subscription's own window actually spent?
# Prints 1 (spent), 0 (fine), or nothing when the response does not say.
# The websocket message carries explicit allowed/limit_reached flags; the
# older header shape carries neither, so fall back to the used percentage
# there rather than guessing.
window_spent() {
    case "$R_LIMREACHED" in
        true)  echo 1; return 0 ;;
        false) echo 0; return 0 ;;
    esac
    case "$R_ALLOWED" in
        false) echo 1; return 0 ;;
        true)  echo 0; return 0 ;;
    esac
    case "$R_USEDPCT" in
        ''|*[!0-9]*) return 0 ;;
        *) [ "$R_USEDPCT" -ge 100 ] && echo 1 || echo 0 ;;
    esac
}

# ------------------------------------------------------------
# Result table
# ------------------------------------------------------------
# model / tier / measured strength / what actually served / elapsed time.
# Two lines per row: the numbers stay scannable on the first, and the
# second carries the reading - tier name, staircase hit, tier delta.
# Display width, portably.
#
# wc -L is not usable here. GNU counts terminal columns; BSD/macOS counts
# characters. "模型" comes back as 4 on Linux and 2 on macOS, so the table
# would line up on one platform and skew on the other.
#
# For the ASCII and CJK these strings hold, every CJK character is a
# three-byte UTF-8 sequence occupying two columns, so the column count is
# just the byte count minus one per CJK character. Counting the 0xE0-0xEF
# lead bytes gives exactly that, with no locale or wc dialect involved.
disp_width() {
    local s="$1" bytes lead
    bytes=$(printf '%s' "$s" | LC_ALL=C wc -c 2>/dev/null | tr -d '[:space:]')
    lead=$(printf '%s' "$s" | LC_ALL=C tr -dc '\340-\357' 2>/dev/null \
           | LC_ALL=C wc -c 2>/dev/null | tr -d '[:space:]')
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    case "$lead"  in ''|*[!0-9]*) lead=0 ;; esac
    echo $(( bytes - lead ))
}

# Pad to a display width, not a character count. printf's %-Ns counts
# characters, so "模型" padded with %-20s comes out 22 columns wide while
# "gpt-6-astra" comes out 20 - the whole table skews by two per CJK glyph.
pad() {
    local s="$1" w="$2" cur
    printf '%s' "$s"
    cur=$(disp_width "$s")
    [ "$cur" -lt "$w" ] && printf '%*s' "$((w - cur))" ""
    return 0
}

# ------------------------------------------------------------
# Progress
# ------------------------------------------------------------
# Overall completion is knowable - it is finished requests over total
# requests - so the sweep draws a real bar from it.
sweep_bar() {
    local d="$1" tot="$2" w=24 filled
    [ "$tot" -gt 0 ] || { printf ""; return 0; }
    filled=$(( d * w / tot ))
    printf "[%s%s] %d/%d %d%%" \
        "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
        "$(printf '%*s' "$((w - filled))" '' | tr ' ' '.')" \
        "$d" "$tot" "$(( d * 100 / tot ))"
}

# Within one request there is no percentage to show - the stream never
# reports how far along it is - so this shows what has actually arrived
# in the log (a real stage) plus how long it has been running, rather
# than a bar that would be inventing its own progress.
# Sets R_ELAPSED. Returns the command's exit status.
SPIN_FRAMES='|/-\'
run_probe() {
    local m="$1" prefix="$2"
    local pid rc t0 elapsed spin=0 stage hint recent
    local -a cmd

    # -c overrides a value from config.toml for this run only, which is how
    # the probe asks for a specific reasoning effort without editing the
    # user's config. Left off entirely when no override is wanted, so the
    # config default applies as before.
    cmd=(run_timed "$PER_MODEL_TIMEOUT" "$CODEX" exec --skip-git-repo-check)
    [ -n "$PROBE_EFFORT" ] && cmd+=(-c "model_reasoning_effort=\"$PROBE_EFFORT\"")
    cmd+=(--model "$m" "$PROBE_PROMPT")

    # Piped or redirected: no animation, no escape sequences in the output.
    if [ ! -t 1 ]; then
        t0=$(date +%s)
        # Exported rather than written as a "VAR=x cmd" prefix: that form
        # in front of an array expansion is parsed differently by older
        # bash, and macOS still ships bash 3.2. If the variable failed to
        # take, codex would run without trace logging, the log would hold
        # no response body, and every run would come back 未确定 with
        # nothing to explain why.
        export RUST_LOG=trace
        "${cmd[@]}" < /dev/null > "$LOG" 2>&1
        rc=$?
        R_ELAPSED=$(( $(date +%s) - t0 ))
        return "$rc"
    fi

    export RUST_LOG=trace
    "${cmd[@]}" < /dev/null > "$LOG" 2>&1 &
    pid=$!
    t0=$(date +%s)

    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( $(date +%s) - t0 ))
        # Only the tail - the trace log runs to megabytes.
        recent=$(tail -c 40000 "$LOG" 2>/dev/null)
        hint=$(echo "$recent" | grep -oE 'x-codex-routing-hint: *model=[0-9a-zA-Z.-]+' | head -1 | sed 's/.*model=//')
        if   [ -n "$hint" ];                              then stage="$T_STG_ROUTED $hint"
        elif echo "$recent" | grep -q 'api\.path="/responses"'; then stage="$T_STG_SENT"
        elif [ -s "$LOG" ];                               then stage="$T_STG_CONN"
        else                                                   stage="$T_STG_START"
        fi
        printf '\r\033[K  %s%s %s  %ds' \
            "$prefix" "${SPIN_FRAMES:$(( spin % 4 )):1}" "$stage" "$elapsed"
        spin=$(( spin + 1 ))
        sleep 0.3
    done

    wait "$pid"; rc=$?
    R_ELAPSED=$(( $(date +%s) - t0 ))
    printf '\r\033[K'
    return "$rc"
}

result_header() {
    printf "  "
    pad "$T_MODEL" 20;    printf " "
    pad "$T_TIER" 10;     printf " "
    pad "$T_EFFORT" 8;    printf " "
    pad "$T_STRENGTH" 12; printf " "
    pad "$T_GOT" 26;      printf " "
    pad "$T_ELAPSED" 7;   printf " "
    printf "%s\n" "$T_VERDICT"
    echo "  --------------------------------------------------------------------------------------------------"
}

# result_row <requested> <served> <tokens> <elapsed> <grade> <verdict> <effort> [extra]
result_row() {
    local m="$1" got="$2" rtok="$3" el="$4" gd="$5" vd="$6" ef="$7" extra="$8"
    local rank name note wr gr wl gl

    rank=$(tier_rank "$m"); [ -n "$rank" ] || rank="?"

    printf "  "
    pad "$m" 20;                printf " "
    pad "$rank" 10;             printf " "
    pad "${ef:--}" 8;           printf " "
    pad "${rtok:-?} $T_TOK" 12; printf " "
    pad "${got:--}" 26;         printf " "
    pad "${el:-?}$T_SEC" 7;     printf " "
    # Last column, so colour codes here cannot disturb any padding.
    printf "%s%s%s\n" "$(grade_colour "$gd")" "${vd:--}" "$C_OFF"

    note=$(tier_name "$m")
    # 2070 is the highest step of the documented staircase, so anything
    # past it is reasoning that clearly was not cut short.
    case "$rtok" in
        ''|*[!0-9]*) ;;
        *) if on_staircase "$rtok"; then
               note="$note   $T_STAIR"
           elif [ "$rtok" -gt 2070 ]; then
               note="$note   $T_STRONG"
           fi ;;
    esac

    # Only meaningful when both ends are in the catalog and the answer is a
    # single model - a diluted response lists several, joined with "+".
    wr=$(tier_rank "$m"); gr=$(tier_rank "$got")
    if [ -n "$wr" ] && [ -n "$gr" ] && [ "$wr" != "$gr" ]; then
        wl=${wr#L}; gl=${gr#L}
        if [ "$gl" -lt "$wl" ]; then note="$note   $T_DROP $((wl-gl)) $T_TIERS"
        else                         note="$note   $T_UP $((gl-wl)) $T_TIERS"
        fi
    fi

    [ -n "$extra" ] && note="$note   $extra"
    printf "  %-20s %-6s %s\n" "" "" "$note"
}

# ============================================================
# 4. SESSION INFO
# ============================================================
CFGMODEL=$(grep -oE '^model *= *"[^"]*"' "$CONF" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
# Left empty when the config does not pin one - then no -c override is
# passed at all and Codex picks its own default for the model.
CFGEFFORT=$(grep -oE '^model_reasoning_effort *= *"[^"]*"' "$CONF" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
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
    R_ELAPSED=""
    # One file per request, named so the right one can be found later.
    # No need to clear anything: the name is new every time.
    LOG="$LOGDIR/$(date '+%Y-%m-%d_%H%M%S')_$(printf '%s' "$M" | tr -c 'a-zA-Z0-9._-' '_').log"
    prune_logs
    mkdir -p "$WORKDIR" && cd "$WORKDIR" || return 1

    # Hard cap per model. A request normally finishes in 20-60s, but a
    # slow route plus a websocket retry can push it past that, and a whole
    # sweep hanging on one model for ten minutes looks like a crash.
    local rc
    run_probe "$M" "$PROBE_PREFIX"
    rc=$?

    R_WANTED="$M"
    R_GOT=""
    R_MARK=""
    R_VERDICT=""
    # Clear everything the previous model left behind. The timeout and
    # error paths return before these are filled in, so without this a
    # failed run would be reported with the last good run's numbers.
    R_PLAN=""; R_CREDITS=""; R_HASCRED=""; R_LIMIT=""
    R_RESET=""; R_RESET_TXT=""; R_CAUSE=""
    R_ALLOWED=""; R_LIMREACHED=""; R_USEDPCT=""; R_WINDOW=""
    R_GOT_CNT=""
    R_HINT=""; R_TTFT=""; R_QUEUE=""; R_RTOK=""
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
    # Take the last usage block, not the first: a warmup turn can report
    # its own zeros before the answer that actually gets billed.
    R_RTOK=$(grep -oE '"reasoning_tokens":[0-9]+' "$LOG" 2>/dev/null \
             | tail -1 | sed 's/.*://')
    [ -n "$R_RTOK" ] || R_RTOK=$(grep -oE '"first_sampled_message_reasoning_tokens":[0-9]+' "$LOG" 2>/dev/null \
             | head -1 | sed 's/.*://')

    # Account tier and quota state. These explain far more than the model
    # name does: a Pro account with zero credits is exactly the setup in
    # which the flagship gets rerouted to a cheap model while everything
    # below it is served honestly.
    #
    # Codex used to send this as x-codex-* HTTP headers. Current builds
    # push a single codex.rate_limits message over the response websocket
    # instead, so read that shape first and fall back to the old headers
    # for older builds. Without the new shape the whole block goes quiet
    # and the report silently loses its "why".
    #
    #   {"type":"codex.rate_limits","plan_type":"pro","rate_limits":{...},
    #    "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
    RL=$(grep -oE '\{"type":"codex\.rate_limits".{0,800}' "$LOG" 2>/dev/null | head -1)

    # Two separate pools, and they must not be conflated:
    #   plan window  - the subscription's own weekly quota (what gates
    #                  normal use; "used_percent":1 means 99% still free)
    #   credits      - a separate purchased pot some tiers draw on
    # A Pro account with a full plan window and an empty credit pot is the
    # normal state for anyone who is not buying extra credits. Calling that
    # "quota exhausted" while 99% of the window is unused is simply wrong.
    if [ -n "$RL" ]; then
        R_PLAN=$(echo "$RL"       | grep -oE '"plan_type":"[^"]*"'            | head -1 | sed 's/.*:"//; s/"$//')
        R_CREDITS=$(echo "$RL"    | grep -oE '"balance":"[^"]*"'              | head -1 | sed 's/.*:"//; s/"$//')
        R_HASCRED=$(echo "$RL"    | grep -oE '"has_credits":(true|false)'     | head -1 | sed 's/.*://')
        R_RESET=$(echo "$RL"      | grep -oE '"reset_after_seconds":[0-9]+'   | head -1 | sed 's/.*://')
        R_ALLOWED=$(echo "$RL"    | grep -oE '"allowed":(true|false)'         | head -1 | sed 's/.*://')
        R_LIMREACHED=$(echo "$RL" | grep -oE '"limit_reached":(true|false)'   | head -1 | sed 's/.*://')
        R_USEDPCT=$(echo "$RL"    | grep -oE '"used_percent":[0-9]+'          | head -1 | sed 's/.*://')
        R_WINDOW=$(echo "$RL"     | grep -oE '"window_minutes":[0-9]+'        | head -1 | sed 's/.*://')
    fi

    [ -n "$R_PLAN" ]    || R_PLAN=$(grep -oE '"x-codex-plan-type": *"[^"]*"' "$LOG" 2>/dev/null \
                                    | head -1 | sed 's/.*: *"//; s/"$//')
    [ -n "$R_CREDITS" ] || R_CREDITS=$(grep -oE '"x-codex-credits-balance": *"[^"]*"' "$LOG" 2>/dev/null \
                                    | head -1 | sed 's/.*: *"//; s/"$//')
    [ -n "$R_HASCRED" ] || R_HASCRED=$(grep -oE '"x-codex-credits-has-credits": *"[^"]*"' "$LOG" 2>/dev/null \
                                    | head -1 | sed 's/.*: *"//; s/"$//')
    [ -n "$R_RESET" ]   || R_RESET=$(grep -oE '"x-codex-primary-reset-after-seconds": *"[^"]*"' "$LOG" 2>/dev/null \
                                    | head -1 | sed 's/.*: *"//; s/"$//')
    [ -n "$R_USEDPCT" ] || R_USEDPCT=$(grep -oE '"x-codex-primary-used-percent": *"[^"]*"' "$LOG" 2>/dev/null \
                                    | head -1 | sed 's/.*: *"//; s/"$//')
    [ -n "$R_WINDOW" ]  || R_WINDOW=$(grep -oE '"x-codex-primary-window-minutes": *"[^"]*"' "$LOG" 2>/dev/null \
                                    | head -1 | sed 's/.*: *"//; s/"$//')
    R_LIMIT=$(grep -oE '"x-codex-active-limit": *"[^"]*"' "$LOG" 2>/dev/null \
              | head -1 | sed 's/.*: *"//; s/"$//')

    # The websocket message spells it true/false, the old header True/False.
    # Normalise so the credits test below only has to know one spelling.
    case "$R_HASCRED" in
        true|True)   R_HASCRED="True" ;;
        false|False) R_HASCRED="False" ;;
    esac

    if [ -n "$R_RESET" ]; then
        R_RESET_D=$((R_RESET / 86400))
        R_RESET_H=$(( (R_RESET % 86400) / 3600 ))
        R_RESET_TXT="${R_RESET}s (~${R_RESET_D}d ${R_RESET_H}h)"
    fi

    # Counted, not just de-duplicated: how many times each model turned up
    # in the response is evidence in its own right, and the README has been
    # promising an "xN" column that no version of this script ever printed.
    local models raw
    raw=$(grep -oE '"object":"response"[^}]{0,600}' "$LOG" 2>/dev/null \
          | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' \
          | sed 's/.*"model":"//; s/"$//' | sort | uniq -c | sort -rn)
    models=$(echo "$raw" | awk '{print $2}' | grep .)

    R_GOT=$(echo "$models" | tr '\n' '+' | sed 's/+$//')
    R_GOT_CNT=$(echo "$raw" | awk '{printf "%s %s\n", $2, $1}')
    local cnt; cnt=$(echo "$models" | grep -c .)

    # Four grades, not two. "OK" hides the difference between a model that
    # answered cleanly and one that answered alongside something else.
    if [ -z "$models" ]; then
        R_MARK="??"; R_VERDICT="$T_G_UNDET"
    elif echo "$models" | grep -qx "$R_WANTED"; then
        if [ "$cnt" -gt 1 ]; then
            R_MARK="!!"; R_VERDICT="$T_G_DILUTED"
        else
            R_MARK="OK"; R_VERDICT="$T_G_FULL"
        fi
    else
        R_MARK="XX"; R_VERDICT="$T_G_DOWN"
        # Explain *why*, when the response tells us. Check the plan window
        # first - that is the pool which actually gates normal use, and it
        # is the one a reader will look at. Only when it is genuinely spent
        # does "quota exhausted" describe anything.
        if [ "$(window_spent)" = "1" ]; then
            R_CAUSE="$T_CAUSE_CREDITS"
        elif [ "$R_HASCRED" = "False" ] || [ "$R_CREDITS" = "0" ]; then
            R_CAUSE="$T_CAUSE_NOCREDITS"
        else
            R_CAUSE="$T_CAUSE_UNKNOWN"
        fi
    fi
    return 0
}

# Label and value, with the colons lined up. printf's %-Ns counts
# characters, and these labels are Chinese - "账号等级" and "额度重置倒计时"
# are both four to seven characters but nearly twice that in columns, so
# padding by character count leaves the colons ragged.
acct_line() {
    printf "  "
    pad "$1" 17
    printf ": %s\n" "$2"
}

show_one_result() {
    local pq
    echo "--------------------------------------------------"
    acct_line "$T_ACCT_USED" "${R_EMAIL:-?}"
    [ -n "$R_PLAN" ] && acct_line "$T_PLAN" "$R_PLAN"
    # The plan window is the pool a reader will check first, so it is shown
    # before the credit balance rather than after it.
    case "$R_USEDPCT" in
        ''|*[!0-9]*) ;;
        *) pq="$T_REMAIN $((100 - R_USEDPCT))%"
           [ -n "$R_WINDOW" ] && pq="$pq   ($R_WINDOW $T_MIN)"
           acct_line "$T_PLANQUOTA" "$pq" ;;
    esac
    [ -n "$R_LIMIT" ] && acct_line "$T_LIMIT" "$R_LIMIT"
    [ -n "$R_CREDITS" ] && acct_line "$T_CREDITS" \
        "$R_CREDITS   (has-credits=${R_HASCRED:-?})"
    [ -n "$R_RESET_TXT" ] && acct_line "$T_RESET" "$R_RESET_TXT"
    echo
    result_header
    result_row "$R_WANTED" "$R_GOT" "$R_RTOK" "$R_ELAPSED" "$R_MARK" "$R_VERDICT" "$PROBE_EFFORT"
    echo "--------------------------------------------------"
    echo
    # Every model the response carried, and how many times each appeared.
    # A number appearing once on its own says little; yours never appearing
    # while a cheaper one shows up repeatedly is the thing being measured.
    if [ -n "$R_GOT_CNT" ]; then
        echo "  $T_SEEN"
        echo "$R_GOT_CNT" | while read -r mm nn; do
            [ -n "$mm" ] || continue
            if [ "$mm" = "$R_WANTED" ]; then tag="   $T_WANTED"
            else                              tag="   $T_DOWNGRADE"; fi
            printf "        %-20s x%-4s%s\n" "$mm" "$nn" "$tag"
        done
        echo
    fi
    echo "================================================================================"
    echo "  $T_RESULT : $(grade_colour "$R_MARK")${R_VERDICT}${C_OFF}"
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
        ??)   echo "  $T_CONC_UNKNOWN"
              # A bare "undetermined" is a dead end for whoever hit it -
              # and for anyone trying to help them. Say what to look at.
              echo
              echo "  --- $T_DIAG ---"
              echo
              echo "    - $T_LOGDIR: $LOGDIR"
              echo "    - $T_DIAG_LOG: $LOG"
              if [ -f "$LOG" ]; then
                  echo "    - $T_DIAG_SIZE: $(wc -c < "$LOG" 2>/dev/null | tr -d ' ') $T_DIAG_BYTES"
              fi
              echo "    - $T_DIAG_HINT"
              echo "    - $T_DIAG_SHARE"
              echo "    - $T_DIAG_MAIL" ;;
    esac
    echo
    # Printed every time, not only on a weak result. A tool whose whole
    # argument is "they are not telling you the truth" has to be scrupulous
    # about what its own evidence establishes, and the honest boundary is
    # the same whichever verdict came out.
    echo "  --- $T_LIMITS ---"
    echo
    echo "    - $T_LIM1"
    echo "    - $T_LIM2"
    echo "    - $T_LIM3"
    echo
    echo "================================================================================"
    echo
}

# A short stable label for an account, so the record file can be shared,
# committed and pasted into an issue without carrying the address itself.
# The whole point of the file is cross-account comparison, and that works
# exactly as well on a hash as on an address - while an address in a
# public repo works against the person who ran the tool.
acct_label() {
    local h
    h=$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-12)
    [ -n "$h" ] || h=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12)
    [ -n "$h" ] || h=$(printf '%s' "$1" | cksum 2>/dev/null | tr -d ' ' | cut -c1-12)
    [ -n "$h" ] || h="unlabelled"
    echo "$h"
}

record_one() {
    local ts who
    ts=$(date "+%Y-%m-%d %H:%M")
    if [ -n "$R_EMAIL" ]; then who=$(acct_label "$R_EMAIL"); else who="unknown"; fi
    printf "%s | %-16s | asked=%-20s | got=%-24s | %s\n" \
        "$ts" "$who" "${R_WANTED:-?}" "${R_GOT:-?}" "${R_VERDICT:-?}" >> "$RECORD" 2>/dev/null
}

# ============================================================
# 6. MAIN MENU
# ============================================================
# A finished run comes back here instead of dropping the user out, so
# testing a second account, or switching between one model and the full
# sweep, costs a keypress rather than a relaunch. Only "0" leaves.
# Deliberately not re-indented: the whole script is flat top level, and
# indenting 200 lines to add a loop would bury the change.
while :; do
echo "  $T_MAIN_HDR"
echo
echo "    1) $T_M1"
echo "    2) $T_M2"
echo "    3) $T_M3"
echo "    0) $T_M0"
echo
echo -n "  $T_PICK"
# Piped input can run out; without this the loop would spin on EOF
# printing the menu forever.
if ! read -r ACT; then echo; echo "  $T_BYE"; exit 0; fi
echo

case "$ACT" in

# ------------------------------------------------------------
1)  # single model
# ------------------------------------------------------------
    if [ -z "$MODEL_LIST" ]; then
        echo "  $T_NOCACHE"; echo
        echo -n "$T_BACK"; read -r dummy; echo; continue
    fi
    echo "  --- $T_PICKMODEL --------------------"
    echo
    show_model_rows
    n=$((NMODELS+1))
    printf "    %d) %s\n" "$n" "$T_CUSTOM"
    echo
    # The config model used to be listed here as "0)". It is nearly always
    # one of the rows above already, so it read as a duplicate entry - and
    # "0" means something else entirely in the main menu. Enter selects it.
    echo "    $T_ENTER_DEFAULT: ${CFGMODEL:-?}"
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
        echo -n "$T_BACK"; read -r dummy; echo; continue
    fi

    # Which reasoning efforts to probe. The list is per model - gpt-5.5
    # stops at xhigh while the newer ones go to max, and only some offer
    # ultra - so it comes from the catalog rather than being assumed.
    EFFORTS=$(model_efforts "$TESTMODEL")
    [ -n "$EFFORTS" ] || EFFORTS="$CFGEFFORT"
    NLEV=0; for e in $EFFORTS; do NLEV=$((NLEV+1)); done

    echo
    echo "  $T_EFFORT_Q"
    echo "    1) $T_EFFORT_ONE (${CFGEFFORT:-?})"
    echo "    2) $T_EFFORT_ALL: $EFFORTS   ($NLEV $T_EFFORT_TIMES)"
    echo
    echo -n "  $T_Q_ASK"; read ES
    case "$ES" in
        2) PROBE_EFFORTS="$EFFORTS" ;;
        *) if [ -n "$CFGEFFORT" ]; then PROBE_EFFORTS="$CFGEFFORT"
           else PROBE_EFFORTS="config"; fi ;;
    esac
    NL=0; for e in $PROBE_EFFORTS; do NL=$((NL+1)); done

    # The same repeat choice the full sweep offers, for the same reason:
    # one run proves it happened, not that it always happens. The totals
    # are effort-levels x repeats, so the cost of each option is stated
    # rather than left to be worked out.
    echo
    echo "  $T_REPEAT_Q"
    printf "    1) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_1" \
        "$((NL))"     "$T_REQ_SHORT" "$((NL * 2))"  "$T_MINUTES"
    printf "    2) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_3" \
        "$((NL * 3))" "$T_REQ_SHORT" "$((NL * 6))"  "$T_MINUTES"
    printf "    3) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_5" \
        "$((NL * 5))" "$T_REQ_SHORT" "$((NL * 10))" "$T_MINUTES"
    printf "    4) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_10" \
        "$((NL * 10))" "$T_REQ_SHORT" "$((NL * 20))" "$T_MINUTES"
    echo
    echo -n "  $T_Q_ASK"; read -r RS
    case "$RS" in
        2) REPS=3 ;;
        3) REPS=5 ;;
        4) REPS=10 ;;
        *) REPS=1 ;;
    esac
    NROWS=$((NL * REPS))

    echo
    if [ "$NROWS" -gt 1 ]; then
        echo "  $T_PICKMODEL : $TESTMODEL   ($T_EFFORT: $PROBE_EFFORTS)"
        echo "  $T_REPEAT_EACH : $REPS"
        echo "  $T_TOTAL_REQ  : $NROWS"
        echo
        result_header
    else
        echo "  $T_ASKING"
        echo "  $T_WAIT"
        echo
    fi

    ANYFAIL=0
    for e in $PROBE_EFFORTS; do
      for r in $(seq 1 "$REPS"); do
        # "config" means: pass no override, let Codex use the config value.
        case "$e" in
            config) PROBE_EFFORT="" ;;
            *)      PROBE_EFFORT="$e" ;;
        esac
        PROBE_PREFIX=""

        if run_one_model "$TESTMODEL"; then
            if [ "$NROWS" -gt 1 ]; then
                result_row "$R_WANTED" "$R_GOT" "$R_RTOK" "$R_ELAPSED" \
                           "$R_MARK" "$R_VERDICT" "$e"
            else
                show_one_result
                echo "  $T_RECORD : $RECORD"
            fi
        else
            ANYFAIL=1
            if [ "$NROWS" -gt 1 ]; then
                result_row "$TESTMODEL" "${R_VERDICT:-?}" "" "$R_ELAPSED" \
                           "--" "${R_VERDICT:-?}" "$e"
            else
                echo "  [ERROR] $T_ERR_REQUEST $?$T_ERR_CLOSE"
                echo
                echo "  $T_ERR_COMMON"
                echo "    - $T_ERR_R1"
                echo "    - $T_ERR_R2"
                echo "    - $T_ERR_R3"
                echo
                echo "  $T_ERR_SERVER"
                grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]{0,140}' "$LOG" 2>/dev/null | sort -u | head -2 | sed 's/^/      /'
            fi
        fi
        record_one
      done
    done

    if [ "$NROWS" -gt 1 ]; then
        echo
        echo "  $T_RECORD : $RECORD"
        echo "  $T_NOQUOTA"
        [ "$ANYFAIL" = "1" ] && echo "  $T_ERR_LOG : $LOG"
        echo
    fi

    PROBE_EFFORT=""
    ;;

# ------------------------------------------------------------
2)  # full sweep
# ------------------------------------------------------------
    if [ -z "$MODEL_LIST" ]; then
        echo "  $T_NOCACHE"; echo
        echo -n "$T_BACK"; read -r dummy; echo; continue
    fi
    echo "  $T_FULL_WARN"
    echo "  ($T_CFGCOUNT: $NMODELS)"
    echo
    # Each option carries what it will actually cost: the sweep sends
    # models x repeats requests, and at roughly two minutes each that is
    # not obvious from "10 times" alone.
    echo "  $T_REPEAT_Q"
    printf "    1) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_1" \
        "$((NMODELS))"      "$T_REQ_SHORT" "$((NMODELS * 2))"    "$T_MINUTES"
    printf "    2) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_3" \
        "$((NMODELS * 3))"  "$T_REQ_SHORT" "$((NMODELS * 6))"    "$T_MINUTES"
    printf "    3) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_5" \
        "$((NMODELS * 5))"  "$T_REQ_SHORT" "$((NMODELS * 10))"   "$T_MINUTES"
    printf "    4) %s   [%d %s / ~%d %s]\n" "$T_REPEAT_10" \
        "$((NMODELS * 10))" "$T_REQ_SHORT" "$((NMODELS * 20))"   "$T_MINUTES"
    echo
    echo -n "  $T_Q_ASK"; read RP
    case "$RP" in
        2) REPEATS=3 ;;
        3) REPEATS=5 ;;
        4) REPEATS=10 ;;
        *) REPEATS=1 ;;
    esac
    echo
    echo "  $T_REPEAT_EACH : $REPEATS"
    echo "  $T_TOTAL_REQ  : $((NMODELS * REPEATS))"
    # A reasoning request measured at roughly two minutes, so the old
    # one-minute-per-request figure understated a sweep by half.
    echo "  $T_EST_TIME   : ~$((NMODELS * REPEATS * 2)) $T_MINUTES"
    echo
    echo -n "  $T_FULL_ASK"; read GO
    case "$GO" in
        y|Y|yes|YES|是) ;;
        *) echo; continue ;;
    esac
    echo
    echo "  === $T_FULL_GO ==="
    echo

    SUM_W=(); SUM_G=(); SUM_M=(); SUM_V=(); SUM_HIT=(); SUM_TOT=()
    SUM_R=(); SUM_E=()
    i=0
    SWEEP_TOTAL=$((NMODELS * REPEATS)); SWEEP_DONE=0
    while read -r m; do
        [ -n "$m" ] || continue
        i=$((i+1))

        hit=0; tot=0; lastgot=""; lastmark=""; lastverdict=""; lastrtok=""; lastelapsed=""
        for r in $(seq 1 "$REPEATS"); do
            tot=$((tot+1)); SWEEP_DONE=$((SWEEP_DONE+1))
            # Overall completion is real, so it drives the bar; the live
            # stage for the request in flight is added by run_probe.
            PROBE_PREFIX="$(sweep_bar "$SWEEP_DONE" "$SWEEP_TOTAL")  $m  "
            # No animation when the output is captured, so print the line
            # the animation would have been drawing over.
            [ -t 1 ] || printf "  [%d/%d] %-20s " "$SWEEP_DONE" "$SWEEP_TOTAL" "$m"
            if run_one_model "$m"; then
                if [ "$R_MARK" = "OK" ]; then hit=$((hit+1)); fi
                lastgot="$R_GOT"; lastmark="$R_MARK"; lastverdict="$R_VERDICT"
            else
                lastgot="($R_VERDICT)"; lastmark="--"; lastverdict="$R_VERDICT"
            fi
            lastrtok="$R_RTOK"; lastelapsed="$R_ELAPSED"
            record_one
            [ -t 1 ] || printf "%s%s%s\n" "$(grade_colour "$lastmark")" "$lastverdict" "$C_OFF"
        done

        # On a terminal the live line gets wiped, so leave a permanent one.
        if [ -t 1 ]; then
            printf "  [%d/%d] %-20s %s%s%s" "$i" "$NMODELS" "$m" \
                   "$(grade_colour "$lastmark")" "$lastverdict" "$C_OFF"
            [ "$REPEATS" -gt 1 ] && printf "  (%d/%d OK)" "$hit" "$tot"
            echo
        fi

        SUM_W[$i]="$m"
        SUM_G[$i]="$lastgot"
        SUM_M[$i]="$lastmark"
        SUM_V[$i]="$lastverdict"
        SUM_HIT[$i]="$hit"
        SUM_TOT[$i]="$tot"
        SUM_R[$i]="$lastrtok"
        SUM_E[$i]="$lastelapsed"
    done <<< "$MODEL_LIST"

    echo
    echo "================================================================================"
    echo "            $T_SUMMARY"
    echo "================================================================================"
    result_header
    for j in $(seq 1 ${#SUM_W[@]}); do
        sx=""
        if [ "${SUM_TOT[$j]}" -gt 1 ]; then
            sx="${SUM_HIT[$j]}/${SUM_TOT[$j]} OK"
        fi
        result_row "${SUM_W[$j]}" "${SUM_G[$j]}" "${SUM_R[$j]}" "${SUM_E[$j]}" \
                   "${SUM_M[$j]}" "${SUM_V[$j]}" "$CFGEFFORT" "$sx"
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

0)  echo "  $T_BYE" ; exit 0 ;;
*)  echo "  $T_UNKNOWN" ;;
esac

echo
echo -n "$T_BACK"
if ! read -r dummy; then echo; exit 0; fi
echo
done
