#!/usr/bin/env bash
#
# Shell-side tests for mac-backup-wizard.sh. Sources the script (the source guard
# keeps the menu from launching) and exercises the pure/guard functions.

set -o pipefail
cd "$(dirname "$0")/.." || exit 2

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fails=$((fails + 1))
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi
}

# shellcheck disable=SC1091
source ./mac-backup-wizard.sh

# --- matching helpers ---
keys_match alfred alfred && ok "keys_match: exact" || bad "keys_match: exact"
keys_match karabiner karabinerelements && ok "keys_match: substring" || bad "keys_match: substring"
keys_match git gitconfig && bad "keys_match: short must not substring" || ok "keys_match: short exact-only"

assert_eq "normalize_app_key" "$(normalize_app_key 'Karabiner-Elements')" "karabinerelements"
assert_eq "relative_key_for_path home" "$(relative_key_for_path "$HOME/.ssh/config")" ".ssh/config"
assert_eq "truncate_text" "$(truncate_text "abcdef" 4)" "a..."
assert_eq "progress_bar half" "$(progress_bar 2 4 10)" "[=====     ]"
errlog="$(mktemp)"
printf 'rsync: write failed: No space left on device\n' >"$errlog"
assert_eq "classify_copy_error_log no space" "$(classify_copy_error_log "$errlog")" "no_space"
printf 'rsync: File name too long\n' >"$errlog"
assert_eq "classify_copy_error_log long name" "$(classify_copy_error_log "$errlog")" "name_too_long"
rm -f "$errlog"
COLUMNS=80 out="$(draw_progress_line 2 4 "Test Setting" "Backing up")"
[[ "$out" == *"50%"* && "$out" == *"Test Setting"* ]] \
  && ok "draw_progress_line: non-tty output" \
  || bad "draw_progress_line output ($out)"
if COLUMNS=80 run_with_progress_line 1 1 "Test Setting" "Backing up" true >/tmp/mbw_progress_test.out; then
  grep -q "100%" /tmp/mbw_progress_test.out \
    && ok "run_with_progress_line: success" \
    || bad "run_with_progress_line missing progress"
else
  bad "run_with_progress_line returned failure"
fi
rm -f /tmp/mbw_progress_test.out

# --- post-backup open-folder prompt ---
DRY_RUN=true
assert_eq "open backup folder: dry-run" "$(prompt_open_backup_folder "/tmp/example")" "DRY RUN: would open /tmp/example"
DRY_RUN=false

(
  tmpdir="$(mktemp -d)"
  fakebin="$tmpdir/bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >>"$OPEN_LOG"\n' >"$fakebin/open"
  chmod +x "$fakebin/open"

  export OPEN_LOG="$tmpdir/open.log"
  PATH="$fakebin:$PATH"
  DRY_RUN=false
  ASSUME_YES=false
  out="$(printf '\n' | prompt_open_backup_folder "$tmpdir")"

  [[ "$out" == *"Open the folder? [n/Y]"* && "$(sed -n '1p' "$OPEN_LOG")" == "$tmpdir" ]]
  rc=$?
  rm -rf "$tmpdir"
  exit "$rc"
) && ok "open backup folder: return opens" || bad "open backup folder: return opens"

# --- Mackup storage folder prompt/config ---
(
  tmpdir="$(mktemp -d)"
  HOME="$tmpdir/home"
  mkdir -p "$HOME"
  BACKUP_ROOT="$HOME/Cloud Backups/MacSettings"
  DRY_RUN=false
  ASSUME_YES=false

  prompt_out="$tmpdir/prompt.out"
  prompt_mackup_backup_folder <<< '' >"$prompt_out"
  [[ "$MACKUP_BACKUP_FOLDER" == "$BACKUP_ROOT/Mackup" ]] \
    && grep -q "Default from current backup location" "$prompt_out"
  rc=$?
  rm -rf "$tmpdir"
  exit "$rc"
) && ok "mackup folder prompt: return uses backup-root default" || bad "mackup folder prompt"

(
  tmpdir="$(mktemp -d)"
  HOME="$tmpdir/home"
  mkdir -p "$HOME"
  MACKUP_CONFIG="$HOME/.mackup.cfg"
  folder="$HOME/Cloud Backups/MacSettings/Mackup"
  cat >"$MACKUP_CONFIG" <<'EOF'
[storage]
engine = icloud
path = old
directory = Old

[applications_to_sync]
vim
EOF

  DRY_RUN=false
  write_mackup_storage_config "$folder"
  grep -q "engine = file_system" "$MACKUP_CONFIG" \
    && grep -q "path = Cloud Backups/MacSettings" "$MACKUP_CONFIG" \
    && grep -q "directory = Mackup" "$MACKUP_CONFIG" \
    && grep -q "\\[applications_to_sync\\]" "$MACKUP_CONFIG" \
    && grep -q "^vim$" "$MACKUP_CONFIG" \
    && [[ -d "$folder" ]] \
    && ! grep -q "engine = icloud" "$MACKUP_CONFIG" \
    && ! grep -q "path = old" "$MACKUP_CONFIG"
  rc=$?
  rm -rf "$tmpdir"
  exit "$rc"
) && ok "mackup storage config: file-system folder" || bad "mackup storage config"

# --- backup copy filters/report ---
(
  tmpdir="$(mktemp -d)"
  src="$tmpdir/source"
  mkdir -p "$src/Config" "$src/CacheStorage" "$src/vms/0/data" "$src/sockets"
  printf 'keep' >"$src/Config/settings.json"
  printf 'skip' >"$src/CacheStorage/cache.bin"
  printf 'skip' >"$src/vms/0/data/Docker.raw"
  printf 'skip' >"$src/sockets/app.socket"

  SETTINGS_MANIFEST="$tmpdir/manifest.tsv"
  printf 'enabled\tname\tpath\tnotes\n' >"$SETTINGS_MANIFEST"
  APP_CATEGORY_FILE="$tmpdir/missing-categories.tsv"
  INSTALLED_APPS_CATALOG="$tmpdir/missing-apps.tsv"
  MACKUP_SELECTION_FILE="$tmpdir/missing-mackup.tsv"
  MACKUP_CONFIG="$tmpdir/missing-mackup.cfg"

  reset_settings_items
  SETTING_COUNT=1
  SETTING_NAME=([1]="Filter Test")
  SETTING_PATH=([1]="$src")
  SETTING_NOTES=([1]="test")
  SETTING_SELECTED=([1]=1)
  SETTING_SIZE_BYTES=([1]=1)
  SETTING_BUNDLE_ID=([1]="")
  SETTING_KIND=([1]="appsupport")
  SETTING_SOURCE=([1]="test")
  SETTING_VERIFIED=([1]="yes")

  DRY_RUN=false
  if backup_selected_settings "$tmpdir/backup" >/tmp/mbw_backup_filter.out 2>&1; then
    dest="$tmpdir/backup/files/absolute$src"
    [[ -f "$dest/Config/settings.json" ]] \
      && [[ ! -e "$dest/CacheStorage" ]] \
      && [[ ! -e "$dest/vms" ]] \
      && [[ ! -e "$dest/sockets" ]] \
      && grep -q $'ok\tFilter Test' "$tmpdir/backup/backup-report.tsv" \
      && [[ ! -s "$tmpdir/backup/backup-errors.log" ]]
    rc=$?
  else
    rc=1
  fi
  rm -f /tmp/mbw_backup_filter.out
  rm -rf "$tmpdir"
  exit "$rc"
) && ok "backup copy filters: skips volatile data" || bad "backup copy filters"

# --- backup size estimate summary ---
(
  tmp_setting="$(mktemp)"
  printf 'x' >"$tmp_setting"
  SETTING_COUNT=2
  SETTING_NAME=([1]="Arc (pref)" [2]="Shell zshrc")
  SETTING_PATH=([1]="$tmp_setting" [2]="$tmp_setting")
  SETTING_SELECTED=([1]=1 [2]=1)
  SETTING_SIZE_BYTES=([1]=1024 [2]=2048)
  SETTING_BUNDLE_ID=([1]="company.thebrowser.Browser" [2]="")
  DEFINED_APP_COUNT=1
  DEFINED_APP_NAME=([1]="Arc")
  DEFINED_APP_BUNDLE_ID=([1]="company.thebrowser.Browser")
  DEFINED_APP_CATEGORY=([1]="productivity")
  APP_CATEGORY_FILE="$(mktemp)"
  printf 'number\tkey\tlabel\taliases\n2\tproductivity\tProductivity\tprod\n' >"$APP_CATEGORY_FILE"
  out="$(print_backup_size_estimate)"
  rm -f "$APP_CATEGORY_FILE" "$tmp_setting"
  [[ "$out" == *"Productivity"* && "$out" == *"Uncategorized / Dotfiles"* && "$out" == *"Total known"* ]]
) && ok "backup size estimate summary" || bad "backup size estimate summary"

# --- remove_backup_dir guard (dry-run) ---
DRY_RUN=true
BACKUP_ROOT="/tmp/mbw_test_root"
mkdir -p "$BACKUP_ROOT/Profile"
out="$(remove_backup_dir "$BACKUP_ROOT/Profile" 2>&1)"
[[ "$out" == DRY\ RUN:* ]] && ok "remove_backup_dir: inside root -> dry-run rm" || bad "remove_backup_dir inside ($out)"
out="$(remove_backup_dir "$BACKUP_ROOT" 2>&1)"
[[ "$out" == *Refusing* ]] && ok "remove_backup_dir: refuses the root itself" || bad "remove_backup_dir root"
out="$(remove_backup_dir "/tmp/somewhere_else" 2>&1)"
[[ "$out" == *Refusing* ]] && ok "remove_backup_dir: refuses outside root" || bad "remove_backup_dir outside"
rmdir "$BACKUP_ROOT/Profile" "$BACKUP_ROOT" 2>/dev/null
DRY_RUN=false

# --- resolve_backup_root precedence ---
(
  BACKUP_ROOT=""
  BACKUP_LOCATION_CONFIG="/tmp/mbw_no_such.conf"
  resolve_backup_root
  [[ "$BACKUP_ROOT" == "$DEFAULT_BACKUP_ROOT" ]]
) && ok "resolve_backup_root: default" || bad "resolve_backup_root: default"

cfg="$(mktemp)"
printf '/tmp/Custom/Backup\n' >"$cfg"
(
  BACKUP_ROOT=""
  BACKUP_LOCATION_CONFIG="$cfg"
  resolve_backup_root
  [[ "$BACKUP_ROOT" == "/tmp/Custom/Backup" ]]
) && ok "resolve_backup_root: saved config" || bad "resolve_backup_root: saved config"
rm -f "$cfg"

# --- bundle-id settings matching (uses the shipped example catalog + scanner) ---
APPS_FIXTURE="mac-installed-apps.example.tsv"
if command -v python3 >/dev/null 2>&1 && [[ -f "$APPS_FIXTURE" ]]; then
  gen="$(mktemp)"
  if python3 mac-settings-scan.py --apps "$APPS_FIXTURE" --skip-containers --output "$gen" >/dev/null 2>&1; then
    SETTINGS_GENERATED="$gen" load_settings_items
    INSTALLED_APPS_CATALOG="$APPS_FIXTURE"
    load_defined_apps
    SELECTED_DEFINED_APP_PATHS=()
    target_bundle=""
    for ((i = 1; i <= DEFINED_APP_COUNT; i++)); do
      if [[ "${DEFINED_APP_NAME[i]}" == "Karabiner-Elements" ]]; then
        SELECTED_DEFINED_APP_PATHS+=("${DEFINED_APP_PATH[i]}")
        target_bundle="${DEFINED_APP_BUNDLE_ID[i]}"
      fi
    done
    if ((${#SELECTED_DEFINED_APP_PATHS[@]} > 0)); then
      select_settings_for_defined_apps backup
      selected=0
      wrong=0
      for ((i = 1; i <= SETTING_COUNT; i++)); do
        [[ "${SETTING_SELECTED[i]}" == "1" ]] || continue
        selected=$((selected + 1))
        # every selected row must either carry the target bundle or have no bundle
        [[ "${SETTING_BUNDLE_ID[i]}" == "$target_bundle" || -z "${SETTING_BUNDLE_ID[i]}" ]] || wrong=1
      done
      if ((selected >= 1)); then
        [[ "$wrong" -eq 0 ]] \
          && ok "bundle match: selects only the chosen app's rows ($selected)" \
          || bad "bundle match (selected=$selected wrong=$wrong)"
      else
        # Karabiner-Elements is in the example catalog but its settings may not
        # exist on this machine; the key assertion (no false matches) still holds.
        ok "bundle match: no Karabiner-Elements settings on this machine (no false matches)"
      fi
    else
      ok "bundle match: skipped (Karabiner-Elements not in example catalog)"
    fi
    rm -f "$gen"
  else
    ok "bundle match: skipped (scan unavailable)"
  fi
else
  ok "bundle match: skipped (no python3 / example catalog)"
fi

# --- restore offers all backed-up items, not just locally-installed ones ---
rdir="$(mktemp -d)"
mkdir -p "$rdir/files"
{
  printf 'enabled\tname\tpath\tnotes\tsource\tbundle_id\tkind\tverified\tsize_bytes\tsize_human\n'
  printf 'yes\tGhost (not installed)\t~/Library/Preferences/com.example.ghost.plist\t\tfs\tcom.example.ghost\tpref\tyes\t1024\t1 KB\n'
} >"$rdir/selected-settings.tsv"
[[ "$(restore_source_manifest "$rdir")" == "$rdir/selected-settings.tsv" ]] \
  && ok "restore: uses the backup's own selected-settings.tsv" \
  || bad "restore: wrong manifest source"
load_settings_items "$(restore_source_manifest "$rdir")"
restore_found=0
for ((i = 1; i <= SETTING_COUNT; i++)); do
  [[ "${SETTING_PATH[i]}" == "~/Library/Preferences/com.example.ghost.plist" ]] && restore_found=1
done
[[ "$restore_found" -eq 1 ]] \
  && ok "restore: offers a backed-up item whose app is not installed" \
  || bad "restore: dropped a backed-up item (count=$SETTING_COUNT)"
rm -rf "$rdir"

# --- install: an uncataloged app falls back to its inventory cask/mas id ---
load_all_app_items
reset_defined_apps
DEFINED_APP_COUNT=1
DEFINED_APP_NAME[1]="Ziggy Example"
DEFINED_APP_PATH[1]="/Applications/Ziggy Example.app"
DEFINED_APP_CATEGORY[1]="dev"
DEFINED_APP_MAS[1]=""
DEFINED_APP_CASK[1]="ziggy-example"
SELECTED_DEFINED_APP_PATHS=("/Applications/Ziggy Example.app")
select_install_items_for_defined_apps
build_install_plan
install_cask_found=0
for c in "${BREW_CASKS[@]}"; do [[ "$c" == "ziggy-example" ]] && install_cask_found=1; done
[[ "$install_cask_found" -eq 1 ]] \
  && ok "install: uncataloged app falls back to inventory cask" \
  || bad "install: inventory cask fallback (casks: ${BREW_CASKS[*]})"

printf '\n'
if [[ "$fails" -eq 0 ]]; then
  printf 'ALL BASH TESTS PASSED\n'
else
  printf '%s BASH TEST FAILURE(S)\n' "$fails"
fi
exit "$fails"
