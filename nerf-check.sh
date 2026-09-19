#!/bin/bash
# ============================================================
#  Codex Nerf Detector
#
#  HOW IT WORKS
#    The request body carries the model you asked for (e.g. gpt-6-astra).
#    The response body carries the model that actually served it.
#    If they differ, your request was routed to another (weaker) model.
#
#  All paths derive from $HOME and from this script's own location,
#  so nothing is hard-coded to a particular user.
# ============================================================

# Switch the console to UTF-8. This MUST NOT live in the .bat:
# cmd loses its read position when the codepage changes mid-batch and
# then truncates the following lines. Calling chcp.com from here is safe.
chcp.com 65001 >/dev/null 2>&1

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

CODEX_DIR="$HOME/AppData/Local/OpenAI/Codex/bin"
CONF="$HOME/.codex/config.toml"
AUTH="$HOME/.codex/auth.json"
LOG="/tmp/codex_nerf_check.log"
WORKDIR="/tmp/codexcheck"
RECORD="$SELF_DIR/check-records.txt"

MODELS="gpt-6-astra|latest flagship (GPT-6)
gpt-5.6-sol|previous flagship
gpt-5.6-terra|previous mid tier
gpt-5.6-luna|cheap fast tier (common downgrade target)
gpt-5.3-codex-spark|legacy codex model"

echo "=================================================="
echo "          Codex Nerf Detector"
echo "=================================================="
echo
echo "  Two quick questions before we start."
echo

# ---------- 0a. OpenAI staff? ----------
echo "  Q1) Are you a member of OpenAI's research staff?"
echo "        1) yes"
echo "        2) no"
echo
echo -n "  > "; read Q1
echo

if [ "$Q1" = "1" ]; then
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
  cynical, and it is what made "just trust us" sound like a plan
  instead of a threat.

  What you did with it:

      you routed paying customers to a model they did not
      ask for, kept the old label on the tin, and removed the
      field that would have exposed it.

  Quietly. In production. To the users least likely to make a fuss -
  the ones with deadlines, who assumed the picker meant something.

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

  They are the reason anyone outside your building knows what a
  token costs.

  And they are exactly the tier you rerouted. A free account, tested
  with this same tool on the same day, was served precisely what it
  asked for. It was the paying one that got sent elsewhere.

  Sit with that for a second. The people paying you got the worse
  deal, on purpose, because you calculated they would not look.

  Some of them looked.


  --------------------------------------------------------------
  This folder is a few kilobytes. One double-click on a clean
  machine, and it prints two lines out of your own API and lets
  them contradict each other in front of the user.

  You already have this data. You have had it the entire time.
  The only thing that changed is who else is allowed to see it.
  ==============================================================
MSG
    echo
    echo -n "  Press Enter to continue anyway, or type Q to quit: "; read Q1C
    case "$Q1C" in
        q|Q) echo; echo "  Bye."; echo; exit 0 ;;
    esac
    echo
fi

# ---------- 0b. affected user? ----------
echo "  Q2) Has your service been affected by model downgrading?"
echo "        1) yes"
echo "        2) no / not sure"
echo
echo -n "  > "; read Q2
echo

case "$Q2" in
    1) echo "  Noted. Let's find out exactly what you're getting." ;;
    *) echo "  Fine - let's check anyway." ;;
esac
echo

# ---------- 1. locate the newest codex.exe ----------
CODEX=""
newest=0
for f in "$CODEX_DIR"/*/codex.exe; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ "$t" -gt "$newest" ]; then newest="$t"; CODEX="$f"; fi
done

if [ -z "$CODEX" ]; then
    echo "  [ERROR] codex.exe not found."
    echo "          looked in: $CODEX_DIR"
    echo
    echo "  This tool needs Codex desktop or Codex CLI installed and"
    echo "  signed in on this machine."
    echo
    echo -n "Press Enter to exit..."; read dummy
    exit 1
fi

# ---------- 2. read current config ----------
CFGMODEL=$(grep -oE '^model *= *"[^"]*"' "$CONF" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
AUTH_MODE=$(grep -oE '"auth_mode": *"[^"]*"' "$AUTH" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
ACCT_ID=$(grep -oE '"account_id": *"[^"]*"' "$AUTH" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

echo "  --- current session ------------------------------"
echo "  auth mode    : ${AUTH_MODE:-unknown}"
if [ -n "$ACCT_ID" ]; then
    echo "  account id   : ${ACCT_ID:0:8}...${ACCT_ID: -4}"
fi
echo "  config model : ${CFGMODEL:-（not readable）}"
echo

# ---------- 3. pick a model ----------
TESTMODEL=""

if [ -n "${1:-}" ]; then
    TESTMODEL="$1"
    echo "  model from command line: $TESTMODEL"
    echo
else
    echo "  --- choose the model to test --------------------"
    echo
    n=0
    while IFS='|' read -r name desc; do
        [ -n "$name" ] || continue
        n=$((n+1))
        printf "    %d) %-22s %s\n" "$n" "$name" "$desc"
    done <<< "$MODELS"
    n=$((n+1))
    printf "    %d) %s\n" "$n" "custom (type a model name)"
    echo
    echo "    0) use the default from config.toml (${CFGMODEL:-unknown})"
    echo
    echo -n "  enter a number: "; read CH

    case "$CH" in
        0|"")  TESTMODEL="$CFGMODEL" ;;
        *)     if [ "$CH" -eq "$n" ] 2>/dev/null; then
                   echo -n "  model name: "; read TESTMODEL
               else
                   TESTMODEL=$(echo "$MODELS" | sed -n "${CH}p" | cut -d'|' -f1)
               fi ;;
    esac
    echo
fi

if [ -z "$TESTMODEL" ]; then
    echo "  [ERROR] no model selected."
    echo -n "Press Enter to exit..."; read dummy
    exit 1
fi

echo "  model to test: $TESTMODEL"
echo
echo "  Sending one minimal request through the current account..."
echo "  Please wait (about 20-60 seconds, uses one tiny request)."
echo

# ---------- 4. send the request ----------
mkdir -p "$WORKDIR" && cd "$WORKDIR" || exit 1
RUST_LOG=trace "$CODEX" exec --skip-git-repo-check --model "$TESTMODEL" \
    "Reply with exactly: OK" < /dev/null > "$LOG" 2>&1
rc=$?

if [ "$rc" -ne 0 ]; then
    echo "  [ERROR] request failed (exit code $rc)"
    echo
    echo "  Common causes:"
    echo "    - this account has no access to $TESTMODEL"
    echo "      (free accounts usually only get gpt-5.6-terra)"
    echo "    - the model name is wrong"
    echo "    - network / proxy is not working"
    echo
    echo "  Server said:"
    grep -oiE '(model[_ ]not[_ ]found|unsupported[_ ]model|not available|no access|invalid[_ ]model|does not exist)[^"]{0,140}' "$LOG" 2>/dev/null | sort -u | head -3 | sed 's/^/      /'
    grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]{0,160}' "$LOG" 2>/dev/null | sort -u | head -3 | sed 's/^/      /'
    echo
    echo "  full log: $LOG"
    echo
    echo -n "Press Enter to exit..."; read dummy
    exit 1
fi

# ---------- 5. account email ----------
EMAIL=$(grep -oE 'user\.email="[^"]*"' "$LOG" 2>/dev/null | head -1 | sed 's/user\.email="//; s/"$//')

# ---------- 6. model in the REQUEST body ----------
REQ_MODEL=$(grep -oE 'codex/responses: \{"model":"[^"]*"' "$LOG" 2>/dev/null \
            | sed 's/.*"model":"//; s/"$//' | head -1)

# ---------- 7. model(s) in the RESPONSE body ----------
RESP_MODELS=$(grep -oE '"object":"response"[^}]{0,600}' "$LOG" 2>/dev/null \
              | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' \
              | sed 's/.*"model":"//; s/"$//' | sort -u)

echo "--------------------------------------------------"
echo "  account used for this request:"
echo "        ${EMAIL:-（not captured）}"
echo
echo "  requested model : ${REQ_MODEL:-（not captured）}"
echo
echo "  response model(s):"
if [ -z "$RESP_MODELS" ]; then
    echo "        （not captured - websocket path, or format changed）"
else
    echo "$RESP_MODELS" | while read -r m; do
        c=$(grep -oE '"object":"response"[^}]{0,600}' "$LOG" 2>/dev/null | grep -c "\"model\":\"$m\"")
        echo "        $m   (x$c)"
    done
fi
echo "--------------------------------------------------"
echo

# ---------- 8. verdict ----------
WANT="${REQ_MODEL:-$TESTMODEL}"
CNT=$(echo "$RESP_MODELS" | grep -c .)

if [ -z "$RESP_MODELS" ]; then
    VERDICT="UNDETERMINED"; MARK="??"
elif echo "$RESP_MODELS" | grep -qx "$WANT"; then
    if [ "$CNT" -gt 1 ]; then
        VERDICT="PARTIALLY DOWNGRADED"; MARK="!!"
    else
        VERDICT="OK"; MARK="OK"
    fi
else
    VERDICT="DOWNGRADED"; MARK="XX"
fi

GOT=$(echo "$RESP_MODELS" | tr '\n' '+' | sed 's/+$//')

echo "=================================================="
echo "  RESULT: [${MARK}] ${VERDICT}"
echo
echo "        you asked for : ${WANT:-unknown}"
echo
echo "        models seen in the response:"
echo "$RESP_MODELS" | while read -r m; do
    if [ "$m" = "$WANT" ]; then
        echo "          $m   <- the one you asked for"
    elif [ "$m" = "gpt-5.6-luna" ]; then
        echo "          $m   <- downgrade target"
    else
        echo "          $m"
    fi
done
echo
case "$MARK" in
    OK) echo "        Your requested model was used." ;;
    "!!") echo "        Requested model appeared, but others were mixed in - unstable." ;;
    XX)  echo "        Your requested model never appeared - routed elsewhere." ;;
    ??)  echo "        Could not determine - please send the log to the author." ;;
esac
echo "=================================================="
echo

# ---------- 9. record ----------
TS=$(date "+%Y-%m-%d %H:%M")
printf "%s | %-32s | asked=%-20s | got=%-22s | %s\n" \
    "$TS" "${EMAIL:-unknown}" "${WANT:-?}" "${GOT:-?}" "$VERDICT" >> "$RECORD" 2>/dev/null

echo "  appended to : $RECORD"
echo "  full log    : $LOG"
echo
echo -n "Press Enter to exit..."; read dummy
