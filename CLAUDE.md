# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A Bash-based backup and restore system using `rsync` with a plugin architecture. Two main scripts — `backup.sh` and `restore.sh` — read configuration files and drive rsync jobs. No build step, no tests, no package manager.

## Running the Scripts

```bash
# Backup (preview + confirmation)
./backup.sh

# Restore dry-run (always recommended before restoring)
./restore.sh --dry-run

# Single-plugin dry-run
./backup.sh --dry-run --plugin=ssh

# Interactive TUI (requires dialog or whiptail)
./backup.sh --tui

# List all plugins and their enabled status
./backup.sh --list

# Syntax check (no tests exist, use bash -n)
bash -n backup.sh && bash -n restore.sh
```

## Architecture

Both `backup.sh` and `restore.sh` share the same design: they parse config files into an `ALL_JOBS` array (entries are `$'\x1e'`-separated fields), show a colored preview, optionally prompt for confirmation, then run rsync for each job.

### Configuration Files

| File | Purpose |
|---|---|
| `backup.conf` | Global settings: `DST`, `RSYNC_FLAGS`, `RSYNC_DELETE`, `LOG_FILE` |
| `common.conf` | Paths always included unless `--no-common` is passed |
| `plugins/*.conf` | Plugin-specific paths; auto-discovered, no registration needed |

### Plugin Directives

| Directive | backup.sh | restore.sh |
|---|---|---|
| `PATH` | Source to back up | Source = backup copy, dest = original path |
| `INCLUDE` | Rsync include (before excludes) | Same |
| `EXCLUDE` | Rsync exclude | Same |
| `PRE_CMD` | Shell command before backup | Ignored |
| `RESTORE_CMD` | Ignored | Shell command **after** rsync (post-restore) |
| `PRE_RESTORE_CMD` | Ignored | Shell command **before** rsync (pre-restore prompts) |
| `RESTORE_EXCLUDE` | Ignored (file stays in backup) | Treated as `EXCLUDE` in rsync |

### Plugin File Format

```bash
# Plugin Name - Description (first comment becomes the display label)
ENABLED=yes

PRE_CMD <shell command>          # runs before backup, skipped during restore

PATH $HOME/.config/myapp
INCLUDE important/               # placed before excludes in rsync args
EXCLUDE cache/
EXCLUDE *.tmp
RESTORE_EXCLUDE hardware.conf   # backed up, but excluded from restore rsync

PRE_RESTORE_CMD <shell command>  # runs before restore rsync (e.g., interactive prompts)
RESTORE_CMD <shell command>      # runs after restore rsync (e.g., package install)
```

- `PATH` starts a new job entry; subsequent `INCLUDE`/`EXCLUDE`/`RESTORE_EXCLUDE` lines apply to it
- Directory `INCLUDE` patterns auto-get a `pattern/**` variant in the rsync command
- `$HOME` and `~` in paths are expanded at parse time
- Plugin name = filename without `.conf`; used with `--plugin=NAME`
- Missing paths are silently skipped (no error)

### Restore Flow (restore.sh main)

```
load_common → load_plugins → collect_pre_restore_commands → collect_restore_commands
→ show_preview → confirm_execution → sudo_preauth → validate_paths
→ run_pre_restore_commands    ← PRE_RESTORE_CMD (interactive prompts, before rsync)
→ run_restore                 ← rsync all jobs (unattended)
→ sudo_keepalive_stop → print_summary
→ run_restore_commands        ← RESTORE_CMD (package install, permissions, etc.)
```

### Sudo Detection

Paths outside `$HOME`, or paths inside `$HOME` that are unreadable (backup) / unwritable (restore), automatically run as `sudo rsync`. If any job needs sudo, both scripts pre-authenticate once upfront and run a background keep-alive (`sudo -v` every 50 s).

### Key Variables in backup.sh / restore.sh

- `ALL_JOBS` — array of `FS`-delimited job records (source, dest, includes, excludes, needs_sudo, label)
- `FS=$'\x1e'` — field separator (ASCII Record Separator) used inside job records
- `DST` — destination root; final path is `$DST/$(hostname)/absolute/source/path`
- `SELECTED_PLUGINS` — array populated by `--plugin=` flags; empty means "all enabled"
- `RESTORE_CMDS` — array of `plugin_label${FS}command` entries for post-restore commands
- `PRE_RESTORE_CMDS` — array of `plugin_label${FS}command` entries for pre-restore commands

### restore.sh Differences from backup.sh

- Never uses `--delete` regardless of `RSYNC_DELETE`
- Source and destination are swapped (backup drive → live system)
- No `PRE_CMD` execution
- No `--no-delete` flag (not applicable)
- Simpler TUI (no config editing options)
- `RESTORE_EXCLUDE` lines are treated as `EXCLUDE` (backup.sh ignores them)
- `PRE_RESTORE_CMD` runs before rsync; `RESTORE_CMD` runs after (backup.sh ignores both)
- `PRE_RESTORE_CMD` commands can use `$DST` (backup path) and `$SKIP_CONFIRM` (true when `--yes`)

## Plugin Design Patterns

### Two-tier approach

- **Dedicated plugins** for apps needing `RESTORE_CMD`, `PRE_RESTORE_CMD`, permissions, or special logic (ssh, gnupg, apt, snap, system, vscode, virt-manager, gnome, zsh)
- **Catch-all plugins** (`dotconfig.conf`, `dotlocal.conf`) for everything else in `~/.config` and `~/.local`, with `EXCLUDE` for directories already covered by dedicated plugins

### When creating a dedicated plugin from a catch-all directory

1. Create `plugins/<name>.conf` with the specific path and any needed `RESTORE_CMD`
2. Add `EXCLUDE <name>/` to `dotconfig.conf` or `dotlocal.conf` to avoid duplicate backups

### Package list pattern (apt, snap, flatpak, pip, vscode)

```bash
PRE_CMD <tool> --list > $HOME/.local/share/package-lists/<tool>-list.txt
PATH $HOME/.local/share/package-lists/<tool>-list.txt
RESTORE_CMD <tool> install from list
```

### Permission fix pattern (ssh, gnupg)

```bash
RESTORE_CMD chmod 700 $HOME/.ssh && chmod 600 $HOME/.ssh/id_*
```

### Hardware-safe restore pattern (system.conf)

```bash
RESTORE_EXCLUDE fstab
PRE_RESTORE_CMD if [[ "$SKIP_CONFIRM" != true ]]; then read -rp "  Restore /etc/fstab? [y/N] " _a; \
  [[ "$_a" =~ ^[Yy]$ ]] && sudo cp "$DST/etc/fstab" /etc/fstab || true; \
  else echo "  (--yes: /etc/fstab not restored)"; fi
```

## Adding a New Plugin

Create `plugins/<name>.conf`. It is auto-discovered — no registration needed:

```bash
# My App - Short description
ENABLED=yes

PATH $HOME/.config/myapp
EXCLUDE cache/
```

If the directory was previously covered by `dotconfig.conf` or `dotlocal.conf`, add an `EXCLUDE` there.
