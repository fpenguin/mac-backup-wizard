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


@dataclass
class Setting:
    index: int
    name: str
    path: str
    notes: str
    available: bool
    status: str
    default_on: bool = True


def enabled(value: str) -> bool:
    return value.strip().lower() in {"yes", "y", "true", "1", "enabled"}


def clean_cell(value: object) -> str:
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def expand_path(value: str) -> Path:
    if value == "~":
        return Path.home()
    if value.startswith("~/"):
        return Path.home() / value[2:]
    return Path(value)


def relative_key_for_path(path: Path) -> str:
    home = str(Path.home())
    text = str(path)
    if text.startswith(home + "/"):
        return text[len(home) + 1 :]
    if text.startswith("/"):
        return "absolute" + text
    return text


def setting_available(mode: str, path: str, backup_dir: Path) -> tuple[bool, str]:
    expanded = expand_path(path)
    if mode == "backup":
        return expanded.exists(), "" if expanded.exists() else "missing locally"

    backup_source = backup_dir / "files" / relative_key_for_path(expanded)
    return backup_source.exists(), "" if backup_source.exists() else "missing in backup"


def load_settings(manifest: Path, mode: str, backup_dir: Path) -> list[Setting]:
    settings: list[Setting] = []
    with manifest.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            # Keep every non-comment row (including ones disabled by default, e.g.
            # large folders) so the user can still enable them. Row order must
            # mirror the wizard's loader for index alignment.
            raw_enabled = clean_cell(row.get("enabled", ""))
            if not raw_enabled or raw_enabled.startswith("#"):
                continue
            path = clean_cell(row.get("path", ""))
            available, status = setting_available(mode, path, backup_dir)
            settings.append(
                Setting(
                    index=len(settings) + 1,
                    name=clean_cell(row.get("name", "")),
                    path=path,
                    notes=clean_cell(row.get("notes", "")),
                    available=available,
                    status=status,
                    default_on=enabled(raw_enabled),
                )
            )
    return settings


class SettingsPicker:
    def __init__(self, stdscr, settings: list[Setting], mode: str, preselect: set[str] | None = None):
        self.stdscr = stdscr
        self.settings = settings
        self.mode = mode
        if preselect is not None:
            self.selected = {s.index for s in settings if s.available and s.path in preselect}
        else:
            self.selected = {s.index for s in settings if s.available and s.default_on}
        self.cursor = 0
        self.scroll = 0
        self.search = ""
        self.searching = False
        self.message = ""

    def run(self) -> set[int] | None:
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

    def visible_settings(self) -> list[Setting]:
        if not self.search:
            return self.settings
        query = self.search.casefold()
        return [
            setting
            for setting in self.settings
            if query
            in " ".join([setting.name, setting.path, setting.notes, setting.status]).casefold()
        ]

    def draw(self) -> None:
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        green = curses.color_pair(1) | curses.A_BOLD
        cyan = curses.color_pair(2) | curses.A_BOLD
        dim = curses.A_DIM
        bold = curses.A_BOLD

        visible = self.visible_settings()
        if self.cursor >= len(visible):
            self.cursor = max(0, len(visible) - 1)
        if self.cursor < self.scroll:
            self.scroll = self.cursor

        page_top = 5
        page_bottom = max(page_top + 1, height - 5)
        page_size = max(1, page_bottom - page_top)
        if self.cursor >= self.scroll + page_size:
            self.scroll = self.cursor - page_size + 1

        selected_available = len(self.selected)
        available_count = sum(1 for setting in self.settings if setting.available)
        self.add(0, 0, f"Settings {self.mode.title()} Picker", green)
        self.add(
            1,
            0,
            f"{len(visible)} shown / {len(self.settings)} settings  |  {selected_available}/{available_count} selected",
            bold,
        )
        if self.search:
            self.add(2, 0, f"Search: {self.search}", cyan)

        self.add(4, 0, f"{'':1} {'':3} {'Setting':30} {'Path':45} Status", bold)
        if not visible:
            self.add(page_top, 0, "No settings match this search.", dim)
        for offset, setting in enumerate(visible[self.scroll : self.scroll + page_size]):
            row = page_top + offset
            absolute = self.scroll + offset
            mark = "x" if setting.index in self.selected else " "
            if not setting.available:
                mark = "-"
            pointer = ">" if absolute == self.cursor else " "
            attr = curses.A_REVERSE if absolute == self.cursor else curses.A_NORMAL
            if setting.index in self.selected:
                attr |= green
            line = (
                f"{pointer} [{mark}] "
                f"{self.fit(setting.name, 30):30} "
                f"{self.fit(setting.path, 45):45} "
                f"{setting.status}"
            )
            self.add(row, 0, line[: width - 1], attr)

        self.add(height - 4, 0, "Up/Down: move  Shift-Up/Down: toggle while moving  Right/Left: page  Space: mark", dim)
        self.add(height - 3, 0, "A: mark all/none  I: invert  /: search  Enter: continue  Q/Esc: cancel", dim)
        if self.message:
            self.add(height - 2, 0, self.message[: width - 1], dim)
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

    def handle_key(self, key: int):
        if key in (ord("q"), ord("Q"), 27):
            return "cancel"
        if key in (10, 13, curses.KEY_ENTER):
            if self.selected:
                return "done"
            self.message = "Select at least one available setting first."
            return None
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
            self.invert_visible()
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
        visible = self.visible_settings()
        if not visible:
            return
        old_cursor = self.cursor
        self.cursor = min(max(0, self.cursor + delta), len(visible) - 1)
        if extend and self.cursor != old_cursor:
            self.toggle_setting(visible[self.cursor])

    def page_size(self) -> int:
        height, _ = self.stdscr.getmaxyx()
        page_top = 5
        page_bottom = max(page_top + 1, height - 5)
        return max(1, page_bottom - page_top)

    def page_move(self, direction: int) -> None:
        visible = self.visible_settings()
        if not visible:
            return
        delta = self.page_size() * direction
        self.cursor = min(max(0, self.cursor + delta), len(visible) - 1)

    def toggle_current(self) -> None:
        visible = self.visible_settings()
        if visible:
            self.toggle_setting(visible[self.cursor])

    def toggle_setting(self, setting: Setting) -> None:
        if not setting.available:
            self.message = f"Unavailable: {setting.name} ({setting.status})."
            self.selected.discard(setting.index)
            return
        if setting.index in self.selected:
            self.selected.remove(setting.index)
            self.message = f"Unmarked {setting.name}."
        else:
            self.selected.add(setting.index)
            self.message = f"Marked {setting.name}."

    def visible_available(self) -> list[Setting]:
        return [setting for setting in self.visible_settings() if setting.available]

    def toggle_all_visible(self) -> None:
        visible = self.visible_available()
        if not visible:
            return
        if all(setting.index in self.selected for setting in visible):
            for setting in visible:
                self.selected.remove(setting.index)
            self.message = "Unmarked all visible available settings."
        else:
            for setting in visible:
                self.selected.add(setting.index)
            self.message = "Marked all visible available settings."

    def invert_visible(self) -> None:
        visible = self.visible_available()
        for setting in visible:
            if setting.index in self.selected:
                self.selected.remove(setting.index)
            else:
                self.selected.add(setting.index)
        self.message = "Inverted visible available settings."


def write_selection(path: Path, selected: set[int]) -> None:
    path.write_text("\n".join(str(index) for index in sorted(selected)) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Pick settings to backup or restore.")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--mode", choices=["backup", "restore"], required=True)
    parser.add_argument("--backup-dir", required=True)
    parser.add_argument("--output")
    parser.add_argument("--preselect-file", help="File of paths to pre-check (one per line).")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    settings = load_settings(Path(args.manifest), args.mode, Path(args.backup_dir))
    if args.check:
        available = sum(1 for setting in settings if setting.available)
        print(f"settings={len(settings)}")
        print(f"available={available}")
        return 0

    if not args.output:
        parser.error("--output is required unless --check is used")

    preselect: set[str] | None = None
    if args.preselect_file:
        pre_path = Path(args.preselect_file)
        if pre_path.exists():
            preselect = {
                line.strip()
                for line in pre_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }

    selected = curses.wrapper(
        lambda stdscr: SettingsPicker(stdscr, settings, args.mode, preselect).run()
    )
    if selected is None:
        return 1
    write_selection(Path(args.output), selected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
