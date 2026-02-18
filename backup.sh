#!/usr/bin/env bash
# =============================================================================
# Rsync Backup Manager - Unified backup system with plugin-based configuration
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_CONF="$SCRIPT_DIR/backup.conf"
COMMON_CONF="$SCRIPT_DIR/common.conf"
PLUGINS_DIR="$SCRIPT_DIR/plugins"

# --- Color codes ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Field separator for job entries (ASCII Record Separator) ---
FS=$'\x1e'

# --- Global state ---
DRY_RUN=false
SKIP_CONFIRM=false
USE_TUI=false
NO_COMMON=false
NO_DELETE=false
QUIET=false
LIST_ONLY=false
SHOW_HELP=false
declare -a SELECTED_PLUGINS=()
declare -a ALL_JOBS=()     # "source|dest|includes|excludes|needs_sudo|label"
DIALOG_CMD=""
TOTAL_FILES=0
TOTAL_ERRORS=0
START_TIME=0

# --- Global config defaults ---
DST=""
RSYNC_FLAGS="--archive --verbose --human-readable --progress --partial"
RSYNC_DELETE=yes
LOG_FILE=""

# =============================================================================
# Dependency checks
# =============================================================================

check_dependencies() {
    if ! command -v rsync &>/dev/null; then
        echo -e "${C_RED}Error: rsync is not installed.${C_RESET}"
        read -rp "Install it now? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo apt install -y rsync || { echo -e "${C_RED}Installation failed. Exiting.${C_RESET}"; exit 1; }
        else
            echo "Cannot continue without rsync. Exiting."
            exit 1
        fi
    fi

    if [[ "$USE_TUI" == true ]]; then
        detect_dialog
        if [[ -z "$DIALOG_CMD" ]]; then
            echo -e "${C_RED}Error: neither dialog nor whiptail is installed.${C_RESET}"
            read -rp "Install dialog now? [y/N] " ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                sudo apt install -y dialog || { echo -e "${C_RED}Installation failed. Exiting.${C_RESET}"; exit 1; }
                DIALOG_CMD="dialog"
            else
                echo "Cannot use TUI without dialog or whiptail. Exiting."
                exit 1
            fi
        fi
    fi
}

# =============================================================================
# Argument parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tui)        USE_TUI=true ;;
            --dry-run)    DRY_RUN=true ;;
            --yes)        SKIP_CONFIRM=true ;;
            --no-common)  NO_COMMON=true ;;
            --no-delete)  NO_DELETE=true ;;
            --quiet)      QUIET=true ;;
            --list)       LIST_ONLY=true ;;
            --help)       SHOW_HELP=true ;;
            --plugin=*)   SELECTED_PLUGINS+=("${1#--plugin=}") ;;
            *)
                echo -e "${C_RED}Unknown option: $1${C_RESET}"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
        shift
    done
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat <<'HELP'
Rsync Backup Manager
====================

A unified backup system using rsync with modular plugin-based configuration,
colored preview, dry-run support, and an interactive TUI.

USAGE
    backup.sh [OPTIONS]

OPTIONS
    --tui               Launch interactive TUI menu (requires dialog or whiptail)
    --dry-run           Run rsync in dry-run mode (no actual changes)
    --yes               Skip confirmation prompt, execute immediately
    --plugin=NAME       Run only the specified plugin (repeatable)
                        Example: --plugin=firefox --plugin=ssh
    --no-common         Skip common.conf paths
    --no-delete         Override RSYNC_DELETE, do not delete from destination
    --list              List all plugins and their ENABLED status, then exit
    --quiet             Minimal output (summary only)
    --help              Show this help message

CONFIGURATION FORMAT
    Global config (backup.conf):
        DST=/media/manzolo/backup-drive
        RSYNC_FLAGS="--archive --verbose --human-readable --progress --partial"
        RSYNC_DELETE=yes
        LOG_FILE=/path/to/backup.log

    Path config (common.conf and plugins/*.conf):
        Each PATH line defines a source directory/file to back up.
        INCLUDE and EXCLUDE lines apply to the immediately preceding PATH.

        PATH /home/user/.config
        EXCLUDE cache/
        PATH /home/user/.local
        INCLUDE important/
        EXCLUDE *

    Plugin files also have an ENABLED=yes|no line at the top.

INCLUDE/EXCLUDE RULES
    Rules follow rsync's "first match wins" logic.
    INCLUDE rules are placed before EXCLUDE rules in the rsync command.
    For directory includes, the pattern/** variant is added automatically.

    Example - back up only "important/" from a directory:
        PATH /home/user/data
        INCLUDE important/
        EXCLUDE *
    This generates: --include='important/' --include='important/**' --exclude='*'

DELETE BEHAVIOR
    When RSYNC_DELETE=yes (default), rsync uses --delete to create an exact
    mirror. Files deleted from the source will also be deleted from the backup.
    Use --no-delete to override this and keep old files on the destination.

SUDO HANDLING
    The script automatically detects paths that require elevated privileges:
    - Paths outside $HOME (e.g., /etc, /opt)
    - Paths inside $HOME that are not readable by the current user
    These jobs run with sudo rsync. The preview shows [sudo] for such jobs.

EXAMPLES
    # Preview and run full backup (all enabled plugins + common paths):
    backup.sh

    # Dry-run to see what would be transferred:
    backup.sh --dry-run

    # Back up only Firefox and SSH, skip confirmation:
    backup.sh --plugin=firefox --plugin=ssh --yes

    # Launch the interactive TUI:
    backup.sh --tui

    # List all plugins:
    backup.sh --list
HELP
}

# =============================================================================
# Configuration loading
# =============================================================================

load_global_config() {
    if [[ ! -f "$GLOBAL_CONF" ]]; then
        echo -e "${C_RED}Error: Global config not found: $GLOBAL_CONF${C_RESET}"
        exit 1
    fi
    # Source the config (it's valid bash variable assignments)
    # shellcheck source=/dev/null
    source "$GLOBAL_CONF"

    if [[ -z "$DST" ]]; then
        echo -e "${C_RED}Error: DST is not set in $GLOBAL_CONF${C_RESET}"
        exit 1
    fi

    # Append hostname to destination
    DST="$DST/$(hostname)"
}

# Parse a conf file with PATH/INCLUDE/EXCLUDE format.
# Populates ALL_JOBS array with entries: "source|includes|excludes|label"
parse_conf_file() {
    local file="$1"
    local label="$2"
    local current_path=""
    local current_includes=""
    local current_excludes=""

    # Flush previous path entry
    _flush_job() {
        if [[ -n "$current_path" ]]; then
            local needs_sudo="no"
            if path_needs_sudo "$current_path"; then
                needs_sudo="yes"
            fi
            local dest="$DST$current_path"
            ALL_JOBS+=("${current_path}${FS}${dest}${FS}${current_includes}${FS}${current_excludes}${FS}${needs_sudo}${FS}${label}")
        fi
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading/trailing whitespace
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # Skip comments and empty lines
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Skip ENABLED line
        [[ "$line" == ENABLED=* ]] && continue
        # Skip PRE_CMD line (handled separately)
        [[ "$line" == PRE_CMD\ * ]] && continue
        # Skip RESTORE_CMD line (only meaningful for restore.sh)
        [[ "$line" == RESTORE_CMD\ * ]] && continue

        if [[ "$line" == PATH\ * ]]; then
            _flush_job
            current_path="${line#PATH }"
            # Expand $HOME and ~ in paths
            current_path="${current_path//\$HOME/$HOME}"
            current_path="${current_path/#\~/$HOME}"
            current_includes=""
            current_excludes=""
        elif [[ "$line" == INCLUDE\ * ]]; then
            local pattern="${line#INCLUDE }"
            if [[ -n "$current_includes" ]]; then
                current_includes="$current_includes|$pattern"
            else
                current_includes="$pattern"
            fi
        elif [[ "$line" == EXCLUDE\ * ]]; then
            local pattern="${line#EXCLUDE }"
            if [[ -n "$current_excludes" ]]; then
                current_excludes="$current_excludes|$pattern"
            else
                current_excludes="$pattern"
            fi
        fi
    done < "$file"
    _flush_job

    unset -f _flush_job
}

load_common() {
    if [[ "$NO_COMMON" == true ]]; then
        return
    fi
    if [[ -f "$COMMON_CONF" ]]; then
        parse_conf_file "$COMMON_CONF" "common"
    fi
}

# Get ENABLED status from a plugin conf file
plugin_is_enabled() {
    local file="$1"
    local enabled
    enabled=$(grep -m1 '^ENABLED=' "$file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    [[ "$enabled" == "yes" ]]
}

# Get the description comment (first # line after ENABLED or first # line)
plugin_description() {
    local file="$1"
    head -1 "$file" 2>/dev/null | sed 's/^#[[:space:]]*//'
}

load_plugins() {
    local plugin_files=("$PLUGINS_DIR"/*.conf)
    if [[ ! -e "${plugin_files[0]}" ]]; then
        return
    fi

    for pfile in "${plugin_files[@]}"; do
        local pname
        pname="$(basename "$pfile" .conf)"

        # If user specified --plugin=..., only load those
        if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
            local found=false
            for sp in "${SELECTED_PLUGINS[@]}"; do
                if [[ "$sp" == "$pname" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                continue
            fi
        else
            # Otherwise respect ENABLED flag
            if ! plugin_is_enabled "$pfile"; then
                continue
            fi
        fi

        parse_conf_file "$pfile" "$pname"
    done
}

# =============================================================================
# Pre-commands execution
# =============================================================================

run_pre_commands() {
    # Execute PRE_CMD lines from common.conf and active plugin confs
    local -a conf_files=()
    if [[ "$NO_COMMON" != true && -f "$COMMON_CONF" ]]; then
        conf_files+=("$COMMON_CONF")
    fi

    local plugin_files=("$PLUGINS_DIR"/*.conf)
    if [[ -e "${plugin_files[0]}" ]]; then
        for pfile in "${plugin_files[@]}"; do
            local pname
            pname="$(basename "$pfile" .conf)"
            if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
                local found=false
                for sp in "${SELECTED_PLUGINS[@]}"; do
                    [[ "$sp" == "$pname" ]] && found=true && break
                done
                [[ "$found" == false ]] && continue
            else
                plugin_is_enabled "$pfile" || continue
            fi
            conf_files+=("$pfile")
        done
    fi

    for cfile in "${conf_files[@]}"; do
        while IFS= read -r line; do
            line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ "$line" == PRE_CMD\ * ]]; then
                local cmd="${line#PRE_CMD }"
                # Expand $HOME in command
                cmd="${cmd//\$HOME/$HOME}"
                if [[ "$QUIET" == false ]]; then
                    echo -e "${C_CYAN}Running pre-command: $cmd${C_RESET}"
                fi
                eval "$cmd" || echo -e "${C_YELLOW}Warning: pre-command failed: $cmd${C_RESET}"
            fi
        done < "$cfile"
    done
}

# =============================================================================
# Sudo pre-authentication
# =============================================================================

SUDO_KEEPALIVE_PID=""

# Check if any loaded job requires sudo and pre-authenticate if so.
# This avoids mid-execution password prompts that stall unattended runs.
sudo_preauth() {
    local needs=false
    for job in "${ALL_JOBS[@]}"; do
        local ns
        ns="$(echo "$job" | cut -d"$FS" -f5)"
        if [[ "$ns" == "yes" ]]; then
            needs=true
            break
        fi
    done

    if [[ "$needs" == false ]]; then
        return
    fi

    if [[ "$QUIET" == false ]]; then
        echo -e "${C_YELLOW}Some jobs require elevated privileges (sudo).${C_RESET}"
        echo -e "${C_YELLOW}Authenticating now so the process won't stall later...${C_RESET}"
        echo ""
    fi

    if ! sudo -v 2>/dev/null; then
        echo -e "${C_RED}Error: sudo authentication failed. Cannot proceed with privileged jobs.${C_RESET}"
        exit 1
    fi

    # Start a background keep-alive to refresh the sudo timestamp
    # so long-running operations don't lose the cached credentials.
    (while true; do sudo -n true 2>/dev/null; sleep 50; done) &
    SUDO_KEEPALIVE_PID=$!
}

# Stop the sudo keep-alive background process
sudo_keepalive_stop() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

# Ensure keep-alive is stopped on exit
trap sudo_keepalive_stop EXIT

# =============================================================================
# Path validation and sudo detection
# =============================================================================

path_needs_sudo() {
    local p="$1"
    # Paths outside HOME need sudo
    if [[ "$p" != "$HOME"* ]]; then
        return 0
    fi
    # Existing but unreadable paths need sudo
    if [[ -e "$p" && ! -r "$p" ]]; then
        return 0
    fi
    # For directories, check if any file inside is not readable.
    # find stops at the first match (-quit) so this is fast even for large trees.
    if [[ -d "$p" ]]; then
        if find "$p" ! -readable -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    fi
    return 1
}

validate_paths() {
    local warn_count=0
    for i in "${!ALL_JOBS[@]}"; do
        local job="${ALL_JOBS[$i]}"
        local src
        src="$(echo "$job" | cut -d"$FS" -f1)"
        # Use compgen to handle glob patterns in paths
        if [[ "$src" == *[\*\?]* ]]; then
            # Path contains glob characters - check if any match exists
            if ! compgen -G "$src" >/dev/null 2>&1; then
                if [[ "$QUIET" == false ]]; then
                    echo -e "${C_YELLOW}Warning: no match for pattern: $src${C_RESET}"
                fi
                warn_count=$((warn_count + 1))
            fi
        elif [[ ! -e "$src" ]]; then
            if [[ "$QUIET" == false ]]; then
                echo -e "${C_YELLOW}Warning: source path does not exist: $src${C_RESET}"
            fi
            warn_count=$((warn_count + 1))
        fi
    done
    if [[ $warn_count -gt 0 && "$QUIET" == false ]]; then
        echo -e "${C_YELLOW}$warn_count path(s) not found. They will be skipped by rsync.${C_RESET}"
        echo ""
    fi
}

# =============================================================================
# Rsync command building
# =============================================================================

build_rsync_args() {
    local job="$1"
    local src includes_str excludes_str needs_sudo
    src="$(echo "$job" | cut -d"$FS" -f1)"
    includes_str="$(echo "$job" | cut -d"$FS" -f3)"
    excludes_str="$(echo "$job" | cut -d"$FS" -f4)"
    needs_sudo="$(echo "$job" | cut -d"$FS" -f5)"

    local dest="$DST$src"
    local -a args=()

    # Base flags (split into array)
    # shellcheck disable=SC2086
    read -ra flag_arr <<< "$RSYNC_FLAGS"
    args+=("${flag_arr[@]}")

    # Delete flag
    if [[ "$RSYNC_DELETE" == "yes" && "$NO_DELETE" == false ]]; then
        args+=("--delete")
    fi

    # Dry-run
    if [[ "$DRY_RUN" == true ]]; then
        args+=("--dry-run")
    fi

    # Include rules (must come before excludes - first match wins)
    if [[ -n "$includes_str" ]]; then
        IFS='|' read -ra inc_arr <<< "$includes_str"
        for inc in "${inc_arr[@]}"; do
            args+=("--include=$inc")
            # For directory patterns, also include contents
            if [[ "$inc" == */ ]]; then
                args+=("--include=${inc}**")
            fi
        done
    fi

    # Exclude rules
    if [[ -n "$excludes_str" ]]; then
        IFS='|' read -ra exc_arr <<< "$excludes_str"
        for exc in "${exc_arr[@]}"; do
            args+=("--exclude=$exc")
        done
    fi

    # Source must end with / for directory sync, or be a file
    local rsync_src="$src"
    if [[ -d "$src" ]]; then
        rsync_src="${src%/}/"
    fi

    # Build the destination directory (parent of the target)
    local rsync_dest
    if [[ -d "$src" ]]; then
        rsync_dest="${dest%/}/"
    else
        rsync_dest="$(dirname "$dest")/"
    fi

    # Prefix with sudo if needed
    local prefix=""
    if [[ "$needs_sudo" == "yes" ]]; then
        prefix="sudo "
    fi

    echo "${prefix}rsync ${args[*]} ${rsync_src} ${rsync_dest}"
}

# =============================================================================
# Preview
# =============================================================================

show_preview() {
    local delete_active=false
    if [[ "$RSYNC_DELETE" == "yes" && "$NO_DELETE" == false ]]; then
        delete_active=true
    fi

    echo ""
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  Rsync Backup Preview${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  Destination root: ${C_CYAN}$DST${C_RESET}"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  Mode:             ${C_YELLOW}DRY-RUN (no changes will be made)${C_RESET}"
    else
        echo -e "  Mode:             ${C_GREEN}LIVE${C_RESET}"
    fi
    if [[ "$delete_active" == true ]]; then
        echo -e "  Delete:           ${C_RED}--delete active (mirror mode)${C_RESET}"
    else
        echo -e "  Delete:           ${C_GREEN}disabled${C_RESET}"
    fi
    echo ""

    local current_label=""
    for job in "${ALL_JOBS[@]}"; do
        local src includes_str excludes_str needs_sudo label
        src="$(echo "$job" | cut -d"$FS" -f1)"
        includes_str="$(echo "$job" | cut -d"$FS" -f3)"
        excludes_str="$(echo "$job" | cut -d"$FS" -f4)"
        needs_sudo="$(echo "$job" | cut -d"$FS" -f5)"
        label="$(echo "$job" | cut -d"$FS" -f6)"

        if [[ "$label" != "$current_label" ]]; then
            current_label="$label"
            echo -e "  ${C_BOLD}── [$label] ──${C_RESET}"
        fi

        local sudo_tag=""
        if [[ "$needs_sudo" == "yes" ]]; then
            sudo_tag="${C_YELLOW}[sudo] ${C_RESET}"
        fi

        echo -e "    ${sudo_tag}${C_GREEN}$src${C_RESET}"
        echo -e "      → ${C_CYAN}$DST$src${C_RESET}"

        if [[ -n "$includes_str" ]]; then
            IFS='|' read -ra inc_arr <<< "$includes_str"
            for inc in "${inc_arr[@]}"; do
                echo -e "        ${C_MAGENTA}+ include: $inc${C_RESET}"
            done
        fi
        if [[ -n "$excludes_str" ]]; then
            IFS='|' read -ra exc_arr <<< "$excludes_str"
            for exc in "${exc_arr[@]}"; do
                echo -e "        ${C_YELLOW}- exclude: $exc${C_RESET}"
            done
        fi
        if [[ ! -e "$src" ]]; then
            echo -e "        ${C_YELLOW}(path does not exist - will be skipped)${C_RESET}"
        fi
    done

    echo ""
    echo -e "${C_BOLD}  Total jobs: ${#ALL_JOBS[@]}${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
}

# Generate plain-text preview (for TUI)
generate_preview_text() {
    local delete_active=false
    if [[ "$RSYNC_DELETE" == "yes" && "$NO_DELETE" == false ]]; then
        delete_active=true
    fi

    echo "==========================================================="
    echo "  Rsync Backup Preview"
    echo "==========================================================="
    echo ""
    echo "  Destination root: $DST"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  Mode:             DRY-RUN (no changes will be made)"
    else
        echo "  Mode:             LIVE"
    fi
    if [[ "$delete_active" == true ]]; then
        echo "  Delete:           --delete active (mirror mode)"
    else
        echo "  Delete:           disabled"
    fi
    echo ""

    local current_label=""
    for job in "${ALL_JOBS[@]}"; do
        local src includes_str excludes_str needs_sudo label
        src="$(echo "$job" | cut -d"$FS" -f1)"
        includes_str="$(echo "$job" | cut -d"$FS" -f3)"
        excludes_str="$(echo "$job" | cut -d"$FS" -f4)"
        needs_sudo="$(echo "$job" | cut -d"$FS" -f5)"
        label="$(echo "$job" | cut -d"$FS" -f6)"

        if [[ "$label" != "$current_label" ]]; then
            current_label="$label"
            echo "  -- [$label] --"
        fi

        local sudo_tag=""
        if [[ "$needs_sudo" == "yes" ]]; then
            sudo_tag="[sudo] "
        fi

        echo "    ${sudo_tag}$src"
        echo "      -> $DST$src"

        if [[ -n "$includes_str" ]]; then
            IFS='|' read -ra inc_arr <<< "$includes_str"
            for inc in "${inc_arr[@]}"; do
                echo "        + include: $inc"
            done
        fi
        if [[ -n "$excludes_str" ]]; then
            IFS='|' read -ra exc_arr <<< "$excludes_str"
            for exc in "${exc_arr[@]}"; do
                echo "        - exclude: $exc"
            done
        fi
        if [[ ! -e "$src" ]]; then
            echo "        (path does not exist - will be skipped)"
        fi
    done

    echo ""
    echo "  Total jobs: ${#ALL_JOBS[@]}"
    echo "==========================================================="
}

# =============================================================================
# Confirmation
# =============================================================================

confirm_execution() {
    if [[ "$SKIP_CONFIRM" == true ]]; then
        return 0
    fi
    read -rp "Proceed with backup? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Backup cancelled."
        exit 0
    fi
}

# =============================================================================
# Backup execution
# =============================================================================

run_backup() {
    START_TIME=$(date +%s)
    TOTAL_FILES=0
    TOTAL_ERRORS=0

    local job_num=0
    local total_jobs=${#ALL_JOBS[@]}

    for job in "${ALL_JOBS[@]}"; do
        job_num=$((job_num + 1))
        local src label
        src="$(echo "$job" | cut -d"$FS" -f1)"
        label="$(echo "$job" | cut -d"$FS" -f6)"

        # Skip non-existent paths (glob-aware)
        local path_exists=true
        if [[ "$src" == *[\*\?]* ]]; then
            compgen -G "$src" >/dev/null 2>&1 || path_exists=false
        elif [[ ! -e "$src" ]]; then
            path_exists=false
        fi
        if [[ "$path_exists" == false ]]; then
            if [[ "$QUIET" == false ]]; then
                echo ""
                echo -e "${C_YELLOW}[$job_num/$total_jobs] Skipping (not found): $src ($label)${C_RESET}"
            fi
            continue
        fi

        if [[ "$QUIET" == false ]]; then
            echo ""
            echo -e "${C_BOLD}[$job_num/$total_jobs] Backing up: $src ($label)${C_RESET}"
        fi

        local cmd
        cmd="$(build_rsync_args "$job")"

        # Create destination directory
        local dest_dir
        if [[ -d "$src" ]]; then
            dest_dir="$DST$src"
        else
            dest_dir="$(dirname "$DST$src")"
        fi

        local needs_sudo
        needs_sudo="$(echo "$job" | cut -d"$FS" -f5)"
        if [[ "$needs_sudo" == "yes" ]]; then
            sudo mkdir -p "$dest_dir"
        else
            mkdir -p "$dest_dir"
        fi

        if [[ "$QUIET" == true ]]; then
            if eval "$cmd" >> "${LOG_FILE:-/dev/null}" 2>&1; then
                TOTAL_FILES=$((TOTAL_FILES + 1))
            else
                TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
            fi
        else
            if eval "$cmd" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                TOTAL_FILES=$((TOTAL_FILES + 1))
            else
                TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
                echo -e "${C_RED}Error backing up: $src${C_RESET}"
            fi
        fi
    done
}

print_summary() {
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    echo ""
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  Backup Summary${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "  Jobs completed:  ${C_GREEN}$TOTAL_FILES${C_RESET}"
    echo -e "  Jobs with errors: ${C_RED}$TOTAL_ERRORS${C_RESET}"
    echo -e "  Elapsed time:    ${mins}m ${secs}s"
    if [[ -n "${LOG_FILE:-}" && "$LOG_FILE" != "" ]]; then
        echo -e "  Log file:        ${C_CYAN}$LOG_FILE${C_RESET}"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${C_YELLOW}(dry-run mode - no actual changes were made)${C_RESET}"
    fi
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
}

# =============================================================================
# Plugin listing
# =============================================================================

list_plugins() {
    echo -e "${C_BOLD}Available plugins:${C_RESET}"
    echo ""

    local plugin_files=("$PLUGINS_DIR"/*.conf)
    if [[ ! -e "${plugin_files[0]}" ]]; then
        echo "  (no plugins found in $PLUGINS_DIR)"
        return
    fi

    for pfile in "${plugin_files[@]}"; do
        local pname desc enabled_str status_color
        pname="$(basename "$pfile" .conf)"
        desc="$(plugin_description "$pfile")"

        if plugin_is_enabled "$pfile"; then
            enabled_str="enabled"
            status_color="$C_GREEN"
        else
            enabled_str="disabled"
            status_color="$C_YELLOW"
        fi

        printf "  %-18s ${status_color}%-8s${C_RESET}  %s\n" "$pname" "$enabled_str" "$desc"
    done
    echo ""
}

# =============================================================================
# TUI functions
# =============================================================================

detect_dialog() {
    if command -v dialog &>/dev/null; then
        DIALOG_CMD="dialog"
    elif command -v whiptail &>/dev/null; then
        DIALOG_CMD="whiptail"
    else
        DIALOG_CMD=""
    fi
}

tui_main_menu() {
    while true; do
        local choice
        if [[ "$DIALOG_CMD" == "dialog" ]]; then
            choice=$($DIALOG_CMD --clear --title "Rsync Backup Manager" \
                --menu "Select an action:" 18 50 8 \
                1 "Run backup" \
                2 "Run backup (dry-run)" \
                3 "Select plugins" \
                4 "Edit backup.conf" \
                5 "Edit common.conf" \
                6 "Edit plugin config" \
                7 "Show preview" \
                8 "Exit" \
                3>&1 1>&2 2>&3) || continue
        else
            choice=$($DIALOG_CMD --title "Rsync Backup Manager" \
                --menu "Select an action:" 18 50 8 \
                1 "Run backup" \
                2 "Run backup (dry-run)" \
                3 "Select plugins" \
                4 "Edit backup.conf" \
                5 "Edit common.conf" \
                6 "Edit plugin config" \
                7 "Show preview" \
                8 "Exit" \
                3>&1 1>&2 2>&3) || continue
        fi

        case "$choice" in
            1) tui_run_backup false || true ;;
            2) tui_run_backup true || true ;;
            3) tui_select_plugins || true ;;
            4) tui_edit_file "$GLOBAL_CONF" || true ;;
            5) tui_edit_file "$COMMON_CONF" || true ;;
            6) tui_choose_plugin_file || true ;;
            7) tui_show_preview || true ;;
            8) break ;;
        esac
    done
    clear
}

tui_select_plugins() {
    local plugin_files=("$PLUGINS_DIR"/*.conf)
    if [[ ! -e "${plugin_files[0]}" ]]; then
        $DIALOG_CMD --title "Error" --msgbox "No plugins found in $PLUGINS_DIR" 8 50
        return
    fi

    # Build checklist args
    local -a cl_args=()
    for pfile in "${plugin_files[@]}"; do
        local pname desc status
        pname="$(basename "$pfile" .conf)"
        desc="$(plugin_description "$pfile")"

        # Check if in SELECTED_PLUGINS override, or use file ENABLED status
        if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
            status="off"
            for sp in "${SELECTED_PLUGINS[@]}"; do
                if [[ "$sp" == "$pname" ]]; then
                    status="on"
                    break
                fi
            done
        else
            if plugin_is_enabled "$pfile"; then
                status="on"
            else
                status="off"
            fi
        fi

        cl_args+=("$pname" "$desc" "$status")
    done

    local result
    if [[ "$DIALOG_CMD" == "dialog" ]]; then
        result=$($DIALOG_CMD --clear --title "Plugin Selection" \
            --checklist "Select plugins to include in backup:" 20 60 10 \
            "${cl_args[@]}" \
            3>&1 1>&2 2>&3) || return
    else
        result=$($DIALOG_CMD --title "Plugin Selection" \
            --checklist "Select plugins to include in backup:" 20 60 10 \
            "${cl_args[@]}" \
            3>&1 1>&2 2>&3) || return
    fi

    # Parse selected plugins (dialog returns "item1" "item2" ...)
    SELECTED_PLUGINS=()
    # Remove quotes from dialog output
    result="${result//\"/}"
    for p in $result; do
        SELECTED_PLUGINS+=("$p")
    done

    # Ask whether to save to conf files or use temporarily
    local save_choice
    if [[ "$DIALOG_CMD" == "dialog" ]]; then
        save_choice=$($DIALOG_CMD --clear --title "Save Selection" \
            --menu "How to apply this selection?" 12 50 2 \
            1 "Save to conf files (permanent)" \
            2 "Temporary only (this session)" \
            3>&1 1>&2 2>&3) || return
    else
        save_choice=$($DIALOG_CMD --title "Save Selection" \
            --menu "How to apply this selection?" 12 50 2 \
            1 "Save to conf files (permanent)" \
            2 "Temporary only (this session)" \
            3>&1 1>&2 2>&3) || return
    fi

    if [[ "$save_choice" == "1" ]]; then
        # Save enabled/disabled status to each plugin conf
        for pfile in "${plugin_files[@]}"; do
            local pname
            pname="$(basename "$pfile" .conf)"
            local new_status="no"
            for sp in "${SELECTED_PLUGINS[@]}"; do
                if [[ "$sp" == "$pname" ]]; then
                    new_status="yes"
                    break
                fi
            done
            # Update ENABLED line in plugin conf
            sed -i "s/^ENABLED=.*/ENABLED=$new_status/" "$pfile"
        done
        $DIALOG_CMD --title "Saved" --msgbox "Plugin selection saved to config files." 8 50
        # Clear SELECTED_PLUGINS so load_plugins uses the file ENABLED status
        SELECTED_PLUGINS=()
    fi
}

tui_edit_file() {
    local file="$1"
    local editor="${EDITOR:-nano}"
    clear
    "$editor" "$file"
}

tui_choose_plugin_file() {
    local plugin_files=("$PLUGINS_DIR"/*.conf)
    if [[ ! -e "${plugin_files[0]}" ]]; then
        $DIALOG_CMD --title "Error" --msgbox "No plugins found in $PLUGINS_DIR" 8 50
        return
    fi

    local -a menu_args=()
    local idx=1
    for pfile in "${plugin_files[@]}"; do
        local pname desc
        pname="$(basename "$pfile" .conf)"
        desc="$(plugin_description "$pfile")"
        menu_args+=("$pname" "$desc")
        idx=$((idx + 1))
    done

    local choice
    if [[ "$DIALOG_CMD" == "dialog" ]]; then
        choice=$($DIALOG_CMD --clear --title "Edit Plugin Config" \
            --menu "Select plugin to edit:" 18 60 10 \
            "${menu_args[@]}" \
            3>&1 1>&2 2>&3) || return
    else
        choice=$($DIALOG_CMD --title "Edit Plugin Config" \
            --menu "Select plugin to edit:" 18 60 10 \
            "${menu_args[@]}" \
            3>&1 1>&2 2>&3) || return
    fi

    tui_edit_file "$PLUGINS_DIR/$choice.conf"
}

tui_choose_backup_scope() {
    local plugin_files=("$PLUGINS_DIR"/*.conf)
    if [[ ! -e "${plugin_files[0]}" ]]; then
        echo "all"
        return
    fi

    # Build menu: "all" + each enabled plugin
    local -a menu_args=()
    menu_args+=("all" "All enabled plugins + common")
    menu_args+=("common" "Common paths only")
    for pfile in "${plugin_files[@]}"; do
        local pname desc
        pname="$(basename "$pfile" .conf)"
        # Show only enabled plugins (or those in SELECTED_PLUGINS)
        if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
            local found=false
            for sp in "${SELECTED_PLUGINS[@]}"; do
                [[ "$sp" == "$pname" ]] && found=true && break
            done
            [[ "$found" == false ]] && continue
        else
            plugin_is_enabled "$pfile" || continue
        fi
        desc="$(plugin_description "$pfile")"
        menu_args+=("$pname" "$desc")
    done

    local choice
    if [[ "$DIALOG_CMD" == "dialog" ]]; then
        choice=$($DIALOG_CMD --clear --title "Backup Scope" \
            --menu "What to back up:" 20 60 12 \
            "${menu_args[@]}" \
            3>&1 1>&2 2>&3) || return 1
    else
        choice=$($DIALOG_CMD --title "Backup Scope" \
            --menu "What to back up:" 20 60 12 \
            "${menu_args[@]}" \
            3>&1 1>&2 2>&3) || return 1
    fi
    echo "$choice"
}

tui_run_backup() {
    local is_dry_run="$1"

    # Ask user what to back up
    local scope
    scope="$(tui_choose_backup_scope)" || return

    # Save and override SELECTED_PLUGINS based on scope
    local -a saved_plugins=("${SELECTED_PLUGINS[@]}")
    local saved_no_common="$NO_COMMON"

    case "$scope" in
        all)
            # Use current selection (all enabled or SELECTED_PLUGINS)
            NO_COMMON=false
            ;;
        common)
            SELECTED_PLUGINS=("__none__")
            NO_COMMON=false
            ;;
        *)
            SELECTED_PLUGINS=("$scope")
            NO_COMMON=true
            ;;
    esac

    # Reload jobs
    ALL_JOBS=()
    load_common
    load_plugins
    local -a scope_plugins=("${SELECTED_PLUGINS[@]}")
    local scope_no_common="$NO_COMMON"

    # Restore saved state
    SELECTED_PLUGINS=("${saved_plugins[@]}")
    NO_COMMON="$saved_no_common"

    if [[ ${#ALL_JOBS[@]} -eq 0 ]]; then
        $DIALOG_CMD --title "No Jobs" --msgbox "No backup jobs configured." 8 50
        return
    fi

    # Show preview and ask for confirmation
    local preview_text
    preview_text="$(generate_preview_text)"

    if [[ "$DIALOG_CMD" == "dialog" ]]; then
        $DIALOG_CMD --title "Backup Preview" --yesno "$preview_text\n\nProceed with backup?" 30 70 || return
    else
        $DIALOG_CMD --title "Backup Preview" --yesno "$preview_text\n\nProceed with backup?" 30 70 || return
    fi

    # Set dry-run flag
    if [[ "$is_dry_run" == true ]]; then
        DRY_RUN=true
    else
        DRY_RUN=false
    fi

    # Drop to shell for backup execution
    clear
    show_preview
    sudo_preauth
    SELECTED_PLUGINS=("${scope_plugins[@]}")
    NO_COMMON="$scope_no_common"
    run_pre_commands
    SELECTED_PLUGINS=("${saved_plugins[@]}")
    NO_COMMON="$saved_no_common"
    run_backup
    sudo_keepalive_stop
    print_summary

    echo ""
    read -rp "Press Enter to return to the menu..."
}

tui_show_preview() {
    # Reload jobs
    ALL_JOBS=()
    load_common
    load_plugins

    if [[ ${#ALL_JOBS[@]} -eq 0 ]]; then
        $DIALOG_CMD --title "No Jobs" --msgbox "No backup jobs configured." 8 50
        return
    fi

    clear
    show_preview

    echo ""
    read -rp "Press Enter to return to the menu..."
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == true ]]; then
        show_help
        exit 0
    fi

    load_global_config
    check_dependencies

    if [[ "$LIST_ONLY" == true ]]; then
        list_plugins
        exit 0
    fi

    # TUI mode
    if [[ "$USE_TUI" == true ]]; then
        tui_main_menu
        exit 0
    fi

    # CLI mode: load all jobs
    ALL_JOBS=()
    load_common
    load_plugins

    if [[ ${#ALL_JOBS[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}No backup jobs configured. Check common.conf and plugins.${C_RESET}"
        exit 0
    fi

    if [[ "$QUIET" == false ]]; then
        show_preview
    fi

    confirm_execution
    sudo_preauth
    run_pre_commands
    validate_paths
    run_backup
    sudo_keepalive_stop
    print_summary
}

main "$@"
