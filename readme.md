# Mac Backup Wizard

A terminal-based Mac setup and backup wizard for a clean-install workflow.

The main entry point is:

```bash
cd /path/to/mac-backup-wizard
./mac-backup-wizard.sh
```

Dry-run mode:

```bash
./mac-backup-wizard.sh --dry-run
```

## Main Menu

```text
Backup:
  1  Define apps to back up
  2  Back up settings

Restore:
  3  Install apps
  4  Restore settings

Mackup:
  5  Install Mackup
  6  Choose apps to back up using Mackup
  7  Choose apps to restore using Mackup

Maintenance:
  8  Change backup location
  9  Remove settings backups
  E  Export settings list for AI review
  I  Import reviewed settings list
```

Settings to back up are discovered by scanning the filesystem keyed by each
app's bundle id (preference plists, Application Support, sandbox Containers),
plus dotfiles and `~/.config`. The scan only ever lists paths that exist; large
folders are flagged off by default. Apps that Mackup supports are deferred to
Mackup (options `6`/`7`) and omitted from this list, so the same files are not
managed two ways. Options `E`/`I` are an optional round-trip:
export a candidate list, have Claude/ChatGPT mark keep/skip and fill gaps, then
import it. Imported paths the AI proposes are re-checked against disk and left
disabled/unverified if missing, so a wrong path can never be backed up.

The settings backup destination is shown in the Catalogs header as `Backup:` and
can be any cloud or local folder (see [Backup Location](#backup-location)).

**Restoring on a new Mac.** Restore (option `4`) reads the list of what to restore
from the backup itself (the `selected-settings.tsv` saved at backup time), not
from whatever is installed on the new Mac. So it offers **everything you backed
up**, regardless of whether each app is installed yet — install the apps first
(option `3`) or restore settings now and install later, in any order.

Option `8` lets you point the settings backup at iCloud Drive, Dropbox, OneDrive,
Google Drive (auto-detected under `~/Library/CloudStorage`), or a custom path.

Option `9` lists the backup profiles under the current backup root, shows each
one's size, and deletes the chosen profile (or all of them) after a confirmation.
It refuses to remove anything outside the backup root, and `--dry-run` only
prints the `rm` it would run.

## Source of Truth

Option `1` writes the app inventory and categories used by the other flows.
Installer/updater/removal helpers are hidden from the scan and saved catalog
because they are not useful backup targets. This includes app names such as
`Uninstall`, `Uninstaller`, `Installer`, `setup`, `Remove`, `Updater`, and
`AutoUpdate`.

When an inventory already exists, option `1` asks whether to **merge** (keep
existing apps and categories, add this Mac's apps, refresh metadata for apps it
finds — recommended when you back up more than one Mac) or **replace** (overwrite
with only the apps found on this Mac). Merge keeps apps that live on your other
Macs instead of dropping them.

While defining apps, press `H` to ask an installed AI CLI to suggest categories
for apps that are still blank:

```text
1  CODEX
2  CLAUDE
```

The wizard sends the category list, existing categorized examples, and blank app
rows to the chosen CLI (`codex exec` or `claude -p`). It captures the response,
validates the returned TSV, and only applies valid category keys. Rows marked
`skip` or invalid category names are left uncategorized. This is a CLI handoff,
not a direct API integration in the script. After the run, the picker shows a
summary screen and writes the raw CLI response to `mac-ai-last-response.txt`
(git-ignored) for troubleshooting.

Long CLI steps run behind an animated wait screen with an indeterminate progress
bar, elapsed time, and install/AI timeout values, so the terminal should no
longer look frozen while a provider installs or responds.

If the chosen CLI is not installed, the wizard tries to install it before
running the categorization:

- Codex: official standalone installer, then Homebrew cask, then npm fallback.
- Claude: official native installer, then npm fallback.

Installation does not sign you in. If authentication fails, run `codex login` or
`claude` once in Terminal, then rerun the AI helper.

- `mac-installed-apps.tsv`: scanned apps, Finder tags, app sizes, last-updated dates, user-assigned categories. Generated locally and git-ignored — see [Your data vs. the repo](#your-data-vs-the-repo).
- `mac-app-categories.tsv`: editable category list.

The other menus use the same defined-app picker where possible:

- Option `2` maps selected apps to matching rows in `mac-settings.tsv`.
- Option `3` maps selected apps to install entries in `mac-apps.tsv`.
- Option `4` maps selected apps to matching restore settings.
- Options `6` and `7` map selected apps to Mackup-supported app IDs.

## Picker Controls

```text
Up/Down: move
Shift-Up/Down: toggle while moving
Right/Left: page
Space: mark current
A: mark all/none visible
I: invert visible
H: AI help fill blank app categories
/: search
Enter: continue/save
Q/Esc: cancel/back
```

In option `1`, category assignment uses:

```text
1-9: assign category
0: clear current app category only
```

## Files

Scripts:

- `mac-backup-wizard.sh`: main wizard.
- `mac-installed-apps.py`: scans installed apps and edits categories (option `1`).
- `mac-defined-app-picker.py`: shared picker for defined apps.
- `mac-settings-scan.py`: discovers settings to back up (filesystem scan by
  bundle id, dotfiles, deny-list/size flag, Mackup deferral, AI review).
- `mac-settings-picker.py`: settings review/finalize picker.

Data (tracked):

- `mac-apps.tsv`: install catalog.
- `mac-settings.tsv`: curated settings overlay (merged into the scan).
- `mac-app-categories.tsv`: editable category config.
- `mac-installed-apps.example.tsv`: sanitized example inventory (template only).

Generated / machine-local (git-ignored): `mac-installed-apps.tsv` (your real
inventory), `mac-settings.generated.tsv`, `mac-settings.reviewed.tsv`,
`mac-settings.candidates.tsv`, `mac-backup-location.conf`, `mac-mackup-apps.tsv`,
`mac-ai-last-response.txt`.

`tests/`: see [Tests](#tests).

## Your data vs. the repo

The repo ships a **sanitized example** inventory (`mac-installed-apps.example.tsv`)
so you can read the format and try the tool. Your **real** inventory lives in
`mac-installed-apps.tsv`, which is **git-ignored** — it is created the first time
you run option `1`, and it never shows up in `git status` or gets pushed.

This means you can use a single clone for both developing the tool and backing up
your own Mac:

- Option `1` always reads/writes your real `mac-installed-apps.tsv`.
- All other flows use your real inventory when it exists, and fall back to the
  example only when it doesn't (e.g. a fresh clone you haven't scanned yet).
- The same pattern already applies to other personal/runtime files
  (`mac-settings.generated.tsv`, `mac-backup-location.conf`, etc.).

So: clone, run option `1`, and your data stays local — nothing personal is ever
committed.

## Backup Location

By default, settings backups go to iCloud Drive:

```text
~/Library/Mobile Documents/com~apple~CloudDocs/Backup/MacSettings
```

Use Maintenance option `8` (Change backup location) to point backups at any
provider instead — iCloud Drive, Dropbox, OneDrive, or Google Drive are
auto-detected (iCloud under `~/Library/Mobile Documents`, the rest under
`~/Library/CloudStorage`), or enter a custom path. The choice is saved to
`mac-backup-location.conf` beside the script (machine-local, git-ignored). The
`--root` flag and the `BACKUP_ROOT`/`ICLOUD_ROOT` environment variables override
the saved value for a single run.

This setting controls the settings backup/restore/remove flows (options `2`,
`4`, `9`). Mackup keeps its own storage configuration (option `5`, below) and is
not changed by option `8`.

During option `2`, selected settings are copied with an overall progress bar.
The line shows `current/total`, percent, the active setting name, and an animated
spinner while each `rsync` copy is running. After the backup finishes, the wizard
asks `Open the folder? [n/Y]`; pressing Return opens the completed backup target
in Finder.

Each backup writes `backup-report.tsv` and `backup-errors.log` into the backup
folder. The report records `ok`, `skipped`, and `failed` rows per setting; the
error log preserves full rsync output for failed rows. If a copy fails because
the destination is out of space, the wizard stops early instead of continuing
through the rest of the list.

Before the final backup confirmation, option `2` also shows an estimated backup
size by app category plus a total. In the normal flow this is fast because the
settings scan writes cached `size_bytes` / `size_human` values into
`mac-settings.generated.tsv`. Legacy or reviewed rows without cached sizes are
listed as unknown rather than forcing a slow folder walk.

The copy step skips volatile data that should not be part of a settings backup:
caches, browser `WebsiteData`, Docker/VM images, socket files, logs, and temporary
AppleDouble metadata files. This avoids most `File name too long`, `Operation not
supported`, and runaway disk-usage failures from browser and container data.

Mackup is configured through:

```text
~/.mackup.cfg
```

Option `5` installs Mackup, then asks where Mackup should keep its backup
folder. The default is based on the current backup location from option `8`:

```text
<current backup location>/Mackup
```

It writes a file-system storage config like:

```ini
[storage]
engine = file_system
path = Library/Mobile Documents/com~apple~CloudDocs/Backup/MacSettings
directory = Mackup
```

When the chosen folder is inside your home folder, the `path` value is stored
home-relative so the config is easier to restore on another Mac.

## Tests

Run the suite from the project root:

```bash
bash tests/run.sh
```

It runs syntax checks (`bash -n`, `py_compile`), Python unit tests
(`tests/test_discovery.py`: scanner pure functions, deny-list, mackup coverage,
catalog merge counts, and the AI-import verified gate) and shell tests
(`tests/test_wizard.sh`: bundle-id matching, backup-root precedence, and the
`remove_backup_dir` safety guard).
