# Roadmap

## Shipped

- **Multi-Mac app catalog saving** (v0.3) — option `1` offers append/merge vs
  replace so saving on a second Mac no longer drops apps that only live on
  other machines.
- **Filesystem settings discovery + bundle-id matching** (v0.5) — settings are
  found by scanning the filesystem keyed by each app's bundle id, plus dotfiles
  and `~/.config`; matching is exact-bundle-id.
- **AI review round-trip** (v0.6), **Mackup deferral** (v0.7), **dead-code
  cleanup** (v0.8), **test suite** (v0.9).
- **AI app category suggestions** — option `1` can press `H` and hand blank app
  rows to either the Codex CLI or Claude CLI, then validate and apply returned
  category keys.

## Possible future work

- **Retire `mac-settings.tsv`** — the scan now reproduces its dotfile rows, so
  the curated overlay could be dropped (per the settings-discovery spec). Keep
  it until you have confirmed a real backup covers those rows.
- **Group Containers** — `~/Library/Group Containers` is not scanned yet (group
  ids are team-prefixed and hard to attribute to an app). Add best-effort
  attribution if shared-container settings matter.
- **Settings AI CLI helper** — the settings review round-trip is still manual
  copy/paste today; it could get the same CLI handoff pattern as app category
  suggestions.
- **Minor UX** — `(run first)` hint on option `1`; tidy the long Google Drive
  labels in "Change backup location".

See `spec-settings-discovery.md` for the full design and the resolved decisions.
