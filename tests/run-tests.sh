#!/bin/bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/mst-omarchy-backup-tests.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc (expected [$expected], got [$actual])"; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then ok "$desc"; else fail "$desc (missing [$needle])"; fi
}

FAKE_BIN="$WORK/bin"
TEST_HOME="$WORK/home"
mkdir -p "$FAKE_BIN" "$TEST_HOME/.local/share/omarchy-backup"
cat > "$TEST_HOME/.local/share/omarchy-backup/state.json" <<'EOF'
{"snapshots":[]}
EOF

cat > "$FAKE_BIN/omarchy-backup" <<'EOF'
#!/bin/bash
case "${1:-}" in
  doctor)
    head -c 20000 /dev/zero | tr '\0' X
    ;;
  status)
    head -c 10000 /dev/zero | tr '\0' Y
    ;;
  config)
    printf '[]\n'
    ;;
  *)
    printf 'ok\n'
    ;;
esac
EOF
chmod +x "$FAKE_BIN/omarchy-backup"

echo "== 1. action output is producer-bounded before JSON/QML forwarding =="
action_json="$(HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/run-action" doctor)"
assert_eq "oversized action returns valid JSON" "true" "$(printf '%s' "$action_json" | jq -e . >/dev/null 2>&1 && echo true || echo false)"
assert_eq "oversized action fails closed" "false" "$(printf '%s' "$action_json" | jq -r .ok)"
assert_contains "oversized action explains the cap" "$(printf '%s' "$action_json" | jq -r .output)" "output exceeded"

echo "== 2. status aggregation refuses oversized CLI output =="
status_json="$(HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/status-json")"
assert_eq "bounded status returns valid JSON" "true" "$(printf '%s' "$status_json" | jq -e . >/dev/null 2>&1 && echo true || echo false)"
assert_eq "oversized status becomes ERROR" "ERROR" "$(printf '%s' "$status_json" | jq -r .color)"
assert_contains "status error explains output/time limit" "$(printf '%s' "$status_json" | jq -r .statusText)" "output or time limit"

echo "== 3. action timeout is surfaced as a bounded failure =="
REAL_TIMEOUT="$(command -v timeout)"
cat > "$FAKE_BIN/timeout" <<EOF
#!/bin/bash
for arg in "\$@"; do
  if [ "\$arg" = doctor ]; then exit 124; fi
done
exec "$REAL_TIMEOUT" "\$@"
EOF
chmod +x "$FAKE_BIN/timeout"
timeout_json="$(HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/bin/run-action" doctor)"
assert_eq "timed-out action fails closed" "false" "$(printf '%s' "$timeout_json" | jq -r .ok)"
assert_contains "timed-out action explains the deadline" "$(printf '%s' "$timeout_json" | jq -r .output)" "safety deadline"

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
