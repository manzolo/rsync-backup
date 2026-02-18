# Rsync Backup & Restore Manager

A unified backup and restore system built on `rsync` with modular plugin-based configuration, colored preview, dry-run support, confirmation prompts, and an interactive TUI powered by `dialog`/`whiptail`.

## Features

- **Plugin-based configuration** - Organize backup paths into logical modules (SSH, Firefox, Docker, etc.)
- **CLI + interactive TUI** - Full command-line interface and a `dialog`/`whiptail`-based menu
- **Dry-run mode** - Preview exactly what rsync would do without making changes
- **Colored preview** - Visual summary of all jobs with direction arrows, include/exclude rules, and sudo indicators
- **Automatic sudo detection** - Paths outside `$HOME` or unreadable/unwritable paths automatically use `sudo rsync`
- **Pre-commands** - Run arbitrary commands before backup (e.g., dump a database, export package lists)
- **Backup + Restore** - `backup.sh` copies to the backup drive; `restore.sh` copies back to original paths

## Directory Structure

```
rsync-backup/
├── backup.sh              # Backup script (CLI + TUI)
├── restore.sh             # Restore script (CLI + TUI)
├── backup.conf            # Global configuration (destination, rsync flags)
├── common.conf            # Paths always included in every run
├── backup.log             # Log file (auto-generated)
├── README.md              # This documentation
└── plugins/
    ├── android.conf       # Android Studio IDE config and projects
    ├── claude.conf        # Claude Code settings and memory
    ├── docker.conf        # Docker configuration and credentials
    ├── documenti.conf     # Personal documents
    ├── firefox.conf       # Firefox browser profiles (snap + traditional)
    ├── gnome.conf         # GNOME desktop settings and extensions
    ├── gnupg.conf         # GPG keys and trust database
    ├── gradle.conf        # Gradle build system config
    ├── packages.conf      # Installed packages list snapshot
    ├── rclone.conf        # Rclone cloud storage configuration
    ├── remmina.conf       # Remmina remote desktop connections
    ├── retropie.conf      # RetroPie emulation config and saves
    ├── ssh.conf           # SSH keys and configuration
    ├── system.conf        # Full /etc system configuration
    ├── virt-manager.conf  # Virtual machine configs and storage pools
    ├── vscode.conf        # VS Code editor settings and snippets
    ├── whisper.conf       # Whisper speech recognition data
    └── workspaces.conf    # Development project workspaces
```

## Installation

No installation required. Ensure `rsync` is available:

```bash
sudo apt install rsync
```

For the interactive TUI, install `dialog` or `whiptail`:

```bash
sudo apt install dialog
```

Make both scripts executable:

```bash
chmod +x backup.sh restore.sh
```

## Quick Start

```bash
# Back up everything (preview + confirmation):
./backup.sh

# Dry-run to see what would be transferred:
./backup.sh --dry-run

# Restore everything from backup:
./restore.sh

# Restore dry-run (recommended first step):
./restore.sh --dry-run
```

## Backup Usage

```
backup.sh [OPTIONS]
```

| Option | Description |
|---|---|
| `--tui` | Launch interactive TUI menu |
| `--dry-run` | Run rsync in simulation mode (no actual changes) |
| `--yes` | Skip confirmation prompt |
| `--plugin=NAME` | Back up only the specified plugin (repeatable) |
| `--no-common` | Skip paths defined in common.conf |
| `--no-delete` | Override RSYNC_DELETE, do not delete from destination |
| `--list` | List all plugins and their ENABLED status |
| `--quiet` | Minimal output (summary only) |
| `--help` | Show detailed help |

### Backup Examples

```bash
# Full backup with all enabled plugins:
./backup.sh

# Back up only Firefox and SSH, skip confirmation:
./backup.sh --plugin=firefox --plugin=ssh --yes

# Dry-run with a single plugin:
./backup.sh --dry-run --plugin=docker

# Full backup without deleting old files from destination:
./backup.sh --no-delete

# Launch the TUI:
./backup.sh --tui
```

## Restore Usage

```
restore.sh [OPTIONS]
```

| Option | Description |
|---|---|
| `--tui` | Launch interactive TUI menu |
| `--dry-run` | Run rsync in simulation mode (no actual changes) |
| `--yes` | Skip confirmation prompt |
| `--plugin=NAME` | Restore only the specified plugin (repeatable) |
| `--no-common` | Skip paths defined in common.conf |
| `--list` | List all plugins and their ENABLED status |
| `--quiet` | Minimal output (summary only) |
| `--help` | Show detailed help |

The restore script **never** uses `--delete`. It only overwrites existing files and adds missing ones — it will not remove any file from your live system.

### Restore Examples

```bash
# Preview what would be restored (always recommended first):
./restore.sh --dry-run

# Restore everything:
./restore.sh

# Restore only SSH keys:
./restore.sh --plugin=ssh

# Restore SSH and GPG keys, skip confirmation:
./restore.sh --plugin=ssh --plugin=gnupg --yes

# Launch the TUI:
./restore.sh --tui
```

## TUI

Both scripts offer an interactive TUI launched with `--tui`.

### Backup TUI Menu

1. **Run backup** - Show preview, confirm, execute backup
2. **Run backup (dry-run)** - Simulation without changes
3. **Select plugins** - Enable/disable plugins via checklist
4. **Edit backup.conf** - Edit global configuration
5. **Edit common.conf** - Edit common paths
6. **Edit plugin config** - Select and edit a plugin file
7. **Show preview** - Display all configured jobs
8. **Exit**

### Restore TUI Menu

1. **Restore** - Show preview, confirm, execute restore
2. **Restore (dry-run)** - Simulation without changes
3. **Select plugins** - Choose which plugins to restore
4. **Show preview** - Display all configured restore jobs
5. **Exit**

The restore TUI is streamlined: no config editing options (you edit configs via the backup TUI or directly).

Both TUIs offer a **scope selector** before execution: restore/back up everything, only common paths, or a single plugin.

## Configuration

### backup.conf - Global Configuration

```bash
# Destination root (e.g., external drive, NAS mount point)
# Data is stored under $DST/$(hostname)/ replicating absolute source paths
DST=/media/manzolo/BackupHD

# Rsync base flags
RSYNC_FLAGS="--archive --verbose --human-readable --progress --partial"

# Delete files on destination not present on source (yes/no)
# Only applies to backup.sh — restore.sh never deletes
RSYNC_DELETE=yes

# Log file path
LOG_FILE=$HOME/backups/rsync-backup/backup.log
```

### common.conf - Always-included Paths

Paths in this file are processed in every run (both backup and restore) unless `--no-common` is specified.

```bash
PATH $HOME/.bashrc
PATH $HOME/.zshrc
PATH $HOME/.profile
PATH $HOME/.gitconfig
PATH $HOME/.config/htop
PATH $HOME/.local/share/applications
EXCLUDE *.bak
```

### Plugin Format (plugins/*.conf)

Each plugin file starts with a description comment and an `ENABLED=yes|no` line, followed by `PATH`, `INCLUDE`, and `EXCLUDE` directives:

```bash
# Firefox - Browser profiles and data (snap + traditional)
ENABLED=yes

PATH $HOME/snap/firefox/common/.mozilla/firefox
EXCLUDE cache2/
EXCLUDE startupCache/

PATH $HOME/.mozilla/firefox
EXCLUDE cache2/
EXCLUDE startupCache/
```

Optionally, `PRE_CMD` lines run shell commands before backup (ignored during restore):

```bash
# Packages - Installed packages list snapshot
ENABLED=yes

PRE_CMD mkdir -p $HOME/.local/share/package-lists
PRE_CMD dpkg --get-selections > $HOME/.local/share/package-lists/dpkg-selections.txt

PATH $HOME/.local/share/package-lists
```

### Include/Exclude Rules

Rules follow rsync's "first match wins" logic. `INCLUDE` rules are placed before `EXCLUDE` rules in the generated rsync command. For directory includes, the `pattern/**` variant is added automatically.

Example — back up only `important/` from a directory:

```bash
PATH /home/user/data
INCLUDE important/
EXCLUDE *
```

This generates: `--include='important/' --include='important/**' --exclude='*'`

## Plugins

| Plugin | Description |
|---|---|
| `android` | Android Studio IDE configuration and projects |
| `claude` | Claude Code settings and memory |
| `docker` | Docker configuration and credentials |
| `documenti` | Personal documents |
| `firefox` | Firefox browser profiles (snap + traditional) |
| `gnome` | GNOME desktop settings, extensions, and shell data |
| `gnupg` | GPG keys and trust database |
| `gradle` | Gradle build system cache and configuration |
| `packages` | Installed packages list snapshot (with PRE_CMD) |
| `rclone` | Rclone cloud storage configuration |
| `remmina` | Remmina remote desktop connections |
| `retropie` | RetroPie emulation configuration and saves |
| `ssh` | SSH keys and configuration |
| `system` | Full /etc system configuration |
| `virt-manager` | Virtual machine configurations and storage pools |
| `vscode` | VS Code editor settings, keybindings, and snippets |
| `whisper` | Whisper speech recognition service data |
| `workspaces` | Development project workspaces (disabled by default) |

## Creating Custom Plugins

1. Create a new `.conf` file in the `plugins/` directory:

```bash
# My App - Description of what this plugin backs up
ENABLED=yes

PATH $HOME/.config/myapp
EXCLUDE cache/
EXCLUDE tmp/
```

2. That's it. The plugin is automatically discovered by both `backup.sh` and `restore.sh`.

Rules:
- The filename (without `.conf`) becomes the plugin name used with `--plugin=NAME`
- The first comment line is used as the plugin description in listings and TUI
- `ENABLED=yes` or `ENABLED=no` controls whether it runs by default
- `PATH`, `INCLUDE`, `EXCLUDE` define what to sync
- `PRE_CMD` runs a shell command before backup (skipped during restore)

## Sudo Handling

Both scripts automatically detect paths that require elevated privileges:

- **Paths outside `$HOME`** (e.g., `/etc`, `/opt`, `/var/lib/libvirt`) always use `sudo rsync`
- **Unreadable paths** (backup) or **unwritable paths** (restore) inside `$HOME` also use `sudo rsync`

The preview clearly marks these jobs with a `[sudo]` indicator.

**Pre-authentication:** If any job requires sudo, both scripts prompt for the password **upfront** (before any rsync command runs). A background keep-alive process refreshes the sudo timestamp every 50 seconds, so long-running operations never stall waiting for a password mid-execution. The keep-alive is automatically stopped when the script finishes.

## Delete Behavior

**Backup (`backup.sh`):** When `RSYNC_DELETE=yes` (default), rsync uses `--delete` to create an exact mirror of the source. Files deleted from the source are also deleted from the backup. Use `--no-delete` to override this and keep old files on the destination.

**Restore (`restore.sh`):** The restore script **never** uses `--delete`, regardless of the `RSYNC_DELETE` setting. It only overwrites existing files and copies missing ones. This ensures that restoring from backup cannot accidentally delete files on your live system.
