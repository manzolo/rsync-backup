# Rsync Backup & Restore Manager

A unified backup and restore system built on `rsync` with modular plugin-based configuration, colored preview, dry-run support, confirmation prompts, and an interactive TUI powered by `dialog`/`whiptail`.

## Features

- **Plugin-based configuration** - Organize backup paths into logical modules (SSH, Firefox, Docker, etc.)
- **Catch-all plugins** - `dotconfig` and `dotlocal` sweep up `~/.config` and `~/.local` directories not covered by specific plugins
- **CLI + interactive TUI** - Full command-line interface and a `dialog`/`whiptail`-based menu
- **Dry-run mode** - Preview exactly what rsync would do without making changes
- **Colored preview** - Visual summary of all jobs with direction arrows, include/exclude rules, and sudo indicators
- **Automatic sudo detection** - Paths outside `$HOME` or unreadable/unwritable paths automatically use `sudo rsync`
- **Pre-commands** - Run arbitrary commands before backup (e.g., dump a database, export package lists)
- **Restore commands** - Run commands after restore (e.g., reinstall packages, fix permissions, re-register VMs)
- **Pre-restore prompts** - Interactive prompts for hardware-specific files (fstab, hostname, etc.) run *before* rsync so the restore is unattended
- **Restore-only excludes** - `RESTORE_EXCLUDE` keeps files in the backup but excludes them from restore (e.g., `/etc/passwd`)
- **Safe by default** - Missing paths are silently skipped; restore never uses `--delete`

## Directory Structure

```
rsync-backup/
├── backup.sh              # Backup script (CLI + TUI)
├── restore.sh             # Restore script (CLI + TUI)
├── backup.conf            # Global configuration (destination, rsync flags)
├── common.conf            # Paths always included in every run
└── plugins/
    ├── android.conf       # Android Studio IDE config and SDK
    ├── apt.conf           # APT packages, repos, signing keys
    ├── claude.conf        # Claude Code settings and memory
    ├── docker.conf        # Docker configuration
    ├── documenti.conf     # Personal documents
    ├── dotconfig.conf     # Catch-all for ~/.config
    ├── dotlocal.conf      # Catch-all for ~/.local
    ├── filezilla.conf     # FTP/SFTP client sites and settings
    ├── firefox.conf       # Firefox browser profiles (snap + traditional)
    ├── flatpak.conf       # Flatpak applications list
    ├── geany.conf         # Geany IDE settings and templates
    ├── gnome.conf         # GNOME desktop settings, extensions, dconf
    ├── gnupg.conf         # GPG keys and trust database
    ├── gradle.conf        # Gradle build system config
    ├── keyrings.conf      # GNOME Keyring (passwords for WiFi, Remmina, etc.)
    ├── pip.conf           # Python pip packages list
    ├── rclone.conf        # Rclone cloud storage configuration
    ├── remmina.conf       # Remmina remote desktop connections
    ├── retropie.conf      # RetroPie emulation config and saves
    ├── snap.conf          # Snap packages (base → apps → classic)
    ├── ssh.conf           # SSH keys and configuration
    ├── system.conf        # Full /etc with hardware-safe restore
    ├── virt-manager.conf  # Virtual machine configs and storage
    ├── vscode.conf        # VS Code settings and extensions list
    ├── whisper.conf       # Whisper speech recognition data
    ├── workspaces.conf    # Development project workspaces
    └── zsh.conf           # Zsh, Oh My Zsh, Powerlevel10k
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
| `--yes` | Skip confirmation prompt, auto-skip hardware-specific files |
| `--plugin=NAME` | Restore only the specified plugin (repeatable) |
| `--no-common` | Skip paths defined in common.conf |
| `--list` | List all plugins and their ENABLED status |
| `--quiet` | Minimal output (summary only) |
| `--help` | Show detailed help |

The restore script **never** uses `--delete`. It only overwrites existing files and adds missing ones — it will not remove any file from your live system.

### Restore Flow

A full restore follows this order:

```
1. Preview + confirmation
2. Sudo pre-authentication
3. Pre-restore Configuration [system]      ← interactive prompts for hardware files
     Restore /etc/fstab? [y/N]
     Restore /etc/hostname? [y/N]
     ...
4. rsync all plugins (unattended)          ← RESTORE_EXCLUDE keeps hardware files out
5. Restore Summary
6. Post-restore Actions [apt] [snap] ...   ← package reinstall, permission fixes, etc.
```

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

# Log file path (parent directory is created automatically)
LOG_FILE=$HOME/backups/rsync-backup/backup.log
```

### common.conf - Always-included Paths

Paths in this file are processed in every run (both backup and restore) unless `--no-common` is specified.

```bash
PATH $HOME/.bashrc
PATH $HOME/.profile
PATH $HOME/.gitconfig
PATH $HOME/.config/htop
PATH $HOME/.config/user-dirs.dirs
PATH $HOME/.config/user-dirs.locale
PATH $HOME/.local/share/applications
EXCLUDE *.bak
```

### Plugin Format (plugins/*.conf)

Each plugin file starts with a description comment and an `ENABLED=yes|no` line, followed by directives:

```bash
# My App - Description of what this plugin backs up
ENABLED=yes

PATH $HOME/.config/myapp
EXCLUDE cache/
EXCLUDE tmp/
```

### Plugin Directives

| Directive | backup.sh | restore.sh |
|---|---|---|
| `PATH` | Source directory/file to back up | Source is the backup copy, destination is the original path |
| `INCLUDE` | Rsync include pattern (before excludes) | Same |
| `EXCLUDE` | Rsync exclude pattern | Same |
| `PRE_CMD` | Shell command run before backup | Ignored |
| `RESTORE_CMD` | Ignored | Shell command run **after** rsync (e.g., package install) |
| `PRE_RESTORE_CMD` | Ignored | Shell command run **before** rsync (e.g., interactive prompts) |
| `RESTORE_EXCLUDE` | Ignored (file is included in backup) | Treated as `EXCLUDE` in rsync |

### Include/Exclude Rules

Rules follow rsync's "first match wins" logic. `INCLUDE` rules are placed before `EXCLUDE` rules in the generated rsync command. For directory includes, the `pattern/**` variant is added automatically.

Example — back up only `important/` from a directory:

```bash
PATH /home/user/data
INCLUDE important/
EXCLUDE *
```

This generates: `--include='important/' --include='important/**' --exclude='*'`

### RESTORE_EXCLUDE - Backup but Don't Restore

`RESTORE_EXCLUDE` keeps files in the backup (for reference or same-hardware restore) but excludes them from the rsync restore. Combined with `PRE_RESTORE_CMD`, this enables interactive per-file restore decisions:

```bash
PATH /etc
RESTORE_EXCLUDE fstab
RESTORE_EXCLUDE hostname

PRE_RESTORE_CMD if [[ "$SKIP_CONFIRM" != true ]]; then \
    read -rp "  Restore /etc/fstab? [y/N] " _a; \
    [[ "$_a" =~ ^[Yy]$ ]] && sudo cp "$DST/etc/fstab" /etc/fstab || true; \
  else echo "  (--yes: /etc/fstab not restored)"; fi
```

With `--yes`, the interactive prompts are skipped and hardware-specific files are not restored (safe default for different hardware).

## Plugins

### Package Managers

| Plugin | Description | RESTORE_CMD |
|---|---|---|
| `apt` | APT packages list, repos (`sources.list.d`), signing keys (`keyrings`, `trusted.gpg.d`) | `apt-get update` + install (warns about packages not in repos) |
| `snap` | Snap packages in dependency order: base → apps → classic | Three-phase install with automatic retry for failed snaps |
| `flatpak` | Flatpak application list | Adds Flathub remote + installs all apps |
| `pip` | Python pip packages list (user-installed) | `pip3 install --user -r requirements.txt` |

### Desktop & Shell

| Plugin | Description | RESTORE_CMD |
|---|---|---|
| `gnome` | GNOME dconf dump, shell extensions, autostart entries | `dconf load` to reload settings |
| `zsh` | `.zshrc`, `.p10k.zsh`, Oh My Zsh (custom plugins and themes) | Installs Oh My Zsh if not present |
| `keyrings` | GNOME Keyring (passwords for WiFi, Remmina, Online Accounts) | - |
| `vscode` | VS Code settings, keybindings, snippets, extensions list | Reinstalls all extensions from saved list |

### Security & Credentials

| Plugin | Description | RESTORE_CMD |
|---|---|---|
| `ssh` | SSH keys and config (`RESTORE_EXCLUDE known_hosts`) | `chmod 700/600` to enforce correct permissions |
| `gnupg` | GPG keys and trust database | `chmod -R go-rwx` (GPG requires strict permissions) |

### System

| Plugin | Description | RESTORE_CMD |
|---|---|---|
| `system` | Full `/etc` with hardware-safe restore | `PRE_RESTORE_CMD` prompts for fstab, hostname, machine-id, SSH host keys, netplan, NetworkManager, passwd/group |

### Applications

| Plugin | Description |
|---|---|
| `firefox` | Firefox profiles (snap + traditional), excludes caches |
| `docker` | Docker client config (`~/.docker/`) |
| `rclone` | Rclone cloud storage config |
| `remmina` | Remmina remote desktop connections and profiles |
| `filezilla` | FTP/SFTP sites, settings, trusted certs |
| `geany` | Geany IDE settings, keybindings, templates |

### Development

| Plugin | Description | RESTORE_CMD |
|---|---|---|
| `android` | Android Studio config + SDK | - |
| `gradle` | Gradle config (excl. caches, dists) | - |
| `virt-manager` | libvirt config, VM images, NVRAM, storage pools | `virsh define` for each VM XML |
| `workspaces` | Development projects (excl. `node_modules`, `vendor`, `.gradle`, `build`, `.venv`) | - |

### Catch-all

| Plugin | Description |
|---|---|
| `dotconfig` | `~/.config/` minus directories covered by specific plugins, browser profiles, and runtime data |
| `dotlocal` | `~/.local/` (bin, lib, coda, share) minus directories covered by specific plugins, Trash, and runtime data |

### Other

| Plugin | Description |
|---|---|
| `claude` | Claude Code settings and memory |
| `documenti` | Personal documents |
| `retropie` | RetroPie/EmulationStation config, ROMs, saves |
| `whisper` | Whisper speech recognition data |

## Creating Custom Plugins

1. Create a new `.conf` file in the `plugins/` directory:

```bash
# My App - Description of what this plugin backs up
ENABLED=yes

PATH $HOME/.config/myapp
EXCLUDE cache/
EXCLUDE tmp/
```

2. That's it. The plugin is automatically discovered by both `backup.sh` and `restore.sh`. Missing paths are silently skipped.

### Plugin Naming

- The filename (without `.conf`) becomes the plugin name used with `--plugin=NAME`
- The first comment line is used as the plugin description in listings and TUI
- `ENABLED=yes` or `ENABLED=no` controls whether it runs by default

### Advanced Plugin Features

```bash
# My App - Full-featured plugin example
ENABLED=yes

# Pre-backup commands (run before rsync, skipped during restore)
PRE_CMD mkdir -p $HOME/.local/share/package-lists
PRE_CMD myapp --export-config > $HOME/.local/share/package-lists/myapp.txt

# Paths and filters
PATH $HOME/.config/myapp
EXCLUDE cache/
EXCLUDE tmp/

# Files to keep in backup but exclude from restore
RESTORE_EXCLUDE hardware-specific.conf

# Interactive prompts before restore rsync (use $DST and $SKIP_CONFIRM)
PRE_RESTORE_CMD if [[ "$SKIP_CONFIRM" != true ]]; then \
    read -rp "  Restore hardware config? [y/N] " _a; \
    [[ "$_a" =~ ^[Yy]$ ]] && sudo cp "$DST/..." /etc/... || true; \
  else echo "  (--yes: not restored)"; fi

# Commands after restore rsync (e.g., reinstall, fix permissions)
RESTORE_CMD chmod 700 $HOME/.config/myapp
RESTORE_CMD myapp --import-config < $HOME/.local/share/package-lists/myapp.txt
```

### Catch-all Integration

When you create a dedicated plugin for an app already covered by `dotconfig` or `dotlocal`, add its directory to the catch-all's `EXCLUDE` list to avoid duplicate backups:

```bash
# In plugins/dotconfig.conf, add:
EXCLUDE myapp/
```

## Sudo Handling

Both scripts automatically detect paths that require elevated privileges:

- **Paths outside `$HOME`** (e.g., `/etc`, `/opt`, `/var/lib/libvirt`) always use `sudo rsync`
- **Unreadable paths** (backup) or **unwritable paths** (restore) inside `$HOME` also use `sudo rsync`

The preview clearly marks these jobs with a `[sudo]` indicator.

**Pre-authentication:** If any job requires sudo, both scripts prompt for the password **upfront** (before any rsync command runs). A background keep-alive process refreshes the sudo timestamp every 50 seconds, so long-running operations never stall waiting for a password mid-execution. The keep-alive is automatically stopped when the script finishes.

## Delete Behavior

**Backup (`backup.sh`):** When `RSYNC_DELETE=yes` (default), rsync uses `--delete` to create an exact mirror of the source. Files deleted from the source are also deleted from the backup. Use `--no-delete` to override this and keep old files on the destination.

**Restore (`restore.sh`):** The restore script **never** uses `--delete`, regardless of the `RSYNC_DELETE` setting. It only overwrites existing files and copies missing ones. This ensures that restoring from backup cannot accidentally delete files on your live system.

## Typical Full-System Restore Workflow

1. Boot a fresh Ubuntu installation
2. Mount the backup drive
3. Clone this repository
4. Edit `backup.conf` to point `DST` to the backup drive
5. Run:

```bash
# Preview first:
./restore.sh --dry-run

# Restore everything:
./restore.sh
```

6. The restore will:
   - Ask about hardware-specific files (fstab, hostname, etc.)
   - Rsync all configuration and data
   - Reinstall APT packages (skipping unavailable ones with a warning)
   - Install snap packages (bases first, then apps, then classic)
   - Install Flatpak apps
   - Reinstall VS Code extensions
   - Reload GNOME dconf settings
   - Re-register VMs with libvirt
   - Fix SSH and GPG permissions
