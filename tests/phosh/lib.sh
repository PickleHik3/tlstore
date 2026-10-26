# lib.sh - helpers for tests/phosh/test-*.sh and run-headless.sh. Source it; bash only.
# Env from run-headless.sh: FAKE_ENDPOINT FAKE_CONTROL FAKE_TOKEN FAKE_CALLS_FILE PHOC_PID
# TL_PHOC_LOG TL_RUN_DIR, and a session bus in DBUS_SESSION_BUS_ADDRESS.

pass() { echo "ok: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# wait_for <seconds> <description> <command...> - run the command until it succeeds. The things
# waited for answer on events (a name appears on the bus, a call reaches the fake); this loop is
# only the test waiting for them.
wait_for() {
    local secs="$1" what="$2" i
    shift 2
    for ((i = 0; i < secs * 10; i++)); do
        if "$@"; then pass "$what"; return 0; fi
        sleep 0.1
    done
    die "$what (not within ${secs}s)"
}

# The fake's API as phosh sees it (bearer token) and its control port as a test sees it.
fake_api() { curl -fsS -H "Authorization: Bearer $FAKE_TOKEN" "$@"; }
fake_control_get() { curl -fsS "$FAKE_CONTROL$1"; }
fake_control_post() { curl -fsS -X POST -H 'Content-Type: application/json' -d "${2:-\{\}}" "$FAKE_CONTROL$1"; }

fake_calls() { fake_control_get /calls; }                 # JSON array of every call so far
fake_reset() { fake_control_post /reset >/dev/null; }     # forget the calls
fake_push() { fake_control_post "/push/$1" "$2" >/dev/null; }   # fake_push battery '{...}'

# fake_call_count <method> <path> - how many calls of that kind the fake has recorded.
fake_call_count() {
    fake_calls | python3 -I -c '
import json, sys
m, p = sys.argv[1:3]
print(sum(1 for c in json.load(sys.stdin) if c["method"] == m and c["path"] == p))' "$1" "$2"
}

# fake_unexpected - print the recorded calls marked unexpected (bad token, unknown route, bad
# body); succeeds when there are none.
fake_unexpected() {
    fake_calls | python3 -I -c '
import json, sys
bad = [c for c in json.load(sys.stdin) if c["unexpected"]]
for c in bad:
    print(json.dumps(c))
sys.exit(1 if bad else 0)'
}

# on_bus <name> - the session bus has an owner for the name.
on_bus() {
    [ "$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null)" = "(true,)" ]
}

# phosh_pid - the pid of phosh, phoc's child.
phosh_pid() {
    local pid
    for pid in $(pgrep -P "$PHOC_PID" 2>/dev/null); do
        if [[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" == */phosh ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

watcher_open() { [ "$(fake_control_get /watchers)" = '{"watchers": 1}' ]; }

# fake_last_body <method> <path> - the JSON body of the last such call, compact and key-sorted
# (fails when there is none), so a test can compare it with a string.
fake_last_body() {
    fake_calls | python3 -I -c '
import json, sys
m, p = sys.argv[1:3]
bodies = [c["body"] for c in json.load(sys.stdin) if c["method"] == m and c["path"] == p]
if not bodies:
    sys.exit(1)
print(json.dumps(bodies[-1], sort_keys=True, separators=(",", ":")))' "$1" "$2"
}

# What phosh shows, read through mobi.phosh.Shell.DebugControl (the shell exports it on the session
# bus; this build adds TlState and TlTile to it, patch 0023 of recipes/cross/phosh).
# tl_state - the JSON of the backends' state: available, battery, wifi, wwan, rotation, torch and
# tiles.<name>.{found,sensitive,visible,active}.
tl_state() {
    gdbus call --session --dest mobi.phosh.Shell.DebugControl --object-path /mobi/phosh/Shell/DebugControl \
        --method mobi.phosh.Shell.DebugControl.TlState | python3 -I -c '
import ast, sys
print(ast.literal_eval(sys.stdin.read().strip())[0])'
}

# tl_get <path> - one value of tl_state by dotted path (battery.percent): strings as they are,
# the rest as JSON (true, 87, null).
tl_get() {
    tl_state | python3 -I -c '
import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v[k]
print(v if isinstance(v, str) else json.dumps(v))' "$1"
}

# tl_is <path> <value> - succeeds when tl_get prints exactly that (for wait_for).
tl_is() { [ "$(tl_get "$1" 2>/dev/null)" = "$2" ]; }

# tl_tile <wifi|wwan|battery|rotation|torch> <click|long-press> - do to a quick setting what a tap or
# a long-press does.
tl_tile() {
    gdbus call --session --dest mobi.phosh.Shell.DebugControl --object-path /mobi/phosh/Shell/DebugControl \
        --method mobi.phosh.Shell.DebugControl.TlTile "$1" "$2" >/dev/null
}

# fake_body_is <method> <path> <json> - the last such call had exactly that body (for wait_for).
fake_body_is() { [ "$(fake_last_body "$1" "$2" 2>/dev/null)" = "$3" ]; }

# fake_self_test - run-headless.sh --self-test: the fake alone, over curl.
fake_self_test() {
    local code out stream cpid n
    code=$(curl -s -o /dev/null -w '%{http_code}' "$FAKE_ENDPOINT/v1/battery")
    [ "$code" = 401 ] || die "no token answered $code, wanted 401"
    out=$(fake_api "$FAKE_ENDPOINT/v1/battery")
    [[ "$out" == *'"percentage": 87'* ]] || die "battery: $out"
    pass "bearer token checked, GET /v1/battery"
    fake_api -X POST -d '{"lock":true}' "$FAKE_ENDPOINT/v1/rotation" >/dev/null
    out=$(fake_api "$FAKE_ENDPOINT/v1/rotation")
    [[ "$out" == *'"lock": true'* ]] || die "rotation after POST: $out"
    pass "POST /v1/rotation then GET"
    fake_api -X POST -d '{"title":"t","body":"b","id":"x"}' "$FAKE_ENDPOINT/v1/notify" >/dev/null
    fake_api -X POST -d '{"close":"x"}' "$FAKE_ENDPOINT/v1/notify" >/dev/null
    fake_api -X POST -d '{"duration_ms":50}' "$FAKE_ENDPOINT/v1/vibrate" >/dev/null
    fake_api -X POST -d '{"on":true}' "$FAKE_ENDPOINT/v1/torch" >/dev/null
    fake_api -X POST -d '{"page":"wifi"}' "$FAKE_ENDPOINT/v1/settings/open" >/dev/null
    pass "notify, close, vibrate, torch, settings/open"
    # The watch stream: opening comment, three events in order, then a pushed one.
    stream="$TL_RUN_DIR/watch.out"
    curl -sN -H "Authorization: Bearer $FAKE_TOKEN" --max-time 3 "$FAKE_ENDPOINT/v1/watch" >"$stream" &
    cpid=$!
    wait_for 3 "a stream is open" watcher_open
    fake_push battery '{"percentage":50}'
    sleep 0.3
    wait "$cpid" 2>/dev/null || true
    [ "$(head -n1 "$stream")" = ": keepalive" ] || die "stream does not open with a keepalive"
    [ "$(grep '^event:' "$stream" | tr '\n' ' ')" = "event: battery event: network event: rotation event: battery " ] ||
        die "stream events: $(grep '^event:' "$stream" | tr '\n' ' ')"
    grep -q '^data: {"percentage":50}$' "$stream" || die "the pushed event is not on the stream"
    pass "GET /v1/watch: keepalive, one event per topic, then the pushed one"
    n=$(fake_call_count POST /v1/notify)
    [ "$n" = 2 ] || die "notify calls recorded: $n"
    # The one 401 above was deliberate, and is the only unexpected call.
    [ "$(fake_unexpected | wc -l)" = 1 ] || die "unexpected: $(fake_unexpected)"
    pass "only the deliberate 401 is marked unexpected"
}
