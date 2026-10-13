#!/bin/bash
# Tests for sign-in renewal: `fetch_usage.sh --renew` and the renew info on a
# token_expired fetch. Runs against a stub `claude` in a throwaway HOME, with a
# stub `curl` too, so it never starts Claude Code, never touches a real
# ~/.claude* folder and never makes a network request. The one --claim case is
# a dry run (CLAUDEMETER_DRY_RUN=1) on fake credentials, which sends nothing.
#
# Usage: bash tests/test_renew.sh   (or: just test-renew)
# Takes about 90 seconds: the timeout cases wait out the real limits (30 s,
# 15 s more for a refresh in flight, the 60 s outer timeout), side by side.
# Set TMPDIR to put the scratch folder somewhere other than /tmp.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/contents/scripts/fetch_usage.sh"
HELPER="$REPO/contents/scripts/renew_signin.py"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudemeter-renew-test.XXXXXX")"
WORK="$(realpath "$WORK")"
FAKE_HOME="$WORK/home"
STUB_BIN="$WORK/bin"        # stub claude and stub curl
NO_CLAUDE_BIN="$WORK/nobin" # stub curl only
LOGS="$WORK/logs"           # what the stub claude saw, one file per case
OUTPUTS="$WORK/outputs"     # every stdout, stderr and exit code the scripts produced
CACHE="$FAKE_HOME/.cache/claudemeter"
mkdir -p "$FAKE_HOME" "$STUB_BIN" "$NO_CLAUDE_BIN" "$LOGS" "$OUTPUTS" "$WORK/tmp"
# Relative folder names (such as a folder called "--renew") resolve in here.
cd "$WORK" || exit 1

cleanup() {
    # Belt and braces: anything a stub started that is somehow still around.
    local pid
    for pid in $(grep -h -E '^(pid|ppid|grandchild)=' "$LOGS"/* 2>/dev/null | cut -d= -f2); do
        kill -KILL "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "$2"; fi; }
section() { printf '\n%s\n' "$1"; }

check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

check_range() {
    if python3 -c 'import sys; v, a, b = map(float, sys.argv[1:]); sys.exit(0 if a <= v <= b else 1)' "$2" "$3" "$4" 2>/dev/null; then
        ok "$1 (${2}s)"
    else
        bad "$1" "'${2}' is outside [$3, $4]"
    fi
}

# A field of a JSON document by dotted path; null when missing.
jget() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print(d if isinstance(d, str) else json.dumps(d))
' "$1" "$2" 2>/dev/null || echo "<not json>"
}

# PATH without any folder that holds a claude, so the real one is unreachable.
SAFE_PATH=""
IFS=: read -ra path_entries <<< "$PATH"
for dir in "${path_entries[@]}"; do
    if [ -z "$dir" ] || [ -e "$dir/claude" ]; then continue; fi
    SAFE_PATH="${SAFE_PATH:+$SAFE_PATH:}$dir"
done

# Everything the helper must remove from Claude Code's environment.
SCRUBBED=(
    CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR CLAUDE_CODE_OAUTH_REFRESH_TOKEN
    CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR
    CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    ANTHROPIC_AWS_API_KEY ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_AUTH_TOKEN
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_GATEWAY
    CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH
    CLAUDE_CODE_DISABLE_AUTH_REFRESH_LOCK CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION
)

# --- stubs -------------------------------------------------------------------

cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
# Stand-in for Claude Code: logs how it was started, then acts out STUB_MODE.
log="${STUB_LOG:?}"
stdin_tty=no;  [ -t 0 ] && stdin_tty=yes
stdout_tty=no; [ -t 1 ] && stdout_tty=yes
stdin_target="$(readlink /proc/$$/fd/0)"
stdout_target="$(readlink /proc/$$/fd/1)"
stderr_target="$(readlink /proc/$$/fd/2)"
{
    echo "start"
    echo "started_at=$(date +%s.%N)"
    echo "pid=$$"
    echo "ppid=$PPID"
    echo "parent=$(ps -o comm= -p "$PPID")"
    echo "pgid=$(ps -o pgid= -p $$ | tr -d ' ')"
    echo "sid=$(ps -o sid= -p $$ | tr -d ' ')"
    echo "argc=$#"
    for a in "$@"; do echo "arg=$a"; done
    echo "cwd=$PWD"
    echo "stdin_tty=$stdin_tty stdin=$stdin_target"
    echo "stdout_tty=$stdout_tty stdout=$stdout_target"
    echo "stderr=$stderr_target"
    # Names only, never values, so a failed scrub cannot leak into the log.
    echo "envnames= $(compgen -e | tr '\n' ' ')"
    for v in CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_SKIP_PROMPT_HISTORY HTTPS_PROXY; do
        if [ -n "${!v+x}" ]; then echo "$v=${!v}"; else echo "$v=<unset>"; fi
    done
    echo "ready"
} >> "$log"

folder="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
folder="${folder/#\~/$HOME}"
renew_creds() {
    python3 -I - "$folder/.credentials.json" <<'PY'
import json, sys, time
with open(sys.argv[1]) as f:
    data = json.load(f)
data["claudeAiOauth"]["expiresAt"] = int(time.time() * 1000) + 8 * 3600 * 1000
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY
    echo "renewed" >> "$log"
}

case "${STUB_MODE:-log}" in
    renew)
        sleep "${STUB_DELAY:-1}"
        renew_creds
        ;;
    log|noop)
        ;;
    fail)
        exit 3
        ;;
    hang)
        while :; do sleep 1; done
        ;;
    ignore-term)
        trap 'echo "got TERM" >> "$log"' TERM
        ( trap '' TERM; exec sleep 1000 ) &
        echo "grandchild=$!" >> "$log"
        while :; do wait; sleep 0.2; done
        ;;
    slow-refresh|stuck-refresh)
        # Holds Claude Code's refresh lock and keeps it fresh, as a refresh in
        # flight does; slow-refresh then renews after STUB_DELAY seconds.
        lock="$folder/.oauth_refresh.lock"
        end=$(( $(date +%s) + ${STUB_DELAY:-33} ))
        mkdir -p "$lock"
        while [ "$STUB_MODE" = stuck-refresh ] || [ "$(date +%s)" -lt "$end" ]; do
            touch "$lock"
            sleep 1
        done
        renew_creds
        rmdir "$lock"
        ;;
esac
exit 0
STUB

cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
# Stand-in for curl: records the call and fails as if offline.
echo "called" >> "${CURL_LOG:?}"
exit 7
STUB
cp "$STUB_BIN/curl" "$NO_CLAUDE_BIN/curl"
chmod +x "$STUB_BIN/claude" "$STUB_BIN/curl" "$NO_CLAUDE_BIN/curl"

CURL_LOG="$WORK/curl.log"

# --- helpers -----------------------------------------------------------------

# creds <folder> <shape>: fake credentials, with fake-* strings as tokens.
creds() {
    mkdir -p "$1"
    python3 -I - "$1/.credentials.json" "$2" <<'PY'
import json, sys, time
path, shape = sys.argv[1], sys.argv[2]
now = int(time.time() * 1000)
hour = 3600 * 1000
oauth = {
    "accessToken": "fake-access",
    "refreshToken": "fake-refresh",
    "expiresAt": now - hour,
    "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "max",
}
if shape == "valid":
    oauth["expiresAt"] = now + 8 * hour
elif shape == "no_refresh":
    del oauth["refreshToken"]
elif shape == "empty_refresh":
    oauth["refreshToken"] = ""
elif shape == "expires_zero":
    oauth["expiresAt"] = 0
elif shape == "no_expires":
    del oauth["expiresAt"]
elif shape == "expires_nan":
    oauth["expiresAt"] = float("nan")
elif shape == "expires_inf":
    oauth["expiresAt"] = float("-inf")
elif shape == "refresh_expired":
    oauth["refreshTokenExpiresAt"] = now - hour
elif shape == "refresh_valid":
    oauth["refreshTokenExpiresAt"] = now + 30 * 24 * hour
elif shape == "signed_out":
    # The shape of a real local account: no token, no refresh, expiresAt 0.
    oauth.update(accessToken="", refreshToken="", expiresAt=0)
elif shape == "malformed":
    with open(path, "w") as f:
        f.write('{"claudeAiOauth": {"accessToken": "fake-access", "refreshToken": "fake-refresh",')
    sys.exit(0)
elif shape != "expired":
    sys.exit("unknown shape " + shape)
with open(path, "w") as f:
    json.dump({"claudeAiOauth": oauth}, f)
PY
}

expires_of() {
    python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["claudeAiOauth"].get("expiresAt"))' "$1/.credentials.json"
}

# The renewal lock and state are keyed on the folder's real path.
renew_key() {
    printf %s "$(realpath -m -- "$1")" | cksum | cut -d' ' -f1
}

state_of() {
    cat "$CACHE/renew_$(renew_key "$1").json" 2>/dev/null || echo "{}"
}

# set_state <folder> <last_try> <failures>: as if earlier tries had happened.
set_state() {
    printf '{"last_try": %s, "failures": %s}' "$2" "$3" > "$CACHE/renew_$(renew_key "$1").json"
}

# How many times the stub claude started in a case.
starts() {
    if [ -f "$1" ]; then grep -c '^start$' "$1"; else echo 0; fi
}

logval() {
    grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

wait_for_ready() {
    local i
    for i in $(seq 1 200); do
        if grep -q '^ready$' "$1" 2>/dev/null; then return 0; fi
        sleep 0.05
    done
    return 1
}

helper_pid() {
    pgrep -f -- "renew_signin.py renew --folder=$1 --key=" | head -n 1
}

# run <label> [VAR=value ...] -- [script args ...]
# fetch_usage.sh in a clean environment. Writes $OUTPUTS/<label>.{out,err,rc,time}.
# The outer timeout only matters if the script's own limits break: it turns a
# hang into a failed check instead of a test run that never ends.
run() {
    local label="$1"
    shift
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    shift
    local start end
    start="$(date +%s.%N)"
    timeout -k 5 90 env -i HOME="$FAKE_HOME" PATH="$STUB_BIN:$SAFE_PATH" TMPDIR="$WORK/tmp" \
        CURL_LOG="$CURL_LOG" STUB_LOG="$LOGS/$label" "${envs[@]}" \
        bash "$SCRIPT" "$@" > "$OUTPUTS/$label.out" 2> "$OUTPUTS/$label.err"
    echo "$?" > "$OUTPUTS/$label.rc"
    end="$(date +%s.%N)"
    python3 -c "print(round($end - $start, 2))" > "$OUTPUTS/$label.time"
}

out()     { cat "$OUTPUTS/$1.out"; }
elapsed() { cat "$OUTPUTS/$1.time"; }
result_reason() { local d; d="$(out "$1")"; echo "$(jget "$d" renew.result) $(jget "$d" renew.reason)"; }

# gone <label> <pid>: neither running nor a zombie.
gone() {
    local label="$1" pid="$2"
    if [ -z "$pid" ]; then
        bad "$label" "no pid logged"
    elif kill -0 "$pid" 2>/dev/null || [ -n "$(ps -o stat= -p "$pid" 2>/dev/null)" ]; then
        bad "$label" "pid $pid still exists ($(ps -o stat=,args= -p "$pid" 2>/dev/null))"
    else
        ok "$label"
    fi
}

group_empty() {
    local label="$1" pgid="$2"
    if [ -n "$(pgrep -g "$pgid" 2>/dev/null)" ]; then
        bad "$label" "process group $pgid still has: $(pgrep -a -g "$pgid")"
    else
        ok "$label"
    fi
}

# killed_case <label> <mode> <folder>: SIGKILLs the helper once claude runs,
# as Plasma does when the widget goes away, then times how long claude lives.
killed_case() {
    local label="$1" mode="$2" folder="$3" res="$OUTPUTS/$1.case"
    # stderr off: bash would announce the job it is about to see killed.
    run "$label" STUB_MODE="$mode" -- --renew -- "$folder" 2>/dev/null &
    local runner=$!
    if ! wait_for_ready "$LOGS/$label"; then echo "no_start=1" > "$res"; wait "$runner"; return; fi
    sleep 0.5
    local helper pgid alive=no outer=no pids pid started deadline
    helper="$(helper_pid "$folder")"
    kill -KILL "$helper"
    wait "$runner"
    pgid="$(logval "$LOGS/$label" pgid)"
    pid="$(logval "$LOGS/$label" pid)"
    if kill -0 "$pid" 2>/dev/null; then alive=yes; fi
    if [ -n "$(pgrep -x -g "$pgid" timeout)" ]; then outer=yes; fi
    pids="$pid $(logval "$LOGS/$label" grandchild)"
    started="$(logval "$LOGS/$label" started_at)"
    deadline=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local any=no p
        for p in $pids; do if kill -0 "$p" 2>/dev/null; then any=yes; fi; done
        [ "$any" = no ] && break
        sleep 0.2
    done
    {
        echo "helper=$helper"
        echo "alive_after_kill=$alive"
        echo "outer_timeout_running=$outer"
        echo "gone_after=$(python3 -c "print(round($(date +%s.%N) - $started, 2))")"
    } > "$res"
}

# term_twice_case <label> <folder>: TERM to the helper, and a second TERM a
# second later, while claude ignores TERM. The cleanup must still finish.
term_twice_case() {
    local label="$1" folder="$2" res="$OUTPUTS/$1.case"
    run "$label" STUB_MODE=ignore-term -- --renew -- "$folder" &
    local runner=$!
    if ! wait_for_ready "$LOGS/$label"; then echo "no_start=1" > "$res"; wait "$runner"; return; fi
    sleep 0.5
    local helper t0 alive=no p
    helper="$(helper_pid "$folder")"
    t0="$(date +%s.%N)"
    kill -TERM "$helper"
    sleep 1
    kill -TERM "$helper" 2>/dev/null
    wait "$runner"
    for p in $(logval "$LOGS/$label" pid) $(logval "$LOGS/$label" grandchild); do
        if kill -0 "$p" 2>/dev/null; then alive=yes; fi
    done
    {
        echo "helper_secs=$(python3 -c "print(round($(date +%s.%N) - $t0, 2))")"
        echo "left_running=$alive"
    } > "$res"
}

caseval() {
    logval "$OUTPUTS/$1.case" "$2"
}

# --- preflight ---------------------------------------------------------------

section "Preflight"
if PATH="$SAFE_PATH" command -v claude >/dev/null; then
    echo "a real claude is still reachable on the filtered PATH; refusing to run" >&2
    exit 1
fi
check_eq "stub claude is the one on PATH" "$(PATH="$STUB_BIN:$SAFE_PATH" command -v claude)" "$STUB_BIN/claude"
check_eq "no claude without the stub folder" "$(PATH="$NO_CLAUDE_BIN:$SAFE_PATH" command -v claude || echo none)" "none"
check_eq "coreutils timeout is available" "$(command -v timeout >/dev/null && echo yes)" "yes"

# --- fetch mode: renew info on token_expired ---------------------------------

section "Fetch mode reports whether renewal is possible, before any network call"
F="$WORK/accounts/fetch"
for shape in expired no_refresh empty_refresh refresh_expired refresh_valid; do
    creds "$F" "$shape"
    run "fetch-$shape" -- -- "$F"
    doc="$(out "fetch-$shape")"
    check_eq "$shape: error is token_expired" "$(jget "$doc" error)" "token_expired"
    case "$shape" in
        expired|refresh_valid) want="true null" ;;
        no_refresh|empty_refresh) want="false no_refresh_token" ;;
        refresh_expired) want="false refresh_token_expired" ;;
    esac
    check_eq "$shape: renew.possible and reason" "$(jget "$doc" renew.possible) $(jget "$doc" renew.reason)" "$want"
done
check_eq "message is unchanged" "$(jget "$(out fetch-expired)" message)" "OAuth token has expired. Run claude to refresh."
if [ -e "$CURL_LOG" ]; then bad "curl was never called for an expired token" "$(cat "$CURL_LOG")"; else ok "curl was never called for an expired token"; fi

# A token from CLAUDE_CODE_OAUTH_TOKEN is used instead of an expired file, so
# there is no token_expired and nothing to renew.
creds "$FAKE_HOME/.claude" expired
run fetch-env CLAUDE_CODE_OAUTH_TOKEN=fake-env-token -- --
check_eq "env token: no token_expired" "$(jget "$(out fetch-env)" error)" "network_error"
check_eq "env token: no renew info" "$(jget "$(out fetch-env)" renew)" "null"
rm -f "$CURL_LOG"

# --- renew mode: credentials that cannot be renewed ---------------------------

section "Renew mode refuses credentials it cannot renew, without starting claude"
N="$WORK/accounts/shapes"
for item in no_refresh:no_refresh_token empty_refresh:no_refresh_token expires_zero:no_expiry \
            no_expires:no_expiry expires_nan:no_expiry expires_inf:no_expiry \
            refresh_expired:refresh_token_expired malformed:unreadable \
            signed_out:no_refresh_token valid:not_expired; do
    shape="${item%%:*}"
    reason="${item#*:}"
    creds "$N" "$shape"
    run "shape-$shape" STUB_MODE=renew -- --renew --now -- "$N"
    check_eq "$shape: not_possible ($reason)" "$(result_reason "shape-$shape")" "not_possible $reason"
done
check_eq "claude never started for any of them" "$(cat "$LOGS"/shape-* 2>/dev/null | grep -c '^start$')" "0"

creds "$FAKE_HOME/.claude" expired
run renew-env CLAUDE_CODE_OAUTH_TOKEN=fake-env-token STUB_MODE=renew -- --renew --now --
check_eq "token from env: not_possible (token_from_env)" "$(result_reason renew-env)" "not_possible token_from_env"
run renew-missing STUB_MODE=renew -- --renew --now -- "$WORK/accounts/nowhere"
check_eq "no credentials file: not_possible (no_credentials)" "$(result_reason renew-missing)" "not_possible no_credentials"
check_eq "claude never started for those either" "$(starts "$LOGS/renew-env")$(starts "$LOGS/renew-missing")" "00"

# --- renewed, cool-down, --now ------------------------------------------------

section "A renewal, the cool-down after it, and --now"
A="$WORK/accounts/one"
creds "$A" expired
echo '{}' > "$A/history.jsonl"
touch -d '2026-01-01 12:00' "$A/history.jsonl"
run renewed STUB_MODE=renew -- --renew -- "$A"
doc="$(out renewed)"
check_eq "result is renewed" "$(jget "$doc" renew.result)" "renewed"
check_range "took about the stub's 1 s" "$(elapsed renewed)" 1.0 5.0
now_ms="$(date +%s%3N)"
if [ "$(expires_of "$A")" -gt "$now_ms" ]; then ok "expiresAt is now in the future"; else bad "expiresAt is now in the future"; fi
check_eq "next_try is 30 minutes after the try" "$(( $(jget "$doc" renew.next_try) - $(jget "$doc" renew.last_try) ))" "1800"
key="$(renew_key "$A")"
if [ -f "$CACHE/renew_$key.lock" ] && [ -f "$CACHE/renew_$key.json" ]; then
    ok "lock and state files are keyed on the folder's real path"
else
    bad "lock and state files are keyed on the folder's real path" "$(ls -A "$CACHE")"
fi
check_eq "history.jsonl untouched (activity check sees no new session)" "$(stat --format=%Y "$A/history.jsonl")" "$(date -d '2026-01-01 12:00' +%s)"
run activity -- --activity -- "$A"
check_eq "--activity still reports the old mtime" "$(out activity)" "$(date -d '2026-01-01 12:00' +%s)"
first_next="$(jget "$doc" renew.next_try)"

creds "$A" expired
run cooldown STUB_MODE=renew -- --renew -- "$A"
doc="$(out cooldown)"
check_eq "second automatic try is refused: cooldown" "$(jget "$doc" renew.result)" "cooldown"
check_eq "cooldown reports the same next_try" "$(jget "$doc" renew.next_try)" "$first_next"
check_eq "claude did not start during the cool-down" "$(starts "$LOGS/cooldown")" "0"
check_range "cooldown answers at once" "$(elapsed cooldown)" 0 2

run now STUB_MODE=renew -- --renew --now -- "$A"
check_eq "--now skips the cool-down" "$(jget "$(out now)" renew.result)" "renewed"
check_eq "claude started once for --now" "$(starts "$LOGS/now")" "1"

# --- backoff -------------------------------------------------------------------

section "Not renewed, and the backoff after it"
B="$WORK/accounts/two"
creds "$B" expired
before="$(expires_of "$B")"
run noop STUB_MODE=noop -- --renew -- "$B"
doc="$(out noop)"
check_eq "exit 0 without a change: not_renewed" "$(jget "$doc" renew.result)" "not_renewed"
check_eq "expiresAt unchanged" "$(expires_of "$B")" "$before"
check_eq "one automatic failure: next try in 1 h" "$(( $(jget "$doc" renew.next_try) - $(jget "$doc" renew.last_try) ))" "3600"
check_eq "failure counted" "$(jget "$(state_of "$B")" failures)" "1"

run fail STUB_MODE=fail -- --renew --now -- "$B"
doc="$(out fail)"
check_eq "non-zero exit: not_renewed" "$(jget "$doc" renew.result)" "not_renewed"
check_eq "a failed click leaves the count alone" "$(jget "$(state_of "$B")" failures)" "1"
check_eq "a failed click still reports the 1 h wait" "$(( $(jget "$doc" renew.next_try) - $(jget "$doc" renew.last_try) ))" "3600"

set_state "$B" "$(( $(date +%s) - 4000 ))" 1
run backoff-2 STUB_MODE=noop -- --renew -- "$B"
doc="$(out backoff-2)"
check_eq "second automatic failure in a row: next try in 2 h" "$(( $(jget "$doc" renew.next_try) - $(jget "$doc" renew.last_try) ))" "7200"

last=$(( $(date +%s) - 3700 ))
set_state "$B" "$last" 2
run backoff-wait STUB_MODE=noop -- --renew -- "$B"
check_eq "after two failures, 1 h later is still the cool-down" "$(result_reason backoff-wait)" "cooldown null"
check_eq "...with the doubled next_try" "$(jget "$(out backoff-wait)" renew.next_try)" "$(( last + 7200 ))"

set_state "$B" "$(( $(date +%s) - 90000 ))" 9
run backoff-cap STUB_MODE=noop -- --renew -- "$B"
doc="$(out backoff-cap)"
check_eq "many failures: capped at 24 h" "$(( $(jget "$doc" renew.next_try) - $(jget "$doc" renew.last_try) ))" "86400"

run backoff-reset STUB_MODE=renew -- --renew --now -- "$B"
doc="$(out backoff-reset)"
check_eq "a click that works: renewed" "$(jget "$doc" renew.result)" "renewed"
check_eq "...and resets the backoff" "$(jget "$(state_of "$B")" failures) $(( $(jget "$doc" renew.next_try) - $(jget "$doc" renew.last_try) ))" "0 1800"

# --- how claude is started ----------------------------------------------------

section "Invocation, environment and work folder"
E="$WORK/accounts/env"
creds "$E" expired
dirty=()
for v in "${SCRUBBED[@]}"; do dirty+=("$v=fake-env-token"); done
run env STUB_MODE=renew "${dirty[@]}" CLAUDE_CONFIG_DIR="$WORK/accounts/other" \
    HTTPS_PROXY=http://proxy.invalid:3128 -- --renew -- "$E"
L="$LOGS/env"
check_eq "renewed with a dirty environment" "$(jget "$(out env)" renew.result)" "renewed"
check_eq "argv is exactly the tested flags" "$(logval "$L" argc) $(grep '^arg=' "$L" | cut -d= -f2 | tr '\n' ' ')" "3 --init-only --safe-mode --strict-mcp-config "
check_eq "cwd is the dedicated work folder" "$(logval "$L" cwd)" "$CACHE/claude-renew"
check_eq "work folder is mode 700" "$(stat --format=%a "$CACHE/claude-renew")" "700"
check_eq "work folder is left empty" "$(ls -A "$CACHE/claude-renew" | wc -l)" "0"
check_eq "stdin is /dev/null, not a TTY" "$(grep '^stdin_tty=' "$L")" "stdin_tty=no stdin=/dev/null"
check_eq "stdout is /dev/null, not a TTY" "$(grep '^stdout_tty=' "$L")" "stdout_tty=no stdout=/dev/null"
check_eq "stderr is /dev/null" "$(logval "$L" stderr)" "/dev/null"
names="$(logval "$L" envnames)"
leftover=""
for v in "${SCRUBBED[@]}"; do
    case " $names " in *" $v "*) leftover="$leftover $v" ;; esac
done
check_eq "all ${#SCRUBBED[@]} credential, provider and session variables are unset" "${leftover:-none}" "none"
check_eq "DISABLE_AUTOUPDATER=1" "$(logval "$L" DISABLE_AUTOUPDATER)" "1"
check_eq "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "$(logval "$L" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)" "1"
check_eq "CLAUDE_CODE_SKIP_PROMPT_HISTORY=1" "$(logval "$L" CLAUDE_CODE_SKIP_PROMPT_HISTORY)" "1"
check_eq "proxy variables are inherited" "$(logval "$L" HTTPS_PROXY)" "http://proxy.invalid:3128"
check_eq "CLAUDE_CONFIG_DIR pointing elsewhere is replaced by the folder" "$(logval "$L" CLAUDE_CONFIG_DIR)" "$E"
check_eq "claude runs under coreutils timeout" "$(logval "$L" parent)" "timeout"
check_eq "...which leads a session and group of its own" "$(logval "$L" pgid) $(logval "$L" sid)" "$(logval "$L" ppid) $(logval "$L" ppid)"

section "CLAUDE_CONFIG_DIR: kept when it names this folder, unset for ~/.claude otherwise"
D="$FAKE_HOME/.claude"
E2="$WORK/accounts/env2"
# name | folder setting | inherited CLAUDE_CONFIG_DIR | what claude should get
cases=(
    "inherited-same|$D|$D|$D"
    "inherited-same-spelled-differently|$D|$D/|$D/"
    "no-folder|||<unset>"
    "no-folder-inherited-default||$D|$D"
    "inherited-literal-tilde|$D|~/.claude|$D"
    "tilde|~/.claude||<unset>"
    "trailing-slash|$D/||<unset>"
    "inherited-elsewhere|$D|$WORK/accounts/other|<unset>"
    "other-folder-inherited-same|$E2|$E2/|$E2/"
)
for item in "${cases[@]}"; do
    IFS='|' read -r name folder inherited want <<< "$item"
    target="${folder:-${inherited:-$D}}"
    target="${target/#\~/$FAKE_HOME}"
    creds "$target" expired
    label="cfg-$name"
    envs=(STUB_MODE=renew)
    if [ -n "$inherited" ]; then envs+=(CLAUDE_CONFIG_DIR="$inherited"); fi
    if [ -n "$folder" ]; then
        run "$label" "${envs[@]}" -- --renew --now -- "$folder"
    else
        run "$label" "${envs[@]}" -- --renew --now --
    fi
    check_eq "$name: renewed" "$(jget "$(out "$label")" renew.result)" "renewed"
    check_eq "$name: claude gets CLAUDE_CONFIG_DIR=${want/#"$WORK"/...}" "$(logval "$LOGS/$label" CLAUDE_CONFIG_DIR)" "$want"
done

# --- folder argument -------------------------------------------------------------

section "The folder comes after --, and a dash-led folder is never a mode"
P="$WORK/accounts/dashdash"
creds "$P" expired
run dd-fetch -- -- "$P"
check_eq "fetch with -- folder" "$(jget "$(out dd-fetch)" error)" "token_expired"
echo '{}' > "$P/history.jsonl"
touch -d '2026-02-02 12:00' "$P/history.jsonl"
run dd-activity -- --activity -- "$P"
check_eq "--activity with -- folder" "$(out dd-activity)" "$(date -d '2026-02-02 12:00' +%s)"
run dd-renew STUB_MODE=renew -- --renew -- "$P"
check_eq "--renew with -- folder" "$(jget "$(out dd-renew)" renew.result)" "renewed"
creds "$P" expired
run dd-renew-now STUB_MODE=renew -- --renew --now -- "$P"
check_eq "--renew --now with -- folder" "$(jget "$(out dd-renew-now)" renew.result)" "renewed"
creds "$P" valid
echo '{"oauthAccount": {"organizationUuid": "00000000-0000-4000-8000-000000000000"}}' > "$P/.claude.json"
run dd-claim CLAUDEMETER_DRY_RUN=1 -- --claim grant_1 req1 -- "$P"
check_eq "--claim with -- folder (dry run, org from that folder)" \
    "$(jget "$(out dd-claim)" claim.result) $(jget "$(out dd-claim)" url)" \
    "dry_run https://api.anthropic.com/api/organizations/00000000-0000-4000-8000-000000000000/reset_rate_limits"
if [ -e "$CURL_LOG" ]; then bad "the dry run never called curl"; else ok "the dry run never called curl"; fi
run dd-named-renew STUB_MODE=renew -- -- --renew
check_eq "a folder called --renew after -- is just a folder" "$(jget "$(out dd-named-renew)" error)" "no_credentials"
check_eq "...and starts nothing" "$(starts "$LOGS/dd-named-renew")" "0"
for args in "--now" "--renew --bogus" "--activity -x" "--renew --now --renew"; do
    label="dd-refuse-${args// /_}"
    # shellcheck disable=SC2086
    run "$label" STUB_MODE=renew -- $args
    check_eq "no --: '$args' is refused" "$(jget "$(out "$label")" error)" "bad_folder"
    check_eq "no --: '$args' starts nothing" "$(starts "$LOGS/$label")" "0"
done

# --- the real folder, however it is spelled ---------------------------------------

section "Lock and state follow the real folder"
X="$FAKE_HOME/.claude-x"
creds "$X" expired
ln -s "$X" "$FAKE_HOME/link-x"
before_files="$(ls "$CACHE" | grep -c '^renew_.*\.json$')"
run real-tilde STUB_MODE=renew -- --renew -- "~/.claude-x"
check_eq "~/.claude-x: renewed" "$(jget "$(out real-tilde)" renew.result)" "renewed"
i=0
for spelled in "$FAKE_HOME/.claude-x/" "$FAKE_HOME//.claude-x" "$FAKE_HOME/link-x"; do
    i=$((i + 1))
    creds "$X" expired
    run "real-$i" STUB_MODE=renew -- --renew -- "$spelled"
    check_eq "${spelled/#"$FAKE_HOME"/\$HOME}: same cool-down" "$(jget "$(out "real-$i")" renew.result)" "cooldown"
done
check_eq "one state file for all four spellings" "$(( $(ls "$CACHE" | grep -c '^renew_.*\.json$') - before_files ))" "1"

# --- locking and the work folder --------------------------------------------------

section "One renewal per account at a time"
C="$WORK/accounts/concurrent"
creds "$C" expired
run conc-a STUB_MODE=renew STUB_DELAY=2 -- --renew --now -- "$C" &
run conc-b STUB_MODE=renew STUB_DELAY=2 -- --renew --now -- "$C" &
wait
results="$(printf '%s\n%s\n' "$(jget "$(out conc-a)" renew.result)" "$(jget "$(out conc-b)" renew.result)" | sort | tr '\n' ' ')"
check_eq "two at once: one renewed, one busy" "$results" "busy renewed "
busy_doc="$(out conc-a)"
if [ "$(jget "$busy_doc" renew.result)" != "busy" ]; then busy_doc="$(out conc-b)"; fi
check_eq "busy reason is running" "$(jget "$busy_doc" renew.reason)" "running"
check_eq "claude started once" "$(( $(starts "$LOGS/conc-a") + $(starts "$LOGS/conc-b") ))" "1"

R="$WORK/accounts/refreshing"
creds "$R" expired
mkdir "$R/.oauth_refresh.lock"
run refreshing STUB_MODE=renew -- --renew --now -- "$R"
check_eq "fresh .oauth_refresh.lock: busy (claude_refreshing)" "$(result_reason refreshing)" "busy claude_refreshing"
check_eq "claude did not start" "$(starts "$LOGS/refreshing")" "0"
touch -d '-2 minutes' "$R/.oauth_refresh.lock"
run stale-lock STUB_MODE=renew -- --renew --now -- "$R"
check_eq "stale .oauth_refresh.lock is ignored" "$(jget "$(out stale-lock)" renew.result)" "renewed"

section "The work folder must be empty"
W="$WORK/accounts/planted"
creds "$W" expired
mkdir -p "$CACHE/claude-renew/.claude"
echo '{"hooks": {}}' > "$CACHE/claude-renew/.claude/settings.json"
run planted STUB_MODE=renew -- --renew --now -- "$W"
check_eq "something in the work folder: workdir_not_empty" "$(jget "$(out planted)" renew.result)" "workdir_not_empty"
check_eq "claude did not start" "$(starts "$LOGS/planted")" "0"
check_eq "no try was recorded" "$(state_of "$W")" "{}"
rm -rf "$CACHE/claude-renew/.claude"

# --- finding claude --------------------------------------------------------------

section "Finding claude"
I="$WORK/accounts/install"
creds "$I" expired
run missing STUB_MODE=renew PATH="$NO_CLAUDE_BIN:$SAFE_PATH" -- --renew -- "$I"
check_eq "not on PATH, no ~/.local/bin/claude: not_installed" "$(jget "$(out missing)" renew.result)" "not_installed"
check_eq "not_installed does not start the cool-down" "$(state_of "$I")" "{}"
mkdir -p "$FAKE_HOME/.local/bin"
cp "$STUB_BIN/claude" "$FAKE_HOME/.local/bin/claude"
chmod 644 "$FAKE_HOME/.local/bin/claude"
run not-exec STUB_MODE=renew PATH="$NO_CLAUDE_BIN:$SAFE_PATH" -- --renew -- "$I"
check_eq "~/.local/bin/claude not executable: not_installed" "$(jget "$(out not-exec)" renew.result)" "not_installed"
printf '#!/nonexistent/interpreter\n' > "$FAKE_HOME/.local/bin/claude"
chmod 755 "$FAKE_HOME/.local/bin/claude"
run broken PATH="$NO_CLAUDE_BIN:$SAFE_PATH" -- --renew --now -- "$I"
check_eq "a claude that cannot start: not_installed (not_started)" "$(result_reason broken)" "not_installed not_started"
cp "$STUB_BIN/claude" "$FAKE_HOME/.local/bin/claude"
run fallback STUB_MODE=renew PATH="$NO_CLAUDE_BIN:$SAFE_PATH" -- --renew --now -- "$I"
check_eq "~/.local/bin/claude is the fallback" "$(jget "$(out fallback)" renew.result)" "renewed"
check_eq "the fallback stub is what ran" "$(starts "$LOGS/fallback")" "1"
rm -f "$FAKE_HOME/.local/bin/claude"

# --- always JSON ---------------------------------------------------------------------

section "Always JSON, always exit 0"
env -i HOME="$FAKE_HOME" PATH="$SAFE_PATH" python3 -I "$HELPER" renew --folder=x --key=1 --bogus \
    > "$OUTPUTS/bad-args.out" 2> "$WORK/bad-args.argparse"
echo "$?" > "$OUTPUTS/bad-args.rc"
check_eq "bad arguments: error JSON" "$(result_reason bad-args)" "error bad_arguments"
env -i HOME="$FAKE_HOME" PATH="$SAFE_PATH" python3 -I "$HELPER" check --bogus \
    > "$OUTPUTS/bad-check.out" 2> "$WORK/bad-check.argparse"
echo "$?" > "$OUTPUTS/bad-check.rc"
check_eq "bad check arguments: check-shaped JSON" "$(out bad-check)" '{"possible": false, "reason": "error"}'
mkdir -p "$WORK/home2/.cache"
echo "not a folder" > "$WORK/home2/.cache/claudemeter"
creds "$WORK/accounts/home2" expired
run broken-cache HOME="$WORK/home2" STUB_MODE=renew -- --renew --now -- "$WORK/accounts/home2"
check_eq "an unexpected failure: error JSON" "$(result_reason broken-cache)" "error internal_error"

# --- the long cases, side by side ------------------------------------------------------

section "Timeouts, a refresh in flight, and the helper being killed (about 70 s)"
H="$WORK/accounts/hang"
T="$WORK/accounts/term"
S="$WORK/accounts/slow"
U="$WORK/accounts/stuck"
K1="$WORK/accounts/killed-hang"
K2="$WORK/accounts/killed-term"
Q="$WORK/accounts/term-twice"
for f in "$H" "$T" "$S" "$U" "$K1" "$K2" "$Q"; do creds "$f" expired; done
run hang STUB_MODE=hang -- --renew -- "$H" &
run term STUB_MODE=ignore-term -- --renew -- "$T" &
run slow STUB_MODE=slow-refresh STUB_DELAY=33 -- --renew -- "$S" &
run stuck STUB_MODE=stuck-refresh -- --renew -- "$U" &
killed_case killed-hang hang "$K1" &
killed_case killed-term ignore-term "$K2" &
term_twice_case term-twice "$Q" &
wait

check_eq "hang: result is timeout" "$(jget "$(out hang)" renew.result)" "timeout"
check_range "hang: stopped by TERM at 30 s" "$(elapsed hang)" 30 33
gone "hang: stub is gone" "$(logval "$LOGS/hang" pid)"
group_empty "hang: its process group is empty" "$(logval "$LOGS/hang" pgid)"
check_eq "hang: a timeout counts for the backoff (next try in 1 h)" \
    "$(( $(jget "$(out hang)" renew.next_try) - $(jget "$(out hang)" renew.last_try) ))" "3600"

check_eq "ignore-TERM: result is timeout" "$(jget "$(out term)" renew.result)" "timeout"
check_range "ignore-TERM: killed 5 s after TERM" "$(elapsed term)" 35 38.5
# coreutils timeout passes the TERM on to the group too, so 1 to 3 can arrive
check_range "ignore-TERM: the stub did get TERM first" "$(grep -c '^got TERM$' "$LOGS/term")" 1 3
gone "ignore-TERM: stub is gone" "$(logval "$LOGS/term" pid)"
gone "ignore-TERM: grandchild is gone" "$(logval "$LOGS/term" grandchild)"
group_empty "ignore-TERM: its process group is empty" "$(logval "$LOGS/term" pgid)"

check_eq "refresh in flight at 30 s: allowed to finish, renewed" "$(jget "$(out slow)" renew.result)" "renewed"
check_range "...at about 33 s" "$(elapsed slow)" 31 36.5
check_eq "refresh lock stays fresh: timeout" "$(jget "$(out stuck)" renew.result)" "timeout"
check_range "...TERM after the 15 s grace, at 45 s" "$(elapsed stuck)" 45 48.5
gone "...and the stub is gone" "$(logval "$LOGS/stuck" pid)"

for k in killed-hang killed-term; do
    check_eq "$k: claude outlives the SIGKILLed helper at first" "$(caseval "$k" alive_after_kill)" "yes"
    check_eq "$k: coreutils timeout is still watching it" "$(caseval "$k" outer_timeout_running)" "yes"
done
check_range "killed-hang: the outer timeout stops it at 60 s" "$(caseval killed-hang gone_after)" 59 63
check_range "killed-term: the outer timeout kills it and its grandchild at 65 s" "$(caseval killed-term gone_after)" 64 68
group_empty "killed-hang: its process group is empty" "$(logval "$LOGS/killed-hang" pgid)"
group_empty "killed-term: its process group is empty" "$(logval "$LOGS/killed-term" pgid)"

check_range "two TERMs: the helper still finishes its cleanup (5 s grace)" "$(caseval term-twice helper_secs)" 5 9
check_eq "two TERMs: nothing left running" "$(caseval term-twice left_running)" "no"
check_eq "two TERMs: error JSON (stopped)" "$(result_reason term-twice)" "error stopped"
check_eq "two TERMs: exit code 0" "$(cat "$OUTPUTS/term-twice.rc")" "0"

# --- leaks and leftovers -----------------------------------------------------------

section "Nothing leaks, nothing is left running"
leaks="$(grep -r -l -E 'fake-(access|refresh|env-token)' "$OUTPUTS" "$LOGS" "$CACHE" 2>/dev/null)"
if [ -z "$leaks" ]; then ok "no fake token string in any output, log or cache file"; else bad "no fake token string in any output, log or cache file" "$leaks"; fi
stderr_bytes="$(cat "$OUTPUTS"/*.err | wc -c)"
check_eq "nothing on stderr" "$stderr_bytes" "0"
nonzero=""
for rc in "$OUTPUTS"/*.rc; do
    label="$(basename "$rc" .rc)"
    case "$label" in killed-*) continue ;; esac
    if [ "$(cat "$rc")" != "0" ]; then nonzero="$nonzero $label=$(cat "$rc")"; fi
done
check_eq "every run exited 0" "${nonzero:-none}" "none"
not_json=""
for o in "$OUTPUTS"/*.out; do
    label="$(basename "$o" .out)"
    case "$label" in killed-*|activity|dd-activity) continue ;; esac
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$o" 2>/dev/null || not_json="$not_json $label"
done
check_eq "every output is JSON" "${not_json:-none}" "none"
left="$(pgrep -a -f "$WORK/" 2>/dev/null || true)"
if [ -z "$left" ]; then ok "no process from this test is still running"; else bad "no process from this test is still running" "$left"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
