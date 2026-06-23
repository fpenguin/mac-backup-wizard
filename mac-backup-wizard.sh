#!/usr/bin/env bash
#
# Mac Backup Wizard — OpenBoot-style setup/backup wizard.
# Version: 1.4

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_CATALOG="${APP_CATALOG:-$SCRIPT_DIR/mac-apps.tsv}"
SETTINGS_MANIFEST="${SETTINGS_MANIFEST:-$SCRIPT_DIR/mac-settings.tsv}"
SETTINGS_GENERATED="${SETTINGS_GENERATED:-$SCRIPT_DIR/mac-settings.generated.tsv}"
SETTINGS_REVIEWED="${SETTINGS_REVIEWED:-$SCRIPT_DIR/mac-settings.reviewed.tsv}"
SETTINGS_CANDIDATES="${SETTINGS_CANDIDATES:-$SCRIPT_DIR/mac-settings.candidates.tsv}"
INSTALLED_APPS_CATALOG="${INSTALLED_APPS_CATALOG:-$SCRIPT_DIR/mac-installed-apps.tsv}"
# Your real inventory (mac-installed-apps.tsv) is git-ignored; the repo ships a
# sanitized mac-installed-apps.example.tsv. Option 1 always writes the real file
# (INSTALLED_APPS_REAL); read-only flows fall back to the example via
# resolve_installed_apps_paths (called from main).
INSTALLED_APPS_EXAMPLE="${INSTALLED_APPS_EXAMPLE:-$SCRIPT_DIR/mac-installed-apps.example.tsv}"
INSTALLED_APPS_REAL="$INSTALLED_APPS_CATALOG"
APP_CATEGORY_FILE="${APP_CATEGORY_FILE:-$SCRIPT_DIR/mac-app-categories.tsv}"
MACKUP_SELECTION_FILE="${MACKUP_SELECTION_FILE:-$SCRIPT_DIR/mac-mackup-apps.tsv}"
MACKUP_CONFIG="${MACKUP_CONFIG:-$HOME/.mackup.cfg}"
DEFAULT_BACKUP_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backup/MacSettings"
BACKUP_LOCATION_CONFIG="${BACKUP_LOCATION_CONFIG:-$SCRIPT_DIR/mac-backup-location.conf}"
# Backup root precedence (finalised in main via resolve_backup_root):
# --root flag > BACKUP_ROOT/ICLOUD_ROOT env > saved location config > iCloud default.
BACKUP_ROOT="${BACKUP_ROOT:-${ICLOUD_ROOT:-}}"
PROFILE_NAME="${PROFILE_NAME:-$(hostname -s 2>/dev/null || hostname)}"

DRY_RUN=false
ASSUME_YES=false
INCLUDE_SYSTEM_APPS=false
SCAN_SKIP_CONTAINERS=false

COLOR_RESET=""
COLOR_GREEN=""
COLOR_DIM=""
COLOR_BOLD=""
PROGRESS_FAILURE_LOG=""
PROGRESS_LAST_ERROR_CLASS=""

BACKUP_RSYNC_EXCLUDES=(
  ".DS_Store"
  "._*"
  "Cache/"
  "Caches/"
  "cache/"
  "CacheStorage/"
  "Code Cache/"
  "GPUCache/"
  "ShaderCache/"
  "Media Cache/"
  "WebsiteData/"
  "Crashpad/"
  "Crash Reports/"
  "Service Worker/ScriptCache/"
  "Service Worker/CacheStorage/"
  "blob_storage/"
  "sentry/"
  "logs/"
  "Logs/"
  "sockets/"
  "*.sock"
  "*.socket"
  "*.lockfile"
  "*.raw"
  "*.qcow2"
  "*.vmdk"
  "*.iso"
  "vms/"
)

ITEM_COUNT=0
ITEM_KEY=()
ITEM_METHOD=()
ITEM_IDENTIFIER=()
ITEM_NAME=()
ITEM_URL=()
ITEM_NOTES=()
ITEM_CATEGORIES=()
ITEM_SELECTED=()

BREW_CASKS=()
BREW_FORMULAE=()
MAS_APPS=()
MANUAL_APPS=()
MACKUP_SELECTED_APPS=()
MACKUP_BACKUP_FOLDER=""
DEFINED_APP_COUNT=0
DEFINED_APP_NAME=()
DEFINED_APP_BUNDLE_ID=()
DEFINED_APP_PATH=()
DEFINED_APP_CATEGORY=()
DEFINED_APP_MAS=()
DEFINED_APP_CASK=()
SELECTED_DEFINED_APP_PATHS=()
UNMATCHED_DEFINED_APPS=()

SETTING_COUNT=0
SETTING_NAME=()
SETTING_PATH=()
SETTING_NOTES=()
SETTING_SELECTED=()
SETTING_SIZE_BYTES=()

usage() {
  cat <<'EOF'
Mac OpenBoot-Style Setup Wizard

Usage:
  ./mac-backup-wizard.sh [options]

Options:
  --app-catalog path        App TSV catalog. Defaults to mac-apps.tsv beside this script.
  --settings-manifest path  Settings TSV manifest. Defaults to mac-settings.tsv beside this script.
  --installed-apps path     Installed-app backup TSV. Defaults to mac-installed-apps.tsv beside this script.
  --app-categories path     App category TSV. Defaults to mac-app-categories.tsv beside this script.
  --mackup-apps path        Remembered Mackup defined-app selection. Defaults to mac-mackup-apps.tsv.
  --mackup-config path      Mackup config path. Defaults to ~/.mackup.cfg.
  --root path               Settings backup root (any cloud or local folder).
  --profile name            Default backup/restore profile name.
  --dry-run                 Preview commands without changing anything.
  --yes                     Skip final destructive/action confirmations.
  --include-system-apps     Include /System/Applications in the installed-app definition screen.
  --skip-containers         Skip ~/Library/Containers when scanning for settings.
  -h, --help                Show this help.
EOF
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_selection() {
  local value="$1"
  value="$(lowercase "$value")"
  value="${value//,/ }"
  value="${value//;/ }"
  printf '%s' "$value"
}

contains() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done

  return 1
}

run_or_print() {
  if $DRY_RUN; then
    printf 'DRY RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

init_colors() {
  if [[ -t 1 ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_GREEN=$'\033[32m'
    COLOR_DIM=$'\033[2m'
    COLOR_BOLD=$'\033[1m'
  fi
}

clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  else
    printf '\n'
  fi
}

terminal_width() {
  local cols
  cols="${COLUMNS:-}"
  if [[ ! "$cols" =~ ^[0-9]+$ ]] || ((cols < 40)); then
    cols="$(tput cols 2>/dev/null || printf '80')"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  ((cols < 40)) && cols=40
  printf '%s' "$cols"
}

truncate_text() {
  local text="$1"
  local max="$2"
  if (( ${#text} <= max )); then
    printf '%s' "$text"
  elif (( max <= 3 )); then
    printf '%s' "${text:0:max}"
  else
    printf '%s...' "${text:0:max-3}"
  fi
}

progress_bar() {
  local current="$1"
  local total="$2"
  local width="$3"
  local filled=0
  local empty=0

  ((total > 0)) && filled=$((current * width / total))
  ((filled > width)) && filled="$width"
  empty=$((width - filled))

  printf '['
  printf '%*s' "$filled" '' | tr ' ' '='
  printf '%*s' "$empty" ''
  printf ']'
}

draw_progress_line() {
  local current="$1"
  local total="$2"
  local label="$3"
  local action="${4:-Backing up}"
  local frame="${5:-}"
  local cols bar_width percent available label_width line
  local spinner=""
  local frames=("-" "\\" "|" "/")

  ((total > 0)) || total=1
  percent=$((current * 100 / total))
  if [[ -n "$frame" ]]; then
    spinner=" ${frames[$((frame % 4))]}"
  fi
  cols="$(terminal_width)"
  bar_width=24
  ((cols < 80)) && bar_width=16
  available=$((cols - bar_width - 24))
  ((available < 10)) && available=10
  label_width="$available"
  line="$(printf '%s%s %3d/%-3d %3d%% %s %s' \
    "$action" \
    "$spinner" \
    "$current" \
    "$total" \
    "$percent" \
    "$(progress_bar "$current" "$total" "$bar_width")" \
    "$(truncate_text "$label" "$label_width")")"

  if [[ -t 1 ]]; then
    printf '\r%-*s' "$cols" "$line"
  else
    printf '%s\n' "$line"
  fi
}

finish_progress_line() {
  [[ -t 1 ]] && printf '\n'
}

human_size_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" '
    function fmt(value, unit) {
      if (unit == "B" || unit == "KB") {
        return sprintf("%.0f %s", value, unit)
      }
      return sprintf("%.1f %s", value, unit)
    }
    BEGIN {
      value = bytes + 0
      split("B KB MB GB TB", units, " ")
      for (i = 1; i < 5 && value >= 1024; i++) {
        value = value / 1024
      }
      print fmt(value, units[i])
    }
  '
}

file_size_bytes() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path" 2>/dev/null
}

classify_copy_error_log() {
  local log="$1"

  if grep -qi "No space left on device" "$log"; then
    printf 'no_space'
  elif grep -qi "File name too long" "$log"; then
    printf 'name_too_long'
  elif grep -Eqi "Permission denied|Operation not permitted" "$log"; then
    printf 'permission'
  elif grep -Eqi "Operation not supported|Invalid argument|mkstempsock" "$log"; then
    printf 'unsupported'
  else
    printf 'copy_error'
  fi
}

copy_error_label() {
  case "$1" in
    no_space) printf 'destination has no free space' ;;
    name_too_long) printf 'path/name too long' ;;
    permission) printf 'permission denied' ;;
    unsupported) printf 'unsupported file type or metadata' ;;
    *) printf 'copy failed' ;;
  esac
}

run_with_progress_line() {
  local current="$1"
  local total="$2"
  local label="$3"
  local action="$4"
  shift 4
  local pid rc log frame=0

  PROGRESS_LAST_ERROR_CLASS=""

  if $DRY_RUN; then
    draw_progress_line "$current" "$total" "$label" "$action"
    run_or_print "$@"
    return $?
  fi

  if [[ ! -t 1 ]]; then
    log="$(mktemp)"
    draw_progress_line "$current" "$total" "$label" "$action"
    "$@" >"$log" 2>&1
    rc=$?
    if ((rc != 0)); then
      PROGRESS_LAST_ERROR_CLASS="$(classify_copy_error_log "$log")"
      printf '[ERROR] %s failed for %s (%s)\n' "$action" "$label" "$(copy_error_label "$PROGRESS_LAST_ERROR_CLASS")"
      sed -n '1,20p' "$log"
      if [[ -n "$PROGRESS_FAILURE_LOG" ]]; then
        {
          printf '\n[%s] %s failed for %s (exit %s, %s)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$action" \
            "$label" \
            "$rc" \
            "$(copy_error_label "$PROGRESS_LAST_ERROR_CLASS")"
          cat "$log"
        } >>"$PROGRESS_FAILURE_LOG"
        printf 'Full error log: %s\n' "$PROGRESS_FAILURE_LOG"
      fi
    fi
    rm -f "$log"
    return "$rc"
  fi

  log="$(mktemp)"
  "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    draw_progress_line "$current" "$total" "$label" "$action" "$frame"
    frame=$((frame + 1))
    sleep 0.15
  done
  wait "$pid"
  rc=$?
  draw_progress_line "$current" "$total" "$label" "$action" "$frame"

  if ((rc != 0)); then
    PROGRESS_LAST_ERROR_CLASS="$(classify_copy_error_log "$log")"
    finish_progress_line
    printf '[ERROR] %s failed for %s (%s)\n' "$action" "$label" "$(copy_error_label "$PROGRESS_LAST_ERROR_CLASS")"
    sed -n '1,20p' "$log"
    if [[ -n "$PROGRESS_FAILURE_LOG" ]]; then
      {
        printf '\n[%s] %s failed for %s (exit %s, %s)\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" \
          "$action" \
          "$label" \
          "$rc" \
          "$(copy_error_label "$PROGRESS_LAST_ERROR_CLASS")"
        cat "$log"
      } >>"$PROGRESS_FAILURE_LOG"
      printf 'Full error log: %s\n' "$PROGRESS_FAILURE_LOG"
    fi
  fi

  rm -f "$log"
  return "$rc"
}

confirm() {
  local prompt="$1"
  local answer

  $DRY_RUN && return 0
  $ASSUME_YES && return 0

  printf '\n%s [y/N]: ' "$prompt"
  IFS= read -r answer
  answer="$(lowercase "$answer")"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

prompt_open_backup_folder() {
  local dir="$1"
  local answer

  if $DRY_RUN; then
    printf 'DRY RUN: would open %s\n' "$dir"
    return 0
  fi

  if ! $ASSUME_YES; then
    printf '\nOpen the folder? [n/Y] '
    IFS= read -r answer
    answer="$(lowercase "$(trim_spaces "$answer")")"
    [[ -z "$answer" || "$answer" == "y" || "$answer" == "yes" ]] || return 0
  fi

  if command -v open >/dev/null 2>&1; then
    command open "$dir" >/dev/null 2>&1 || printf 'Could not open folder: %s\n' "$dir"
  else
    printf 'open command not found. Backup folder: %s\n' "$dir"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --app-catalog)
        APP_CATALOG="$2"
        shift
        ;;
      --app-catalog=*)
        APP_CATALOG="${1#--app-catalog=}"
        ;;
      --settings-manifest)
        SETTINGS_MANIFEST="$2"
        shift
        ;;
      --settings-manifest=*)
        SETTINGS_MANIFEST="${1#--settings-manifest=}"
        ;;
      --installed-apps)
        INSTALLED_APPS_CATALOG="$2"
        shift
        ;;
      --installed-apps=*)
        INSTALLED_APPS_CATALOG="${1#--installed-apps=}"
        ;;
      --app-categories)
        APP_CATEGORY_FILE="$2"
        shift
        ;;
      --app-categories=*)
        APP_CATEGORY_FILE="${1#--app-categories=}"
        ;;
      --mackup-apps)
        MACKUP_SELECTION_FILE="$2"
        shift
        ;;
      --mackup-apps=*)
        MACKUP_SELECTION_FILE="${1#--mackup-apps=}"
        ;;
      --mackup-config)
        MACKUP_CONFIG="$2"
        shift
        ;;
      --mackup-config=*)
        MACKUP_CONFIG="${1#--mackup-config=}"
        ;;
      --root)
        BACKUP_ROOT="$2"
        shift
        ;;
      --root=*)
        BACKUP_ROOT="${1#--root=}"
        ;;
      --profile)
        PROFILE_NAME="$2"
        shift
        ;;
      --profile=*)
        PROFILE_NAME="${1#--profile=}"
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      --yes|-y)
        ASSUME_YES=true
        ;;
      --include-system-apps)
        INCLUDE_SYSTEM_APPS=true
        ;;
      --skip-containers)
        SCAN_SKIP_CONTAINERS=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

require_file() {
  local path="$1"
  local label="$2"

  if [[ ! -f "$path" ]]; then
    printf '%s not found: %s\n' "$label" "$path" >&2
    exit 1
  fi
}

header() {
  printf '\n'
  printf '========================================\n'
  printf '%s\n' "$1"
  printf '========================================\n'
}

enabled_row() {
  local value
  value="$(lowercase "$(trim_spaces "$1")")"

  case "$value" in
    yes|y|true|1|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

print_wrapped_names() {
  local indent="$1"
  shift

  local line="$indent"
  local separator=""
  local entry

  if (($# == 0)); then
    printf '%snone\n' "$indent"
    return
  fi

  for entry in "$@"; do
    if ((${#line} + ${#separator} + ${#entry} > 100)); then
      printf '%s\n' "$line"
      line="$indent$entry"
      separator=", "
    else
      line="${line}${separator}${entry}"
      separator=", "
    fi
  done

  printf '%s\n' "$line"
}

normalize_app_key() {
  lowercase "$1" | tr -cd '[:alnum:]'
}

keys_match() {
  local left="$1"
  local right="$2"

  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "$left" == "$right" ]] && return 0

  if ((${#left} >= 4 && ${#right} >= 4)); then
    [[ "$left" == *"$right"* || "$right" == *"$left"* ]] && return 0
  fi

  return 1
}

reset_defined_apps() {
  DEFINED_APP_COUNT=0
  DEFINED_APP_NAME=()
  DEFINED_APP_BUNDLE_ID=()
  DEFINED_APP_PATH=()
  DEFINED_APP_CATEGORY=()
  SELECTED_DEFINED_APP_PATHS=()
  UNMATCHED_DEFINED_APPS=()
}

load_defined_apps() {
  local name bundle_id path size_bytes size_human finder_tags last_updated category mas_id cask
  local line_number=0

  reset_defined_apps

  while IFS=$'\t' read -r name bundle_id path size_bytes size_human finder_tags last_updated category mas_id cask || [[ -n "$name" ]]; do
    line_number=$((line_number + 1))
    [[ "$line_number" -eq 1 && "$name" == "name" ]] && continue
    [[ -z "$name" || -z "$path" ]] && continue

    DEFINED_APP_COUNT=$((DEFINED_APP_COUNT + 1))
    DEFINED_APP_NAME[DEFINED_APP_COUNT]="$(trim_spaces "$name")"
    DEFINED_APP_BUNDLE_ID[DEFINED_APP_COUNT]="$(trim_spaces "$bundle_id")"
    DEFINED_APP_PATH[DEFINED_APP_COUNT]="$(trim_spaces "$path")"
    DEFINED_APP_CATEGORY[DEFINED_APP_COUNT]="$(trim_spaces "$category")"
    DEFINED_APP_MAS[DEFINED_APP_COUNT]="$(trim_spaces "$mas_id")"
    DEFINED_APP_CASK[DEFINED_APP_COUNT]="$(trim_spaces "$cask")"
  done <"$INSTALLED_APPS_CATALOG"
}

app_category_label_for_key() {
  local key="$1"
  local number row_key label aliases

  [[ -n "$key" && "$key" != "uncategorized" ]] || {
    printf 'Uncategorized / Dotfiles'
    return 0
  }

  if [[ -f "$APP_CATEGORY_FILE" ]]; then
    while IFS=$'\t' read -r number row_key label aliases || [[ -n "$number" ]]; do
      [[ "$number" == "number" ]] && continue
      if [[ "$(trim_spaces "$row_key")" == "$key" ]]; then
        label="$(trim_spaces "$label")"
        printf '%s' "${label:-$key}"
        return 0
      fi
    done <"$APP_CATEGORY_FILE"
  fi

  printf '%s' "$key"
}

setting_category_key() {
  local index="$1"
  local app_index app_key setting_key

  if ((DEFINED_APP_COUNT == 0)) && [[ -f "$INSTALLED_APPS_CATALOG" ]]; then
    load_defined_apps
  fi

  if [[ -n "${SETTING_BUNDLE_ID[index]}" ]]; then
    for ((app_index = 1; app_index <= DEFINED_APP_COUNT; app_index++)); do
      if [[ "${DEFINED_APP_BUNDLE_ID[app_index]}" == "${SETTING_BUNDLE_ID[index]}" ]]; then
        printf '%s' "${DEFINED_APP_CATEGORY[app_index]}"
        return 0
      fi
    done
  fi

  setting_key="$(normalize_app_key "${SETTING_NAME[index]}")"
  for ((app_index = 1; app_index <= DEFINED_APP_COUNT; app_index++)); do
    app_key="$(normalize_app_key "${DEFINED_APP_NAME[app_index]}")"
    if keys_match "$setting_key" "$app_key"; then
      printf '%s' "${DEFINED_APP_CATEGORY[app_index]}"
      return 0
    fi
  done

  printf 'uncategorized'
}

defined_app_index_for_path() {
  local path="$1"
  local index

  for ((index = 1; index <= DEFINED_APP_COUNT; index++)); do
    [[ "${DEFINED_APP_PATH[index]}" == "$path" ]] && {
      printf '%s' "$index"
      return 0
    }
  done

  return 1
}

defined_app_name_for_path() {
  local path="$1"
  local index

  if index="$(defined_app_index_for_path "$path")"; then
    printf '%s' "${DEFINED_APP_NAME[index]}"
    return 0
  fi

  printf '%s' "$path"
}

defined_app_cask_for_path() {
  local index
  index="$(defined_app_index_for_path "$1")" && printf '%s' "${DEFINED_APP_CASK[index]}"
}

defined_app_mas_for_path() {
  local index
  index="$(defined_app_index_for_path "$1")" && printf '%s' "${DEFINED_APP_MAS[index]}"
}

choose_defined_apps() {
  local title="$1"
  local default_category="${2:-}"
  local initial_file="${3:-}"
  local remember_file="${4:-}"
  local picker="$SCRIPT_DIR/mac-defined-app-picker.py"
  local tmp
  local selected_path
  local args=()

  SELECTED_DEFINED_APP_PATHS=()

  if [[ ! -f "$INSTALLED_APPS_CATALOG" ]]; then
    printf 'Defined app catalog not found: %s\n' "$INSTALLED_APPS_CATALOG"
    printf 'Run option 1 first to define app categories.\n'
    return 1
  fi

  if [[ ! -f "$APP_CATEGORY_FILE" ]]; then
    printf 'App category file not found: %s\n' "$APP_CATEGORY_FILE"
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'Python 3 is required for the defined-app picker.\n'
    return 1
  fi

  if [[ ! -f "$picker" ]]; then
    printf 'Defined-app picker not found: %s\n' "$picker"
    return 1
  fi

  [[ -t 0 && -t 1 ]] || {
    printf 'The defined-app picker needs an interactive terminal.\n'
    return 1
  }

  load_defined_apps
  if ((DEFINED_APP_COUNT == 0)); then
    printf 'No apps found in %s. Run option 1 first.\n' "$INSTALLED_APPS_CATALOG"
    return 1
  fi

  tmp="$(mktemp)"
  args=(
    "$picker"
    --apps "$INSTALLED_APPS_CATALOG"
    --categories "$APP_CATEGORY_FILE"
    --output "$tmp"
    --title "$title"
  )
  [[ -n "$default_category" ]] && args+=(--default-category "$default_category")
  [[ -n "$initial_file" && -f "$initial_file" ]] && args+=(--initial-file "$initial_file")

  if ! python3 "${args[@]}"; then
    rm -f "$tmp"
    return 1
  fi

  while IFS= read -r selected_path; do
    selected_path="$(trim_spaces "$selected_path")"
    [[ -n "$selected_path" ]] && SELECTED_DEFINED_APP_PATHS+=("$selected_path")
  done <"$tmp"

  if [[ -n "$remember_file" && "$DRY_RUN" == "false" ]]; then
    mkdir -p "$(dirname "$remember_file")"
    cp "$tmp" "$remember_file"
  fi

  rm -f "$tmp"
  ((${#SELECTED_DEFINED_APP_PATHS[@]} > 0))
}

add_unmatched_defined_app() {
  local name="$1"
  contains "$name" "${UNMATCHED_DEFINED_APPS[@]}" || UNMATCHED_DEFINED_APPS+=("$name")
}

print_unmatched_defined_apps() {
  ((${#UNMATCHED_DEFINED_APPS[@]} == 0)) && return 0

  printf '\nSelected apps without a match for this action:\n'
  print_wrapped_names "  " "${UNMATCHED_DEFINED_APPS[@]}"
}

reset_app_items() {
  ITEM_COUNT=0
  ITEM_KEY=()
  ITEM_METHOD=()
  ITEM_IDENTIFIER=()
  ITEM_NAME=()
  ITEM_URL=()
  ITEM_NOTES=()
  ITEM_CATEGORIES=()
  ITEM_SELECTED=()
}

add_app_item() {
  local categories="$1"
  local method="$2"
  local identifier="$3"
  local name="$4"
  local url="$5"
  local notes="$6"
  local key
  local index

  if [[ -n "$identifier" && "$identifier" != "-" ]]; then
    key="${method}|${identifier}"
  else
    key="${method}|${name}"
  fi

  for ((index = 1; index <= ITEM_COUNT; index++)); do
    [[ "${ITEM_KEY[index]}" == "$key" ]] && return 0
  done

  ITEM_COUNT=$((ITEM_COUNT + 1))
  ITEM_KEY[ITEM_COUNT]="$key"
  ITEM_METHOD[ITEM_COUNT]="$method"
  ITEM_IDENTIFIER[ITEM_COUNT]="$identifier"
  ITEM_NAME[ITEM_COUNT]="$name"
  ITEM_URL[ITEM_COUNT]="$url"
  ITEM_NOTES[ITEM_COUNT]="$notes"
  ITEM_CATEGORIES[ITEM_COUNT]="$categories"
  ITEM_SELECTED[ITEM_COUNT]=1
}

load_all_app_items() {
  local enabled categories method identifier name url notes
  local line_number=0

  reset_app_items

  while IFS=$'\t' read -r enabled categories method identifier name url notes || [[ -n "$enabled" ]]; do
    line_number=$((line_number + 1))
    [[ "$line_number" -eq 1 && "$enabled" == "enabled" ]] && continue
    [[ -z "$enabled" || "$enabled" == \#* ]] && continue
    enabled_row "$enabled" || continue

    categories="$(trim_spaces "$categories")"
    method="$(lowercase "$(trim_spaces "$method")")"
    identifier="$(trim_spaces "$identifier")"
    name="$(trim_spaces "$name")"
    url="$(trim_spaces "$url")"
    notes="$(trim_spaces "$notes")"
    [[ "$url" == "-" ]] && url=""
    [[ "$notes" == "-" ]] && notes=""

    add_app_item "$categories" "$method" "$identifier" "$name" "$url" "$notes"
  done <"$APP_CATALOG"
}

selected_app_count() {
  local count=0
  local index

  for ((index = 1; index <= ITEM_COUNT; index++)); do
    [[ "${ITEM_SELECTED[index]}" == "1" ]] && count=$((count + 1))
  done

  printf '%s' "$count"
}

select_no_apps() {
  local index

  for ((index = 1; index <= ITEM_COUNT; index++)); do
    ITEM_SELECTED[index]=0
  done
}

reset_install_plan() {
  BREW_CASKS=()
  BREW_FORMULAE=()
  MAS_APPS=()
  MANUAL_APPS=()
  UNMATCHED_DEFINED_APPS=()
}

add_brew_cask() {
  local cask="$1"
  contains "$cask" "${BREW_CASKS[@]}" || BREW_CASKS+=("$cask")
}

add_brew_formula() {
  local formula="$1"
  contains "$formula" "${BREW_FORMULAE[@]}" || BREW_FORMULAE+=("$formula")
}

add_mas() {
  local app_id="$1"
  local app_name="$2"
  local entry="${app_id}|${app_name}"
  local existing

  for existing in "${MAS_APPS[@]}"; do
    [[ "$existing" == "${app_id}|"* ]] && return 0
  done

  MAS_APPS+=("$entry")
}

add_manual() {
  local app_name="$1"
  local url="$2"
  local note="$3"
  local entry="${app_name}|${url}|${note}"
  local existing

  for existing in "${MANUAL_APPS[@]}"; do
    [[ "$existing" == "${app_name}|"* ]] && return 0
  done

  MANUAL_APPS+=("$entry")
}

# Append an install item resolved from the inventory (cask/mas columns) for an
# app that has no curated catalog entry, and mark it selected so it joins the plan.
add_synthetic_install_item() {
  local method="$1" identifier="$2" name="$3"
  local key="${method}|${identifier}"
  local index

  for ((index = 1; index <= ITEM_COUNT; index++)); do
    [[ "${ITEM_KEY[index]}" == "$key" ]] && { ITEM_SELECTED[index]=1; return 0; }
  done

  ITEM_COUNT=$((ITEM_COUNT + 1))
  ITEM_KEY[ITEM_COUNT]="$key"
  ITEM_METHOD[ITEM_COUNT]="$method"
  ITEM_IDENTIFIER[ITEM_COUNT]="$identifier"
  ITEM_NAME[ITEM_COUNT]="$name"
  ITEM_URL[ITEM_COUNT]=""
  ITEM_NOTES[ITEM_COUNT]="from inventory"
  ITEM_CATEGORIES[ITEM_COUNT]=""
  ITEM_SELECTED[ITEM_COUNT]=1
}

build_install_plan() {
  local index method identifier name url notes

  reset_install_plan

  for ((index = 1; index <= ITEM_COUNT; index++)); do
    [[ "${ITEM_SELECTED[index]}" == "1" ]] || continue

    method="${ITEM_METHOD[index]}"
    identifier="${ITEM_IDENTIFIER[index]}"
    name="${ITEM_NAME[index]}"
    url="${ITEM_URL[index]}"
    notes="${ITEM_NOTES[index]}"

    case "$method" in
      brew_cask) add_brew_cask "$identifier" ;;
      brew_formula) add_brew_formula "$identifier" ;;
      mas) add_mas "$identifier" "$name" ;;
      manual) add_manual "$name" "$url" "$notes" ;;
      *) printf 'Skipping %s: unknown method %s\n' "$name" "$method" ;;
    esac
  done
}

select_install_items_for_defined_apps() {
  local selected_path app_name app_key
  local index item_name_key item_identifier_key matched

  select_no_apps
  UNMATCHED_DEFINED_APPS=()

  for selected_path in "${SELECTED_DEFINED_APP_PATHS[@]}"; do
    app_name="$(defined_app_name_for_path "$selected_path")"
    app_key="$(normalize_app_key "$app_name")"
    matched=false

    for ((index = 1; index <= ITEM_COUNT; index++)); do
      item_name_key="$(normalize_app_key "${ITEM_NAME[index]}")"
      item_identifier_key="$(normalize_app_key "${ITEM_IDENTIFIER[index]}")"
      if keys_match "$app_key" "$item_name_key" || keys_match "$app_key" "$item_identifier_key"; then
        ITEM_SELECTED[index]=1
        matched=true
      fi
    done

    # Curated catalog wins. Otherwise fall back to install info captured in the
    # inventory (Homebrew cask, then App Store id) so "missing" apps still install.
    if ! $matched; then
      local app_cask app_mas
      app_cask="$(defined_app_cask_for_path "$selected_path")"
      app_mas="$(defined_app_mas_for_path "$selected_path")"
      if [[ -n "$app_cask" ]]; then
        add_synthetic_install_item brew_cask "$app_cask" "$app_name"
      elif [[ -n "$app_mas" ]]; then
        add_synthetic_install_item mas "$app_mas" "$app_name"
      else
        add_unmatched_defined_app "$app_name"
      fi
    fi
  done
}

summary_names() {
  local max="$1"
  shift

  local count="$#"
  local shown=0
  local item
  local output=""

  if ((count == 0)); then
    printf 'none'
    return
  fi

  for item in "$@"; do
    shown=$((shown + 1))
    if ((shown > max)); then
      output="${output} and $((count - max)) more..."
      break
    fi

    if [[ -z "$output" ]]; then
      output="$item"
    else
      output="${output}, ${item}"
    fi
  done

  printf '%s' "$output"
}

mas_summary_names() {
  local entry app_id app_name
  local names=()

  for entry in "${MAS_APPS[@]}"; do
    IFS='|' read -r app_id app_name <<<"$entry"
    names+=("$app_name")
  done

  summary_names 6 "${names[@]}"
}

manual_summary_names() {
  local entry manual_name manual_url manual_note
  local names=()

  for entry in "${MANUAL_APPS[@]}"; do
    IFS='|' read -r manual_name manual_url manual_note <<<"$entry"
    names+=("$manual_name")
  done

  summary_names 6 "${names[@]}"
}

estimated_install_minutes() {
  local total="$1"
  local minutes

  minutes=$((total / 4 + 3))
  ((minutes < 3)) && minutes=3
  printf '%s' "$minutes"
}

confirm_install_summary_tui() {
  local command total minutes

  total=$((${#BREW_FORMULAE[@]} + ${#BREW_CASKS[@]} + ${#MAS_APPS[@]} + ${#MANUAL_APPS[@]}))
  minutes="$(estimated_install_minutes "$total")"

  while true; do
    clear_screen
    printf '%s========================================%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    printf '%sInstall Summary%s\n' "$COLOR_GREEN$COLOR_BOLD" "$COLOR_RESET"
    printf '%s========================================%s\n\n' "$COLOR_GREEN" "$COLOR_RESET"
    printf 'Total: %s packages\n\n' "$total"

    printf '%sHomebrew Formulae (%d)%s\n' "$COLOR_BOLD" "${#BREW_FORMULAE[@]}" "$COLOR_RESET"
    printf '  %s%s%s\n\n' "$COLOR_DIM" "$(summary_names 6 "${BREW_FORMULAE[@]}")" "$COLOR_RESET"

    printf '%sApplications / Casks (%d)%s\n' "$COLOR_BOLD" "${#BREW_CASKS[@]}" "$COLOR_RESET"
    printf '  %s%s%s\n\n' "$COLOR_DIM" "$(summary_names 8 "${BREW_CASKS[@]}")" "$COLOR_RESET"

    printf '%sMac App Store (%d)%s\n' "$COLOR_BOLD" "${#MAS_APPS[@]}" "$COLOR_RESET"
    printf '  %s%s%s\n\n' "$COLOR_DIM" "$(mas_summary_names)" "$COLOR_RESET"

    printf '%sManual Follow-up (%d)%s\n' "$COLOR_BOLD" "${#MANUAL_APPS[@]}" "$COLOR_RESET"
    printf '  %s%s%s\n\n' "$COLOR_DIM" "$(manual_summary_names)" "$COLOR_RESET"

    printf 'Estimated time: ~%s minutes\n\n' "$minutes"
    printf '%s[Enter] Confirm & Install%s\n' "$COLOR_DIM" "$COLOR_RESET"
    printf '%s[B] Go Back%s\n' "$COLOR_DIM" "$COLOR_RESET"

    printf '\nCommand: '
    if ! IFS= read -r command; then
      return 1
    fi
    command="$(lowercase "$(trim_spaces "$command")")"

    case "$command" in
      "") return 0 ;;
      b|back|q|quit) return 1 ;;
    esac
  done
}

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  if $DRY_RUN; then
    printf 'DRY RUN: install Homebrew from https://brew.sh/\n'
    return 0
  fi

  printf '\nHomebrew is not installed. Installing Homebrew...\n'
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if ! command -v brew >/dev/null 2>&1; then
    printf 'Homebrew install finished, but brew is still not on PATH. Open a new terminal and rerun this script.\n' >&2
    exit 1
  fi
}

install_brew_formulae() {
  local formula failures=()

  ((${#BREW_FORMULAE[@]} == 0)) && return 0
  ensure_brew

  printf '\nInstalling Homebrew formulae...\n'
  for formula in "${BREW_FORMULAE[@]}"; do
    if ! run_or_print brew install "$formula"; then
      failures+=("$formula")
    fi
  done

  if ((${#failures[@]} > 0)); then
    printf '\nHomebrew formulae that need attention:\n'
    printf '  - %s\n' "${failures[@]}"
  fi
}

install_brew_casks() {
  local cask failures=()

  ((${#BREW_CASKS[@]} == 0)) && return 0
  ensure_brew

  printf '\nInstalling Homebrew casks...\n'
  for cask in "${BREW_CASKS[@]}"; do
    if ! run_or_print brew install --cask "$cask"; then
      failures+=("$cask")
    fi
  done

  if ((${#failures[@]} > 0)); then
    printf '\nHomebrew casks that need attention:\n'
    printf '  - %s\n' "${failures[@]}"
  fi
}

ensure_mas() {
  ensure_brew

  if command -v mas >/dev/null 2>&1; then
    return 0
  fi

  printf '\nInstalling mas, the Mac App Store command line helper...\n'
  run_or_print brew install mas
}

install_mas_apps() {
  local app_id app_name entry failures=()

  ((${#MAS_APPS[@]} == 0)) && return 0
  ensure_mas

  if $DRY_RUN; then
    printf 'DRY RUN: verify App Store sign-in with mas account\n'
  elif ! mas account >/dev/null 2>&1; then
    printf '\nSkipping Mac App Store installs because you are not signed in.\n'
    printf 'Open the App Store app, sign in, then rerun this script.\n'
    return 0
  fi

  printf '\nInstalling Mac App Store apps...\n'
  for entry in "${MAS_APPS[@]}"; do
    IFS='|' read -r app_id app_name <<<"$entry"
    printf '\n%s (%s)\n' "$app_name" "$app_id"
    if ! run_or_print mas install "$app_id"; then
      failures+=("${app_name} (${app_id})")
    fi
  done

  if ((${#failures[@]} > 0)); then
    printf '\nMac App Store apps that need attention:\n'
    printf '  - %s\n' "${failures[@]}"
  fi
}

print_manual_apps() {
  local entry manual_name manual_url manual_note

  ((${#MANUAL_APPS[@]} == 0)) && return 0

  printf '\nManual follow-up apps:\n'
  for entry in "${MANUAL_APPS[@]}"; do
    IFS='|' read -r manual_name manual_url manual_note <<<"$entry"
    printf '  - %s' "$manual_name"
    [[ -n "$manual_url" ]] && printf ': %s' "$manual_url"
    printf '\n'
    [[ -n "$manual_note" ]] && printf '    %s\n' "$manual_note"
  done
}

install_apps_flow() {
  require_file "$APP_CATALOG" "App catalog"
  require_file "$INSTALLED_APPS_CATALOG" "Defined app catalog"
  require_file "$APP_CATEGORY_FILE" "App category file"

  load_all_app_items

  if ! choose_defined_apps "Choose Apps to Install" "essential"; then
    return 0
  fi

  select_install_items_for_defined_apps
  if (( $(selected_app_count) == 0 )); then
    printf '\nNo selected apps matched installable entries in %s.\n' "$APP_CATALOG"
    print_unmatched_defined_apps
    return 0
  fi

  build_install_plan

  if confirm_install_summary_tui; then
    install_brew_formulae
    install_brew_casks
    install_mas_apps
    print_manual_apps
    printf '\nInstall flow complete.\n'
  else
    printf 'Install cancelled.\n'
  fi
}

define_apps_to_backup_flow() {
  local picker="$SCRIPT_DIR/mac-installed-apps.py"
  local scan_args=()
  local preview_file

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'Python 3 is required for the installed-app definition editor.\n'
    return 0
  fi

  if [[ ! -f "$picker" ]]; then
    printf 'Installed-app definition editor not found: %s\n' "$picker"
    return 0
  fi

  header "Define Apps to Backup"
  printf 'Installed-app list: %s\n' "$INSTALLED_APPS_REAL"
  printf 'Categories:         %s\n' "$APP_CATEGORY_FILE"
  if $INCLUDE_SYSTEM_APPS; then
    scan_args+=(--include-system)
    printf '\nScanning /Applications, ~/Applications, and /System/Applications...\n'
  else
    printf '\nScanning /Applications and ~/Applications...\n'
  fi

  if $DRY_RUN; then
    if [[ -t 0 && -t 1 ]]; then
      preview_file="$(mktemp)"
      printf 'DRY RUN: opening the editor as a preview only.\n'
      printf 'Changes you make here will be discarded. Run without --dry-run to save to:\n'
      printf '  %s\n\n' "$INSTALLED_APPS_REAL"

      if python3 "$picker" \
        --output "$preview_file" \
        --categories "$APP_CATEGORY_FILE" \
        --seed-app-catalog "$APP_CATALOG" \
        --merge-base "$INSTALLED_APPS_REAL" \
        --save-mode merge \
        "${scan_args[@]}"; then
        printf '\nDRY RUN: preview saved to a temporary file and discarded.\n'
        printf 'To keep those app/category changes, rerun: ./mac-backup-wizard.sh\n'
      else
        printf '\nDRY RUN: app definition preview cancelled.\n'
      fi
      rm -f "$preview_file"
    else
      python3 "$picker" \
        --output "$INSTALLED_APPS_REAL" \
        --categories "$APP_CATEGORY_FILE" \
        --seed-app-catalog "$APP_CATALOG" \
        "${scan_args[@]}" \
        --check
      printf 'DRY RUN: no app definition file was written.\n'
      printf 'Run without --dry-run to edit and save app categories.\n'
    fi
    return 0
  fi

  if python3 "$picker" \
    --output "$INSTALLED_APPS_REAL" \
    --categories "$APP_CATEGORY_FILE" \
    --seed-app-catalog "$APP_CATALOG" \
    "${scan_args[@]}"; then
    printf '\nApp backup definition saved.\n'
    printf 'Edit category names later in: %s\n' "$APP_CATEGORY_FILE"
  else
    printf '\nApp backup definition cancelled.\n'
  fi
}

install_mackup_if_needed() {
  if command -v mackup >/dev/null 2>&1; then
    printf 'Mackup is already installed: %s\n' "$(command -v mackup)"
    return 0
  fi

  ensure_brew
  printf 'Installing Mackup...\n'
  run_or_print brew install mackup
}

normalize_dir_path() {
  local value="$1"
  value="$(expand_path "$(trim_spaces "$value")")"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

mackup_default_backup_folder() {
  local root="$BACKUP_ROOT"
  [[ -n "$root" ]] || root="$DEFAULT_BACKUP_ROOT"
  root="$(normalize_dir_path "$root")"
  printf '%s/Mackup' "$root"
}

mackup_storage_path_value() {
  local parent="$1"
  local home="$HOME"

  parent="$(normalize_dir_path "$parent")"
  case "$parent" in
    "$home")
      printf '.'
      ;;
    "$home"/*)
      printf '%s' "${parent#"$home"/}"
      ;;
    *)
      printf '%s' "$parent"
      ;;
  esac
}

prompt_mackup_backup_folder() {
  local default_folder input chosen

  default_folder="$(mackup_default_backup_folder)"

  if $DRY_RUN || $ASSUME_YES; then
    MACKUP_BACKUP_FOLDER="$default_folder"
    $DRY_RUN && printf 'DRY RUN: would use Mackup backup folder: %s\n' "$MACKUP_BACKUP_FOLDER"
    return 0
  fi

  printf '\nMackup backup folder\n'
  printf 'Default from current backup location:\n  %s\n' "$default_folder"
  printf 'Press Return to use the default, or enter another folder.\n'
  printf 'Mackup backup folder [%s]: ' "$default_folder"
  IFS= read -r input
  input="$(trim_spaces "$input")"
  [[ -n "$input" ]] || input="$default_folder"

  chosen="$(normalize_dir_path "$input")"
  if [[ -z "$chosen" || "$chosen" == "/" ]]; then
    printf 'Invalid Mackup backup folder: %s\n' "$input"
    return 1
  fi

  MACKUP_BACKUP_FOLDER="$chosen"
}

write_mackup_storage_config() {
  local folder="$1"
  local config_path tmp parent directory path_value

  folder="$(normalize_dir_path "$folder")"
  parent="$(dirname "$folder")"
  directory="$(basename "$folder")"
  path_value="$(mackup_storage_path_value "$parent")"
  config_path="$(expand_path "$MACKUP_CONFIG")"

  if $DRY_RUN; then
    printf 'DRY RUN: update %s with:\n' "$config_path"
    printf '[storage]\nengine = file_system\npath = %s\ndirectory = %s\n' "$path_value" "$directory"
    return 0
  fi

  if ! mkdir -p "$(dirname "$config_path")"; then
    printf 'Could not create Mackup config folder: %s\n' "$(dirname "$config_path")"
    return 1
  fi

  if ! mkdir -p "$folder"; then
    printf 'Could not create Mackup backup folder: %s\n' "$folder"
    return 1
  fi

  if [[ ! -f "$config_path" ]]; then
    printf '[storage]\nengine = file_system\npath = %s\ndirectory = %s\n' "$path_value" "$directory" >"$config_path"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v storage_path="$path_value" -v storage_dir="$directory" '
    /^[[:space:]]*\[storage\][[:space:]]*$/ {
      seen_storage = 1
      inside = 1
      print "[storage]"
      print "engine = file_system"
      print "path = " storage_path
      print "directory = " storage_dir
      next
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      inside = 0
    }
    inside && /^[[:space:]]*(engine|path|directory)[[:space:]]*=/ {
      next
    }
    {
      print
    }
    END {
      if (!seen_storage) {
        if (NR > 0) {
          print ""
        }
        print "[storage]"
        print "engine = file_system"
        print "path = " storage_path
        print "directory = " storage_dir
      }
    }
  ' "$config_path" >"$tmp"
  if ! mv "$tmp" "$config_path"; then
    rm -f "$tmp"
    printf 'Could not update Mackup config: %s\n' "$config_path"
    return 1
  fi
}

mackup_setup_flow() {
  header "Install Mackup"

  install_mackup_if_needed || return 0
  prompt_mackup_backup_folder || return 0
  write_mackup_storage_config "$MACKUP_BACKUP_FOLDER" || return 0

  if $DRY_RUN; then
    printf '\nDRY RUN: Mackup setup preview complete.\n'
    return 0
  fi

  printf '\nMackup is configured to use:\n  %s\n' "$MACKUP_BACKUP_FOLDER"
  printf 'Config: %s\n' "$(expand_path "$MACKUP_CONFIG")"
}

write_mackup_supported_apps_file() {
  local apps_file="$1"

  if ! command -v mackup >/dev/null 2>&1; then
    install_mackup_if_needed || return 1
  fi

  if ! command -v mackup >/dev/null 2>&1; then
    printf 'Mackup is not available yet. Run option 5 first.\n'
    return 1
  fi

  mackup list | sed -n 's/^ - //p' >"$apps_file"
  [[ -s "$apps_file" ]]
}

mackup_id_for_defined_app() {
  local app_name="$1"
  local apps_file="$2"
  local app_key mackup_id mackup_key

  app_key="$(normalize_app_key "$app_name")"

  while IFS= read -r mackup_id; do
    mackup_id="$(trim_spaces "$mackup_id")"
    [[ -n "$mackup_id" ]] || continue
    mackup_key="$(normalize_app_key "$mackup_id")"
    if keys_match "$app_key" "$mackup_key"; then
      printf '%s' "$mackup_id"
      return 0
    fi
  done <"$apps_file"

  return 1
}

choose_mackup_apps() {
  local apps_file selected_path app_name mackup_id

  MACKUP_SELECTED_APPS=()
  UNMATCHED_DEFINED_APPS=()

  apps_file="$(mktemp)"

  if ! write_mackup_supported_apps_file "$apps_file"; then
    rm -f "$apps_file"
    return 1
  fi

  if ! choose_defined_apps "Choose Apps for Mackup" "" "$MACKUP_SELECTION_FILE" "$MACKUP_SELECTION_FILE"; then
    rm -f "$apps_file"
    return 1
  fi

  for selected_path in "${SELECTED_DEFINED_APP_PATHS[@]}"; do
    app_name="$(defined_app_name_for_path "$selected_path")"
    if mackup_id="$(mackup_id_for_defined_app "$app_name" "$apps_file")"; then
      contains "$mackup_id" "${MACKUP_SELECTED_APPS[@]}" || MACKUP_SELECTED_APPS+=("$mackup_id")
    else
      add_unmatched_defined_app "$app_name"
    fi
  done

  rm -f "$apps_file"
  if ((${#MACKUP_SELECTED_APPS[@]} == 0)); then
    printf '\nNo selected apps matched Mackup-supported application IDs.\n'
    print_unmatched_defined_apps
    return 1
  fi

  return 0
}

print_mackup_plan() {
  local action="$1"
  local label="$action"

  case "$action" in
    backup) label="Backup" ;;
    restore) label="Restore" ;;
  esac

  header "Mackup $label Plan"
  printf 'Config: %s\n' "$(expand_path "$MACKUP_CONFIG")"
  printf 'Remembered selection: %s\n' "$MACKUP_SELECTION_FILE"
  printf 'Selected apps: %s\n' "${#MACKUP_SELECTED_APPS[@]}"
  print_wrapped_names "  " "${MACKUP_SELECTED_APPS[@]}"
  print_unmatched_defined_apps
}

run_mackup_for_selected_apps() {
  local action="$1"
  local app
  local args=()
  local failures=()

  if ! command -v mackup >/dev/null 2>&1; then
    printf 'Mackup is not installed. Run option 5 first.\n'
    return 1
  fi

  for app in "${MACKUP_SELECTED_APPS[@]}"; do
    args=()
    $DRY_RUN && args+=("-n")
    $ASSUME_YES && args+=("-f")
    args+=("-c" "$(expand_path "$MACKUP_CONFIG")" "$action" "$app")

    printf '\nMackup %s: %s\n' "$action" "$app"
    if ! run_or_print mackup "${args[@]}"; then
      failures+=("$app")
    fi
  done

  if ((${#failures[@]} > 0)); then
    printf '\nMackup apps that need attention:\n'
    printf '  - %s\n' "${failures[@]}"
  fi
}

mackup_selected_apps_flow() {
  local action="$1"
  local prompt

  choose_mackup_apps || return 0
  print_mackup_plan "$action"

  if [[ "$action" == "backup" ]]; then
    prompt="Run Mackup backup for selected apps?"
  else
    prompt="Restore selected app settings with Mackup?"
  fi

  if confirm "$prompt"; then
    run_mackup_for_selected_apps "$action"
    printf '\nMackup %s flow complete.\n' "$action"
  else
    printf 'Mackup %s cancelled.\n' "$action"
  fi
}

expand_path() {
  local path="$1"

  case "$path" in
    "~")
      printf '%s' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s' "$HOME" "${path#\~/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

relative_key_for_path() {
  local path="$1"

  if [[ "$path" == "$HOME/"* ]]; then
    printf '%s' "${path#$HOME/}"
  elif [[ "$path" == /* ]]; then
    printf 'absolute%s' "$path"
  else
    printf '%s' "$path"
  fi
}

backup_dir() {
  printf '%s/%s/latest' "$BACKUP_ROOT" "$PROFILE_NAME"
}

reset_settings_items() {
  SETTING_COUNT=0
  SETTING_NAME=()
  SETTING_PATH=()
  SETTING_NOTES=()
  SETTING_SELECTED=()
  SETTING_SIZE_BYTES=()
  SETTING_BUNDLE_ID=()
  SETTING_KIND=()
  SETTING_SOURCE=()
}

active_settings_manifest() {
  # Precedence: an imported AI-reviewed list, then the freshly generated scan,
  # then the curated manual overlay.
  if [[ -f "$SETTINGS_REVIEWED" ]]; then
    printf '%s' "$SETTINGS_REVIEWED"
  elif [[ -f "$SETTINGS_GENERATED" ]]; then
    printf '%s' "$SETTINGS_GENERATED"
  else
    printf '%s' "$SETTINGS_MANIFEST"
  fi
}

export_settings_for_review_flow() {
  local scanner="$SCRIPT_DIR/mac-settings-scan.py"
  local args=()

  header "Export Settings for AI Review"

  command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required.\n'; return 0; }
  [[ -f "$scanner" ]] || { printf 'Scanner not found: %s\n' "$scanner"; return 0; }
  [[ -f "$INSTALLED_APPS_CATALOG" ]] || { printf 'Run option 1 first to define apps.\n'; return 0; }

  if $DRY_RUN; then
    printf 'DRY RUN: would scan and write candidates to %s\n' "$SETTINGS_CANDIDATES"
    return 0
  fi

  args=(--apps "$INSTALLED_APPS_CATALOG" --export-candidates "$SETTINGS_CANDIDATES")
  [[ -f "$SETTINGS_MANIFEST" ]] && args+=(--overlay "$SETTINGS_MANIFEST")
  $SCAN_SKIP_CONTAINERS && args+=(--skip-containers)

  local mackup_ids
  mackup_ids="$(mktemp)"
  write_mackup_ids_file "$mackup_ids" && args+=(--mackup-ids "$mackup_ids")

  printf 'Scanning and exporting review candidates...\n'
  if ! python3 "$scanner" "${args[@]}"; then
    rm -f "$mackup_ids"
    printf 'Export failed.\n'
    return 0
  fi
  rm -f "$mackup_ids"

  printf '\nReview file written:\n  %s\n' "$SETTINGS_CANDIDATES"
  printf '\nPaste it into Claude or ChatGPT with a prompt like:\n'
  printf '  "For each row set keep to yes or no (yes = real user config worth\n'
  printf '   restoring on a new Mac; no = cache/state/machine-bound) and add a\n'
  printf '   one-line reason. For (none found) rows, propose the real config\n'
  printf '   path(s) and set source to llm."\n'
  printf '\nSave the edited file back to the same path, then run:\n'
  printf '  Maintenance > Import reviewed settings list\n'
}

import_reviewed_settings_flow() {
  local scanner="$SCRIPT_DIR/mac-settings-scan.py"

  header "Import Reviewed Settings"

  command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required.\n'; return 0; }
  [[ -f "$scanner" ]] || { printf 'Scanner not found: %s\n' "$scanner"; return 0; }
  [[ -f "$SETTINGS_CANDIDATES" ]] || {
    printf 'No review file at:\n  %s\n' "$SETTINGS_CANDIDATES"
    printf 'Run "Export settings list for AI review" first.\n'
    return 0
  }

  if $DRY_RUN; then
    printf 'DRY RUN: would import %s -> %s\n' "$SETTINGS_CANDIDATES" "$SETTINGS_REVIEWED"
    return 0
  fi

  if ! python3 "$scanner" \
    --apps "$INSTALLED_APPS_CATALOG" \
    --import-candidates "$SETTINGS_CANDIDATES" \
    --output "$SETTINGS_REVIEWED"; then
    printf 'Import failed.\n'
    return 0
  fi

  printf '\nReviewed settings saved to:\n  %s\n' "$SETTINGS_REVIEWED"
  printf 'Backups will now use this list instead of rescanning.\n'
  printf 'Delete that file to return to automatic scanning.\n'
}

write_mackup_ids_file() {
  # Write the list of Mackup-supported app ids (one per line). Returns non-zero
  # if Mackup is unavailable or the list is empty.
  local out="$1"

  command -v mackup >/dev/null 2>&1 || return 1
  mackup list 2>/dev/null | sed -n 's/^ - //p' >"$out"
  [[ -s "$out" ]]
}

scan_settings_manifest() {
  local scanner="$SCRIPT_DIR/mac-settings-scan.py"
  local args=()
  local mackup_ids rc

  command -v python3 >/dev/null 2>&1 || {
    printf '[WARN] python3 not found; using existing settings manifest.\n'
    return 1
  }
  [[ -f "$scanner" ]] || {
    printf '[WARN] settings scanner not found; using existing settings manifest.\n'
    return 1
  }
  [[ -f "$INSTALLED_APPS_CATALOG" ]] || {
    printf '[WARN] no app catalog yet (run option 1 first); using existing settings manifest.\n'
    return 1
  }

  args=(--apps "$INSTALLED_APPS_CATALOG" --output "$SETTINGS_GENERATED")
  [[ -f "$SETTINGS_MANIFEST" ]] && args+=(--overlay "$SETTINGS_MANIFEST")
  $SCAN_SKIP_CONTAINERS && args+=(--skip-containers)

  mackup_ids="$(mktemp)"
  write_mackup_ids_file "$mackup_ids" && args+=(--mackup-ids "$mackup_ids")

  python3 "$scanner" "${args[@]}"
  rc=$?
  rm -f "$mackup_ids"
  return $rc
}

load_settings_items() {
  # Optional arg: explicit manifest path (e.g. a backup's selected-settings.tsv).
  # Defaults to the local active manifest, used by the backup/scan flows.
  local manifest="${1:-$(active_settings_manifest)}"
  local enabled name path notes source bundle_id kind verified size_bytes size_human
  local line_number=0

  reset_settings_items
  [[ -f "$manifest" ]] || return 0

  while IFS=$'\t' read -r enabled name path notes source bundle_id kind verified size_bytes size_human || [[ -n "$enabled" ]]; do
    line_number=$((line_number + 1))
    [[ "$line_number" -eq 1 && "$enabled" == "enabled" ]] && continue
    [[ -z "$enabled" || "$enabled" == \#* ]] && continue

    SETTING_COUNT=$((SETTING_COUNT + 1))
    SETTING_NAME[SETTING_COUNT]="$(trim_spaces "$name")"
    SETTING_PATH[SETTING_COUNT]="$(trim_spaces "$path")"
    SETTING_NOTES[SETTING_COUNT]="$(trim_spaces "$notes")"
    SETTING_BUNDLE_ID[SETTING_COUNT]="$(trim_spaces "$bundle_id")"
    SETTING_KIND[SETTING_COUNT]="$(trim_spaces "$kind")"
    SETTING_SOURCE[SETTING_COUNT]="$(trim_spaces "${source:-manual}")"
    SETTING_SIZE_BYTES[SETTING_COUNT]="$(trim_spaces "$size_bytes")"
    # Rows disabled in the manifest (e.g. large folders) load but start unchecked.
    if enabled_row "$enabled"; then
      SETTING_SELECTED[SETTING_COUNT]=1
    else
      SETTING_SELECTED[SETTING_COUNT]=0
    fi
  done <"$manifest"
}

selected_setting_count() {
  local count=0
  local index

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] && count=$((count + 1))
  done

  printf '%s' "$count"
}

setting_available_for_mode() {
  local mode="$1"
  local index="$2"
  local source_path
  local dir
  local rel_key
  local backup_source

  source_path="$(expand_path "${SETTING_PATH[index]}")"

  if [[ "$mode" == "backup" ]]; then
    [[ -e "$source_path" ]]
    return
  fi

  dir="$(backup_dir)"
  rel_key="$(relative_key_for_path "$source_path")"
  backup_source="$dir/files/$rel_key"
  [[ -e "$backup_source" ]]
}

setting_estimated_size_bytes() {
  local index="$1"
  local source_path size

  size="${SETTING_SIZE_BYTES[index]:-}"
  if [[ "$size" =~ ^[0-9]+$ ]]; then
    printf '%s' "$size"
    return 0
  fi

  source_path="$(expand_path "${SETTING_PATH[index]}")"
  if size="$(file_size_bytes "$source_path")" && [[ "$size" =~ ^[0-9]+$ ]]; then
    printf '%s' "$size"
    return 0
  fi

  return 1
}

print_backup_size_estimate() {
  local index key size label total=0 known=0 unknown=0 selected=0
  local cat_index found
  local categories=()
  local category_bytes=()
  local category_counts=()

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] || continue
    setting_available_for_mode backup "$index" || continue
    selected=$((selected + 1))
    key="$(setting_category_key "$index")"
    [[ -n "$key" ]] || key="uncategorized"
    found=-1
    for ((cat_index = 0; cat_index < ${#categories[@]}; cat_index++)); do
      if [[ "${categories[cat_index]}" == "$key" ]]; then
        found="$cat_index"
        break
      fi
    done
    if ((found < 0)); then
      categories+=("$key")
      category_bytes+=(0)
      category_counts+=(0)
      found=$((${#categories[@]} - 1))
    fi
    category_counts[found]=$((category_counts[found] + 1))
    if size="$(setting_estimated_size_bytes "$index")"; then
      category_bytes[found]=$((category_bytes[found] + size))
      total=$((total + size))
      known=$((known + 1))
    else
      unknown=$((unknown + 1))
    fi
  done

  printf '\nEstimated backup size by app category:\n'
  if ((selected == 0)); then
    printf '  No selected settings are available to back up.\n'
    return 0
  fi

  for ((cat_index = 0; cat_index < ${#categories[@]}; cat_index++)); do
    label="$(app_category_label_for_key "${categories[cat_index]}")"
    printf '  %-24s %8s  (%d item(s))\n' \
      "$label" \
      "$(human_size_bytes "${category_bytes[cat_index]:-0}")" \
      "${category_counts[cat_index]:-0}"
  done

  printf '  %-24s %8s  (%d known item(s))\n' \
    "Total known" \
    "$(human_size_bytes "$total")" \
    "$known"
  if ((unknown > 0)); then
    printf '  %-24s %8s  (%d item(s), legacy/no cached size)\n' \
      "Unknown" \
      "-" \
      "$unknown"
  fi
}

selected_known_backup_size_bytes() {
  local index size total=0

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] || continue
    setting_available_for_mode backup "$index" || continue
    if size="$(setting_estimated_size_bytes "$index")"; then
      total=$((total + size))
    fi
  done

  printf '%s' "$total"
}

existing_path_for_df() {
  local path="$1"

  path="$(expand_path "$path")"
  while [[ ! -e "$path" && "$path" != "/" ]]; do
    path="$(dirname "$path")"
  done
  [[ -e "$path" ]] || path="/"
  printf '%s' "$path"
}

filesystem_available_bytes() {
  local path="$1"
  local existing available_kb

  existing="$(existing_path_for_df "$path")"
  available_kb="$(df -Pk "$existing" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$((available_kb * 1024))"
}

backup_space_preflight() {
  local dir="$1"
  local known_bytes available_bytes threshold

  known_bytes="$(selected_known_backup_size_bytes)"
  ((known_bytes > 0)) || return 0

  if ! available_bytes="$(filesystem_available_bytes "$dir")"; then
    printf '\n[WARN] Could not determine free space for backup destination.\n'
    return 0
  fi

  threshold=$((available_bytes * 85 / 100))
  if ((known_bytes > threshold)); then
    printf '\n[WARN] Selected settings are about %s before backup filters.\n' "$(human_size_bytes "$known_bytes")"
    printf '       Free space near the backup destination is about %s.\n' "$(human_size_bytes "$available_bytes")"
    printf '       This backup may fail with "No space left on device".\n'
    confirm "Continue anyway?"
    return $?
  fi
}

print_backup_filter_note() {
  printf '\nBackup filters: skipping caches, browser WebsiteData, Docker/VM images, sockets, logs, and temporary AppleDouble files.\n'
}

tsv_cell() {
  local value="$1"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

write_backup_report_header() {
  local report="$1"

  $DRY_RUN && return 0
  printf 'status\tname\tpath\tdestination\tdetail\n' >"$report"
}

append_backup_report_row() {
  local report="$1"
  local status="$2"
  local name="$3"
  local path="$4"
  local destination="$5"
  local detail="$6"

  $DRY_RUN && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(tsv_cell "$status")" \
    "$(tsv_cell "$name")" \
    "$(tsv_cell "$path")" \
    "$(tsv_cell "$destination")" \
    "$(tsv_cell "$detail")" >>"$report"
}

available_setting_count() {
  local mode="$1"
  local count=0
  local index

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    setting_available_for_mode "$mode" "$index" && count=$((count + 1))
  done

  printf '%s' "$count"
}

all_available_settings_selected() {
  local mode="$1"
  local index

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    setting_available_for_mode "$mode" "$index" || continue
    [[ "${SETTING_SELECTED[index]}" == "1" ]] || return 1
  done

  return 0
}

select_all_available_settings() {
  local mode="$1"
  local index

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    if setting_available_for_mode "$mode" "$index"; then
      SETTING_SELECTED[index]=1
    else
      SETTING_SELECTED[index]=0
    fi
  done
}

select_settings_for_defined_apps() {
  local mode="$1"
  local selected_path app_index app_name app_bundle app_key
  local index matched

  UNMATCHED_DEFINED_APPS=()

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    SETTING_SELECTED[index]=0
  done

  for selected_path in "${SELECTED_DEFINED_APP_PATHS[@]}"; do
    app_name="$(defined_app_name_for_path "$selected_path")"
    app_bundle=""
    if app_index="$(defined_app_index_for_path "$selected_path")"; then
      app_bundle="${DEFINED_APP_BUNDLE_ID[app_index]}"
    fi
    app_key="$(normalize_app_key "$app_name")"
    matched=false

    for ((index = 1; index <= SETTING_COUNT; index++)); do
      setting_available_for_mode "$mode" "$index" || continue

      # Primary match: exact bundle id (filesystem-scanned rows carry the app's
      # bundle id). Fallback: name match, only for rows that have no bundle id
      # (curated manual rows and dotfiles).
      if [[ -n "$app_bundle" && -n "${SETTING_BUNDLE_ID[index]}" ]]; then
        [[ "${SETTING_BUNDLE_ID[index]}" == "$app_bundle" ]] || continue
      else
        keys_match "$app_key" "$(normalize_app_key "${SETTING_NAME[index]}")" || continue
      fi

      SETTING_SELECTED[index]=1
      matched=true
    done

    $matched || add_unmatched_defined_app "$app_name"
  done
}

preselect_settings_from_defined_apps() {
  # Optionally pre-select settings by choosing apps (bundle-id match). On cancel,
  # the manifest-default selection is left untouched. Always returns 0 so the
  # caller proceeds to the full settings picker.
  local mode="$1"
  local label="$mode"

  [[ -t 0 && -t 1 ]] || return 0

  case "$mode" in
    backup) label="Backup" ;;
    restore) label="Restore" ;;
  esac

  printf '\nOptional: choose apps to pre-select their settings.\n'
  printf 'Cancel (Q) to skip and pick settings directly.\n'

  if choose_defined_apps "Pre-select Settings by App ($label)" ""; then
    select_settings_for_defined_apps "$mode"
    if (( $(selected_setting_count) == 0 )); then
      printf '\nNo chosen apps matched scanned settings; pick settings directly next.\n'
      select_all_available_settings "$mode"
    fi
    print_unmatched_defined_apps
  fi

  return 0
}

settings_picker_curses_flow() {
  local mode="$1"
  local picker="$SCRIPT_DIR/mac-settings-picker.py"
  local manifest tmp pre
  local selected_index
  local index

  [[ -t 0 && -t 1 ]] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  [[ -f "$picker" ]] || return 2

  manifest="$(active_settings_manifest)"
  tmp="$(mktemp)"
  pre="$(mktemp)"

  # Seed the picker with the currently selected rows (by path) so app pre-selection
  # and manifest defaults carry through.
  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] && printf '%s\n' "${SETTING_PATH[index]}" >>"$pre"
  done

  if ! python3 "$picker" \
    --manifest "$manifest" \
    --mode "$mode" \
    --backup-dir "$(backup_dir)" \
    --preselect-file "$pre" \
    --output "$tmp"; then
    rm -f "$tmp" "$pre"
    return 1
  fi

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    SETTING_SELECTED[index]=0
  done

  while IFS= read -r selected_index; do
    [[ "$selected_index" =~ ^[0-9]+$ ]] || continue
    if ((selected_index >= 1 && selected_index <= SETTING_COUNT)); then
      SETTING_SELECTED[selected_index]=1
    fi
  done <"$tmp"

  rm -f "$tmp" "$pre"
  (( $(selected_setting_count) > 0 ))
}

print_settings_table() {
  local index mark status source_path dir rel_key backup_source
  local mode="$1"
  local selected_count
  local available_count
  local unavailable_count

  selected_count="$(selected_setting_count)"
  available_count="$(available_setting_count "$mode")"
  unavailable_count=$((SETTING_COUNT - available_count))

  printf '\nSettings available for %s (%s selected, %s available, %s unavailable):\n' \
    "$mode" \
    "$selected_count" \
    "$available_count" \
    "$unavailable_count"
  dir="$(backup_dir)"

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    mark=" "
    [[ "${SETTING_SELECTED[index]}" == "1" ]] && mark="x"

    status=""
    source_path="$(expand_path "${SETTING_PATH[index]}")"
    rel_key="$(relative_key_for_path "$source_path")"
    backup_source="$dir/files/$rel_key"

    if [[ "$mode" == "backup" ]]; then
      [[ -e "$source_path" ]] || status="missing locally"
    else
      [[ -e "$backup_source" ]] || status="missing in backup"
    fi

    [[ -n "$status" ]] && mark="-"

    printf '  [%s] %2d  %-30s  %s' "$mark" "$index" "${SETTING_NAME[index]}" "${SETTING_PATH[index]}"
    [[ -n "$status" ]] && printf '  (%s)' "$status"
    printf '\n'
  done
}

toggle_setting_number() {
  local number="$1"
  local mode="$2"

  if [[ ! "$number" =~ ^[0-9]+$ ]] || ((number < 1 || number > SETTING_COUNT)); then
    printf 'Ignoring invalid setting number: %s\n' "$number"
    return 0
  fi

  if ! setting_available_for_mode "$mode" "$number"; then
    printf 'Cannot select %s because it is not available for %s.\n' "${SETTING_NAME[number]}" "$mode"
    SETTING_SELECTED[number]=0
    return 0
  fi

  if [[ "${SETTING_SELECTED[number]}" == "1" ]]; then
    SETTING_SELECTED[number]=0
  else
    SETTING_SELECTED[number]=1
  fi
}

process_setting_toggle_tokens() {
  local choice="$1"
  local mode="$2"
  local token start end number tmp

  choice="$(normalize_selection "$choice")"
  for token in $choice; do
    if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${token%-*}"
      end="${token#*-}"
      if ((start > end)); then
        tmp="$start"
        start="$end"
        end="$tmp"
      fi
      for ((number = start; number <= end; number++)); do
        toggle_setting_number "$number" "$mode"
      done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      toggle_setting_number "$token" "$mode"
    else
      printf 'Ignoring unknown setting selection: %s\n' "$token"
    fi
  done
}

review_settings_selection() {
  local mode="$1"
  local choice index

  if ((SETTING_COUNT == 0)); then
    printf 'No settings found in manifest.\n'
    return 1
  fi

  if (( $(available_setting_count "$mode") == 0 )); then
    print_settings_table "$mode"
    printf '\nNo settings are currently available for %s.\n' "$mode"
    return 1
  fi

  # Seed selection: optionally by app (bundle-id match); otherwise manifest defaults.
  preselect_settings_from_defined_apps "$mode"

  # Always let the user finalize in the picker so unmatched rows (dotfiles, etc.)
  # can be added. Fall back to the numbered editor only if the picker can't run.
  if settings_picker_curses_flow "$mode"; then
    return 0
  else
    case "$?" in
      1) return 1 ;;
    esac
  fi

  while true; do
    print_settings_table "$mode"
    cat <<'EOF'

Enter or C = continue with checked settings
Numbers toggle settings. Ranges work too: 2,5,8-11
A = select all available, N = select none, B = back
[-] rows are unavailable and cannot be selected because there is nothing to copy.
EOF
    printf '\nSettings to toggle/command: '
    IFS= read -r choice
    choice="$(lowercase "$(trim_spaces "$choice")")"

    case "$choice" in
      ""|c|continue|done)
        if (( $(selected_setting_count) == 0 )); then
          printf 'No settings selected.\n'
          continue
        fi
        return 0
        ;;
      a|all)
        if all_available_settings_selected "$mode"; then
          printf 'All %s available settings are already selected. %s unavailable rows marked [-] cannot be selected.\n' \
            "$(available_setting_count "$mode")" \
            "$((SETTING_COUNT - $(available_setting_count "$mode")))"
          printf 'Press Return or C to continue.\n'
        else
          select_all_available_settings "$mode"
          printf 'All %s available settings selected. %s unavailable rows marked [-] cannot be selected.\n' \
            "$(available_setting_count "$mode")" \
            "$((SETTING_COUNT - $(available_setting_count "$mode")))"
          printf 'Press Return or C to continue.\n'
        fi
        ;;
      n|none)
        for ((index = 1; index <= SETTING_COUNT; index++)); do
          SETTING_SELECTED[index]=0
        done
        ;;
      b|back|q|quit)
        return 1
        ;;
      *)
        process_setting_toggle_tokens "$choice" "$mode"
        ;;
    esac
  done
}

copy_backup_metadata_file() {
  local src="$1"
  local dest="$2"
  local label="$3"

  [[ -f "$src" ]] || return 0

  if [[ -d "$dest" ]]; then
    if $DRY_RUN; then
      printf 'DRY RUN: would replace directory metadata target: %s\n' "$dest"
    else
      rm -rf "$dest" || {
        printf '[ERROR] Could not replace directory metadata target: %s\n' "$dest"
        return 1
      }
    fi
  fi

  run_or_print rsync -aE "$src" "$dest" || {
    printf '[ERROR] Failed to copy %s to backup metadata.\n' "$label"
    return 1
  }
}

copy_settings_manifest_to_backup() {
  local dir="$1"
  local failed=0
  local mackup_config_path

  run_or_print mkdir -p "$dir" || return 1
  copy_backup_metadata_file "$SETTINGS_MANIFEST" "$dir/manifest.tsv" "settings manifest" || failed=1

  if [[ -f "$APP_CATEGORY_FILE" ]]; then
    copy_backup_metadata_file "$APP_CATEGORY_FILE" "$dir/app-categories.tsv" "app categories" || failed=1
  fi

  if [[ -f "$INSTALLED_APPS_CATALOG" ]]; then
    copy_backup_metadata_file "$INSTALLED_APPS_CATALOG" "$dir/installed-apps.tsv" "installed apps catalog" || failed=1
  fi

  if [[ -f "$MACKUP_SELECTION_FILE" ]]; then
    copy_backup_metadata_file "$MACKUP_SELECTION_FILE" "$dir/mackup-apps.tsv" "Mackup app selection" || failed=1
  fi

  mackup_config_path="$(expand_path "$MACKUP_CONFIG")"
  if [[ -f "$mackup_config_path" ]]; then
    copy_backup_metadata_file "$mackup_config_path" "$dir/mackup.cfg" "Mackup config" || failed=1
  fi

  ((failed == 0))
}

write_selected_settings_manifest() {
  local dir="$1"
  local out="$dir/selected-settings.tsv"
  local index

  $DRY_RUN && {
    printf 'DRY RUN: write selected settings manifest to %q\n' "$out"
    return 0
  }

  mkdir -p "$dir" || return 1
  # Full schema so restore can load this directly (matches load_settings_items).
  {
    printf 'enabled\tname\tpath\tnotes\tsource\tbundle_id\tkind\tverified\tsize_bytes\tsize_human\n'
    for ((index = 1; index <= SETTING_COUNT; index++)); do
      [[ "${SETTING_SELECTED[index]}" == "1" ]] || continue
      printf 'yes\t%s\t%s\t%s\t%s\t%s\t%s\tyes\t%s\t%s\n' \
        "${SETTING_NAME[index]}" \
        "${SETTING_PATH[index]}" \
        "${SETTING_NOTES[index]}" \
        "${SETTING_SOURCE[index]}" \
        "${SETTING_BUNDLE_ID[index]}" \
        "${SETTING_KIND[index]}" \
        "${SETTING_SIZE_BYTES[index]:-0}" \
        "$(human_size_bytes "${SETTING_SIZE_BYTES[index]:-0}")"
    done
  } >"$out"
}

backup_selected_settings() {
  local dir="$1"
  local index source_path rel_key dest
  local total=0
  local current=0
  local skipped=0
  local failed=0
  local aborted=0
  local metadata_failed=0
  local report="$dir/backup-report.tsv"
  local error_log="$dir/backup-errors.log"
  local old_progress_log="$PROGRESS_FAILURE_LOG"
  local rsync_excludes=()
  local pattern reason

  run_or_print mkdir -p "$dir" || return 1
  if ! $DRY_RUN; then
    write_backup_report_header "$report" || return 1
    : >"$error_log" || return 1
  fi

  copy_settings_manifest_to_backup "$dir" || metadata_failed=1
  write_selected_settings_manifest "$dir" || metadata_failed=1

  for pattern in "${BACKUP_RSYNC_EXCLUDES[@]}"; do
    rsync_excludes+=(--exclude "$pattern")
  done

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] || continue
    source_path="$(expand_path "${SETTING_PATH[index]}")"
    [[ -e "$source_path" ]] || continue
    total=$((total + 1))
  done

  if ((total == 0)); then
    printf 'No selected settings are available to back up.\n'
    ((metadata_failed == 0))
    return $?
  fi

  PROGRESS_FAILURE_LOG="$error_log"
  printf '\nBacking up selected settings...\n'

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] || continue

    source_path="$(expand_path "${SETTING_PATH[index]}")"
    rel_key="$(relative_key_for_path "$source_path")"
    dest="$dir/files/$rel_key"

    if [[ ! -e "$source_path" ]]; then
      printf 'Skipping missing: %s (%s)\n' "${SETTING_NAME[index]}" "$source_path"
      skipped=$((skipped + 1))
      append_backup_report_row "$report" "skipped" "${SETTING_NAME[index]}" "$source_path" "" "missing locally"
      continue
    fi

    current=$((current + 1))
    draw_progress_line "$current" "$total" "${SETTING_NAME[index]}" "Backing up"
    if ! run_or_print mkdir -p "$(dirname "$dest")"; then
      failed=$((failed + 1))
      append_backup_report_row "$report" "failed" "${SETTING_NAME[index]}" "$source_path" "$dest" "could not create destination folder"
      continue
    fi

    if [[ -d "$source_path" && ! -L "$source_path" ]]; then
      if run_with_progress_line "$current" "$total" "${SETTING_NAME[index]}" "Backing up" \
        rsync -aE --delete --delete-excluded "${rsync_excludes[@]}" "$source_path/" "$dest/"; then
        append_backup_report_row "$report" "ok" "${SETTING_NAME[index]}" "$source_path" "$dest" "copied"
      else
        failed=$((failed + 1))
        reason="$(copy_error_label "$PROGRESS_LAST_ERROR_CLASS")"
        append_backup_report_row "$report" "failed" "${SETTING_NAME[index]}" "$source_path" "$dest" "$reason"
        if [[ "$PROGRESS_LAST_ERROR_CLASS" == "no_space" ]]; then
          aborted=1
          break
        fi
      fi
    else
      if run_with_progress_line "$current" "$total" "${SETTING_NAME[index]}" "Backing up" \
        rsync -aE "${rsync_excludes[@]}" "$source_path" "$dest"; then
        append_backup_report_row "$report" "ok" "${SETTING_NAME[index]}" "$source_path" "$dest" "copied"
      else
        failed=$((failed + 1))
        reason="$(copy_error_label "$PROGRESS_LAST_ERROR_CLASS")"
        append_backup_report_row "$report" "failed" "${SETTING_NAME[index]}" "$source_path" "$dest" "$reason"
        if [[ "$PROGRESS_LAST_ERROR_CLASS" == "no_space" ]]; then
          aborted=1
          break
        fi
      fi
    fi
  done

  PROGRESS_FAILURE_LOG="$old_progress_log"

  draw_progress_line "$current" "$total" "Complete" "Backed up"
  finish_progress_line
  if ((metadata_failed > 0)); then
    printf 'Failed to copy one or more metadata files.\n'
  fi
  if ((skipped > 0)); then
    printf 'Skipped %d missing setting(s).\n' "$skipped"
  fi
  if ((failed > 0)); then
    printf 'Failed to copy %d setting(s).\n' "$failed"
    printf 'Backup report: %s\n' "$report"
    printf 'Error log: %s\n' "$error_log"
  fi
  if ((aborted > 0)); then
    printf 'Backup stopped early because the destination ran out of space.\n'
  fi
  ((failed == 0 && metadata_failed == 0 && aborted == 0))
}

restore_selected_settings() {
  local dir="$1"
  local index target_path rel_key source

  for ((index = 1; index <= SETTING_COUNT; index++)); do
    [[ "${SETTING_SELECTED[index]}" == "1" ]] || continue

    target_path="$(expand_path "${SETTING_PATH[index]}")"
    rel_key="$(relative_key_for_path "$target_path")"
    source="$dir/files/$rel_key"

    if [[ ! -e "$source" ]]; then
      printf 'Skipping missing backup: %s (%s)\n' "${SETTING_NAME[index]}" "$source"
      continue
    fi

    printf 'Restoring: %s\n' "${SETTING_NAME[index]}"
    run_or_print mkdir -p "$(dirname "$target_path")"

    if [[ -d "$source" && ! -L "$source" ]]; then
      run_or_print rsync -aE "$source/" "$target_path/"
    else
      run_or_print rsync -aE "$source" "$target_path"
    fi
  done
}

prompt_backup_profile() {
  local answer

  printf '\nBackup profile name [%s]: ' "$PROFILE_NAME"
  IFS= read -r answer
  answer="$(trim_spaces "$answer")"
  [[ -n "$answer" ]] && PROFILE_NAME="$answer"
}

load_backup_profiles() {
  local dir profile

  BACKUP_PROFILES=()
  [[ -d "$BACKUP_ROOT" ]] || return 0

  while IFS= read -r dir; do
    profile="$(basename "$(dirname "$dir")")"
    BACKUP_PROFILES+=("$profile")
  done < <(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type d -name latest -print 2>/dev/null | sort)
}

choose_restore_profile() {
  local choice profile index

  load_backup_profiles

  if ((${#BACKUP_PROFILES[@]} > 0)); then
    printf '\nAvailable backups in %s:\n' "$BACKUP_ROOT"
    for ((index = 0; index < ${#BACKUP_PROFILES[@]}; index++)); do
      printf '  %d  %s\n' "$((index + 1))" "${BACKUP_PROFILES[index]}"
    done
    printf '  M  Type profile manually\n'
    printf '  B  Back\n'
    printf '\nRestore profile [1]: '
    IFS= read -r choice
    choice="$(trim_spaces "$choice")"
    choice="${choice:-1}"

    case "$(lowercase "$choice")" in
      b|back|q|quit)
        return 1
        ;;
      m|manual)
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#BACKUP_PROFILES[@]})); then
          PROFILE_NAME="${BACKUP_PROFILES[choice - 1]}"
          return 0
        fi
        printf 'Unknown profile selection: %s\n' "$choice"
        return 1
        ;;
    esac
  else
    printf '\nNo backup profiles found under %s.\n' "$BACKUP_ROOT"
  fi

  printf 'Profile name [%s]: ' "$PROFILE_NAME"
  IFS= read -r profile
  profile="$(trim_spaces "$profile")"
  [[ -n "$profile" ]] && PROFILE_NAME="$profile"
  return 0
}

backup_settings_flow() {
  local dir

  header "Backup Settings"
  printf 'Backup root: %s\n' "$BACKUP_ROOT"
  if [[ -f "$SETTINGS_REVIEWED" ]]; then
    printf 'Using reviewed settings list: %s\n' "$SETTINGS_REVIEWED"
  else
    printf 'Scanning this Mac for settings (this can take a moment)...\n'
    scan_settings_manifest || printf '[INFO] Continuing with the existing settings manifest.\n'
  fi
  require_file "$(active_settings_manifest)" "Settings manifest"
  prompt_backup_profile
  dir="$(backup_dir)"
  printf 'Backup target: %s\n' "$dir"

  load_settings_items
  review_settings_selection backup || return 0
  print_backup_size_estimate
  print_backup_filter_note
  if ! backup_space_preflight "$dir"; then
    printf 'Backup cancelled.\n'
    return 0
  fi

  if confirm "Back up selected settings?"; then
    if backup_selected_settings "$dir"; then
      printf '\nBackup flow complete.\n'
      prompt_open_backup_folder "$dir"
    else
      printf '\nBackup flow completed with errors.\n'
      prompt_open_backup_folder "$dir"
    fi
  else
    printf 'Backup cancelled.\n'
  fi
}

restore_source_manifest() {
  # Prefer the manifest saved inside the backup (the list of what was actually
  # backed up) so restore offers every backed-up item regardless of what is
  # installed on this Mac. Fall back to older backups, then the local manifest.
  local dir="$1"
  if [[ -f "$dir/selected-settings.tsv" ]]; then
    printf '%s' "$dir/selected-settings.tsv"
  elif [[ -f "$dir/manifest.tsv" ]]; then
    printf '%s' "$dir/manifest.tsv"
  else
    printf '%s' "$(active_settings_manifest)"
  fi
}

restore_settings_flow() {
  local dir

  require_file "$(active_settings_manifest)" "Settings manifest"

  header "Restore Settings"
  choose_restore_profile || return 0
  dir="$(backup_dir)"
  printf 'Restore source: %s\n' "$dir"

  # Restore from the backup's own manifest, not the local one, so every backed-up
  # item is offered even when the matching app is not installed on this Mac.
  load_settings_items "$(restore_source_manifest "$dir")"
  review_settings_selection restore || return 0

  if confirm "Restore selected settings to this Mac?"; then
    restore_selected_settings "$dir"
    printf '\nRestore flow complete.\n'
  else
    printf 'Restore cancelled.\n'
  fi
}

list_backups_flow() {
  local root="$BACKUP_ROOT"
  local found=false
  local dir

  header "Available Backups"
  printf 'Backup root: %s\n' "$root"

  if [[ ! -d "$root" ]]; then
    printf 'No backup root found yet.\n'
    return 0
  fi

  while IFS= read -r dir; do
    found=true
    printf '  - %s\n' "$(basename "$(dirname "$dir")")"
    printf '    %s\n' "$dir"
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -name latest -print 2>/dev/null | sort)

  $found || printf 'No backup profiles found yet.\n'
}

backup_path_size() {
  local path="$1"
  local size

  [[ -d "$path" ]] || { printf '?'; return; }
  if size="$(du -sh "$path" 2>/dev/null | awk 'NR==1{print $1}')" && [[ -n "$size" ]]; then
    printf '%s' "$size"
  else
    printf '?'
  fi
}

remove_backup_dir() {
  local target="$1"

  # Safety: only ever delete a profile directory strictly inside the backup root.
  if [[ -z "$BACKUP_ROOT" ]]; then
    printf '[ERROR] Backup root is not set; refusing to remove anything.\n' >&2
    return 1
  fi

  case "$target" in
    "$BACKUP_ROOT"/?*) ;;
    *)
      printf '[ERROR] Refusing to remove path outside backup root: %s\n' "$target" >&2
      return 1
      ;;
  esac

  if [[ ! -d "$target" ]]; then
    printf '[WARN] Not a backup directory, skipping: %s\n' "$target"
    return 1
  fi

  run_or_print rm -rf "$target"
}

remove_backups_flow() {
  local choice index profile target
  local targets=()

  header "Remove Backups"
  printf 'Backup root: %s\n' "$BACKUP_ROOT"

  if [[ ! -d "$BACKUP_ROOT" ]]; then
    printf 'No backup root found. Nothing to remove.\n'
    return 0
  fi

  load_backup_profiles
  if ((${#BACKUP_PROFILES[@]} == 0)); then
    printf 'No backup profiles found under %s.\n' "$BACKUP_ROOT"
    return 0
  fi

  printf '\nAvailable backups:\n'
  for ((index = 0; index < ${#BACKUP_PROFILES[@]}; index++)); do
    profile="${BACKUP_PROFILES[index]}"
    printf '  %d  %-24s  %s\n' "$((index + 1))" "$profile" "$(backup_path_size "$BACKUP_ROOT/$profile")"
  done
  printf '  A  Remove ALL profiles\n'
  printf '  B  Back (default)\n'

  printf '\nRemove which backup? [B]: '
  IFS= read -r choice
  choice="$(lowercase "$(trim_spaces "$choice")")"

  case "$choice" in
    ""|b|back|q|quit)
      printf 'No backups removed.\n'
      return 0
      ;;
    a|all)
      for profile in "${BACKUP_PROFILES[@]}"; do
        targets+=("$BACKUP_ROOT/$profile")
      done
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#BACKUP_PROFILES[@]})); then
        targets+=("$BACKUP_ROOT/${BACKUP_PROFILES[choice - 1]}")
      else
        printf 'Unknown selection: %s\n' "$choice"
        return 0
      fi
      ;;
  esac

  printf '\nThe following backup(s) will be permanently removed:\n'
  for target in "${targets[@]}"; do
    printf '  - %s  (%s)\n' "$target" "$(backup_path_size "$target")"
  done

  if confirm "Permanently delete the backup(s) listed above?"; then
    for target in "${targets[@]}"; do
      remove_backup_dir "$target"
    done
    printf '\nBackup removal complete.\n'
  else
    printf 'No backups removed.\n'
  fi
}

load_backup_location() {
  local line

  [[ -f "$BACKUP_LOCATION_CONFIG" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_spaces "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s' "$line"
    return 0
  done <"$BACKUP_LOCATION_CONFIG"

  return 1
}

save_backup_location() {
  printf '%s\n' "$1" >"$BACKUP_LOCATION_CONFIG"
}

resolve_backup_root() {
  # Honor an explicit --root flag or env value; otherwise use the saved
  # location, then fall back to the iCloud default.
  [[ -n "$BACKUP_ROOT" ]] && return 0

  local saved
  if saved="$(load_backup_location)" && [[ -n "$saved" ]]; then
    BACKUP_ROOT="$saved"
    return 0
  fi

  BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
}

detect_backup_providers() {
  # Emit "label<TAB>backup_root" lines for cloud folders present on this Mac.
  local cloud="$HOME/Library/CloudStorage"
  local icloud="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
  local dir base

  [[ -d "$icloud" ]] && printf 'iCloud Drive\t%s\n' "$icloud/Backup/MacSettings"

  if [[ -d "$cloud" ]]; then
    for dir in "$cloud"/Dropbox* "$cloud"/OneDrive* "$cloud"/GoogleDrive*; do
      [[ -d "$dir" ]] || continue
      base="$(basename "$dir")"
      case "$base" in
        GoogleDrive*) printf '%s\t%s\n' "$base" "$dir/My Drive/Backup/MacSettings" ;;
        *) printf '%s\t%s\n' "$base" "$dir/Backup/MacSettings" ;;
      esac
    done
  fi

  [[ -d "$HOME/Dropbox" ]] && printf 'Dropbox (home)\t%s\n' "$HOME/Dropbox/Backup/MacSettings"
}

set_backup_location() {
  local new_root="$1"

  BACKUP_ROOT="$new_root"

  if $DRY_RUN; then
    printf '\nDRY RUN: would set backup location to:\n  %s\n' "$new_root"
    printf 'DRY RUN: would save it to %s\n' "$BACKUP_LOCATION_CONFIG"
    return 0
  fi

  save_backup_location "$new_root"
  printf '\nBackup location set to:\n  %s\n' "$new_root"
  printf 'Saved to %s\n' "$BACKUP_LOCATION_CONFIG"
  printf 'The folder is created the next time you back up.\n'
}

change_backup_location_flow() {
  local labels=() paths=()
  local label path choice custom index

  header "Change Backup Location"
  printf 'Current backup location:\n  %s\n' "$BACKUP_ROOT"

  while IFS=$'\t' read -r label path; do
    [[ -n "$path" ]] || continue
    labels+=("$label")
    paths+=("$path")
  done < <(detect_backup_providers)

  printf '\nChoose a backup location:\n'
  if ((${#paths[@]} == 0)); then
    printf '  (no cloud folders detected under ~/Library/CloudStorage)\n'
  else
    for ((index = 0; index < ${#paths[@]}; index++)); do
      printf '  %d  %-16s  %s\n' "$((index + 1))" "${labels[index]}" "${paths[index]}"
    done
  fi
  printf '  C  Custom path\n'
  printf '  B  Back (keep current)\n'

  printf '\nSelection [B]: '
  IFS= read -r choice
  choice="$(trim_spaces "$choice")"

  case "$(lowercase "$choice")" in
    ""|b|back|q|quit)
      printf 'Backup location unchanged.\n'
      return 0
      ;;
    c|custom)
      printf 'Enter full backup folder path: '
      IFS= read -r custom
      custom="$(trim_spaces "$custom")"
      if [[ -z "$custom" ]]; then
        printf 'No path entered. Backup location unchanged.\n'
        return 0
      fi
      set_backup_location "$(expand_path "$custom")"
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#paths[@]})); then
        set_backup_location "${paths[choice - 1]}"
      else
        printf 'Unknown selection: %s\n' "$choice"
        return 0
      fi
      ;;
  esac
}

main_menu() {
  local choice

  while true; do
    header "Mac Setup Wizard"
    cat <<EOF
Catalogs:
  Install apps:   $APP_CATALOG
  Installed apps: $INSTALLED_APPS_CATALOG
  Categories:     $APP_CATEGORY_FILE
  Settings:       $SETTINGS_MANIFEST
  Mackup config:  $(expand_path "$MACKUP_CONFIG")
  Mackup apps:    $MACKUP_SELECTION_FILE
  Backup:         $BACKUP_ROOT

Choose an action:
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

  Q  Quit
EOF

    $DRY_RUN && printf '\nMode: dry run, no changes will be made.\n'

    printf '\nSelection: '
    if ! IFS= read -r choice; then
      printf '\n'
      return 0
    fi
    choice="$(lowercase "$(trim_spaces "$choice")")"

    case "$choice" in
      "")
        continue
        ;;
      1|define|inventory|apps-backup)
        define_apps_to_backup_flow
        ;;
      2|backup)
        backup_settings_flow
        ;;
      3|install|apps)
        install_apps_flow
        ;;
      4|restore)
        restore_settings_flow
        ;;
      5|mackup|mackup-setup)
        mackup_setup_flow
        ;;
      6|mackup-backup)
        mackup_selected_apps_flow backup
        ;;
      7|mackup-restore)
        mackup_selected_apps_flow restore
        ;;
      8|location|backup-location)
        change_backup_location_flow
        ;;
      9|remove|remove-backups|cleanup)
        remove_backups_flow
        ;;
      e|export|export-settings)
        export_settings_for_review_flow
        ;;
      i|import|import-settings)
        import_reviewed_settings_flow
        ;;
      list|backups)
        list_backups_flow
        ;;
      q|quit|exit)
        printf 'Bye.\n'
        return 0
        ;;
      *)
        printf 'Unknown selection: %s\n' "$choice"
        ;;
    esac

    printf '\nPress Return to continue...'
    IFS= read -r _ || return 0
  done
}

resolve_installed_apps_paths() {
  # Option 1 always writes/merges the real (git-ignored) inventory.
  INSTALLED_APPS_REAL="$INSTALLED_APPS_CATALOG"
  # Read-only flows fall back to the shipped example when no real inventory exists.
  if [[ ! -f "$INSTALLED_APPS_CATALOG" && -f "$INSTALLED_APPS_EXAMPLE" ]]; then
    INSTALLED_APPS_CATALOG="$INSTALLED_APPS_EXAMPLE"
  fi
}

main() {
  parse_args "$@"
  resolve_installed_apps_paths
  resolve_backup_root
  init_colors
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
