#!/usr/bin/env bash
# =============================================================================
# selftest.sh — End-to-end tests for .local.conf and .conf.override mechanisms
# =============================================================================
# Runs 6 tests covering:
#   1. .local.conf auto-discovery (listed as enabled)
#   2. .conf.override with ENABLED=no disables plugin
#   3. .conf.override replaces PATH (override content, not base)
#   4. Full backup with base plugin (files land at correct destination)
#   5. Full restore recovers modified file
#   6. Both files are git-ignored
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
echo -e "${C_BOLD}Running 6 tests...${C_RESET}"
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
# Done
# =============================================================================

echo ""
echo -e "${C_BOLD}${C_GREEN}All 6 tests passed.${C_RESET}"
echo ""
