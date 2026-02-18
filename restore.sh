#!/usr/bin/env bash
# =============================================================================
# Rsync Restore Manager - Restore files from rsync-backup to original paths
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
QUIET=false
LIST_ONLY=false
SHOW_HELP=false
declare -a SELECTED_PLUGINS=()
declare -a ALL_JOBS=()     # "source|dest|includes|excludes|needs_sudo|label"
declare -a RESTORE_CMDS=()  # "plugin_label${FS}command" entries
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
Rsync Restore Manager
=====================

Restore files from an rsync-backup to their original paths on the system.
Uses the same configuration files (backup.conf, common.conf, plugins/*.conf)
as backup.sh, with the transfer direction inverted.

IMPORTANT: This script NEVER uses --delete. It only overwrites existing files
and adds missing ones. It will not remove any file from your live system.

USAGE
    restore.sh [OPTIONS]

OPTIONS
    --tui               Launch interactive TUI menu (requires dialog or whiptail)
    --dry-run           Run rsync in dry-run mode (no actual changes)
                        TIP: always do a dry-run first to review what will change
    --yes               Skip confirmation prompt, execute immediately
    --plugin=NAME       Restore only the specified plugin (repeatable)
                        Example: --plugin=firefox --plugin=ssh
    --no-common         Skip common.conf paths
    --list              List all plugins and their ENABLED status, then exit
    --quiet             Minimal output (summary only)
    --help              Show this help message

RESTORE LOGIC
    Backup stored at:  $DST/$(hostname)/original/path/
    Restores back to:  /original/path/

    The script reads the same PATH entries from common.conf and plugins/*.conf,
    but swaps source and destination: backup path becomes rsync source,
    original system path becomes rsync destination.

SUDO HANDLING
    Paths outside $HOME (e.g., /etc, /opt) or unwritable paths inside $HOME
    are restored with sudo rsync. The preview shows [sudo] for such jobs.

EXAMPLES
    # Preview what would be restored (recommended first step):
    restore.sh --dry-run

    # Restore everything (all enabled plugins + common paths):
    restore.sh

    # Restore only SSH keys and Firefox:
    restore.sh --plugin=ssh --plugin=firefox

    # Launch the interactive TUI:
    restore.sh --tui

    # List all plugins:
    restore.sh --list
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
# For restore: source = backup path ($DST + original), dest = original path
# needs_sudo is based on the DESTINATION (original path on live system)
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
            # For restore, check sudo on the DESTINATION (original path)
            if path_needs_sudo "$current_path"; then
                needs_sudo="yes"
            fi
            local backup_path="$DST$current_path"
            # Job: source=backup_path, dest=original_path
            ALL_JOBS+=("${backup_path}${FS}${current_path}${FS}${current_includes}${FS}${current_excludes}${FS}${needs_sudo}${FS}${label}")
        fi
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading/trailing whitespace
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # Skip comments and empty lines
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Skip ENABLED line
        [[ "$line" == ENABLED=* ]] && continue
        # Skip PRE_CMD line (not relevant for restore)
        [[ "$line" == PRE_CMD\ * ]] && continue
        # Skip RESTORE_CMD line (collected separately by collect_restore_commands)
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
# Restore command collection
# =============================================================================

collect_restore_commands() {
    RESTORE_CMDS=()

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
        local plugin_label
        plugin_label="$(basename "$cfile" .conf)"
        while IFS= read -r line; do
            line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ "$line" == RESTORE_CMD\ * ]]; then
                local cmd="${line#RESTORE_CMD }"
                cmd="${cmd//\$HOME/$HOME}"
                RESTORE_CMDS+=("${plugin_label}${FS}${cmd}")
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
    # Existing but unwritable paths need sudo (for restore, check write access)
    if [[ -e "$p" && ! -w "$p" ]]; then
        return 0
    fi
    # Parent directory not writable (for new paths)
    local parent
    parent="$(dirname "$p")"
    if [[ -e "$parent" && ! -w "$parent" ]]; then
        return 0
    fi
    # For directories, check if any file inside is not writable.
    # find stops at the first match (-quit) so this is fast even for large trees.
    if [[ -d "$p" ]]; then
        if find "$p" ! -writable -print -quit 2>/dev/null | grep -q .; then
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
        # Check that backup source path exists
        if [[ "$src" == *[\*\?]* ]]; then
            if ! compgen -G "$src" >/dev/null 2>&1; then
                if [[ "$QUIET" == false ]]; then
                    echo -e "${C_YELLOW}Warning: no match for pattern in backup: $src${C_RESET}"
                fi
                warn_count=$((warn_count + 1))
            fi
        elif [[ ! -e "$src" ]]; then
            if [[ "$QUIET" == false ]]; then
                echo -e "${C_YELLOW}Warning: backup path does not exist: $src${C_RESET}"
            fi
            warn_count=$((warn_count + 1))
        fi
    done
    if [[ $warn_count -gt 0 && "$QUIET" == false ]]; then
        echo -e "${C_YELLOW}$warn_count backup path(s) not found. They will be skipped by rsync.${C_RESET}"
        echo ""
    fi
}

# =============================================================================
# Rsync command building
# =============================================================================

build_rsync_args() {
    local job="$1"
    local src dest includes_str excludes_str needs_sudo
    src="$(echo "$job" | cut -d"$FS" -f1)"
    dest="$(echo "$job" | cut -d"$FS" -f2)"
    includes_str="$(echo "$job" | cut -d"$FS" -f3)"
    excludes_str="$(echo "$job" | cut -d"$FS" -f4)"
    needs_sudo="$(echo "$job" | cut -d"$FS" -f5)"

    local -a args=()

    # Base flags (split into array)
    # shellcheck disable=SC2086
    read -ra flag_arr <<< "$RSYNC_FLAGS"
    args+=("${flag_arr[@]}")

    # NEVER use --delete for restore

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

    # Source (backup path) must end with / for directory sync
    local rsync_src="$src"
    if [[ -d "$src" ]]; then
        rsync_src="${src%/}/"
    fi

    # Destination (original path)
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
    echo ""
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  Rsync Restore Preview${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  Backup root:  ${C_CYAN}$DST${C_RESET}"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  Mode:         ${C_YELLOW}DRY-RUN (no changes will be made)${C_RESET}"
    else
        echo -e "  Mode:         ${C_GREEN}LIVE${C_RESET}"
    fi
    echo -e "  Delete:       ${C_GREEN}disabled (restore never deletes)${C_RESET}"
    echo ""

    local current_label=""
    for job in "${ALL_JOBS[@]}"; do
        local src dest includes_str excludes_str needs_sudo label
        src="$(echo "$job" | cut -d"$FS" -f1)"
        dest="$(echo "$job" | cut -d"$FS" -f2)"
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

        echo -e "    ${sudo_tag}${C_CYAN}$src${C_RESET}"
        echo -e "      → ${C_GREEN}$dest${C_RESET}"

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
            echo -e "        ${C_YELLOW}(backup path does not exist - will be skipped)${C_RESET}"
        fi
    done

    echo ""
    echo -e "${C_BOLD}  Total jobs: ${#ALL_JOBS[@]}${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
}

# Generate plain-text preview (for TUI)
generate_preview_text() {
    echo "==========================================================="
    echo "  Rsync Restore Preview"
    echo "==========================================================="
    echo ""
    echo "  Backup root:  $DST"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  Mode:         DRY-RUN (no changes will be made)"
    else
        echo "  Mode:         LIVE"
    fi
    echo "  Delete:       disabled (restore never deletes)"
    echo ""

    local current_label=""
    for job in "${ALL_JOBS[@]}"; do
        local src dest includes_str excludes_str needs_sudo label
        src="$(echo "$job" | cut -d"$FS" -f1)"
        dest="$(echo "$job" | cut -d"$FS" -f2)"
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
        echo "      -> $dest"

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
            echo "        (backup path does not exist - will be skipped)"
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
    echo -e "${C_RED}${C_BOLD}WARNING: This will overwrite files on your live system.${C_RESET}"
    echo -e "${C_YELLOW}Consider running with --dry-run first to preview changes.${C_RESET}"
    echo ""
    read -rp "Proceed with restore? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        exit 0
    fi
}

# =============================================================================
# Restore execution
# =============================================================================

run_restore() {
    START_TIME=$(date +%s)
    TOTAL_FILES=0
    TOTAL_ERRORS=0

    local job_num=0
    local total_jobs=${#ALL_JOBS[@]}

    for job in "${ALL_JOBS[@]}"; do
        job_num=$((job_num + 1))
        local src dest label
        src="$(echo "$job" | cut -d"$FS" -f1)"
        dest="$(echo "$job" | cut -d"$FS" -f2)"
        label="$(echo "$job" | cut -d"$FS" -f6)"

        # Skip non-existent backup paths (glob-aware)
        local path_exists=true
        if [[ "$src" == *[\*\?]* ]]; then
            compgen -G "$src" >/dev/null 2>&1 || path_exists=false
        elif [[ ! -e "$src" ]]; then
            path_exists=false
        fi
        if [[ "$path_exists" == false ]]; then
            if [[ "$QUIET" == false ]]; then
                echo ""
                echo -e "${C_YELLOW}[$job_num/$total_jobs] Skipping (not found in backup): $src ($label)${C_RESET}"
            fi
            continue
        fi

        if [[ "$QUIET" == false ]]; then
            echo ""
            echo -e "${C_BOLD}[$job_num/$total_jobs] Restoring: $dest ($label)${C_RESET}"
        fi

        local cmd
        cmd="$(build_rsync_args "$job")"

        # Create destination directory on live system
        local dest_dir
        if [[ -d "$src" ]]; then
            dest_dir="$dest"
        else
            dest_dir="$(dirname "$dest")"
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
                echo -e "${C_RED}Error restoring: $dest${C_RESET}"
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
    echo -e "${C_BOLD}  Restore Summary${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "  Jobs completed:   ${C_GREEN}$TOTAL_FILES${C_RESET}"
    echo -e "  Jobs with errors: ${C_RED}$TOTAL_ERRORS${C_RESET}"
    echo -e "  Elapsed time:     ${mins}m ${secs}s"
    if [[ -n "${LOG_FILE:-}" && "$LOG_FILE" != "" ]]; then
        echo -e "  Log file:         ${C_CYAN}$LOG_FILE${C_RESET}"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${C_YELLOW}(dry-run mode - no actual changes were made)${C_RESET}"
    fi
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
}

# =============================================================================
# Post-restore command execution
# =============================================================================

run_restore_commands() {
    if [[ ${#RESTORE_CMDS[@]} -eq 0 ]]; then
        return
    fi

    echo ""
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  Package Reinstall${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"

    # Collect unique plugin labels preserving order
    local -a seen_labels=()
    for entry in "${RESTORE_CMDS[@]}"; do
        local label="${entry%%$'\x1e'*}"
        local already_seen=false
        for s in "${seen_labels[@]}"; do
            [[ "$s" == "$label" ]] && already_seen=true && break
        done
        [[ "$already_seen" == false ]] && seen_labels+=("$label")
    done

    for label in "${seen_labels[@]}"; do
        local -a cmds_for_label=()
        for entry in "${RESTORE_CMDS[@]}"; do
            local entry_label="${entry%%$'\x1e'*}"
            local entry_cmd="${entry#*$'\x1e'}"
            [[ "$entry_label" == "$label" ]] && cmds_for_label+=("$entry_cmd")
        done

        echo ""
        echo -e "  ${C_BOLD}── [$label] ──${C_RESET}"
        for cmd in "${cmds_for_label[@]}"; do
            echo -e "    ${C_CYAN}$cmd${C_RESET}"
        done

        if [[ "$DRY_RUN" == true ]]; then
            echo -e "    ${C_YELLOW}(dry-run: skipping execution)${C_RESET}"
            continue
        fi

        local run_it=false
        if [[ "$SKIP_CONFIRM" == true ]]; then
            run_it=true
            echo -e "    ${C_GREEN}Auto-confirmed (--yes)${C_RESET}"
        else
            local ans
            read -rp "  Run reinstall commands for [$label]? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] && run_it=true
        fi

        if [[ "$run_it" == true ]]; then
            for cmd in "${cmds_for_label[@]}"; do
                echo -e "${C_CYAN}Running: $cmd${C_RESET}"
                eval "$cmd" || echo -e "${C_YELLOW}Warning: restore command failed: $cmd${C_RESET}"
            done
        else
            echo -e "    ${C_YELLOW}Skipped.${C_RESET}"
        fi
    done

    echo ""
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
            choice=$($DIALOG_CMD --clear --title "Rsync Restore Manager" \
                --menu "Select an action:" 14 50 5 \
                1 "Restore" \
                2 "Restore (dry-run)" \
                3 "Select plugins" \
                4 "Show preview" \
                5 "Exit" \
                3>&1 1>&2 2>&3) || continue
        else
            choice=$($DIALOG_CMD --title "Rsync Restore Manager" \
                --menu "Select an action:" 14 50 5 \
                1 "Restore" \
                2 "Restore (dry-run)" \
                3 "Select plugins" \
                4 "Show preview" \
                5 "Exit" \
                3>&1 1>&2 2>&3) || continue
        fi

        case "$choice" in
            1) tui_run_restore false || true ;;
            2) tui_run_restore true || true ;;
            3) tui_select_plugins || true ;;
            4) tui_show_preview || true ;;
            5) break ;;
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
            --checklist "Select plugins to restore:" 20 60 10 \
            "${cl_args[@]}" \
            3>&1 1>&2 2>&3) || return
    else
        result=$($DIALOG_CMD --title "Plugin Selection" \
            --checklist "Select plugins to restore:" 20 60 10 \
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

    $DIALOG_CMD --title "Selection Applied" --msgbox "Plugin selection applied for this session." 8 50
}

tui_choose_restore_scope() {
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
        choice=$($DIALOG_CMD --clear --title "Restore Scope" \
            --menu "What to restore:" 20 60 12 \
            "${menu_args[@]}" \
            3>&1 1>&2 2>&3) || return 1
    else
        choice=$($DIALOG_CMD --title "Restore Scope" \
            --menu "What to restore:" 20 60 12 \
            "${menu_args[@]}" \
            3>&1 1>&2 2>&3) || return 1
    fi
    echo "$choice"
}

tui_run_restore() {
    local is_dry_run="$1"

    # Ask user what to restore
    local scope
    scope="$(tui_choose_restore_scope)" || return

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
    collect_restore_commands

    # Restore saved state
    SELECTED_PLUGINS=("${saved_plugins[@]}")
    NO_COMMON="$saved_no_common"

    if [[ ${#ALL_JOBS[@]} -eq 0 ]]; then
        $DIALOG_CMD --title "No Jobs" --msgbox "No restore jobs configured." 8 50
        return
    fi

    # Show preview and ask for confirmation
    local preview_text
    preview_text="$(generate_preview_text)"

    local confirm_msg="$preview_text\n\nWARNING: This will overwrite files on your system.\nProceed with restore?"
    if [[ "$DIALOG_CMD" == "dialog" ]]; then
        $DIALOG_CMD --title "Restore Preview" --yesno "$confirm_msg" 30 70 || return
    else
        $DIALOG_CMD --title "Restore Preview" --yesno "$confirm_msg" 30 70 || return
    fi

    # Set dry-run flag
    if [[ "$is_dry_run" == true ]]; then
        DRY_RUN=true
    else
        DRY_RUN=false
    fi

    # Drop to shell for restore execution
    clear
    show_preview
    sudo_preauth
    run_restore
    sudo_keepalive_stop
    print_summary
    run_restore_commands

    echo ""
    read -rp "Press Enter to return to the menu..."
}

tui_show_preview() {
    # Reload jobs
    ALL_JOBS=()
    load_common
    load_plugins

    if [[ ${#ALL_JOBS[@]} -eq 0 ]]; then
        $DIALOG_CMD --title "No Jobs" --msgbox "No restore jobs configured." 8 50
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
    collect_restore_commands

    if [[ ${#ALL_JOBS[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}No restore jobs configured. Check common.conf and plugins.${C_RESET}"
        exit 0
    fi

    if [[ "$QUIET" == false ]]; then
        show_preview
    fi

    confirm_execution
    sudo_preauth
    validate_paths
    run_restore
    sudo_keepalive_stop
    print_summary
    run_restore_commands
}

main "$@"
