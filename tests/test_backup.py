"""Run with: python3 -m unittest discover -s tests -p 'test_backup.py'."""

import importlib.util
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("backup", REPO / "scripts/backup.py")
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="selvedge backup tests ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "original checkout"
        self.root.mkdir()
        self.archive = self.base / "backups" / "selvedge-backup-test.tar.gz"

    def write(self, name, content="saved state"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_round_trip_ignored_state_and_portable_links(self):
        ignored = [
            ".env", "docker-compose.override.yml",
            "etc/traefik/enabled/crowdsec.yml", "etc/mkcert/rootCA/key.pem",
            "etc/certificates/private.pem", "etc/letsencrypt/acme.json",
            "etc/config/crowdsec/scenarios/custom.yaml",
            "etc/config/crowdsec/whitelists/custom.yaml",
            "etc/config/crowdsec/acquis.d/custom.yaml",
            "data/crowdsec/config/config.yaml", "data/crowdsec/data/crowdsec.db",
            "data/grafana/grafana.db", "data/log/traefik/access.log", "data/.hidden",
        ]
        for name in ignored:
            self.write(name, name)
            result = subprocess.run(["git", "check-ignore", "--no-index", "-q", name], cwd=REPO)
            self.assertEqual(result.returncode, 0, name)
        self.write("docker-compose.yml")
        self.write("etc/compose/services-available/crowdsec.yml")
        for kind in ("services", "overrides"):
            target = self.write(f"etc/compose/{kind}-available/crowdsec.yml")
            link = self.root / f"etc/compose/{kind}-enabled/crowdsec.yml"
            link.parent.mkdir()
            link.symlink_to(target)
        (self.root / ".env").chmod(0o600)
        os.link(self.root / "data/.hidden", self.root / "data/hardlink")
        self.write(".git/private", "excluded")
        self.write("backup/old.tar.gz", "excluded")
        backup.backup(self.root, self.archive)
        self.assertEqual(stat.S_IMODE(self.archive.stat().st_mode), 0o600)
        restored = self.base / "new checkout"
        restored.mkdir()
        backup.restore(restored, self.archive)
        for name in ignored:
            self.assertEqual((restored / name).read_text(), name)
        self.assertEqual(stat.S_IMODE((restored / ".env").stat().st_mode), 0o600)
        self.assertEqual((restored / ".env").stat().st_uid, (self.root / ".env").stat().st_uid)
        for kind in ("services", "overrides"):
            link = restored / f"etc/compose/{kind}-enabled/crowdsec.yml"
            self.assertFalse(os.path.isabs(os.readlink(link)))
            self.assertEqual(link.resolve(), restored / f"etc/compose/{kind}-available/crowdsec.yml")
        self.assertEqual((restored / "data/.hidden").stat().st_ino,
                         (restored / "data/hardlink").stat().st_ino)
        self.assertFalse((restored / ".git").exists())
        self.assertFalse((restored / "backup").exists())

    def test_optional_paths_and_failed_backup_publication(self):
        self.write(".env")
        backup.backup(self.root, self.archive)
        with self.assertRaises(ValueError):
            backup.backup(self.root, self.archive)
        external = self.root / "etc"
        external.symlink_to(self.base)
        failed = self.archive.parent / "failed.tar.gz"
        with self.assertRaises(ValueError):
            backup.backup(self.root, failed)
        self.assertFalse(failed.exists())
        self.assertFalse(list(self.archive.parent.glob(".selvedge-backup-*")))

    def test_truncated_archive_does_not_modify_destination(self):
        self.write(".env", "old")
        backup.backup(self.root, self.archive)
        self.archive.write_bytes(self.archive.read_bytes()[:-8])
        self.write(".env", "current")
        with self.assertRaises((EOFError, OSError, tarfile.TarError)):
            backup.restore(self.root, self.archive)
        self.assertEqual((self.root / ".env").read_text(), "current")

    def test_unsafe_paths_rejected_before_writes(self):
        for name, link in [("../outside", None), ("etc/link", "/tmp"),
                           (".git/config", None), ("etc/link", "../../outside")]:
            with self.subTest(name=name, link=link):
                self.archive.parent.mkdir(exist_ok=True)
                with tarfile.open(self.archive, "w:gz") as archive:
                    good = tarfile.TarInfo(".env")
                    good.size = 7
                    archive.addfile(good, io.BytesIO(b"changed"))
                    bad = tarfile.TarInfo(name)
                    if link:
                        bad.type = tarfile.SYMTYPE
                        bad.linkname = link
                    archive.addfile(bad)
                self.write(".env", "current")
                with self.assertRaises(ValueError):
                    backup.restore(self.root, self.archive)
                self.assertEqual((self.root / ".env").read_text(), "current")

    def test_existing_parent_symlink_rejected(self):
        self.write("etc/config/file")
        backup.backup(self.root, self.archive)
        target = self.base / "target"
        target.mkdir()
        (target / "etc").symlink_to(self.root / "etc")
        with self.assertRaises(ValueError):
            backup.restore(target, self.archive)

    def test_backup_cannot_include_itself(self):
        self.write("data/database")
        with self.assertRaises(ValueError):
            backup.backup(self.root, self.root / "data/backups/archive.tar.gz")

    def test_latest_ignores_incomplete_and_other_project_archives(self):
        self.write(".env", "first")
        backup.backup(self.root, self.archive)
        os.utime(self.archive, (1, 1))
        newer = self.archive.parent / "selvedge-backup-newer.tar.gz"
        self.write(".env", "second")
        backup.backup(self.root, newer)
        (self.archive.parent / ".selvedge-backup-incomplete").write_text("partial")
        (self.archive.parent / "other-backup-newest.tar.gz").write_text("unrelated")
        self.assertEqual(backup.archives(self.archive.parent, "selvedge"), [newer, self.archive])

    def test_make_targets_with_spaces_and_error_status(self):
        self.write(".env", "original")
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(REPO / "scripts/backup.py", scripts)
        command = ["make", "--no-print-directory", "-f", str(REPO / "make.d/backup.mk"),
                   f"CURRENT_DIR={self.root}", "PROJECT_LOCASED=selvedge",
                   f"BACKUP_DIR={self.archive.parent}"]
        def run(*args):
            return subprocess.run(command + list(args), capture_output=True, text=True)
        self.assertNotEqual(run("restore").returncode, 0)
        result = run("backup")
        self.assertEqual(result.returncode, 0, result.stderr)
        found = backup.archives(self.archive.parent, "selvedge")
        self.assertEqual(len(found), 1)
        self.assertIn(str(found[0]), run("list-backups").stdout)
        self.write(".env", "modified")
        result = run("restore", f"BACKUP_FILE={found[0]}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / ".env").read_text(), "original")
        result = run("backup", f"BACKUP_FILE={found[0]}")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Backup created", result.stdout)


if __name__ == "__main__":
    unittest.main()
