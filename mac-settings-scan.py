#!/usr/bin/env python3

"""Discover macOS settings to back up by observing the filesystem.

Sources, in order:
  - Filesystem observation keyed by bundle id (from the app catalog): preference
    plists, Application Support folders, and (by default) sandbox Containers.
  - Top-level dotfiles and ~/.config/* entries.
  - A curated manual overlay (the legacy mac-settings.tsv), merged in last.

Core principle: only ever emit a path that actually exists on disk. The output
is a tab-separated manifest the wizard consumes:

    enabled  name  path  notes  source  bundle_id  kind  verified  size_bytes  size_human
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HOME = Path.home()
LIBRARY = HOME / "Library"

# Paths containing any of these are never offered.
DEFAULT_DENY = [
    "/Library/Caches/",
    "/Saved Application State/",
    "/Library/Logs/",
    "CrashReporter",
    "/Crashpad/",
    "/Crash Reports/",
    "/Library/Cookies/",
    "/Library/HTTPStorages/",
    "/WebsiteData/",
    "/CacheStorage/",
    "/Code Cache/",
    "/GPUCache/",
    "/ShaderCache/",
    "/Service Worker/ScriptCache/",
    "/Service Worker/CacheStorage/",
    "/blob_storage/",
    "/sockets/",
    "/vms/",
    ".Docker.raw",
    ".qcow2",
    ".vmdk",
]

# Top-level dotfiles worth backing up (relative to $HOME).
DOTFILES = [
    (".zshrc", "Shell zshrc"),
    (".zprofile", "Shell zprofile"),
    (".zshenv", "Shell zshenv"),
    (".bashrc", "Shell bashrc"),
    (".bash_profile", "Shell bash profile"),
    (".profile", "Shell profile"),
    (".gitconfig", "Git config"),
    (".gitignore_global", "Git global ignore"),
    (".inputrc", "Readline config"),
    (".vimrc", "Vim config"),
    (".tmux.conf", "tmux config"),
    (".ssh/config", "SSH config"),
]


@dataclass
class Row:
    enabled: str
    name: str
    path: str  # tilde form for portability
    notes: str
    source: str
    bundle_id: str
    kind: str
    verified: str
    size_bytes: int = 0


# --- pure helpers (unit-tested) ----------------------------------------------

def tilde(path: object) -> str:
    text = str(path)
    home = str(HOME)
    if text == home:
        return "~"
    if text.startswith(home + "/"):
        return "~/" + text[len(home) + 1 :]
    return text


def norm(value: str) -> str:
    return "".join(ch for ch in value.lower() if ch.isalnum())


def is_denied(path_str: str, deny: list[str]) -> bool:
    return any(token in path_str for token in deny)


def keys_match(left: str, right: str) -> bool:
    if not left or not right:
        return False
    if left == right:
        return True
    if len(left) >= 4 and len(right) >= 4:
        return left in right or right in left
    return False


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit in ("B", "KB") else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def clean_cell(value: object) -> str:
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


# --- filesystem ---------------------------------------------------------------

def du_bytes(path: Path) -> int:
    try:
        result = subprocess.run(
            ["du", "-sk", str(path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout:
            return int(result.stdout.split("\t", 1)[0].split()[0]) * 1024
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    try:
        return path.stat().st_size if path.is_file() else 0
    except OSError:
        return 0


def app_candidates(name: str, bundle_id: str, include_containers: bool) -> list[tuple[str, Path]]:
    prefs = LIBRARY / "Preferences"
    appsup = LIBRARY / "Application Support"
    containers = LIBRARY / "Containers"

    out: list[tuple[str, Path]] = []
    if bundle_id:
        out.append(("pref", prefs / f"{bundle_id}.plist"))
        try:
            for variant in sorted(prefs.glob(f"{bundle_id}*.plist")):
                out.append(("pref", variant))
        except OSError:
            pass
        if include_containers:
            out.append(("container", containers / bundle_id / "Data"))
    if name:
        out.append(("appsupport", appsup / name))
    if bundle_id:
        out.append(("appsupport", appsup / bundle_id))
    return out


def load_apps(path: Path) -> list[tuple[str, str]]:
    apps: list[tuple[str, str]] = []
    if not path.exists():
        return apps
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            name = clean_cell(row.get("name", ""))
            bundle = clean_cell(row.get("bundle_id", ""))
            if name or bundle:
                apps.append((name, bundle))
    return apps


def load_overlay(path: Path) -> list[Row]:
    """Load the curated manual manifest (4-col legacy or generated format)."""
    rows: list[Row] = []
    if not path.exists():
        return rows
    with path.open(newline="", encoding="utf-8") as handle:
        for raw in csv.DictReader(handle, delimiter="\t"):
            manifest_path = clean_cell(raw.get("path", ""))
            if not manifest_path:
                continue
            size_bytes = 0
            raw_size = clean_cell(raw.get("size_bytes", ""))
            if raw_size.isdigit():
                size_bytes = int(raw_size)
            else:
                expanded = expand_tilde(manifest_path)
                if expanded.exists():
                    size_bytes = du_bytes(expanded)
            rows.append(
                Row(
                    enabled=clean_cell(raw.get("enabled", "")) or "yes",
                    name=clean_cell(raw.get("name", "")),
                    path=manifest_path,
                    notes=clean_cell(raw.get("notes", "")),
                    source=clean_cell(raw.get("source", "")) or "manual",
                    bundle_id=clean_cell(raw.get("bundle_id", "")),
                    kind=clean_cell(raw.get("kind", "")) or "manual",
                    verified=clean_cell(raw.get("verified", "")) or "yes",
                    size_bytes=size_bytes,
                )
            )
    return rows


def load_mackup_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def app_covered_by_mackup(name: str, bundle_id: str, mackup_ids: set[str]) -> bool:
    name_key = norm(name)
    bundle_key = norm(bundle_id.split(".")[-1]) if bundle_id else ""
    for mackup_id in mackup_ids:
        id_key = norm(mackup_id)
        if keys_match(name_key, id_key) or (bundle_key and keys_match(bundle_key, id_key)):
            return True
    return False


def attribute_dotfile(child_name: str, apps: list[tuple[str, str]]) -> tuple[str, str]:
    """Best-effort owner for a ~/.config child: returns (name, bundle_id)."""
    key = norm(child_name)
    for name, bundle in apps:
        if keys_match(key, norm(name)) or keys_match(key, norm(bundle)):
            return name, bundle
    return "", ""


# --- scan ---------------------------------------------------------------------

def scan(
    apps: list[tuple[str, str]],
    overlay: list[Row],
    deny: list[str],
    size_flag_bytes: int,
    include_containers: bool,
) -> list[Row]:
    rows: list[Row] = []
    seen: set[str] = set()

    def add(kind: str, path: Path, name: str, bundle_id: str) -> None:
        resolved = str(path)
        if resolved in seen:
            return
        try:
            if not path.exists():
                return
        except OSError:
            return
        if is_denied(resolved, deny):
            return
        seen.add(resolved)

        enabled = "yes"
        label = f"{name} ({kind})" if name else kind
        notes = f"{kind} for {name}" if name else f"{kind} config"
        size = du_bytes(path)
        if size_flag_bytes and size >= size_flag_bytes:
            enabled = "no"
            notes = f"large ~{human(size)}; enable manually if wanted. {notes}"
        rows.append(Row(enabled, label, tilde(path), notes, "fs", bundle_id, kind, "yes", size))

    for name, bundle_id in apps:
        for kind, path in app_candidates(name, bundle_id, include_containers):
            add(kind, path, name, bundle_id)

    for rel, label in DOTFILES:
        add("dotfile", HOME / rel, label, "")

    config_dir = HOME / ".config"
    if config_dir.is_dir():
        try:
            children = sorted(config_dir.iterdir(), key=lambda p: p.name.casefold())
        except OSError:
            children = []
        for child in children:
            name, bundle = attribute_dotfile(child.name, apps)
            add("dotfile", child, name or f".config/{child.name}", bundle)

    # Merge curated manual rows last; skip any whose path is already covered.
    for row in overlay:
        expanded = str(Path(row.path.replace("~", str(HOME), 1)) if row.path.startswith("~") else Path(row.path))
        if expanded in seen:
            continue
        seen.add(expanded)
        rows.append(row)

    return rows


def write_manifest(path: Path, rows: list[Row]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(
            [
                "enabled",
                "name",
                "path",
                "notes",
                "source",
                "bundle_id",
                "kind",
                "verified",
                "size_bytes",
                "size_human",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row.enabled,
                    row.name,
                    row.path,
                    row.notes,
                    row.source,
                    row.bundle_id,
                    row.kind,
                    row.verified,
                    row.size_bytes,
                    human(row.size_bytes),
                ]
            )


def expand_tilde(text: str) -> Path:
    if text == "~":
        return HOME
    if text.startswith("~/"):
        return HOME / text[2:]
    return Path(text)


def write_candidates(path: Path, rows: list[Row], apps: list[tuple[str, str]]) -> None:
    """Write a review TSV for an LLM to curate (keep/reason) and fill gaps."""
    found_bundles = {row.bundle_id for row in rows if row.bundle_id}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(
            ["app_name", "bundle_id", "source", "kind", "found_path", "size_human", "keep", "reason"]
        )
        for row in rows:
            writer.writerow(
                [row.name, row.bundle_id, row.source, row.kind, row.path, human(row.size_bytes), "", ""]
            )
        for name, bundle in apps:
            if bundle and bundle not in found_bundles:
                writer.writerow([name, bundle, "fs", "", "(none found)", "-", "", ""])


def import_candidates(path: Path) -> list[Row]:
    """Read an LLM-reviewed candidate TSV into manifest rows.

    keep=no drops a row. Rows proposed by the LLM (source=llm) are re-checked
    against the filesystem: missing paths are kept but disabled and verified=no.
    """
    rows: list[Row] = []
    with path.open(newline="", encoding="utf-8") as handle:
        for raw in csv.DictReader(handle, delimiter="\t"):
            keep = clean_cell(raw.get("keep", "")).lower()
            if keep in ("no", "n", "0", "skip", "drop"):
                continue
            found = clean_cell(raw.get("found_path", ""))
            if not found or found.startswith("(none"):
                continue

            name = clean_cell(raw.get("app_name", ""))
            bundle = clean_cell(raw.get("bundle_id", ""))
            source = clean_cell(raw.get("source", "")) or "fs"
            kind = clean_cell(raw.get("kind", "")) or "manual"
            reason = clean_cell(raw.get("reason", ""))

            exists = expand_tilde(found).exists()
            verified = "yes" if (exists or source != "llm") else "no"
            enabled = "yes" if exists else "no"
            label = f"{name} ({kind})" if name and kind != "manual" else (name or kind)
            notes = reason or (f"{kind} for {name}" if name else kind)
            size_bytes = du_bytes(expand_tilde(found)) if exists else 0
            rows.append(Row(enabled, label, found, notes, source, bundle, kind, verified, size_bytes))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Discover macOS settings to back up.")
    parser.add_argument("--apps", required=True, help="Installed-app catalog TSV (name, bundle_id).")
    parser.add_argument("--overlay", help="Curated manual settings TSV to merge in.")
    parser.add_argument("--output", help="Where to write the generated manifest TSV.")
    parser.add_argument("--skip-containers", action="store_true", help="Skip ~/Library/Containers.")
    parser.add_argument(
        "--mackup-ids", help="File of Mackup app ids; matching apps are deferred to Mackup."
    )
    parser.add_argument(
        "--size-flag-mb",
        type=int,
        default=250,
        help="Folders at/above this size are flagged disabled (0 disables the check).",
    )
    parser.add_argument("--check", action="store_true", help="Print counts only; do not write.")
    parser.add_argument("--export-candidates", help="Write an LLM review TSV and exit.")
    parser.add_argument(
        "--import-candidates", help="Read a reviewed TSV; write the manifest to --output."
    )
    args = parser.parse_args()

    if args.import_candidates:
        if not args.output:
            parser.error("--import-candidates requires --output")
        rows = import_candidates(Path(args.import_candidates))
        write_manifest(Path(args.output), rows)
        unverified = sum(1 for row in rows if row.verified == "no")
        print(f"Imported {len(rows)} settings ({unverified} proposed/unverified) to {args.output}")
        return 0

    apps = load_apps(Path(args.apps))
    mackup_ids = load_mackup_ids(Path(args.mackup_ids)) if args.mackup_ids else set()
    if mackup_ids:
        kept, deferred = [], []
        for name, bundle in apps:
            (deferred if app_covered_by_mackup(name, bundle, mackup_ids) else kept).append((name, bundle))
        apps = kept
        if deferred:
            names = ", ".join(sorted({name for name, _ in deferred if name}))
            print(f"Deferred to Mackup ({len(deferred)}): {names}", file=sys.stderr)

    overlay = load_overlay(Path(args.overlay)) if args.overlay else []
    size_flag_bytes = args.size_flag_mb * 1024 * 1024 if args.size_flag_mb else 0

    rows = scan(
        apps=apps,
        overlay=overlay,
        deny=DEFAULT_DENY,
        size_flag_bytes=size_flag_bytes,
        include_containers=not args.skip_containers,
    )

    if args.export_candidates:
        write_candidates(Path(args.export_candidates), rows, apps)
        gaps = sum(1 for name, bundle in apps if bundle and bundle not in {r.bundle_id for r in rows if r.bundle_id})
        print(f"Wrote {len(rows)} candidates (+{gaps} gap rows) to {args.export_candidates}")
        return 0

    if args.check or not args.output:
        by_kind: dict[str, int] = {}
        for row in rows:
            by_kind[row.kind] = by_kind.get(row.kind, 0) + 1
        enabled = sum(1 for row in rows if row.enabled.lower() in ("yes", "y", "true", "1"))
        print(f"settings={len(rows)}")
        print(f"enabled={enabled}")
        for kind in sorted(by_kind):
            print(f"{kind}={by_kind[kind]}")
        if not args.output:
            return 0

    write_manifest(Path(args.output), rows)
    print(f"Wrote {len(rows)} settings rows to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
