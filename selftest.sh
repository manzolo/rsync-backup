#!/usr/bin/env bash
# =============================================================================
# selftest.sh — End-to-end tests for .local.conf and .conf.override mechanisms
# =============================================================================
# Runs 10 tests covering:
#   1. .local.conf auto-discovery (listed as enabled)
#   2. .conf.override with ENABLED=no disables plugin
#   3. .conf.override replaces PATH (override content, not base)
#   4. Full backup with base plugin (files land at correct destination)
#   5. Full restore recovers modified file
#   6. Both files are git-ignored
#   7. Versioning: overwritten file is preserved in .versions/<timestamp>/
#   8. "VERSIONING no" in a plugin: overwritten file is NOT kept in .versions/
#   9. Log: a header and a closing line per job, counts instead of the file list,
#      rsync errors kept whole and counted (also without --quiet)
#  10. Pruning: the VERSIONS_KEEP_RUNS most recent version dirs survive their age
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# --- Colors ---
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

PASS() { echo -e "  ${C_GREEN}PASS${C_RESET}  $1"; }
FAIL() { echo -e "  ${C_RED}FAIL${C_RESET}  $1"; exit 1; }
INFO() { echo -e "  ${C_CYAN}....${C_RESET}  $1"; }

# New content for testfile.txt with an mtime of its own: "version 2" and
# "version 3" have the same size, and written within the same second rsync's
# quick check (size + mtime) skipped the file — test 8 failed about 1 run in 3.
VER_TICK=0
new_version() {
    VER_TICK=$((VER_TICK + 1))
    echo "$1" > "$SRC_DIR/testfile.txt"
    touch -d "@$(( $(date +%s) + VER_TICK * 10 ))" "$SRC_DIR/testfile.txt"
}

# --- Test fixtures ---
WORK_DIR="$(mktemp -d -p "$HOME")"
SRC_DIR="$WORK_DIR/src"
DST_DIR="$WORK_DIR/dst"
PLUGIN_NAME="rsync_test.local"
PLUGIN_FILE="plugins/${PLUGIN_NAME}.conf"
PLUGIN_OVERRIDE="plugins/${PLUGIN_NAME}.conf.override"
BKUP_HOST="$(hostname)"

cleanup() {
    rm -f "$PLUGIN_FILE" "$PLUGIN_OVERRIDE"
    if [[ -f .env.bak ]]; then
        mv .env.bak .env
    else
        rm -f .env
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# =============================================================================
# Setup
# =============================================================================

echo ""
echo -e "${C_BOLD}Setting up test environment...${C_RESET}"

mkdir -p "$SRC_DIR" "$DST_DIR"
echo "hello from test" > "$SRC_DIR/testfile.txt"
mkdir -p "$SRC_DIR/subdir"
echo "nested file"    > "$SRC_DIR/subdir/nested.txt"

# Write .env with test DST (trap restores/removes it on exit)
[[ -f .env ]] && cp .env .env.bak
echo "DST=$DST_DIR" > .env

# Create local plugin
cat > "$PLUGIN_FILE" <<EOF
# Test Plugin - End-to-end override test
ENABLED=yes

PATH $SRC_DIR
EOF

echo ""
echo -e "${C_BOLD}Running 8 tests...${C_RESET}"
echo ""

# =============================================================================
# Test 1: .local.conf auto-discovered and listed as enabled
# =============================================================================

INFO "Test 1: .local.conf is auto-discovered and listed as enabled"

# Capture output first to avoid SIGPIPE from grep -q exiting early
LIST_OUT="$(./backup.sh --list 2>&1)"
if ! echo "$LIST_OUT" | grep -q "${PLUGIN_NAME}.*enabled"; then
    FAIL "Plugin '${PLUGIN_NAME}' not listed as enabled (test 1)"
fi
PASS "Plugin '${PLUGIN_NAME}' appears as enabled in --list"

# =============================================================================
# Test 2: .conf.override with ENABLED=no disables plugin
# =============================================================================

INFO "Test 2: .conf.override with ENABLED=no disables the plugin"

cat > "$PLUGIN_OVERRIDE" <<EOF
# Test Plugin Override
ENABLED=no
PATH $SRC_DIR
EOF

LIST_OUT="$(./backup.sh --list 2>&1)"
if ! echo "$LIST_OUT" | grep -q "${PLUGIN_NAME}.*disabled"; then
    FAIL "Plugin '${PLUGIN_NAME}' not listed as disabled when override has ENABLED=no (test 2)"
fi
PASS "Plugin '${PLUGIN_NAME}' appears as disabled when override has ENABLED=no"

rm -f "$PLUGIN_OVERRIDE"

# =============================================================================
# Test 3: .conf.override replaces PATH — backup uses override PATH, not base
# =============================================================================

INFO "Test 3: .conf.override PATH replaces base plugin PATH"

OVERRIDE_SRC="$WORK_DIR/override_src"
mkdir -p "$OVERRIDE_SRC"
echo "override content" > "$OVERRIDE_SRC/override.txt"

cat > "$PLUGIN_OVERRIDE" <<EOF
# Test Plugin Override
ENABLED=yes
PATH $OVERRIDE_SRC
EOF

./backup.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME"

if [[ ! -f "$DST_DIR/$BKUP_HOST$OVERRIDE_SRC/override.txt" ]]; then
    FAIL "override.txt not found in backup (override PATH not used) (test 3)"
fi
if [[ -f "$DST_DIR/$BKUP_HOST$SRC_DIR/testfile.txt" ]]; then
    FAIL "testfile.txt found in backup (base PATH used despite override) (test 3)"
fi
PASS "Backup used override PATH; base PATH was not backed up"

rm -f "$PLUGIN_OVERRIDE"
rm -rf "$DST_DIR"
mkdir -p "$DST_DIR"

# =============================================================================
# Test 4: Full backup — files land at correct destination
# =============================================================================

INFO "Test 4: Full backup writes files to correct destination"

./backup.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME"

BKUP_DEST="$DST_DIR/$BKUP_HOST$SRC_DIR"

if [[ ! -f "$BKUP_DEST/testfile.txt" ]]; then
    FAIL "testfile.txt not found in backup destination '$BKUP_DEST' (test 4)"
fi
if [[ ! -f "$BKUP_DEST/subdir/nested.txt" ]]; then
    FAIL "subdir/nested.txt not found in backup destination (test 4)"
fi
if [[ "$(cat "$BKUP_DEST/testfile.txt")" != "hello from test" ]]; then
    FAIL "Backup content mismatch for testfile.txt (test 4)"
fi
PASS "All files present in backup with correct content"

# =============================================================================
# Test 5: Restore — recovers modified file from backup
# =============================================================================

INFO "Test 5: Restore recovers modified file from backup"

echo "modified content" > "$SRC_DIR/testfile.txt"

./restore.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME"

if [[ "$(cat "$SRC_DIR/testfile.txt")" != "hello from test" ]]; then
    FAIL "Restore did not recover original content of testfile.txt (test 5)"
fi
PASS "Restore recovered original content"

# =============================================================================
# Test 6: Both files are git-ignored
# =============================================================================

INFO "Test 6: .local.conf and .conf.override are git-ignored"

# Ensure override file exists for this check
touch "$PLUGIN_OVERRIDE"

GIT_OUT="$(git status --porcelain)"

if echo "$GIT_OUT" | grep -q "$PLUGIN_FILE"; then
    FAIL ".local.conf ('$PLUGIN_FILE') appears in git status — not git-ignored (test 6)"
fi
if echo "$GIT_OUT" | grep -q "$PLUGIN_OVERRIDE"; then
    FAIL ".conf.override ('$PLUGIN_OVERRIDE') appears in git status — not git-ignored (test 6)"
fi
PASS "Neither file appears in git status (both are git-ignored)"

# =============================================================================
# Test 7: Versioning — overwritten file is preserved in .versions/<timestamp>/
# =============================================================================

INFO "Test 7: versioning preserves the overwritten file in .versions/"

rm -f "$PLUGIN_OVERRIDE"   # test 6 left an empty override that disables the plugin
new_version "version 2"

./backup.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME"

if [[ "$(cat "$BKUP_DEST/testfile.txt")" != "version 2" ]]; then
    FAIL "Backup destination was not updated to new content (test 7)"
fi

VERSIONED=("$DST_DIR/$BKUP_HOST/.versions/"*"$SRC_DIR/testfile.txt")
if [[ ! -f "${VERSIONED[0]}" ]]; then
    FAIL "Old testfile.txt not found under .versions/ (test 7)"
fi
if [[ "$(cat "${VERSIONED[0]}")" != "hello from test" ]]; then
    FAIL "Versioned file content mismatch: expected original content (test 7)"
fi
PASS "Old content preserved in ${VERSIONED[0]#"$DST_DIR/"}"

# =============================================================================
# Test 8: "VERSIONING no" in a plugin — overwritten file is NOT kept in .versions/
# =============================================================================

INFO "Test 8: a plugin with VERSIONING no mirrors without keeping old versions"

sed -i 's/^ENABLED=yes$/ENABLED=yes\nVERSIONING no/' "$PLUGIN_FILE"
new_version "version 3"
BEFORE=$(find "$DST_DIR/$BKUP_HOST/.versions" -type f -name testfile.txt | wc -l)

./backup.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME"

if [[ "$(cat "$BKUP_DEST/testfile.txt")" != "version 3" ]]; then
    FAIL "Backup destination was not updated to new content (test 8)"
fi
AFTER=$(find "$DST_DIR/$BKUP_HOST/.versions" -type f -name testfile.txt | wc -l)
if [[ "$AFTER" -ne "$BEFORE" ]]; then
    FAIL "A new version landed in .versions/ although the plugin says VERSIONING no (test 8)"
fi
PASS "Destination updated, .versions/ untouched ($AFTER copies before and after)"

# =============================================================================
# Test 9: log — one header and one closing line per job, counts instead of the
# per-file list, rsync errors kept whole and counted, with and without --quiet
# =============================================================================

INFO "Test 9: the log tells each job apart and keeps its errors"

LOG="$WORK_DIR/test.log"
printf 'DST=%s\nLOG_FILE=%s\n' "$DST_DIR" "$LOG" > .env
sed -i '/^VERSIONING no$/d' "$PLUGIN_FILE"
new_version "version 4"

./backup.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME" >/dev/null

grep -q "^######## .* backup .* LIVE  1 jobs" "$LOG" || FAIL "No run header in the log (test 9)"
grep -q "^=== \[1/1\] .*$SRC_DIR (" "$LOG"       || FAIL "No job header in the log (test 9)"
grep -q "^  files transferred: 1, deleted: 0$" "$LOG" || FAIL "Wrong or missing transfer count (test 9)"
grep -q "^--- ok in [0-9]*s$" "$LOG"               || FAIL "No closing line for the job (test 9)"
if grep -q "testfile.txt" "$LOG"; then
    FAIL "The per-file list reached the log although LOG_FILE_LIST=no (test 9)"
fi
PASS "Run and job headers, counts, closing line; no file list"

# A failing rsync. A real error is hard to provoke here: for a file the user
# cannot read, backup.sh moves the job to sudo rsync, which reads it. What is
# under test is how backup.sh logs and counts the failure, so a fake rsync
# first in PATH prints a sender error and exits 23 like the real one.
FAKE_BIN="$WORK_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/rsync" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && exec /usr/bin/rsync --version
echo "sending incremental file list"
echo 'rsync: [sender] send_files failed to open "/src/unreadable.txt": Permission denied (13)' >&2
echo "sent 10 bytes  received 10 bytes  40,00 bytes/sec"
echo "total size is 4  speedup is 0,20"
exit 23
FAKE
chmod +x "$FAKE_BIN/rsync"
for mode in --quiet ""; do
    : > "$LOG"
    OUT="$(PATH="$FAKE_BIN:$PATH" ./backup.sh --yes $mode --no-common --plugin="$PLUGIN_NAME" 2>&1 || true)"
    grep -q '^  ! rsync: \[sender\] send_files failed to open .*Permission denied (13)$' "$LOG" \
        || FAIL "rsync error missing from the log (test 9, mode '${mode:-interactive}')"
    grep -q "^--- ERROR: rsync exit 23 after" "$LOG" || FAIL "No ERROR closing line (test 9, mode '${mode:-interactive}')"
    echo "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Jobs with errors: 1" \
        || FAIL "The failed job was not counted as an error (test 9, mode '${mode:-interactive}')"
done
PASS "rsync error kept in the log and counted, with --quiet and without"

# =============================================================================
# Test 10: pruning keeps the VERSIONS_KEEP_RUNS most recent version dirs,
# whatever their age, and prunes the older ones past VERSIONS_KEEP_DAYS
# =============================================================================

INFO "Test 10: the most recent runs survive the age limit"

VROOT="$DST_DIR/$BKUP_HOST/.versions"
rm -rf "$VROOT"
for day in 01 02 03 04 05; do
    mkdir -p "$VROOT/2020-01-${day}_000000/x"
    echo "old $day" > "$VROOT/2020-01-${day}_000000/x/f"
    touch -d "2020-01-$day" "$VROOT/2020-01-${day}_000000"
done
new_version "version 5"   # this run versions a file: 6 dirs, keep 3

./backup.sh --yes --quiet --no-common --plugin="$PLUGIN_NAME" >/dev/null

LEFT="$(cd "$VROOT" && ls -1 | sort | tr '\n' ' ')"
[[ $(ls -1 "$VROOT" | wc -l) -eq 3 ]]              || FAIL "Expected 3 version dirs, found: $LEFT (test 10)"
[[ -d "$VROOT/2020-01-05_000000" && -d "$VROOT/2020-01-04_000000" ]] \
    || FAIL "The two most recent old runs were pruned: $LEFT (test 10)"
[[ ! -e "$VROOT/2020-01-03_000000" ]]               || FAIL "A run beyond the last 3 was kept: $LEFT (test 10)"
PASS "Kept the current run and the two before it: $LEFT"

# =============================================================================
# Done
# =============================================================================

echo ""
echo -e "${C_BOLD}${C_GREEN}All 10 tests passed.${C_RESET}"
echo ""
