# Rsync Backup Manager

Sistema di backup unificato basato su `rsync` con configurazione modulare a plugin, anteprima visuale, dry-run, conferma prima dell'esecuzione e TUI interattiva con `dialog`/`whiptail`.

## Struttura

```
rsync-backup/
├── backup.sh              # Script principale (CLI + TUI)
├── backup.conf            # Configurazione globale (destinazione, flag rsync)
├── common.conf            # Percorsi sempre inclusi nel backup
├── README.md              # Questa documentazione
└── plugins/
    ├── firefox.conf       # Profili Firefox
    ├── android.conf       # Android Studio
    ├── system.conf        # File di sistema (/etc)
    ├── ssh.conf           # Chiavi SSH
    ├── retropie.conf      # RetroPie (disabilitato di default)
    ├── virt-manager.conf  # Configurazioni VM
    └── whisper.conf       # Servizio Whisper
```

## Installazione

Non richiede installazione. Assicurarsi che `rsync` sia presente:

```bash
sudo apt install rsync
```

Per la TUI interattiva, installare `dialog` o `whiptail`:

```bash
sudo apt install dialog
```

## Uso rapido

```bash
# Backup completo con anteprima e conferma:
./backup.sh

# Solo anteprima senza eseguire:
./backup.sh --dry-run

# Backup senza conferma:
./backup.sh --yes

# TUI interattiva:
./backup.sh --tui

# Solo un plugin specifico:
./backup.sh --plugin=firefox --plugin=ssh

# Elenco plugin:
./backup.sh --list

# Help completo:
./backup.sh --help
```

## Opzioni CLI

| Opzione | Descrizione |
|---|---|
| `--tui` | Avvia la TUI interattiva |
| `--dry-run` | Esegue rsync in modalita' simulazione |
| `--yes` | Salta la conferma, esegue direttamente |
| `--plugin=NOME` | Esegue solo il plugin specificato (ripetibile) |
| `--no-common` | Salta i percorsi definiti in common.conf |
| `--no-delete` | Non cancella file dalla destinazione |
| `--list` | Elenca tutti i plugin e il loro stato |
| `--quiet` | Output minimale (solo riepilogo) |
| `--help` | Mostra l'help dettagliato |

## Configurazione

### backup.conf - Configurazione globale

```bash
# Cartella di destinazione (es. disco esterno, NAS)
DST=/media/manzolo/backup-drive

# Flag base di rsync
RSYNC_FLAGS="--archive --verbose --human-readable --progress --partial"

# Cancella dalla destinazione i file non piu' presenti nella sorgente (yes/no)
RSYNC_DELETE=yes

# File di log
LOG_FILE=/home/manzolo/backups/rsync-backup/backup.log
```

La destinazione finale sara' `$DST/$(hostname)/` con struttura che replica i path assoluti sorgente.

### Formato PATH/INCLUDE/EXCLUDE

I file `common.conf` e i plugin in `plugins/*.conf` usano questo formato:

```bash
# Ogni riga PATH definisce un percorso sorgente da backuppare.
# INCLUDE e EXCLUDE si applicano all'ultimo PATH definito.

PATH /home/manzolo/.config
EXCLUDE cache/

PATH /home/manzolo/.local
INCLUDE importante/
EXCLUDE *
```

Le regole seguono la logica "first match wins" di rsync: le INCLUDE vengono messe prima delle EXCLUDE nel comando generato.

### Plugin

I file plugin in `plugins/*.conf` hanno in piu' la riga `ENABLED=yes` o `ENABLED=no`:

```bash
# Firefox - Profili e dati browser
ENABLED=yes

PATH /home/manzolo/.mozilla/firefox
EXCLUDE cache2/
EXCLUDE startupCache/
```

Per creare un nuovo plugin, basta aggiungere un file `.conf` nella cartella `plugins/`.

## TUI Interattiva

Avviare con `./backup.sh --tui`. Il menu principale offre:

1. **Run backup** - Mostra anteprima, chiede conferma, esegue il backup
2. **Run backup (dry-run)** - Simulazione senza modifiche
3. **Select plugins** - Seleziona/deseleziona plugin con checklist
4. **Edit backup.conf** - Modifica configurazione globale
5. **Edit common.conf** - Modifica percorsi comuni
6. **Edit plugin config** - Seleziona e modifica un plugin
7. **Show preview** - Mostra anteprima di tutti i job
8. **Exit** - Esci

La selezione plugin puo' essere salvata permanentemente nei file `.conf` oppure applicata solo per la sessione corrente.

## Gestione sudo

Lo script rileva automaticamente i percorsi che richiedono permessi elevati:

- Percorsi fuori da `$HOME` (es. `/etc`, `/opt`)
- Percorsi nella home non leggibili dall'utente corrente

Per questi job viene usato `sudo rsync`. L'anteprima mostra chiaramente l'indicatore `[sudo]`.

## Comportamento --delete

Con `RSYNC_DELETE=yes` (default), rsync usa `--delete` per creare un mirror esatto: i file cancellati dalla sorgente vengono cancellati anche dal backup. Usare `--no-delete` da CLI per sovrascrivere questo comportamento.
