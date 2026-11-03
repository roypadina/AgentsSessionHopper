#!/usr/bin/env bash
# Live test of `sessionhopper run` with the REAL claude: one conversation moves across every profile,
# forced by mocked usage (SESSIONHOPPER_MOCK_LIMITS), then comes back to the first.
#
#   Scripts/live/run-swaps.sh ~/.claude ~/.claude-work [...] [--openrouter-key-file F]
#
# Each turn is one tiny prompt on haiku with no tools (a few cents of usage per profile, no files written).
# Temp state dir: your own ASH config, logs and usage are untouched. Without a key file the OpenRouter step
# uses a fake key and expects the auth failure. Profiles must share one projects/ folder (sessionhopper doctor).
set -uo pipefail

# Not SESSIONHOPPER_BIN: inside a supervised session that names the installed release, not this build.
BIN="${ASH_TEST_BIN:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/sessionhopper}"
DIRS=(); KEY=""
while [ $# -gt 0 ]; do
  case "$1" in --openrouter-key-file) KEY="$2"; shift 2;; *) DIRS+=("$(cd "$1" && pwd)"); shift;; esac
done
[ ${#DIRS[@]} -ge 2 ] || { echo "usage: $0 <claude config dir> <claude config dir> [...] [--openrouter-key-file F]"; exit 2; }
[ -x "$BIN" ] || { echo "build first: swift build ($BIN)"; exit 2; }
"$BIN" help | grep -q "sessionhopper run" || { echo "$BIN has no \`run\` (an older build?)"; exit 2; }

T="$(mktemp -d)"; export SESSIONHOPPER_STATE_DIR="$T/state" SESSIONHOPPER_MOCK_LIMITS="$T/mock"
mkdir -p "$SESSIONHOPPER_STATE_DIR" "$SESSIONHOPPER_MOCK_LIMITS" "$T/cwd"; cd "$T/cwd"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR SESSIONHOPPER_SESSION_ID
NAMES=(); profiles=""
for i in "${!DIRS[@]}"; do
  n="p$((i + 1))"; NAMES+=("$n"); exp=true; [ "${DIRS[$i]}" = "$HOME/.claude" ] && exp=false
  profiles+="${profiles:+,}{\"name\":\"$n\",\"dir\":\"${DIRS[$i]}\",\"exportConfigDir\":$exp}"
done
printf '{"profiles":[%s]}' "$profiles" > "$SESSIONHOPPER_STATE_DIR/config.json"
if [ -z "$KEY" ]; then
  KEY="$T/fake.key"; (umask 077; echo "sk-or-v1-$(printf '0%.0s' {1..64})" > "$KEY"); FAKE=1
  # claude retries a 401 for minutes by default; a fake key should fail at once.
  export CLAUDE_CODE_MAX_RETRIES=1
else FAKE=0; fi
"$BIN" profiles add or --openrouter --model haiku=anthropic/claude-haiku-4.5 --key-file "$KEY" >/dev/null

full() { printf '{"five_hour":{"used_percentage":99,"resets_at":%s},"sampled_at":%s}' $(( $(date +%s) + 3600 )) "$(date +%s)" > "$SESSIONHOPPER_MOCK_LIMITS/$1.limits.json"; }
served() { jq -r 'select(.type=="run") | .to' "$SESSIONHOPPER_STATE_DIR/events.jsonl" 2>/dev/null | tail -1; }
# Profiles that hit a REAL limit during this test (an account may really be full): the expected server skips them.
really_full() { jq -r 'select(.type=="limit" and .trigger=="limit") | .from' "$SESSIONHOPPER_STATE_DIR/events.jsonl" 2>/dev/null; }
expect_after() { # first profile after p$1 that is not really full, else "or"
  local k; for k in $(seq $(( $1 + 1 )) ${#NAMES[@]}); do really_full | grep -qx "p$k" || { echo "p$k"; return; }; done; echo or; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1: expected '$3', got '$2'"; fail=$((fail + 1)); fi; }
turn() { local flag=$1; shift; echo "$*" | "$BIN" run -- -p "$flag" "$SID" --model haiku --tools "" 2>>"$T/stderr"; }

SID="$(uuidgen | tr 'A-Z' 'a-z')"; WORD="ZEBRA$RANDOM"
turn --session-id "The code word is $WORD. Reply with just: ok" >/dev/null
check "no usage known: first profile serves" "$(served)" "$(expect_after 0)"
for i in $(seq 1 $(( ${#NAMES[@]} - 1 ))); do
  full "p$i"
  turn --resume "Reply with just: ok" >/dev/null
  want="$(expect_after "$i")"
  [ "$want" = or ] && [ "$FAKE" = 1 ] && { echo "SKIP p1..p$i at 99%: the rest are really full, the fake key cannot serve"; continue; }
  check "p1..p$i at 99%: $want serves, same conversation" "$(served)" "$want"
done
full "p${#NAMES[@]}"
before=$(wc -l < "$SESSIONHOPPER_STATE_DIR/events.jsonl")
turn --resume "Reply with just: ok" >/dev/null; rc=$?
if [ "$FAKE" = 1 ]; then
  # A fake key fails either on auth (401) or, when resuming a conversation, before sending ("Prompt is too long":
  # gateway model discovery failed, so the context size is unknown). Either way: OpenRouter was the one tried.
  check "all subscriptions full: OpenRouter is tried (fake key fails, rc $rc)" \
    "$(tail -n +$((before + 1)) "$SESSIONHOPPER_STATE_DIR/events.jsonl" | jq -r '[.from, .to] | map(select(. == "or")) | length > 0' | sort -u | tail -1)" true
else
  check "all subscriptions full: OpenRouter serves" "$(served)" or
fi
"$BIN" config gateway manual >/dev/null
rm -f "$SESSIONHOPPER_STATE_DIR/profiles/or.limits.json"
before=$(wc -l < "$SESSIONHOPPER_STATE_DIR/events.jsonl")
turn --resume "Reply with just: ok" >/dev/null; rc=$?
check "gateway manual: exit 75 without trying OpenRouter" "$rc $(tail -n +$((before + 1)) "$SESSIONHOPPER_STATE_DIR/events.jsonl" | grep -c '"from":"or"')" "75 0"
rm -f "$SESSIONHOPPER_MOCK_LIMITS"/*.json
answer="$(turn --resume "What is the code word? Reply with just the word.")"
check "usage back: first profile serves again" "$(served)" "$(expect_after 0)"
check "the conversation survived every move" "$(echo "$answer" | grep -o "$WORD")" "$WORD"

# Only this test's own transcript, by its exact id.
for d in "${DIRS[@]}"; do
  find "$d/projects/" -maxdepth 2 -name "$SID.jsonl" -delete 2>/dev/null
  # Its project folder too, once empty (claude leaves an empty memory/ in it).
  find "$d/projects/" -maxdepth 1 -type d -name "*$(basename "$T")-cwd" -exec find {} -empty -delete \; 2>/dev/null
done
echo "---- $pass passed, $fail failed (state: $T)"
[ "$fail" = 0 ]
