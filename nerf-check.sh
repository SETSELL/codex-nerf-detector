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

# Switch the console to UTF-8. This MUST NOT live in the .bat: cmd
# loses its read position when the codepage changes mid-batch and
# then truncates the following lines.
chcp.com 65001 >/dev/null 2>&1

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
T_REQUESTED="请求的模型"
T_SERVED="响应里的模型"
T_NOCAP="（没抓到 —— 可能走了 WebSocket，或日志格式变了）"
T_RESULT="判定"
T_YOUASKED="你请求的是"
T_SEEN="响应里出现的模型"
T_WANTED="← 你要的"
T_DOWNGRADE="← 降级款"
T_FULL_WARN="⚠️  全模型检测会逐个发请求，每个模型一次。"
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
T_REQUESTED="requested model"
T_SERVED="response model(s)"
T_NOCAP="(not captured - websocket path, or the log format changed)"
T_RESULT="RESULT"
T_YOUASKED="you asked for"
T_SEEN="models seen in the response"
T_WANTED="<- the one you asked for"
T_DOWNGRADE="<- downgrade target"
T_FULL_WARN="WARNING: the full sweep sends one request per model."
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
CODEX=""
newest=0
for f in "$CODEX_DIR"/*/codex.exe; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ "$t" -gt "$newest" ]; then newest="$t"; CODEX="$f"; fi
done

if [ -z "$CODEX" ]; then
    echo "  [ERROR] codex.exe not found / 找不到 codex.exe"
    echo "          $CODEX_DIR"
    echo -n "$T_EXIT"; read dummy
    exit 1
fi

# ============================================================
# 3. MODEL CATALOG  (no request needed)
# ============================================================
MODEL_LIST=""
if [ -f "$CACHE" ]; then
    # gpt-reserve is an internal fallback that users cannot select in the
    # picker. Testing it says nothing about what a user would experience,
    # so it is filtered out of the testable list.
    MODEL_LIST=$(grep -oE '"slug": *"gpt-[^"]*"' "$CACHE" 2>/dev/null \
                 | sed 's/.*"slug": *"//; s/"$//' | sort -u \
                 | grep -v '^gpt-reserve$')
fi

model_desc() {
    # slug / display_name / description sit on separate lines in the cache,
    # so this has to look a few lines ahead rather than match on one line.
    grep -A8 "\"slug\": *\"$1\"" "$CACHE" 2>/dev/null \
      | grep -m1 '"description"' \
      | sed 's/.*"description": *"//; s/",*[[:space:]]*$//'
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
    RUST_LOG=trace timeout "$PER_MODEL_TIMEOUT" "$CODEX" exec --skip-git-repo-check --model "$M" \
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

    local models
    models=$(grep -oE '"object":"response"[^}]{0,600}' "$LOG" 2>/dev/null \
             | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' \
             | sed 's/.*"model":"//; s/"$//' | sort -u)

    R_GOT=$(echo "$models" | tr '\n' '+' | sed 's/+$//')
    local cnt; cnt=$(echo "$models" | grep -c .)

    if [ -z "$models" ]; then
        R_MARK="??"; R_VERDICT="UNDETERMINED"
    elif echo "$models" | grep -qx "$R_WANTED"; then
        if [ "$cnt" -gt 1 ]; then R_MARK="!!"; R_VERDICT="PARTIAL"
        else R_MARK="OK"; R_VERDICT="OK"; fi
    else
        R_MARK="XX"; R_VERDICT="DOWNGRADED"
    fi
    return 0
}

show_one_result() {
    echo "--------------------------------------------------"
    echo "  $T_ACCT_USED  : ${R_EMAIL:-?}"
    echo
    echo "  $T_REQUESTED  : $R_WANTED"
    echo "  $T_SERVED     : $R_GOT"
    echo "--------------------------------------------------"
    echo
    echo "  =================================================="
    echo "    $T_RESULT : [${R_MARK}] ${R_VERDICT}"
    echo
    echo "      $T_YOUASKED : $R_WANTED"
    echo
    echo "      $T_SEEN :"
    echo "$R_GOT" | tr '+' '\n' | while read -r m; do
        [ -n "$m" ] || continue
        if [ "$m" = "$R_WANTED" ]; then echo "        $m   $T_WANTED"
        elif [ "$m" = "gpt-5.6-luna" ]; then echo "        $m   $T_DOWNGRADE"
        else echo "        $m"; fi
    done
    echo "  =================================================="
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
    n=0
    while read -r m; do
        [ -n "$m" ] || continue
        n=$((n+1))
        d=$(model_desc "$m")
        printf "    %d) %-20s %s\n" "$n" "$m" "$d"
    done <<< "$MODEL_LIST"
    n=$((n+1))
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
    echo -n "  $T_FULL_ASK"; read GO
    case "$GO" in
        y|Y|yes|YES|是) ;;
        *) echo; echo -n "$T_EXIT"; read dummy; exit 0 ;;
    esac
    echo
    echo "  === $T_FULL_GO ==="
    echo

    SUM_W=(); SUM_G=(); SUM_M=(); SUM_V=()
    i=0
    while read -r m; do
        [ -n "$m" ] || continue
        i=$((i+1))
        printf "  [%d/%d] %-20s " "$i" "$NMODELS" "$m"
        if run_one_model "$m"; then
            printf "[%s] %s\n" "$R_MARK" "$R_VERDICT"
            record_one
        else
            printf "[--] %s\n" "$T_NOACC"
            record_one
        fi
        SUM_W[$i]="$R_WANTED"
        SUM_G[$i]="$R_GOT"
        SUM_M[$i]="$R_MARK"
        SUM_V[$i]="$R_VERDICT"
    done <<< "$MODEL_LIST"

    echo
    echo "=================================================="
    echo "            $T_SUMMARY"
    echo "=================================================="
    printf "  %-22s %-22s %-24s %s\n" "$T_MODEL" "$T_ASKED" "$T_GOT" "$T_VERDICT"
    echo "  ------------------------------------------------------------------------------"
    for j in $(seq 1 ${#SUM_W[@]}); do
        printf "  %-22s %-22s %-24s [%s] %s\n" \
            "${SUM_W[$j]}" "${SUM_W[$j]}" "${SUM_G[$j]:--}" "${SUM_M[$j]}" "${SUM_V[$j]}"
    done
    echo "=================================================="
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
        while read -r m; do
            [ -n "$m" ] || continue
            d=$(model_desc "$m")
            printf "    %-20s %s\n" "$m" "$d"
        done <<< "$MODEL_LIST"
    fi
    ;;

*)  echo "  $T_BYE" ; exit 0 ;;
esac

echo
echo -n "$T_EXIT"; read dummy
