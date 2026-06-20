#!/usr/bin/env python3

"""Unit tests for the settings discovery + app catalog merge logic.

Run: python3 -m unittest discover -s tests   (from the project root)
"""

from __future__ import annotations

import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load(filename: str, name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # register before exec so dataclasses resolve
    spec.loader.exec_module(module)
    return module


mss = _load("mac-settings-scan.py", "mss")
mia = _load("mac-installed-apps.py", "mia")
mdap = _load("mac-defined-app-picker.py", "mdap")


class ScannerPureFunctions(unittest.TestCase):
    def test_tilde(self):
        self.assertEqual(mss.tilde(str(mss.HOME) + "/Library/X"), "~/Library/X")
        self.assertEqual(mss.tilde("/etc/hosts"), "/etc/hosts")

    def test_norm(self):
        self.assertEqual(mss.norm("Karabiner-Elements"), "karabinerelements")

    def test_deny_list(self):
        self.assertTrue(mss.is_denied("/u/Library/Caches/x", mss.DEFAULT_DENY))
        self.assertTrue(mss.is_denied("/u/Library/Saved Application State/x", mss.DEFAULT_DENY))
        self.assertTrue(mss.is_denied("/u/Library/Application Support/App/CacheStorage/x", mss.DEFAULT_DENY))
        self.assertTrue(mss.is_denied("/u/Library/Containers/com.x/Data/Library/WebKit/WebsiteData/x", mss.DEFAULT_DENY))
        self.assertTrue(mss.is_denied("/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", mss.DEFAULT_DENY))
        self.assertFalse(mss.is_denied("/u/Library/Preferences/x.plist", mss.DEFAULT_DENY))

    def test_keys_match(self):
        self.assertTrue(mss.keys_match("alfred", "alfred"))
        self.assertTrue(mss.keys_match("karabiner", "karabinerelements"))  # both >= 4
        self.assertFalse(mss.keys_match("git", "gitconfig"))  # left < 4 -> exact only

    def test_app_candidates(self):
        kinds = [k for k, _ in mss.app_candidates("Alfred", "com.x.Alfred", True)]
        self.assertIn("pref", kinds)
        self.assertIn("container", kinds)
        self.assertIn("appsupport", kinds)
        self.assertNotIn("container", [k for k, _ in mss.app_candidates("Alfred", "com.x.Alfred", False)])

    def test_attribute_dotfile(self):
        apps = [("Karabiner-Elements", "org.pqrs.Karabiner-Elements")]
        self.assertEqual(mss.attribute_dotfile("karabiner", apps)[0], "Karabiner-Elements")
        self.assertEqual(mss.attribute_dotfile("zzznope", apps), ("", ""))

    def test_mackup_coverage(self):
        ids = {"alfred", "vim"}
        self.assertTrue(mss.app_covered_by_mackup("Alfred", "com.x.Alfred", ids))
        self.assertFalse(mss.app_covered_by_mackup("Arc", "com.x.arc", ids))
        # "vim" is 3 chars -> exact match only, so it must not swallow "Vimcal"
        self.assertFalse(mss.app_covered_by_mackup("Vimcal", "com.x.vimcal", ids))


class ImportVerifiedGate(unittest.TestCase):
    def test_keep_and_verified(self):
        with tempfile.TemporaryDirectory() as d:
            real = Path(d) / "real.txt"
            real.write_text("x")
            missing = Path(d) / "nope"
            cand = Path(d) / "candidates.tsv"
            rows = [
                ["app_name", "bundle_id", "source", "kind", "found_path", "size_human", "keep", "reason"],
                ["A", "com.a", "fs", "pref", "~/Library/Preferences/com.a.plist", "1 KB", "no", "junk"],
                ["B", "com.b", "fs", "appsupport", str(real), "1 KB", "yes", "real"],
                ["C", "com.c", "llm", "dotfile", str(real), "-", "yes", "exists"],
                ["D", "com.d", "llm", "appsupport", str(missing), "-", "yes", "gap"],
            ]
            with cand.open("w", newline="") as handle:
                csv.writer(handle, delimiter="\t").writerows(rows)

            out = mss.import_candidates(cand)
            first = {r.name.split(" ")[0]: r for r in out}

            self.assertNotIn("A", first)  # keep=no dropped
            self.assertEqual(first["B"].verified, "yes")
            self.assertEqual(first["C"].verified, "yes")  # llm path exists -> trusted
            self.assertEqual(first["C"].enabled, "yes")
            self.assertEqual(first["D"].verified, "no")  # llm path missing -> unverified
            self.assertEqual(first["D"].enabled, "no")   # and not selected for backup


class CatalogMerge(unittest.TestCase):
    def _app(self, name, bundle="", path="", category=""):
        return mia.InstalledApp(
            name=name, bundle_id=bundle, path=path, size_bytes=1, tags=[], updated_ts=0.0, category=category
        )

    def test_merge_counts_and_dedup(self):
        existing = [
            self._app("Logic Pro", "com.apple.logic", "/A/Logic Pro.app", "music"),  # other Mac only
            self._app("Alfred", "com.rwc.Alfred", "/A/Alfred.app", "productivity"),   # both (bundle)
            self._app("Ghost", "", "/Old/Ghost.app", "work"),                          # name match
        ]
        scanned = [
            self._app("Alfred", "com.rwc.Alfred", "/A/Alfred.app", "productivity"),
            self._app("New", "com.x.new", "/A/New.app", "ai"),
            self._app("Ghost", "", "/A/Ghost.app", "work"),
        ]
        merged, counts = mia.merge_apps(existing, scanned)
        self.assertEqual(counts, {"added": 1, "updated": 2, "kept": 1})
        names = sorted(a.name for a in merged)
        self.assertIn("Logic Pro", names)  # other-Mac app retained
        self.assertEqual(names.count("Ghost"), 1)  # deduped

    def test_merge_empty_existing(self):
        scanned = [self._app("New", "com.x.new", "/A/New.app", "ai")]
        _, counts = mia.merge_apps([], scanned)
        self.assertEqual(counts, {"added": 1, "updated": 0, "kept": 0})

    def test_merge_drops_backup_noise_apps(self):
        existing = [
            self._app("Arc", "company.thebrowser.Browser", "/A/Arc.app", "productivity"),
            self._app("Krisp Uninstaller", "", "/A/Krisp Uninstaller.app", ""),
            self._app("Remove Soundtoys", "", "/A/Remove Soundtoys.app", ""),
        ]
        scanned = [
            self._app("Arc", "company.thebrowser.Browser", "/A/Arc.app", "productivity"),
            self._app("Logi Options+ Driver Installer", "", "/A/Logi Options+ Driver Installer.app", ""),
            self._app("setup", "", "/A/setup.app", ""),
        ]
        merged, counts = mia.merge_apps(existing, scanned)
        self.assertEqual(counts, {"added": 0, "updated": 1, "kept": 0})
        self.assertEqual([app.name for app in merged], ["Arc"])


class AICategoryHelp(unittest.TestCase):
    def test_parse_ai_category_output(self):
        categories = [
            mia.Category(1, "essential", "Essential", ()),
            mia.Category(2, "productivity", "Productivity", ("utilities",)),
        ]
        output = "\n".join(
            [
                "1\tessential",
                "2\tskip",
                "| 3 | Productivity |",
                "4\tmadeup",
            ]
        )
        suggestions, skipped, invalid = mia.parse_ai_category_output(output, categories)
        self.assertEqual(suggestions, {1: "essential", 3: "productivity"})
        self.assertEqual(skipped, 1)
        self.assertEqual(invalid, 1)

    def test_auth_error_detection(self):
        self.assertTrue(mia.looks_like_auth_error("API Error: 401 Invalid authentication credentials"))
        self.assertTrue(mia.looks_like_auth_error("Failed to authenticate"))
        self.assertFalse(mia.looks_like_auth_error("1\tessential"))

    def test_progress_helpers(self):
        bar = mia.InstalledAppEditor.progress_bar(20, 0)
        self.assertEqual(len(bar), 22)
        self.assertIn("=", bar)
        self.assertEqual(mia.InstalledAppEditor.format_elapsed(65), "01:05")

    def test_sort_help_marks_current_sort(self):
        editor = object.__new__(mia.InstalledAppEditor)
        editor.sort_key = "name"
        self.assertIn("Name*", editor.sort_help_line())
        self.assertNotIn("Category*", editor.sort_help_line())
        editor.sort_key = "category"
        self.assertIn("Category*", editor.sort_help_line())

    def test_backup_noise_app_names(self):
        self.assertTrue(mia.is_backup_noise_app_name("Krisp Uninstaller"))
        self.assertTrue(mia.is_backup_noise_app_name("Logi Options+ Driver Installer"))
        self.assertTrue(mia.is_backup_noise_app_name("Remove Soundtoys"))
        self.assertTrue(mia.is_backup_noise_app_name("setup"))
        self.assertTrue(mia.is_backup_noise_app_name("Microsoft AutoUpdate"))
        self.assertTrue(mia.is_backup_noise_app_name("Install macOS Tahoe"))
        self.assertFalse(mia.is_backup_noise_app_name("Setapp"))
        self.assertFalse(mia.is_backup_noise_app_name("Arc"))
        self.assertTrue(mdap.is_backup_noise_app_name("OpenVPN Uninstaller"))
        self.assertFalse(mdap.is_backup_noise_app_name("Bitwarden"))


if __name__ == "__main__":
    unittest.main()
