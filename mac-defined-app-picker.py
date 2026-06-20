#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import curses
import sys
import time
from dataclasses import dataclass
from pathlib import Path

SHIFT_UP = -1001
SHIFT_DOWN = -1002
UNCATEGORIZED_KEY = "__uncategorized__"
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


@dataclass
class DefinedApp:
    index: int
    name: str
    bundle_id: str
    path: str
    size: str
    tags: str
    updated: str
    category: str


def clean_cell(value: object) -> str:
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


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


def load_categories(path: Path) -> list[Category]:
    categories: list[Category] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            try:
                number = int(clean_cell(row.get("number", "")))
            except ValueError:
                continue
            key = clean_cell(row.get("key", "")).lower()
            label = clean_cell(row.get("label", "")) or key.title()
            if key:
                categories.append(Category(number, key, label))
    categories.sort(key=lambda category: category.number)
    return categories


def load_apps(path: Path) -> list[DefinedApp]:
    apps: list[DefinedApp] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            name = clean_cell(row.get("name", ""))
            app_path = clean_cell(row.get("path", ""))
            if not name or not app_path:
                continue
            if is_backup_noise_app_name(name, app_path):
                continue
            apps.append(
                DefinedApp(
                    index=len(apps) + 1,
                    name=name,
                    bundle_id=clean_cell(row.get("bundle_id", "")),
                    path=app_path,
                    size=clean_cell(row.get("size_human", "")),
                    tags=clean_cell(row.get("finder_tags", "")),
                    updated=clean_cell(row.get("last_updated", "")),
                    category=clean_cell(row.get("category", "")).lower(),
                )
            )
    return apps


def load_initial(path: Path | None) -> set[str]:
    if path is None or not path.exists():
        return set()
    selected: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if value and not value.startswith("#"):
            selected.add(value)
    return selected


def write_selection(path: Path, apps: list[DefinedApp], selected_paths: set[str]) -> None:
    path.write_text(
        "\n".join(app.path for app in apps if app.path in selected_paths)
        + ("\n" if selected_paths else ""),
        encoding="utf-8",
    )


class DefinedAppPicker:
    def __init__(
        self,
        stdscr,
        apps: list[DefinedApp],
        categories: list[Category],
        title: str,
        initial: set[str],
        default_category: str,
    ):
        self.stdscr = stdscr
        self.apps = apps
        self.categories = categories + [Category(0, UNCATEGORIZED_KEY, "Uncategorized")]
        self.title = title
        self.selected = {app.path for app in apps if app.path in initial}
        if not self.selected and default_category:
            self.selected = {app.path for app in apps if app.category == default_category}
        self.view = "categories"
        self.category_cursor = 0
        self.app_cursor = 0
        self.app_scroll = 0
        self.search = ""
        self.searching = False
        self.message = ""

    def run(self) -> set[str] | None:
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
        self.stdscr.keypad(True)

        while True:
            self.draw()
            key = self.read_key()
            if self.searching:
                self.handle_search_key(key)
                continue
            result = self.handle_key(key)
            if result == "done":
                return self.selected
            if result == "cancel":
                return None

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

    @property
    def current_category(self) -> str:
        return self.visible_categories()[self.category_cursor].key

    def app_in_category(self, app: DefinedApp, category: str) -> bool:
        if category == UNCATEGORIZED_KEY:
            return not app.category
        return app.category == category

    def category_apps(self, category: str) -> list[DefinedApp]:
        if self.search:
            query = self.search.casefold()
            return [
                app
                for app in self.apps
                if query
                in " ".join(
                    [app.name, app.bundle_id, app.path, app.tags, app.category]
                ).casefold()
            ]
        return [app for app in self.apps if self.app_in_category(app, category)]

    def current_apps(self) -> list[DefinedApp]:
        return self.category_apps(self.current_category)

    def category_counts(self, category: str) -> tuple[int, int]:
        apps = [app for app in self.apps if self.app_in_category(app, category)]
        selected = sum(1 for app in apps if app.path in self.selected)
        return selected, len(apps)

    def visible_categories(self) -> list[Category]:
        return [
            category
            for category in self.categories
            if self.category_counts(category.key)[1] > 0
        ]

    def draw(self) -> None:
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        green = curses.color_pair(1) | curses.A_BOLD
        cyan = curses.color_pair(2) | curses.A_BOLD
        dim = curses.A_DIM
        bold = curses.A_BOLD

        self.add(0, 0, self.title, green)
        self.add(1, 0, "Categories and apps come from option 1: Define apps to backup", dim)

        if self.view == "categories":
            self.draw_categories(height, width, green, dim, bold)
        else:
            self.draw_apps(height, width, green, cyan, dim, bold)

        footer_y = max(0, height - 3)
        self.add(footer_y, 0, f"Selected: {len(self.selected)} apps / {len(self.apps)} total", bold)
        if self.message:
            self.add(footer_y + 1, 0, self.message[: width - 1], dim)
        self.stdscr.refresh()

    def draw_categories(self, height, width, green, dim, bold) -> None:
        self.add(3, 0, "Categories", bold)
        row = 5
        visible_categories = self.visible_categories()
        if self.category_cursor >= len(visible_categories):
            self.category_cursor = max(0, len(visible_categories) - 1)
        for index, category in enumerate(visible_categories):
            selected, total = self.category_counts(category.key)
            pointer = ">" if index == self.category_cursor else " "
            attr = curses.A_REVERSE if index == self.category_cursor else curses.A_NORMAL
            text = f"{pointer}  {category.label:<18} {selected:>3}/{total:<3} selected"
            self.add(row, 0, text[: width - 1], attr | (green if selected else curses.A_NORMAL))
            row += 1

        help_y = min(height - 7, row + 2)
        self.add(help_y, 0, "Enter: open category  Space: select/deselect category  A: mark all/none", dim)
        self.add(help_y + 1, 0, "I: invert all  /: search apps  Q/Esc: cancel", dim)

    def draw_apps(self, height, width, green, cyan, dim, bold) -> None:
        title = self.category_label(self.current_category)
        if self.search:
            title = f"Search: {self.search}"
        self.add(3, 0, title, cyan | bold)

        apps = self.current_apps()
        page_top = 5
        page_bottom = max(page_top, height - 5)
        page_size = max(1, page_bottom - page_top)
        if self.app_cursor >= len(apps):
            self.app_cursor = max(0, len(apps) - 1)
        if self.app_cursor < self.app_scroll:
            self.app_scroll = self.app_cursor
        if self.app_cursor >= self.app_scroll + page_size:
            self.app_scroll = self.app_cursor - page_size + 1

        if not apps:
            self.add(page_top, 0, "No apps match this view.", dim)
        for offset, app in enumerate(apps[self.app_scroll : self.app_scroll + page_size]):
            row = page_top + offset
            absolute = self.app_scroll + offset
            checked = "[x]" if app.path in self.selected else "[ ]"
            pointer = ">" if absolute == self.app_cursor else " "
            attr = curses.A_REVERSE if absolute == self.app_cursor else curses.A_NORMAL
            if app.path in self.selected:
                attr |= green
            line = (
                f"{pointer} {checked} "
                f"{self.fit(app.name, 32):32} "
                f"{self.fit(app.tags or '-', 10):10} "
                f"{app.updated:10} "
                f"{self.fit(app.path, 45)}"
            )
            self.add(row, 0, line[: width - 1], attr)

        self.add(height - 6, 0, "Up/Down: move  Shift-Up/Down: toggle while moving  Right/Left: page  Space: mark", dim)
        self.add(height - 5, 0, "A: mark all/none  I: invert  Enter: continue  Backspace: categories  /: search", dim)

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

    def category_label(self, key: str) -> str:
        for category in self.categories:
            if category.key == key:
                return category.label
        return key

    def move_category(self, delta: int) -> None:
        visible_categories = self.visible_categories()
        if not visible_categories:
            return
        self.category_cursor = min(max(0, self.category_cursor + delta), len(visible_categories) - 1)

    def handle_key(self, key: int):
        if key in (ord("q"), ord("Q"), 27):
            if self.view == "apps":
                self.view = "categories"
                self.search = ""
                self.message = "Back to categories."
                return None
            return "cancel"
        if key == ord("/"):
            self.searching = True
            self.search = ""
            self.view = "apps"
            self.app_cursor = 0
            self.app_scroll = 0
            self.message = "Search: type query, Enter to apply, Esc to clear."
            return None
        if self.view == "categories":
            return self.handle_category_key(key)
        return self.handle_app_key(key)

    def handle_category_key(self, key: int):
        if key in (curses.KEY_UP, ord("k"), ord("K")):
            self.move_category(-1)
        elif key in (curses.KEY_DOWN, ord("j"), ord("J")):
            self.move_category(1)
        elif key in (10, 13, curses.KEY_ENTER):
            self.view = "apps"
            self.app_cursor = 0
            self.app_scroll = 0
            self.search = ""
        elif key == ord(" "):
            self.toggle_category(self.current_category)
        elif key in (ord("a"), ord("A")):
            all_paths = {app.path for app in self.apps}
            if self.selected >= all_paths:
                self.selected.clear()
                self.message = "Unmarked all apps."
            else:
                self.selected = all_paths
                self.message = "Marked all apps."
        elif key in (ord("i"), ord("I")):
            all_paths = {app.path for app in self.apps}
            self.selected = all_paths - self.selected
            self.message = "Inverted all selections."
        return None

    def handle_app_key(self, key: int):
        apps = self.current_apps()
        if key in (curses.KEY_BACKSPACE, 127, 8):
            self.view = "categories"
            self.search = ""
            self.message = "Back to categories."
        elif key in (curses.KEY_UP, ord("k"), ord("K")):
            self.move_app(-1, extend=False)
        elif key in (curses.KEY_DOWN, ord("j"), ord("J")):
            self.move_app(1, extend=False)
        elif key in (curses.KEY_RIGHT, curses.KEY_NPAGE):
            self.page_move_app(1)
        elif key in (curses.KEY_LEFT, curses.KEY_PPAGE):
            self.page_move_app(-1)
        elif key in (SHIFT_UP, getattr(curses, "KEY_SR", None)):
            self.move_app(-1, extend=True)
        elif key in (SHIFT_DOWN, getattr(curses, "KEY_SF", None)):
            self.move_app(1, extend=True)
        elif key in (10, 13, curses.KEY_ENTER):
            if self.selected:
                return "done"
            self.message = "Select at least one app first."
        elif key == ord(" ") and apps:
            self.toggle_app(apps[self.app_cursor])
        elif key in (ord("a"), ord("A")):
            self.toggle_all_visible_apps()
        elif key in (ord("i"), ord("I")):
            for app in apps:
                self.toggle_app(app)
            self.message = "Inverted selections in this view."
        return None

    def handle_search_key(self, key: int) -> None:
        if key == 27:
            self.searching = False
            self.search = ""
            self.app_cursor = 0
            self.app_scroll = 0
            self.message = "Search cleared."
        elif key in (10, 13, curses.KEY_ENTER):
            self.searching = False
            self.app_cursor = 0
            self.app_scroll = 0
            self.message = f"Search applied: {self.search}" if self.search else "Search cleared."
        elif key in (curses.KEY_BACKSPACE, 127, 8):
            self.search = self.search[:-1]
        elif 32 <= key <= 126:
            self.search += chr(key)
        self.view = "apps"

    def toggle_app(self, app: DefinedApp) -> None:
        if app.path in self.selected:
            self.selected.remove(app.path)
        else:
            self.selected.add(app.path)

    def move_app(self, delta: int, extend: bool) -> None:
        apps = self.current_apps()
        if not apps:
            return
        old_cursor = self.app_cursor
        self.app_cursor = min(max(0, self.app_cursor + delta), len(apps) - 1)
        if extend and self.app_cursor != old_cursor:
            self.toggle_app(apps[self.app_cursor])

    def app_page_size(self) -> int:
        height, _ = self.stdscr.getmaxyx()
        page_top = 5
        page_bottom = max(page_top, height - 5)
        return max(1, page_bottom - page_top)

    def page_move_app(self, direction: int) -> None:
        apps = self.current_apps()
        if not apps:
            return
        delta = self.app_page_size() * direction
        self.app_cursor = min(max(0, self.app_cursor + delta), len(apps) - 1)

    def toggle_all_visible_apps(self) -> None:
        apps = self.current_apps()
        if not apps:
            return
        if all(app.path in self.selected for app in apps):
            for app in apps:
                self.selected.discard(app.path)
            self.message = "Unmarked all apps in this view."
        else:
            for app in apps:
                self.selected.add(app.path)
            self.message = "Marked all apps in this view."

    def toggle_category(self, category: str) -> None:
        apps = [app for app in self.apps if self.app_in_category(app, category)]
        if not apps:
            return
        if all(app.path in self.selected for app in apps):
            for app in apps:
                self.selected.discard(app.path)
            self.message = f"Unmarked {self.category_label(category)}."
        else:
            for app in apps:
                self.selected.add(app.path)
            self.message = f"Marked {self.category_label(category)}."


def main() -> int:
    parser = argparse.ArgumentParser(description="Pick apps from the defined installed-app catalog.")
    parser.add_argument("--apps", required=True)
    parser.add_argument("--categories", required=True)
    parser.add_argument("--output")
    parser.add_argument("--title", default="App Picker")
    parser.add_argument("--initial-file")
    parser.add_argument("--default-category", default="")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    categories = load_categories(Path(args.categories))
    apps = load_apps(Path(args.apps))

    if args.check:
        print(f"apps={len(apps)}")
        for category in categories:
            total = sum(1 for app in apps if app.category == category.key)
            print(f"{category.key}={total}")
        uncategorized = sum(1 for app in apps if not app.category)
        print(f"uncategorized={uncategorized}")
        return 0

    if not args.output:
        parser.error("--output is required unless --check is used")
    if not apps:
        print("No apps found in defined app catalog. Run option 1 first.", file=sys.stderr)
        return 1

    initial = load_initial(Path(args.initial_file) if args.initial_file else None)
    selected = curses.wrapper(
        lambda stdscr: DefinedAppPicker(
            stdscr,
            apps,
            categories,
            args.title,
            initial,
            args.default_category,
        ).run()
    )
    if selected is None:
        return 1

    write_selection(Path(args.output), apps, selected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
