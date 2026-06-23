#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import curses
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


DEFAULT_CATEGORIES = [
    (1, "essential", "Essential", "everyday,essentials"),
    (2, "productivity", "Productivity", "prod,utility,utilities"),
    (3, "ai", "AI", "artificial-intelligence"),
    (4, "dev", "Dev", "development,developer,coding"),
    (5, "music", "Music", "audio"),
    (6, "design", "Design", "graphic,graphics"),
    (7, "video", "Video", "media,film"),
    (8, "game", "Game", "games,gaming"),
    (9, "work", "Work", "business"),
]

SHIFT_UP = -1001
SHIFT_DOWN = -1002
FINDER_TAG_COLORS = {
    "1": "Gray",
    "2": "Green",
    "3": "Purple",
    "4": "Blue",
    "5": "Yellow",
    "6": "Red",
    "7": "Orange",
}

BACKUP_NOISE_APP_TERMS = (
    "uninstall",
    "uninstaller",
    "installer",
    "setup",
    "remove",
    "updater",
    "autoupdate",
    "auto update",
)


@dataclass(frozen=True)
class Category:
    number: int
    key: str
    label: str
    aliases: tuple[str, ...]


@dataclass
class InstalledApp:
    name: str
    bundle_id: str
    path: str
    size_bytes: int
    tags: list[str]
    updated_ts: float
    category: str = ""
    mas_id: str = ""
    cask: str = ""

    @property
    def size_human(self) -> str:
        return human_size(self.size_bytes)

    @property
    def tag_text(self) -> str:
        return ", ".join(self.tags)

    @property
    def updated_text(self) -> str:
        if self.updated_ts <= 0:
            return ""
        return datetime.fromtimestamp(self.updated_ts).strftime("%Y-%m-%d")


def clean_cell(value: object) -> str:
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit in {"B", "KB"}:
                return f"{value:.0f} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def parse_int(value: str, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def parse_date(value: str) -> float:
    value = value.strip()
    if not value:
        return 0.0
    try:
        return datetime.strptime(value, "%Y-%m-%d").timestamp()
    except ValueError:
        return 0.0


def compact_key(value: str) -> str:
    return "".join(char for char in value.casefold() if char.isalnum())


def is_backup_noise_app_name(name: str, path: str = "") -> bool:
    name_text = clean_cell(name).casefold()
    path_name = Path(path).stem.casefold() if path else ""
    text = " ".join(part for part in (name_text, path_name) if part)
    compact = compact_key(text)
    return (
        any(term in text for term in BACKUP_NOISE_APP_TERMS)
        or "autoupdate" in compact
        or compact.startswith("install")
    )


def is_backup_noise_app(app: InstalledApp) -> bool:
    return is_backup_noise_app_name(app.name, app.path)


def ensure_categories_file(path: Path) -> None:
    if path.exists():
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(["number", "key", "label", "aliases"])
        for row in DEFAULT_CATEGORIES:
            writer.writerow(row)


def load_categories(path: Path) -> list[Category]:
    ensure_categories_file(path)
    categories: list[Category] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            number = parse_int(row.get("number", ""))
            key = clean_cell(row.get("key", "")).lower()
            label = clean_cell(row.get("label", "")) or key.title()
            aliases = tuple(
                clean_cell(alias).lower()
                for alias in row.get("aliases", "").split(",")
                if clean_cell(alias)
            )
            if 1 <= number <= 9 and key:
                categories.append(Category(number, key, label, aliases))
    categories.sort(key=lambda category: category.number)
    return categories


def category_lookup(categories: list[Category]) -> dict[str, str]:
    lookup: dict[str, str] = {}
    for category in categories:
        values = [category.key, category.label.lower(), *category.aliases]
        for value in values:
            lookup[value.strip().lower()] = category.key
    return lookup


def normalize_category(value: str, categories: list[Category]) -> str:
    lookup = category_lookup(categories)
    value = clean_cell(value).lower()
    return lookup.get(value, value if value in lookup.values() else "")


def load_existing_categories(path: Path, categories: list[Category]) -> dict[str, str]:
    existing: dict[str, str] = {}
    if not path.exists():
        return existing
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            category = normalize_category(row.get("category", ""), categories)
            if not category:
                continue
            path_key = clean_cell(row.get("path", ""))
            bundle_key = clean_cell(row.get("bundle_id", ""))
            name_key = clean_cell(row.get("name", "")).lower()
            if path_key:
                existing[f"path:{path_key}"] = category
            if bundle_key:
                existing[f"bundle:{bundle_key}"] = category
            if name_key:
                existing[f"name:{name_key}"] = category
    return existing


def load_seed_categories(path: Path | None, categories: list[Category]) -> dict[str, str]:
    seeds: dict[str, str] = {}
    if path is None or not path.exists():
        return seeds
    lookup = category_lookup(categories)
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            name = clean_cell(row.get("name", "")).lower()
            identifier = clean_cell(row.get("identifier", "")).lower()
            first_category = ""
            for raw_category in row.get("categories", "").split(","):
                key = lookup.get(clean_cell(raw_category).lower())
                if key:
                    first_category = key
                    break
            if not first_category:
                continue
            if name:
                seeds[f"name:{name}"] = first_category
            if identifier:
                seeds[f"identifier:{identifier}"] = first_category
    return seeds


def info_plist(path: Path) -> dict:
    info_path = path / "Contents" / "Info.plist"
    if not info_path.exists():
        return {}
    try:
        with info_path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception:
        return {}


def app_display_name(path: Path, info: dict) -> str:
    for key in ("CFBundleDisplayName", "CFBundleName"):
        value = clean_cell(info.get(key, ""))
        if value:
            return value
    return path.stem


def fallback_app_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def app_sizes(paths: list[Path]) -> dict[str, int]:
    if not paths:
        return {}
    try:
        result = subprocess.run(
            ["du", "-sk", *[str(path) for path in paths]],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if result.returncode == 0:
            sizes: dict[str, int] = {}
            for line in result.stdout.splitlines():
                parts = line.split(None, 1)
                if len(parts) == 2:
                    sizes[parts[1]] = parse_int(parts[0]) * 1024
            return sizes
    except OSError:
        pass
    return {str(path): fallback_app_size(path) for path in paths}


def finder_tag_bytes(path: Path) -> bytes | None:
    attr = "com.apple.metadata:_kMDItemUserTags"
    getxattr = getattr(os, "getxattr", None)
    if getxattr is not None:
        try:
            return getxattr(str(path), attr)
        except OSError:
            pass

    try:
        result = subprocess.run(
            ["xattr", "-px", attr, str(path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None

    if result.returncode == 0 and result.stdout:
        try:
            return bytes.fromhex(result.stdout.decode("ascii", errors="ignore"))
        except ValueError:
            return None
    return None


def normalize_finder_tag(value: object) -> str:
    raw = "" if value is None else str(value)
    label, _, color = raw.partition("\n")
    label = clean_cell(label)
    color = clean_cell(color)
    if label:
        return label
    return FINDER_TAG_COLORS.get(color, "")


def finder_tags(path: Path) -> list[str]:
    raw = finder_tag_bytes(path)
    if not raw:
        return []
    try:
        values = plistlib.loads(raw)
    except Exception:
        return []

    tags: list[str] = []
    for value in values if isinstance(values, list) else []:
        text = normalize_finder_tag(value)
        if text and text not in tags:
            tags.append(text)
    return tags


def find_apps(app_dirs: list[Path], max_depth: int = 3) -> list[Path]:
    found: dict[str, Path] = {}
    for app_dir in app_dirs:
        expanded = Path(os.path.expanduser(str(app_dir)))
        if not expanded.exists():
            continue
        stack: list[tuple[Path, int]] = [(expanded, 0)]
        while stack:
            current, depth = stack.pop()
            try:
                children = list(current.iterdir())
            except OSError:
                continue
            for child in children:
                if child.suffix == ".app" and child.is_dir():
                    found[str(child)] = child
                    continue
                if depth < max_depth and child.is_dir() and not child.is_symlink():
                    stack.append((child, depth + 1))
    return sorted(found.values(), key=lambda item: item.name.casefold())


def path_under(path: Path, root: Path) -> bool:
    path_text = str(path)
    root_text = str(root)
    return path_text == root_text or path_text.startswith(root_text.rstrip("/") + "/")


def inherited_finder_tags(path: Path, app_dirs: list[Path]) -> list[str]:
    roots = [Path(os.path.expanduser(str(root))) for root in app_dirs]
    parent = path.parent
    while parent != parent.parent:
        if any(path_under(parent, root) for root in roots):
            tags = finder_tags(parent)
            if tags:
                return tags
            if any(parent == root for root in roots):
                break
            parent = parent.parent
            continue
        break
    return []


def scan_apps(
    app_dirs: list[Path],
    existing: dict[str, str],
    seeds: dict[str, str],
) -> list[InstalledApp]:
    apps: list[InstalledApp] = []
    paths = find_apps(app_dirs)
    sizes = app_sizes(paths)
    for path in paths:
        info = info_plist(path)
        name = app_display_name(path, info)
        bundle_id = clean_cell(info.get("CFBundleIdentifier", ""))
        path_text = str(path)
        if is_backup_noise_app_name(name, path_text):
            continue
        name_key = name.lower()
        identifier_key = path.stem.lower()
        category = (
            existing.get(f"path:{path_text}")
            or existing.get(f"bundle:{bundle_id}")
            or existing.get(f"name:{name_key}")
            or seeds.get(f"name:{name_key}")
            or seeds.get(f"identifier:{identifier_key}")
            or ""
        )
        try:
            updated_ts = path.stat().st_mtime
        except OSError:
            updated_ts = 0.0
        apps.append(
            InstalledApp(
                name=name,
                bundle_id=bundle_id,
                path=path_text,
                size_bytes=sizes.get(path_text, fallback_app_size(path)),
                tags=finder_tags(path) or inherited_finder_tags(path, app_dirs),
                updated_ts=updated_ts,
                category=category,
            )
        )
    return apps


def write_apps(path: Path, apps: list[InstalledApp]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(
            [
                "name",
                "bundle_id",
                "path",
                "size_bytes",
                "size_human",
                "finder_tags",
                "last_updated",
                "category",
                "mas_id",
                "cask",
            ]
        )
        filtered = (app for app in apps if not is_backup_noise_app(app))
        for app in sorted(filtered, key=lambda item: item.name.casefold()):
            writer.writerow(
                [
                    app.name,
                    app.bundle_id,
                    app.path,
                    app.size_bytes,
                    app.size_human,
                    app.tag_text,
                    app.updated_text,
                    app.category,
                    app.mas_id,
                    app.cask,
                ]
            )


def load_apps_from_tsv(path: Path) -> list[InstalledApp]:
    apps: list[InstalledApp] = []
    if not path.exists():
        return apps
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            apps.append(
                InstalledApp(
                    name=clean_cell(row.get("name", "")),
                    bundle_id=clean_cell(row.get("bundle_id", "")),
                    path=clean_cell(row.get("path", "")),
                    size_bytes=parse_int(row.get("size_bytes", "")),
                    tags=[
                        clean_cell(tag)
                        for tag in row.get("finder_tags", "").split(",")
                        if clean_cell(tag)
                    ],
                    updated_ts=parse_date(row.get("last_updated", "")),
                    category=clean_cell(row.get("category", "")).lower(),
                    mas_id=clean_cell(row.get("mas_id", "")),
                    cask=clean_cell(row.get("cask", "")),
                )
            )
    return apps


def ai_timeout_seconds() -> int:
    return max(30, parse_int(os.environ.get("MAC_BACKUP_AI_TIMEOUT", ""), 600))


def ai_install_timeout_seconds() -> int:
    return max(60, parse_int(os.environ.get("MAC_BACKUP_AI_INSTALL_TIMEOUT", ""), 900))


def extended_path() -> str:
    paths = [
        os.environ.get("PATH", ""),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        str(Path.home() / ".local" / "bin"),
    ]
    return os.pathsep.join(path for path in paths if path)


def find_executable(name: str) -> str | None:
    executable = shutil.which(name, path=extended_path())
    if executable:
        return executable
    for base in (
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
        Path.home() / ".local" / "bin",
    ):
        candidate = base / name
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def ai_cli_executable(provider: str) -> str | None:
    if provider == "codex":
        return find_executable("codex")
    if provider == "claude":
        return find_executable("claude")
    return None


def ai_response_log_path() -> Path:
    return Path(__file__).with_name("mac-ai-last-response.txt")


def write_ai_response_log(provider: str, output: str, error: str = "") -> Path:
    path = ai_response_log_path()
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        path.write_text(
            "\n".join(
                [
                    f"time\t{timestamp}",
                    f"provider\t{provider}",
                    f"error\t{error}",
                    "",
                    output,
                ]
            ),
            encoding="utf-8",
        )
    except OSError:
        pass
    return path


def first_line(value: str, fallback: str = "") -> str:
    for line in value.splitlines():
        line = line.strip()
        if line:
            return line
    return fallback


def looks_like_auth_error(value: str) -> bool:
    text = value.casefold()
    markers = (
        "failed to authenticate",
        "invalid authentication",
        "api error: 401",
        "authentication required",
        "not logged in",
        "login required",
        "please log in",
    )
    return any(marker in text for marker in markers)


def cli_failure_message(provider: str, stdout: str, stderr: str, default: str) -> str:
    combined = "\n".join(part for part in (stdout, stderr) if part)
    if looks_like_auth_error(combined):
        login = "codex login" if provider == "Codex" else "claude"
        return f"{provider} CLI authentication failed. Run `{login}` in Terminal, then try again."
    detail = first_line(stderr) or first_line(stdout) or default
    return f"{provider} CLI failed: {detail}"


def install_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    env = os.environ.copy()
    env["PATH"] = extended_path()
    if extra:
        env.update(extra)
    return env


def install_command_available(command: list[str]) -> bool:
    if len(command) >= 3 and command[0] in {"/bin/sh", "/bin/bash"} and command[1] == "-c":
        shell_text = command[2]
        if "curl " in shell_text and find_executable("curl") is None:
            return False
        if command[0] == "/bin/bash" and not Path("/bin/bash").exists():
            return False
        return True
    return find_executable(command[0]) is not None


def run_install_command(
    command: list[str],
    env: dict[str, str] | None = None,
) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=ai_install_timeout_seconds(),
            env=env or install_env(),
        )
    except subprocess.TimeoutExpired:
        return False, "timed out"
    except OSError as error:
        return False, str(error)

    combined = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    if result.returncode == 0:
        return True, first_line(combined, "installed")
    return False, first_line(combined, f"exit code {result.returncode}")


def install_ai_cli(provider: str) -> tuple[str, str]:
    existing = ai_cli_executable(provider)
    if existing:
        return existing, ""

    if provider == "codex":
        label = "Codex"
        attempts = [
            (
                [
                    "/bin/sh",
                    "-c",
                    "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh",
                ],
                install_env({"CODEX_NON_INTERACTIVE": "1"}),
                "official standalone installer",
            ),
            ([find_executable("brew") or "brew", "install", "--cask", "codex"], install_env(), "Homebrew cask"),
            ([find_executable("npm") or "npm", "install", "-g", "@openai/codex"], install_env(), "npm package"),
        ]
    elif provider == "claude":
        label = "Claude"
        attempts = [
            (
                ["/bin/bash", "-c", "curl -fsSL https://claude.ai/install.sh | bash"],
                install_env(),
                "official native installer",
            ),
            (
                [find_executable("npm") or "npm", "install", "-g", "@anthropic-ai/claude-code"],
                install_env(),
                "npm package",
            ),
        ]
    else:
        return "", f"Unknown AI provider: {provider}"

    failures: list[str] = []
    for command, env, description in attempts:
        if not install_command_available(command):
            failures.append(f"{description}: required command not found")
            continue
        ok, detail = run_install_command(command, env)
        if ok:
            installed = ai_cli_executable(provider)
            if installed:
                return installed, ""
            failures.append(f"{description}: completed, but `{provider}` was not found on PATH")
        else:
            failures.append(f"{description}: {detail}")

    return (
        "",
        f"{label} CLI was not found and automatic install failed. "
        + " | ".join(failures),
    )


def build_ai_category_prompt(
    apps: list[InstalledApp],
    uncategorized: list[InstalledApp],
    categories: list[Category],
) -> str:
    lines: list[str] = [
        "You are categorizing installed Mac apps for a backup/restore wizard.",
        "Use the user's category names and their existing categorized apps as examples.",
        "Do not use tools. Do not edit files. Do not browse. Return only TSV rows.",
        "",
        "Valid categories:",
        "number\tkey\tlabel\taliases",
    ]
    for category in categories:
        lines.append(
            f"{category.number}\t{category.key}\t{category.label}\t"
            f"{', '.join(category.aliases)}"
        )

    lines.extend(["", "Existing categorized examples:"])
    for category in categories:
        names = [app.name for app in apps if app.category == category.key]
        if names:
            examples = ", ".join(clean_cell(name) for name in names[:60])
            more = "" if len(names) <= 60 else f", and {len(names) - 60} more"
            lines.append(f"{category.key}\t{examples}{more}")

    lines.extend(
        [
            "",
            "Uncategorized apps to classify:",
            "id\tapp_name\tbundle_id\tfinder_tags\tpath",
        ]
    )
    for index, app in enumerate(uncategorized, start=1):
        lines.append(
            "\t".join(
                [
                    str(index),
                    clean_cell(app.name),
                    clean_cell(app.bundle_id),
                    clean_cell(app.tag_text),
                    clean_cell(app.path),
                ]
            )
        )

    lines.extend(
        [
            "",
            "Output rules:",
            "- Output only TSV, no Markdown and no explanation.",
            "- Format every row as: id<TAB>category_key",
            "- category_key must be one of the valid category keys.",
            "- Use skip only for helper apps, drivers, plugins, uninstallers, or apps that should remain uncategorized.",
            "- Do not invent categories.",
        ]
    )
    return "\n".join(lines)


def run_codex_category_help(prompt: str) -> tuple[str, str]:
    executable, install_error = install_ai_cli("codex")
    if install_error:
        return "", install_error

    output_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile("w+", delete=False) as handle:
            output_path = Path(handle.name)
        result = subprocess.run(
            [
                executable,
                "exec",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--color",
                "never",
                "--ephemeral",
                "-o",
                str(output_path),
                "-",
            ],
            input=prompt,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=ai_timeout_seconds(),
        )
        output = ""
        if output_path.exists():
            output = output_path.read_text(encoding="utf-8", errors="replace")
        if not output.strip():
            output = result.stdout
        if result.returncode != 0 or looks_like_auth_error(output + result.stderr):
            return "", cli_failure_message("Codex", output, result.stderr, "unknown error")
        return output, ""
    except subprocess.TimeoutExpired:
        return "", "Codex CLI timed out. Set MAC_BACKUP_AI_TIMEOUT to allow more time."
    except OSError as error:
        return "", f"Codex CLI failed: {error}"
    finally:
        if output_path is not None:
            try:
                output_path.unlink()
            except OSError:
                pass


def run_claude_category_help(prompt: str) -> tuple[str, str]:
    executable, install_error = install_ai_cli("claude")
    if install_error:
        return "", install_error

    try:
        result = subprocess.run(
            [
                executable,
                "-p",
                "--input-format",
                "text",
                "--output-format",
                "text",
                "--tools",
                "",
                "--permission-mode",
                "plan",
            ],
            input=prompt,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=ai_timeout_seconds(),
        )
    except subprocess.TimeoutExpired:
        return "", "Claude CLI timed out. Set MAC_BACKUP_AI_TIMEOUT to allow more time."
    except OSError as error:
        return "", f"Claude CLI failed: {error}"

    if result.returncode != 0 or looks_like_auth_error(result.stdout + result.stderr):
        return "", cli_failure_message(
            "Claude",
            result.stdout,
            result.stderr,
            "unknown error",
        )
    return result.stdout, ""


def run_ai_category_help(provider: str, prompt: str) -> tuple[str, str]:
    if provider == "codex":
        return run_codex_category_help(prompt)
    if provider == "claude":
        return run_claude_category_help(prompt)
    return "", f"Unknown AI provider: {provider}"


def parse_ai_category_output(
    output: str,
    categories: list[Category],
) -> tuple[dict[int, str], int, int]:
    valid_keys = {category.key for category in categories}
    suggestions: dict[int, str] = {}
    skipped = 0
    invalid = 0

    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("```") or line.startswith("#"):
            continue
        if line.startswith("|"):
            cells = [clean_cell(cell) for cell in line.strip("|").split("|")]
            if len(cells) < 2 or set(cells[0].replace("-", "").replace(":", "")) == set():
                continue
        else:
            cells = [clean_cell(cell) for cell in line.split("\t")]
            if len(cells) < 2:
                cells = [clean_cell(cell) for cell in line.split(",", 2)[:2]]
            if len(cells) < 2:
                parts = line.split()
                cells = parts[:2]
        if len(cells) < 2:
            continue

        row_id = parse_int(cells[0].lstrip("-* ").rstrip("."), -1)
        if row_id < 1:
            continue

        raw_category = cells[1].strip().strip("`").lower()
        first_token = raw_category.split()[0].strip(",;:") if raw_category else ""
        if first_token in {"skip", "none", "uncategorized", "-", "n/a", "na"}:
            skipped += 1
            continue

        category = normalize_category(raw_category, categories) or normalize_category(
            first_token,
            categories,
        )
        if category in valid_keys:
            suggestions[row_id] = category
        else:
            invalid += 1

    return suggestions, skipped, invalid


class InstalledAppEditor:
    def __init__(self, stdscr, apps: list[InstalledApp], categories: list[Category]):
        self.stdscr = stdscr
        self.apps = apps
        self.categories = categories
        self.selected: set[str] = set()
        self.cursor = 0
        self.scroll = 0
        self.anchor = 0
        self.sort_key = "name"
        self.sort_reverse = False
        self.search = ""
        self.searching = False
        self.message = ""

    def run(self) -> bool:
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        try:
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_GREEN, -1)
            curses.init_pair(2, curses.COLOR_CYAN, -1)
        except curses.error:
            pass
        try:
            curses.set_escdelay(25)
        except Exception:
            pass
        self.stdscr.keypad(True)

        while True:
            self.draw()
            key = self.read_key()
            if self.searching:
                self.handle_search_key(key)
                continue
            result = self.handle_key(key)
            if result == "save":
                return True
            if result == "cancel":
                return False

    def read_key(self) -> int:
        key = self.stdscr.getch()
        if key != 27:
            return key

        seq: list[int] = []
        self.stdscr.nodelay(True)
        for _ in range(8):
            time.sleep(0.002)
            nxt = self.stdscr.getch()
            if nxt == -1:
                break
            seq.append(nxt)
            if 64 <= nxt <= 126:
                if len(seq) >= 2 and seq[0] in (ord("["), ord("O")):
                    break
        self.stdscr.nodelay(False)

        if seq in ([91, 65], [79, 65]):
            return curses.KEY_UP
        if seq in ([91, 66], [79, 66]):
            return curses.KEY_DOWN
        if seq in ([91, 67], [79, 67]):
            return curses.KEY_RIGHT
        if seq in ([91, 68], [79, 68]):
            return curses.KEY_LEFT
        if seq in ([91, 49, 59, 50, 65], [91, 97]):
            return SHIFT_UP
        if seq in ([91, 49, 59, 50, 66], [91, 98]):
            return SHIFT_DOWN
        return 27

    def visible_apps(self) -> list[InstalledApp]:
        apps = self.apps
        if self.search:
            query = self.search.casefold()
            apps = [
                app
                for app in apps
                if query
                in " ".join(
                    [
                        app.name,
                        app.bundle_id,
                        app.path,
                        app.tag_text,
                        self.category_label(app.category),
                    ]
                ).casefold()
            ]
        return sorted(apps, key=self.sort_value, reverse=self.sort_reverse)

    def sort_value(self, app: InstalledApp):
        if self.sort_key == "size":
            return (app.size_bytes, app.name.casefold())
        if self.sort_key == "tag":
            return (app.tag_text.casefold(), app.name.casefold())
        if self.sort_key == "date":
            return (app.updated_ts, app.name.casefold())
        if self.sort_key == "category":
            return (self.category_label(app.category).casefold(), app.name.casefold())
        return app.name.casefold()

    def category_label(self, key: str) -> str:
        for category in self.categories:
            if category.key == key:
                return category.label
        return "-"

    def draw(self) -> None:
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        bold = curses.A_BOLD
        dim = curses.A_DIM
        green = curses.color_pair(1) | curses.A_BOLD
        cyan = curses.color_pair(2)

        visible = self.visible_apps()
        if self.cursor >= len(visible):
            self.cursor = max(0, len(visible) - 1)
        if self.cursor < self.scroll:
            self.scroll = self.cursor

        table_top = 5
        table_bottom = max(table_top + 1, height - 8)
        page_size = max(1, table_bottom - table_top)
        if self.cursor >= self.scroll + page_size:
            self.scroll = self.cursor - page_size + 1

        sort_direction = "Z-A" if self.sort_reverse and self.sort_key == "name" else "A-Z"
        if self.sort_key == "size":
            sort_direction = "large first" if self.sort_reverse else "small first"
        elif self.sort_key == "date":
            sort_direction = "recent first" if self.sort_reverse else "older first"
        elif self.sort_key not in {"name", "size", "date"}:
            sort_direction = "Z-A" if self.sort_reverse else "A-Z"

        self.add(0, 0, "Define Apps to Backup", green)
        self.add(
            1,
            0,
            f"{len(visible)} shown / {len(self.apps)} apps  |  {len(self.selected)} marked  |  Sort: {self.sort_key} ({sort_direction})",
            dim,
        )
        if self.search:
            self.add(2, 0, f"Search: {self.search}", cyan | bold)

        header = f"{'':1} {'':3} {'App':34} {'Size':>9}  {'Tag':16} {'Updated':10} {'Category':14}"
        self.add(4, 0, header[: width - 1], bold)

        for offset, app in enumerate(visible[self.scroll : self.scroll + page_size]):
            row = table_top + offset
            absolute = self.scroll + offset
            marked = "[x]" if app.path in self.selected else "[ ]"
            pointer = ">" if absolute == self.cursor else " "
            attr = curses.A_REVERSE if absolute == self.cursor else curses.A_NORMAL
            line = (
                f"{pointer} {marked} "
                f"{self.fit(app.name, 34):34} "
                f"{app.size_human:>9}  "
                f"{self.fit(app.tag_text or '-', 16):16} "
                f"{app.updated_text:10} "
                f"{self.fit(self.category_label(app.category), 14):14}"
            )
            if app.category:
                attr |= green
            self.add(row, 0, line[: width - 1], attr)

        category_line = "  ".join(
            f"{category.number} {category.label}" for category in self.categories
        )
        self.add(
            height - 7,
            0,
            "[Navigate] Up/Down: move  Shift-Up/Down: toggle while moving  Right/Left: page  /: search",
            dim,
        )
        self.add(
            height - 6,
            0,
            "[Select] Space: mark  A: mark all/none  I: invert  H: AI help",
            dim,
        )
        self.add(
            height - 5,
            0,
            self.sort_help_line(),
            dim,
        )
        self.add(height - 3, 0, category_line[: width - 1], cyan)
        self.add(height - 2, 0, "1-9: assign category  0: clear current  Enter: save  Q/Esc: cancel", dim)
        if self.message:
            self.add(height - 1, 0, self.message[: width - 1], dim)
        self.stdscr.refresh()

    def add(self, y: int, x: int, text: str, attr: int = 0) -> None:
        height, width = self.stdscr.getmaxyx()
        if 0 <= y < height and 0 <= x < width:
            try:
                self.stdscr.addnstr(y, x, text, max(0, width - x - 1), attr)
            except curses.error:
                pass

    @staticmethod
    def fit(text: str, width: int) -> str:
        if len(text) <= width:
            return text
        if width <= 3:
            return text[:width]
        return text[: width - 3] + "..."

    def sort_help_line(self) -> str:
        labels = [
            ("n", "Name", "name"),
            ("s", "Size", "size"),
            ("t", "Tag", "tag"),
            ("d", "Date", "date"),
            ("c", "Category", "category"),
        ]
        parts = [
            f"{key}: {label}{'*' if self.sort_key == sort_key else ''}"
            for key, label, sort_key in labels
        ]
        return "[Sort] " + " / ".join(parts)

    def handle_key(self, key: int):
        if key in (ord("q"), ord("Q"), 27):
            return "cancel"
        if key in (10, 13, curses.KEY_ENTER):
            return "save"
        if key == ord("/"):
            self.searching = True
            self.search = ""
            self.message = "Search: type text, Enter to apply, Esc to clear."
            return None
        if key in (curses.KEY_UP, ord("k"), ord("K")):
            self.move(-1, extend=False)
        elif key in (curses.KEY_DOWN, ord("j"), ord("J")):
            self.move(1, extend=False)
        elif key in (curses.KEY_RIGHT, curses.KEY_NPAGE):
            self.page_move(1)
        elif key in (curses.KEY_LEFT, curses.KEY_PPAGE):
            self.page_move(-1)
        elif key in (SHIFT_UP, getattr(curses, "KEY_SR", None)):
            self.move(-1, extend=True)
        elif key in (SHIFT_DOWN, getattr(curses, "KEY_SF", None)):
            self.move(1, extend=True)
        elif key == ord(" "):
            self.toggle_current()
        elif key in (ord("a"), ord("A")):
            self.toggle_all_visible()
        elif key in (ord("i"), ord("I")):
            for app in self.visible_apps():
                if app.path in self.selected:
                    self.selected.remove(app.path)
                else:
                    self.selected.add(app.path)
            self.message = "Inverted visible marks."
        elif key in (ord("h"), ord("H")):
            self.ai_help()
        elif key in (ord("n"), ord("N")):
            self.set_sort("name")
        elif key in (ord("s"), ord("S")):
            self.set_sort("size")
        elif key in (ord("t"), ord("T")):
            self.set_sort("tag")
        elif key in (ord("d"), ord("D")):
            self.set_sort("date")
        elif key in (ord("c"), ord("C")):
            self.set_sort("category")
        elif key == ord("0"):
            self.clear_current_category()
        elif ord("1") <= key <= ord("9"):
            self.assign_category(chr(key))
        return None

    def handle_search_key(self, key: int) -> None:
        if key == 27:
            self.searching = False
            self.search = ""
            self.cursor = 0
            self.scroll = 0
            self.message = "Search cleared."
        elif key in (10, 13, curses.KEY_ENTER):
            self.searching = False
            self.cursor = 0
            self.scroll = 0
            self.message = f"Search applied: {self.search}" if self.search else "Search cleared."
        elif key in (curses.KEY_BACKSPACE, 127, 8):
            self.search = self.search[:-1]
        elif 32 <= key <= 126:
            self.search += chr(key)

    def move(self, delta: int, extend: bool) -> None:
        visible = self.visible_apps()
        if not visible:
            return
        old_cursor = self.cursor
        self.cursor = min(max(0, self.cursor + delta), len(visible) - 1)
        if extend:
            if self.cursor == old_cursor:
                return
            app = visible[self.cursor]
            if app.path in self.selected:
                self.selected.remove(app.path)
                self.message = f"Unmarked {app.name}."
            else:
                self.selected.add(app.path)
                self.message = f"Marked {app.name}."
        else:
            self.anchor = self.cursor

    def page_size(self) -> int:
        try:
            height, _ = self.stdscr.getmaxyx()
        except AttributeError:
            return 10
        table_top = 5
        table_bottom = max(table_top + 1, height - 8)
        return max(1, table_bottom - table_top)

    def page_move(self, direction: int) -> None:
        visible = self.visible_apps()
        if not visible:
            return
        delta = self.page_size() * direction
        self.cursor = min(max(0, self.cursor + delta), len(visible) - 1)
        self.anchor = self.cursor

    def toggle_current(self) -> None:
        visible = self.visible_apps()
        if not visible:
            return
        app = visible[self.cursor]
        if app.path in self.selected:
            self.selected.remove(app.path)
            self.message = f"Unmarked {app.name}."
        else:
            self.selected.add(app.path)
            self.message = f"Marked {app.name}."

    def toggle_all_visible(self) -> None:
        visible = self.visible_apps()
        if not visible:
            return
        if all(app.path in self.selected for app in visible):
            for app in visible:
                self.selected.remove(app.path)
            self.message = "Unmarked all visible apps."
        else:
            for app in visible:
                self.selected.add(app.path)
            self.message = "Marked all visible apps."

    def target_apps(self) -> list[InstalledApp]:
        if self.selected:
            selected = set(self.selected)
            return [app for app in self.apps if app.path in selected]
        visible = self.visible_apps()
        if not visible:
            return []
        return [visible[self.cursor]]

    def clear_current_category(self) -> None:
        visible = self.visible_apps()
        if not visible:
            return
        app = visible[self.cursor]
        app.category = ""
        self.message = f"Cleared category for {app.name}."

    def assign_category(self, number: str) -> None:
        targets = self.target_apps()
        if not targets:
            return
        category = next(
            (item for item in self.categories if item.number == int(number)),
            None,
        )
        if category is None:
            return
        for app in targets:
            app.category = category.key
        self.message = f"Assigned {category.label} to {len(targets)} app(s)."

    def ai_help(self) -> None:
        uncategorized = [app for app in self.apps if not app.category]
        if not uncategorized:
            self.message = "No blank categories to suggest."
            return

        provider = self.choose_ai_provider(len(uncategorized))
        if not provider:
            self.message = "AI help cancelled."
            return

        self.draw_ai_status(provider, f"Preparing {len(uncategorized)} app(s)...")
        prompt = build_ai_category_prompt(self.apps, uncategorized, self.categories)
        self.draw_ai_status(
            provider,
            "Installing CLI if needed, then waiting for AI response...",
        )
        output, error = self.run_ai_with_progress(provider, prompt)
        log_path = write_ai_response_log(provider, output, error)
        if error:
            self.show_ai_result(
                provider=provider,
                blank_count=len(uncategorized),
                parsed_count=0,
                applied=0,
                skipped=0,
                invalid=0,
                error=error,
                log_path=log_path,
            )
            self.message = error
            return

        suggestions, skipped, invalid = parse_ai_category_output(output, self.categories)
        applied = self.apply_ai_suggestions(uncategorized, suggestions)
        self.show_ai_result(
            provider=provider,
            blank_count=len(uncategorized),
            parsed_count=len(suggestions),
            applied=applied,
            skipped=skipped,
            invalid=invalid,
            error="" if suggestions else "No valid category rows were parsed from the CLI response.",
            log_path=log_path,
        )
        self.message = (
            f"AI help applied {applied} categorization(s)"
            f" ({skipped} skipped, {invalid} invalid)."
        )

    def run_ai_with_progress(self, provider: str, prompt: str) -> tuple[str, str]:
        result = {"output": "", "error": ""}

        def worker() -> None:
            try:
                result["output"], result["error"] = run_ai_category_help(provider, prompt)
            except Exception as error:
                result["output"] = ""
                result["error"] = f"AI helper crashed: {error}"

        thread = threading.Thread(target=worker, daemon=True)
        started = time.monotonic()
        cli_missing = ai_cli_executable(provider) is None
        frame = 0

        thread.start()
        try:
            self.stdscr.nodelay(True)
            while thread.is_alive():
                elapsed = time.monotonic() - started
                status = (
                    "CLI missing. Installing first, then requesting categories..."
                    if cli_missing
                    else "CLI found. Requesting category suggestions..."
                )
                self.draw_ai_progress(provider, status, elapsed, frame)
                frame += 1
                while self.stdscr.getch() != -1:
                    pass
                time.sleep(0.12)
        finally:
            self.stdscr.nodelay(False)

        thread.join(timeout=0)
        self.draw_ai_progress(
            provider,
            "Processing CLI response...",
            time.monotonic() - started,
            frame,
        )
        return result["output"], result["error"]

    def choose_ai_provider(self, app_count: int) -> str:
        while True:
            self.draw_ai_provider_prompt(app_count)
            key = self.read_key()
            if key in (ord("q"), ord("Q"), 27, curses.KEY_BACKSPACE, 127, 8):
                return ""
            if key == ord("1"):
                return "codex"
            if key == ord("2"):
                return "claude"

    def draw_ai_provider_prompt(self, app_count: int) -> None:
        self.stdscr.erase()
        green = curses.color_pair(1) | curses.A_BOLD
        cyan = curses.color_pair(2)
        dim = curses.A_DIM
        self.add(0, 0, "AI Help", green)
        self.add(2, 0, f"{app_count} app(s) have no category.", dim)
        self.add(4, 0, "Let AI help auto-suggest categories for blank apps?", cyan)
        self.add(6, 2, "1  CODEX")
        self.add(7, 2, "2  CLAUDE")
        self.add(9, 0, "Q/Esc/Backspace: cancel", dim)
        self.stdscr.refresh()

    def draw_ai_status(self, provider: str, status: str) -> None:
        self.stdscr.erase()
        green = curses.color_pair(1) | curses.A_BOLD
        dim = curses.A_DIM
        self.add(0, 0, "AI Help", green)
        self.add(2, 0, f"Provider: {provider.upper()}", dim)
        self.add(4, 0, status, dim)
        self.add(6, 0, "The CLI response will be validated before categories are applied.", dim)
        self.stdscr.refresh()

    def draw_ai_progress(
        self,
        provider: str,
        status: str,
        elapsed: float,
        frame: int,
    ) -> None:
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        green = curses.color_pair(1) | curses.A_BOLD
        cyan = curses.color_pair(2)
        dim = curses.A_DIM
        bar_width = max(12, min(46, width - 8))
        self.add(0, 0, "AI Help", green)
        self.add(2, 0, f"Provider: {provider.upper()}", cyan)
        self.add(4, 0, status, dim)
        self.add(6, 0, self.progress_bar(bar_width, frame))
        self.add(8, 0, f"Elapsed: {self.format_elapsed(elapsed)}", dim)
        self.add(
            10,
            0,
            (
                f"Install timeout: {self.format_elapsed(ai_install_timeout_seconds())}  |  "
                f"AI timeout: {self.format_elapsed(ai_timeout_seconds())}"
            )[: max(0, width - 1)],
            dim,
        )
        self.add(12, 0, "The CLI response will be validated before categories are applied.", dim)
        if height > 15:
            self.add(14, 0, "Please wait. Output is captured in the background.", dim)
        self.stdscr.refresh()

    @staticmethod
    def progress_bar(width: int, frame: int) -> str:
        width = max(4, width)
        chunk = max(3, min(10, width // 4))
        span = max(1, width - chunk)
        period = max(1, span * 2)
        position = frame % period
        if position > span:
            position = period - position
        cells = [" "] * width
        for index in range(position, min(width, position + chunk)):
            cells[index] = "="
        return "[" + "".join(cells) + "]"

    @staticmethod
    def format_elapsed(seconds: float) -> str:
        total = max(0, int(seconds))
        minutes, secs = divmod(total, 60)
        hours, minutes = divmod(minutes, 60)
        if hours:
            return f"{hours:d}:{minutes:02d}:{secs:02d}"
        return f"{minutes:02d}:{secs:02d}"

    def show_ai_result(
        self,
        provider: str,
        blank_count: int,
        parsed_count: int,
        applied: int,
        skipped: int,
        invalid: int,
        error: str,
        log_path: Path,
    ) -> None:
        while True:
            self.draw_ai_result(
                provider,
                blank_count,
                parsed_count,
                applied,
                skipped,
                invalid,
                error,
                log_path,
            )
            key = self.read_key()
            if key in (
                10,
                13,
                curses.KEY_ENTER,
                ord(" "),
                ord("q"),
                ord("Q"),
                27,
                curses.KEY_BACKSPACE,
                127,
                8,
            ):
                return

    def draw_ai_result(
        self,
        provider: str,
        blank_count: int,
        parsed_count: int,
        applied: int,
        skipped: int,
        invalid: int,
        error: str,
        log_path: Path,
    ) -> None:
        self.stdscr.erase()
        green = curses.color_pair(1) | curses.A_BOLD
        cyan = curses.color_pair(2)
        dim = curses.A_DIM
        self.add(0, 0, "AI Result", green)
        self.add(2, 0, f"Provider: {provider.upper()}", cyan)
        self.add(4, 2, f"Blank apps sent: {blank_count}")
        self.add(5, 2, f"Parsed suggestions: {parsed_count}")
        self.add(6, 2, f"Applied categories: {applied}")
        self.add(7, 2, f"Skipped rows: {skipped}")
        self.add(8, 2, f"Invalid rows: {invalid}")
        if error:
            self.add(10, 2, f"Problem: {error}", curses.A_BOLD)
        self.add(12, 2, f"Raw CLI response: {log_path}", dim)
        self.add(14, 0, "Return/Space/Esc: back to app list", dim)
        self.stdscr.refresh()

    def apply_ai_suggestions(
        self,
        uncategorized: list[InstalledApp],
        suggestions: dict[int, str],
    ) -> int:
        applied = 0
        for row_id, category in suggestions.items():
            if not 1 <= row_id <= len(uncategorized):
                continue
            app = uncategorized[row_id - 1]
            if app.category:
                continue
            app.category = category
            applied += 1
        return applied

    def set_sort(self, key: str) -> None:
        if self.sort_key == key:
            self.sort_reverse = not self.sort_reverse
        else:
            self.sort_key = key
            self.sort_reverse = key == "date"
        self.cursor = 0
        self.scroll = 0
        self.message = f"Sorted by {key}."


def default_app_dirs(include_system: bool) -> list[Path]:
    dirs = [Path("/Applications"), Path.home() / "Applications"]
    if include_system:
        dirs.extend([Path("/System/Applications"), Path("/System/Applications/Utilities")])
    return dirs


def _app_keys(app: InstalledApp) -> tuple[str, str, str]:
    return (app.bundle_id.strip(), app.path.strip(), app.name.strip().casefold())


def merge_apps(
    existing: list[InstalledApp],
    scanned: list[InstalledApp],
) -> tuple[list[InstalledApp], dict[str, int]]:
    """Combine an existing (possibly multi-Mac) catalog with this Mac's scan.

    Scanned rows win: they carry refreshed metadata plus categories (seeded from
    the existing catalog and/or edited this session). Existing apps that are not
    present on this Mac are retained. Matching is by bundle id, then path, then
    case-folded name.
    """
    existing = [app for app in existing if not is_backup_noise_app(app)]
    scanned = [app for app in scanned if not is_backup_noise_app(app)]

    scanned_bundles = {a.bundle_id for a in scanned if a.bundle_id}
    scanned_paths = {a.path for a in scanned if a.path}
    scanned_names = {a.name.casefold() for a in scanned if a.name}

    def on_this_mac(app: InstalledApp) -> bool:
        bundle, path, name = _app_keys(app)
        return (
            (bundle != "" and bundle in scanned_bundles)
            or (path != "" and path in scanned_paths)
            or (name != "" and name in scanned_names)
        )

    existing_bundles = {a.bundle_id for a in existing if a.bundle_id}
    existing_paths = {a.path for a in existing if a.path}
    existing_names = {a.name.casefold() for a in existing if a.name}

    def in_existing(app: InstalledApp) -> bool:
        bundle, path, name = _app_keys(app)
        return (
            (bundle != "" and bundle in existing_bundles)
            or (path != "" and path in existing_paths)
            or (name != "" and name in existing_names)
        )

    kept = [app for app in existing if not on_this_mac(app)]
    updated = sum(1 for app in scanned if in_existing(app))
    counts = {
        "added": len(scanned) - updated,
        "updated": updated,
        "kept": len(kept),
    }
    return scanned + kept, counts


def prompt_save_mode(existing_count: int) -> str:
    print()
    print(f"An app catalog already exists with {existing_count} app(s).")
    print("  [M] Merge   keep existing apps + categories, add this Mac's apps (recommended)")
    print("  [R] Replace overwrite with only the apps found on this Mac")
    try:
        answer = input("Save mode [M]: ").strip().lower()
    except EOFError:
        answer = ""
    if answer in ("r", "replace"):
        return "replace"
    return "merge"


def _parse_mas_list(text: str) -> dict[str, str]:
    """Map a compact app-name key -> App Store id, from `mas list` output."""
    mapping: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"\s*(\d+)\s+(.*\S)", line)
        if not match:
            continue
        name = re.sub(r"\s*\([^)]*\)\s*$", "", match.group(2)).strip()
        key = compact_key(name)
        if key:
            mapping.setdefault(key, match.group(1))
    return mapping


def _parse_brew_casks(text: str) -> dict[str, str]:
    """Map a compact app-name key -> cask token, from `brew info --json=v2`."""
    mapping: dict[str, str] = {}
    try:
        data = json.loads(text or "{}")
    except json.JSONDecodeError:
        return mapping
    for cask in data.get("casks", []) or []:
        token = clean_cell(cask.get("token", ""))
        if not token:
            continue
        for artifact in cask.get("artifacts", []) or []:
            names: list = []
            if isinstance(artifact, dict):
                names = artifact.get("app", []) or []
            elif isinstance(artifact, list):
                names = artifact
            for app_name in names:
                if isinstance(app_name, str) and app_name.endswith(".app"):
                    key = compact_key(app_name[:-4])
                    if key:
                        mapping.setdefault(key, token)
        mapping.setdefault(compact_key(token), token)
    return mapping


def _command_output(command: list[str], timeout: int) -> str:
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout or ""


def mas_id_map() -> dict[str, str]:
    exe = find_executable("mas")
    return _parse_mas_list(_command_output([exe, "list"], 30)) if exe else {}


def cask_app_map() -> dict[str, str]:
    exe = find_executable("brew")
    if not exe:
        return {}
    return _parse_brew_casks(_command_output([exe, "info", "--json=v2", "--installed"], 120))


def resolve_install_sources(apps: list[InstalledApp]) -> None:
    """Fill mas_id / cask on each app from Homebrew cask metadata and `mas list`,
    so option 3 can bulk-install apps that aren't in the curated catalog. Only
    fills blanks; never overwrites values already present (e.g. merged rows)."""
    casks = cask_app_map()
    mas = mas_id_map()
    if not casks and not mas:
        return
    for app in apps:
        name_key = compact_key(app.name)
        stem_key = compact_key(Path(app.path).stem) if app.path else ""
        if not app.cask:
            app.cask = casks.get(name_key) or (casks.get(stem_key, "") if stem_key else "")
        if not app.mas_id:
            app.mas_id = mas.get(name_key) or (mas.get(stem_key, "") if stem_key else "")


def main() -> int:
    parser = argparse.ArgumentParser(description="Define installed Mac apps and categories.")
    parser.add_argument("--output", required=True, help="TSV file to write.")
    parser.add_argument("--categories", required=True, help="Editable category TSV.")
    parser.add_argument("--seed-app-catalog", help="Optional installer catalog to seed categories.")
    parser.add_argument("--include-system", action="store_true", help="Also include Apple system apps.")
    parser.add_argument("--check", action="store_true", help="Scan and print counts without opening UI.")
    parser.add_argument(
        "--merge-base",
        help="Existing catalog to merge against and seed categories from (defaults to --output).",
    )
    parser.add_argument(
        "--save-mode",
        choices=["ask", "merge", "replace"],
        default="ask",
        help="How to combine this Mac's apps with an existing catalog. Default: ask.",
    )
    args = parser.parse_args()

    output_path = Path(args.output)
    categories_path = Path(args.categories)
    categories = load_categories(categories_path)
    if not categories:
        print(f"No categories found in {categories_path}", file=sys.stderr)
        return 2

    app_dirs = default_app_dirs(args.include_system)
    merge_base_path = Path(args.merge_base) if args.merge_base else output_path
    existing = load_existing_categories(merge_base_path, categories)
    existing_apps = load_apps_from_tsv(merge_base_path)
    seeds = load_seed_categories(
        Path(args.seed_app_catalog) if args.seed_app_catalog else None,
        categories,
    )
    apps = scan_apps(app_dirs, existing, seeds)
    resolve_install_sources(apps)

    if args.check:
        categorized = sum(1 for app in apps if app.category)
        print(f"apps={len(apps)}")
        print(f"categorized={categorized}")
        for category in categories:
            count = sum(1 for app in apps if app.category == category.key)
            print(f"{category.number} {category.key}={count}")
        return 0

    saved = curses.wrapper(lambda stdscr: InstalledAppEditor(stdscr, apps, categories).run())
    if not saved:
        return 1

    mode = args.save_mode if existing_apps else "replace"
    if mode == "ask":
        mode = prompt_save_mode(len(existing_apps))

    if mode == "merge":
        merged, counts = merge_apps(existing_apps, apps)
        write_apps(output_path, merged)
        print(
            f"Merged: {counts['added']} added, {counts['updated']} updated, "
            f"{counts['kept']} kept from other Macs."
        )
        print(f"Saved {len(merged)} apps to {output_path}")
    else:
        write_apps(output_path, apps)
        print(f"Saved {len(apps)} apps to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
