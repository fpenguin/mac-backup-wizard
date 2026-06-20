# Spec: Settings Discovery, LLM Curation, and Backup Teardown

Status: **draft for review** — no code written yet.
Author: audit follow-up.
Applies to: `mac-backup-wizard.sh`, `mac-installed-apps.py`, `mac-settings.tsv`, plus one new helper.

---

## 1. Why

The tool is a **one-time, clean-install assistant**: capture settings on the old
Mac, restore once on the new Mac, then get out of the way. Two problems block
that from being trustworthy today:

1. **Discovery is wrong.** Settings are matched by comparing app names against the
   `name + path + notes` prose of a hand-written manifest
   (`mac-backup-wizard.sh` `select_settings_for_defined_apps`). This both **misses**
   real config (e.g. "Karabiner-Elements" never matches its "Karabiner" row) and
   risks **false positives** (notes text leaks into the match key). It also can't
   scale to the long tail of apps, and it ignores the reliable identifier
   (`bundle_id`) that `mac-installed-apps.py` already collects.

2. **Cleanup is missing.** Backups land in
   `~/Library/Mobile Documents/com~apple~CloudDocs/Backup/MacSettings/` with no
   in-app way to remove them. For a one-time tool, leftover backup clutter is a
   real cost.

This spec replaces prose-matching with **filesystem observation keyed by bundle
ID**, adds an **optional LLM curation pass** over *observed* paths (not guessed
ones), and adds a **teardown command**.

### Non-goals

- No backup versioning / history. Single `latest` per profile stays.
- No always-on pre-restore snapshot (overkill for a clean target).
- No attempt to auto-discover settings for apps that store data in arbitrary,
  non-conventional locations with nothing on disk to observe — those are handled
  by the LLM gap-fill step, with mandatory verification.

---

## 2. Design overview

Three discovery sources, stacked in priority order:

| Source | Covers | Trust |
|---|---|---|
| **A. Filesystem observation (bundle ID + name)** | Apps that wrote to the standard macOS locations | High — only ever offers paths that exist |
| **B. Mackup** | ~500 community-mapped apps (already integrated, options 5/6/7) | High |
| **C. LLM curation/gap-fill** | Long tail, dotfiles, `~/.config/*` | Medium — **must** pass existence verification before use |

Core principle: **observe what exists; never invent a path.** A path is only ever
backed up or restored if it was confirmed present on disk. The LLM never produces
a write target directly — it only classifies/curates observed paths and proposes
candidates that are then re-verified.

---

## 3. Source A — filesystem observation engine

New scanning logic (Python, alongside `mac-installed-apps.py` or a new
`mac-settings-scan.py`). For each installed app (from `mac-installed-apps.tsv`,
which carries `name`, `bundle_id`, `path`) enumerate **candidate config
locations**, `stat` them, and keep only the ones that exist.

### Parent locations scanned

```
~/Library/Preferences/<bundle_id>.plist
~/Library/Preferences/<bundle_id>*.plist        # e.g. Alfred-Preferences variants
~/Library/Application Support/<AppName>/         # folder name = display name
~/Library/Application Support/<bundle_id>/        # folder name = bundle id
~/Library/Containers/<bundle_id>/Data/           # sandboxed / App Store apps
~/Library/Group Containers/*<bundle_id-ish>*/     # shared group containers
~/Library/Saved Application State/<bundle_id>.savedState   # DENY (see §5)
```

Plus a small inverted scan for dotfile-style apps (Source C territory, but cheap
to observe): enumerate `~/.config/*` and a known set of top-level dotfiles
(`~/.zshrc`, `~/.zprofile`, `~/.gitconfig`, `~/.ssh/config`, …) and attribute by
name where possible; leave the rest unattributed for the LLM step.

### Attribution rules

- **Preferences plist & Containers** → match by **exact `bundle_id`**. Reliable.
- **Application Support folders** → match by normalized display name, then fall
  back to bundle id. (Folder naming is inconsistent across vendors.)
- Anything found but unattributed is still listed (owner = "unknown") so it can be
  curated rather than silently dropped.

### Output

A candidate TSV (see §6) with one row per *observed* path, tagged with `source=fs`,
the owning app, bundle id, kind (`pref|appsupport|container|groupcontainer|dotfile`),
and size. This becomes the working manifest, replacing the hand-maintained
`mac-settings.tsv` as the primary input.

**Containers are scanned by default** (decision §11): `~/Library/Containers/<bundle_id>/Data/`
is included so sandboxed / App Store apps (Logic Pro, BBEdit, Toggl Track, etc.)
are captured — these are missed entirely today. Containers can be large, so the
deny-list (§5) and size flagging still apply, and a `--skip-containers` escape
hatch is provided for a faster scan.

---

## 4. Source B — Mackup (unchanged, integration note)

Keep options 5/6/7. **Decision §11: when an app is mackup-supported, defer to
Mackup automatically** — use Mackup for that app and **suppress its Source A rows**
in the settings flow, so the same files are never managed two ways. No per-app
prompt. Surface it clearly in the plan ("Alfred: handled by Mackup") so the user
can see why those files don't appear under the filesystem backup.

---

## 5. Deny-list (never back up)

Applied to every source before a path is offered:

- `~/Library/Caches/**`
- `~/Library/Saved Application State/**`
- `~/Library/Logs/**`, `**/CrashReporter/**`
- Cookies, `**/*.lock`, sockets, FIFOs, symlinks pointing outside `$HOME`
- Known machine-bound license/activation blobs (iLok, etc. — list grows over time)
- Oversized data dirs above a threshold (default 250 MB) → flagged, not auto-included
  (e.g. Obsidian vaults, Logseq graphs — the existing manifest already warns these
  belong in their own synced folder).

Deny-list lives in an editable file (`mac-settings-denylist.tsv`) so it's tunable
without code edits.

---

## 6. Source C — LLM curation round-trip

The optional step the user asked about. The key safety move: **feed the LLM
existence-checked observations, not bare app names.**

### Export (tool → LLM)

`mac-backup-wizard.sh` gains an export action that writes a candidate TSV:

```
app_name   bundle_id   source   kind        found_path                         size_human   keep   reason
Alfred     com.run...  fs       appsupport  ~/Library/Application Support/Alfred  48 MB                
Alfred     com.run...  fs       pref        ~/Library/Preferences/...Alfred-Preferences.plist  12 KB        
Cursor     com.cursor  fs       appsupport  ~/Library/Application Support/Cursor/User  3 MB           
zsh        -           fs       dotfile     ~/.zshrc                            2 KB                 
<gap>      com.foo.bar fs       -           (none found)                        -                    
```

The user pastes this into Claude/ChatGPT with a prompt like *"For each row, set
`keep` to yes/no (yes = real user config worth restoring on a new Mac; no =
cache/state/machine-bound) and give a one-line `reason`. For `<gap>` rows where no
path was found, propose the most likely real config path(s) for that bundle id,
marked source=llm."*

### Re-import (LLM → tool)

- Rows with `keep=yes` and `source=fs` → trusted (already verified to exist).
- Rows with `source=llm` (proposed paths) → imported as **`verified=no`**.
- On the next backup run, the tool re-`stat`s every `source=llm` path:
  - exists → promote to `verified=yes`, include.
  - missing → keep `verified=no`, **exclude from backup**, report as "proposed but
    not found."

### Hard rule

**Restore never writes to a path that wasn't confirmed present at backup time.**
Because backup only ever copies existing files into the backup tree, and restore
only ever copies *from* that tree back to its recorded origin, an LLM
hallucination can at worst produce a no-op (nothing to back up → nothing to
restore). This is the whole reason the LLM is safe to use here.

---

## 7. Backup teardown command

New main-menu item:

```
  8  Remove backups
```

Behavior:
- List profiles under `$ICLOUD_ROOT` (reuse `load_backup_profiles`,
  `mac-backup-wizard.sh`).
- Let the user pick one profile or "all".
- Show total size and the resolved path, then `confirm` (respects `--dry-run` /
  `--yes`).
- Delete with a guarded `rm -rf` that asserts the target is **inside**
  `$ICLOUD_ROOT` and non-empty before running (refuse if either check fails).
- Dry-run prints the `rm` it would run via `run_or_print`.

This is the clutter answer: one backup, restore once, one keystroke to wipe.

---

## 8. Multi-Mac app catalog merge (from roadmap.md)

Today `mac-installed-apps.py` `write_apps` rewrites `mac-installed-apps.tsv` with
only the apps found on the *current* Mac. Categories survive (via
`load_existing_categories`, which re-applies them by path/bundle/name), but **apps
that aren't installed on this machine are dropped** — so for someone with more
than one Mac, saving on a second machine silently shrinks the catalog.

Add a save prompt after "Define apps to backup" (option 1) when a non-empty app
TSV already exists:

- **Append / merge (recommended default):** keep all existing app rows and their
  categories, add apps newly discovered on the current Mac, and refresh metadata
  (`size`, `last_updated`, `finder_tags`) for rows that match an existing entry.
  Existing category assignments win unless the row had none. Apps not seen on this
  Mac are retained (that's the point).
- **Replace:** overwrite the TSV with only apps discovered on the current Mac —
  for rebuilding a clean single-machine catalog.

UX: default to append/merge whenever an existing non-empty TSV is detected; make
clear that merge is the safer choice for shared household / multi-device catalogs
and replace is for a single-machine rebuild.

Implementation notes:
- Merge key priority: `bundle_id` (exact) → `path` → normalized name, mirroring
  the §3 attribution rules.
- Optionally tag each row with provenance (which Mac/profile last saw it) so the
  picker can show it.
- Respect `--dry-run`: preview counts (`N kept, M added, K updated`) and write
  nothing.

---

## 9. Data model / schema changes

Extend the settings manifest schema (backward compatible — missing columns
default sensibly):

```
enabled   name   path   notes   source   bundle_id   kind   verified
```

- `source` ∈ `fs | mackup | manual | llm` (default `manual` for hand-added rows).
- `verified` ∈ `yes | no` (default `yes` for manual rows; `no` only for
  un-confirmed `llm` rows).
- The legacy 4-column `mac-settings.tsv` still loads (as `source=manual`,
  `verified=yes`) during migration. **Decision §11: retire it once covered** — the
  scan + LLM gap-fill must demonstrably reproduce its dotfile rows (`~/.zshrc`,
  `~/.zprofile`, `~/.gitconfig`, `~/.ssh/config`) *before* the curated file is
  removed, so we don't silently reintroduce the "dotfiles unreachable" gap (audit
  H2). `manual` stays in the enum for any rows a user hand-adds later.

`relative_key_for_path` and the rsync backup/restore plumbing
(`backup_selected_settings` / `restore_selected_settings`) are unchanged — they
already copy existing paths and skip missing ones.

---

## 10. Impact on existing code

| Area | Change |
|---|---|
| `mac-installed-apps.py` | Reuse bundle-id scan; optionally host the new candidate scan, or split into `mac-settings-scan.py`. |
| `mac-backup-wizard.sh` settings flow | Replace `select_settings_for_defined_apps` prose-matching with: load observed manifest → filter by selected apps via **bundle_id**, not notes. |
| `mac-backup-wizard.sh` menu | Add `8 Remove backups`; add an "Export settings candidates for review" action (could live under option 2). |
| `mac-settings.tsv` | Becomes a *generated* working file + an optional curated overlay; document that it's no longer purely hand-edited. |
| Dead code | While here: the unreachable settings fallback (`settings_picker_curses_flow` / numbered loop) and the orphaned category-picker subsystem can be removed (see audit M4/L2). Out of scope for this spec but related. |

---

## 11. Decisions (resolved)

| # | Decision | Resolution |
|---|---|---|
| 1 | Mackup overlap | **Defer to Mackup automatically** for supported apps; suppress their fs rows, no per-app prompt (§4). |
| 2 | Legacy `mac-settings.tsv` | **Retire once covered** — delete only after the scan + LLM reproduce its dotfile rows (§9). |
| 3 | LLM gap-fill | **Manual copy/paste round-trip** — no network or API keys in the tool (§6). |
| 4 | `~/Library/Containers` | **Scan by default**, with a `--skip-containers` escape hatch (§3). |
| 5 | Size threshold | Default **250 MB** → flag, don't auto-include (§5). |
| 6 | Where the scan lives | **Extend `mac-installed-apps.py`** (shares the bundle-id scan); split to `mac-settings-scan.py` only if it grows unwieldy. |
| 7 | Multi-Mac save | **Append/merge default**, replace optional — per `roadmap.md` (§8). |
| 8 | Scope | Current user's `~` only; no multi-user / `/System` settings. |

Remaining to confirm during build (not blocking): exact dotfile allow-list for the
inverted `~` scan, and the precise machine-bound license deny patterns.

---

## 12. Rollout order (once approved)

1. Add `8 Remove backups` (small, self-contained, immediate value).
2. Add the append/merge vs replace save prompt to option 1 (§8) — protects
   multi-Mac catalogs before any other catalog work.
3. Build Source A scan + new schema; wire settings flow to match on bundle_id.
4. Add deny-list file + size flagging.
5. Add export/import candidate TSV + `verified=no` re-check for LLM rows.
6. Mackup precedence + clean up dead settings-fallback code.
7. Tests for: bundle-id attribution, deny-list filtering, verified-gate on
   restore, and merge (kept/added/updated counts).
