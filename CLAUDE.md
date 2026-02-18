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
```

## Architecture

Both `backup.sh` and `restore.sh` share the same design: they parse config files into an `ALL_JOBS` array (entries are `$'\x1e'`-separated fields), show a colored preview, optionally prompt for confirmation, then run rsync for each job.

### Configuration Files

| File | Purpose |
|---|---|
| `backup.conf` | Global settings: `DST`, `RSYNC_FLAGS`, `RSYNC_DELETE`, `LOG_FILE` |
| `common.conf` | Paths always included unless `--no-common` is passed |
| `plugins/*.conf` | Plugin-specific paths; auto-discovered, no registration needed |

### Plugin File Format

```bash
# Plugin Name - Description (first comment becomes the display label)
ENABLED=yes

PRE_CMD <shell command>   # optional; runs before backup, skipped during restore

PATH $HOME/.config/myapp
INCLUDE important/        # placed before excludes in rsync args
EXCLUDE cache/
EXCLUDE *.tmp
```

- `PATH` starts a new job entry; subsequent `INCLUDE`/`EXCLUDE` lines apply to it
- Directory `INCLUDE` patterns auto-get a `pattern/**` variant in the rsync command
- `$HOME` and `~` in paths are expanded at parse time
- Plugin name = filename without `.conf`; used with `--plugin=NAME`

### Sudo Detection

Paths outside `$HOME`, or paths inside `$HOME` that are unreadable (backup) / unwritable (restore), automatically run as `sudo rsync`. If any job needs sudo, both scripts pre-authenticate once upfront and run a background keep-alive (`sudo -v` every 50 s).

### Key Variables in backup.sh / restore.sh

- `ALL_JOBS` — array of `FS`-delimited job records (source, dest, includes, excludes, needs_sudo, label)
- `FS=$'\x1e'` — field separator (ASCII Record Separator) used inside job records
- `DST` — destination root; final path is `$DST/$(hostname)/absolute/source/path`
- `SELECTED_PLUGINS` — array populated by `--plugin=` flags; empty means "all enabled"

### restore.sh Differences from backup.sh

- Never uses `--delete` regardless of `RSYNC_DELETE`
- Source and destination are swapped (backup drive → live system)
- No `PRE_CMD` execution
- No `--no-delete` flag (not applicable)
- Simpler TUI (no config editing options)

## Adding a New Plugin

Create `plugins/<name>.conf`. It is auto-discovered — no registration needed:

```bash
# My App - Short description
ENABLED=yes

PATH $HOME/.config/myapp
EXCLUDE cache/
```
