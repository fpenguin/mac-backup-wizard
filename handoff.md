# Handoff Notes

## What this is

A personal, one-time macOS clean-install + settings backup wizard with an
OpenBoot/Total-Commander-style terminal UI. Entry point: `./mac-backup-wizard.sh`
(add `--dry-run` to preview without changing anything).

## Menu

```
Backup:       1 Define apps to back up   2 Back up settings
Restore:      3 Install apps             4 Restore settings
Mackup:       5 Install Mackup          6 backup  7 restore
Maintenance:  8 Change backup location   9 Remove settings backups
              E Export settings for AI review  I Import reviewed settings
```

## Architecture

- **Option `1` is the source of truth.** `mac-installed-apps.py` scans
  `/Applications` + `~/Applications`, captures name + **bundle id** + path +
  Finder tags + size, and writes `mac-installed-apps.tsv`. On a second Mac it
  offers append/merge vs replace. Categories live in `mac-app-categories.tsv`.
  Installer/updater/removal helper apps are filtered from both scan and merge
  (`uninstall`, `uninstaller`, `installer`, `setup`, `remove`, `updater`,
  `autoupdate`, plus app names beginning with `install`). `mac-defined-app-picker.py`
  applies the same filter when reading an older TSV.
  Inside the option `1` picker, `H` runs an AI category helper for blank rows:
  `1` shells out to `codex exec`, `2` shells out to `claude -p`. The script sends
  category definitions, existing categorized examples, and blank app rows as a
  prompt, then parses TSV output and applies only valid category keys. It shows
  an AI result screen and writes the raw response to `mac-ai-last-response.txt`;
  auth/login failures are detected before parsing. If a chosen CLI is missing,
  it attempts automatic install first: Codex standalone installer, Homebrew cask,
  npm fallback; Claude native installer, npm fallback. Install still requires a
  later interactive login (`codex login` or `claude`). Slow install/request work
  runs in a worker thread while curses redraws an indeterminate progress bar with
  elapsed time and timeout values.
- **App install (option 3)** maps defined apps to `mac-apps.tsv` (normalized
  name/identifier match) and builds a Homebrew/mas/manual plan. Apps with no
  catalog entry fall back to the inventory's `cask` / `mas_id` columns
  (synthetic install items), so uncataloged apps still install. Those columns are
  filled at scan time by `resolve_install_sources` in `mac-installed-apps.py`
  from `brew info --json=v2 --installed` and `mas list` (blanks only; never
  overwrites). Inventory schema gained `mas_id` and `cask` (appended last;
  `load_defined_apps` reads them).
- **Settings (options 2/4)** are discovered by `mac-settings-scan.py`: for each
  app it observes the filesystem keyed by bundle id (preference plists,
  Application Support, sandbox Containers), plus dotfiles and `~/.config`. Only
  paths that exist are emitted. A deny-list drops caches/state; large folders
  load disabled-by-default. Mackup-supported apps are deferred. The scan writes
  the machine-local `mac-settings.generated.tsv` (schema:
  `enabled name path notes source bundle_id kind verified size_bytes size_human`), with
  `mac-settings.tsv` merged in as a curated overlay. Restore (option 4) loads the
  manifest from the chosen backup (`selected-settings.tsv`, written at backup
  time) via `restore_source_manifest`, not the local manifest, so every backed-up
  item is offered even when its app is not installed on this Mac.
- **Matching is exact bundle id** (with a name fallback only for rows that have
  no bundle id, e.g. dotfiles). The settings picker (`mac-settings-picker.py`)
  always opens, pre-seeded by an optional app pre-selection, so dotfiles and
  other unmatched rows can be added.
- **AI review (E/I)** exports a candidate TSV, you curate keep/skip and fill
  gaps in Claude/ChatGPT, then import. Proposed (`source=llm`) paths are
  re-checked against disk; missing ones stay disabled + `verified=no`.
- **Backup location** is universal (`BACKUP_ROOT`): option `8` auto-detects
  iCloud / Dropbox / OneDrive / Google Drive (or a custom path) and saves the
  choice to `mac-backup-location.conf`. Backup/restore use `rsync -aE`.
  Option `2` wraps each selected `rsync` copy with an overall progress line
  (`current/total`, percent, active setting, spinner while the process runs) and
  reports copy failures instead of always printing a clean completion. Before
  confirmation, it prints estimated backup size by app category and total using
  cached manifest sizes; legacy rows without sizes are counted as unknown rather
  than walking folders. It also preflights free space and applies rsync excludes
  for caches, browser `WebsiteData`, Docker/VM images, sockets, logs, and
  AppleDouble files. Each backup writes `backup-report.tsv` and
  `backup-errors.log`; `No space left on device` aborts the remaining copy loop.
  After backup completion, it asks `Open the folder? [n/Y]` and opens the backup
  target when the user presses Return or answers yes.
- **Mackup setup (option 5)** installs Mackup, then prompts for the Mackup backup
  folder. The default is `$BACKUP_ROOT/Mackup`, so it follows whatever option `8`
  saved. The wizard writes `~/.mackup.cfg` with `[storage] engine = file_system`,
  a home-relative `path` when possible, and `directory` set to the selected
  folder name.

## Active files

Scripts: `mac-backup-wizard.sh`, `mac-installed-apps.py`, `mac-defined-app-picker.py`,
`mac-settings-scan.py`, `mac-settings-picker.py`.
Tracked data: `mac-apps.tsv`, `mac-settings.tsv`, `mac-app-categories.tsv`,
`mac-installed-apps.example.tsv` (sanitized template).
Git-ignored (machine-local): `mac-installed-apps.tsv` (your real inventory,
written by option 1), `mac-settings.generated.tsv`, `mac-settings.reviewed.tsv`,
`mac-settings.candidates.tsv`, `mac-backup-location.conf`, `mac-mackup-apps.tsv`,
`mac-ai-last-response.txt`.

The real inventory is resolved at startup (`resolve_installed_apps_paths`):
option 1 always writes the real `mac-installed-apps.tsv` (`INSTALLED_APPS_REAL`);
read-only flows use it when present and fall back to the example otherwise
(`INSTALLED_APPS_CATALOG`).

The legacy standalone scripts and the old category-driven picker have been
removed; `spec-settings-discovery.md` records the design and decisions.

## Tests

```bash
bash tests/run.sh
```

Syntax checks + Python unit tests (`tests/test_discovery.py`) + shell tests
(`tests/test_wizard.sh`). All green.

## Latest Backup Audit Context

The most recent real backup run exposed noisy/unsafe backup targets, especially
browser/WebKit data and Docker VM data. Observed from the pasted run:

- `493` setting copy attempts.
- `2,271` rsync error lines.
- `2,248` `File name too long` errors, mostly browser/WebKit cache paths.
- Docker hit `No space left on device`.
- Destination volume had about `29 GiB` free at the time of inspection.
- Latest profile inspected: the most recent dated profile under the configured
  backup root (e.g. `<backup-root>/MacSettings/<machine>/latest`).

Changes made after that run:

- `mac-backup-wizard.sh` has `BACKUP_RSYNC_EXCLUDES` for caches, browser
  `WebsiteData`, Docker/VM images, sockets, logs, and AppleDouble `._*` files.
- Option `2` now writes `backup-report.tsv` and `backup-errors.log` into each
  backup folder.
- Copy errors are classified into `no_space`, `name_too_long`, `permission`,
  `unsupported`, and `copy_error`.
- `No space left on device` aborts the remaining copy loop.
- `backup_space_preflight` warns when known selected settings are large relative
  to available space.
- `mac-settings-scan.py` deny-list now also covers direct `WebsiteData`,
  `CacheStorage`, Docker/VM image, socket, and related volatile paths.

## Claude Audit Focus

Please audit this codebase for correctness and safety, prioritizing:

- Backup/restore safety in `mac-backup-wizard.sh`, especially:
  `backup_selected_settings`, `restore_selected_settings`,
  `copy_settings_manifest_to_backup`, `run_with_progress_line`,
  `backup_space_preflight`, and path handling via `relative_key_for_path`.
- Whether rsync excludes are too broad or too narrow for a settings backup.
  The intent is to keep user/app settings while avoiding cache, browser runtime
  stores, sockets, logs, VM images, and huge temporary data.
- Whether `backup-report.tsv` / `backup-errors.log` cover every failure path,
  including metadata copy failures and directory creation failures.
- Restore behavior for partial backups: should failed/skipped rows in
  `backup-report.tsv` influence restore selection or warning text?
- Whether the generated `selected-settings.tsv` schema is backward compatible
  with older 4-column backups.
- Mackup config writing in option `5`: it rewrites `[storage]` to
  `engine = file_system`, `path = ...`, `directory = ...`; check whether this is
  valid for paths inside and outside `$HOME`.
- App/category picker behavior in `mac-installed-apps.py` and
  `mac-defined-app-picker.py`, especially AI CLI install/login handling and
  whether automatic category suggestions can corrupt user-curated categories.
- Cross-Mac merge behavior: option `1` should preserve apps from other Macs when
  the user chooses append/merge, and only drop them on replace.
- Any shell quoting/path bugs involving spaces, iCloud paths, absolute paths, and
  tilde expansion.

Useful command:

```bash
bash tests/run.sh
```

Please return findings ordered by severity, with file/line references and
concrete fixes. Avoid broad refactors unless they reduce real safety risk.

## Repo / git conventions

- Standalone repository; the project lives at the repo root.
- Work is tagged per change (`v0.1` … `v1.1`).

## Safety notes

- Restore overwrites live config with a single confirmation and no pre-restore
  snapshot — intended for a clean machine. Be careful running it on a populated
  Mac.
- Restoring `.plist` files via rsync bypasses cfprefsd; quit the target app
  first (or expect a re-login) for preferences to take effect.

## Pending / optional

See `roadmap.md` (retire `mac-settings.tsv`, Group Containers, in-tool AI call,
minor UX).
