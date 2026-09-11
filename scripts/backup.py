#!/usr/bin/env python3
"""Archive Selvedge bind mounts independently of Git's tracked-file list."""

import argparse
import gzip
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import tempfile
from datetime import datetime


ROOTS = (".env", "docker-compose.yml", "docker-compose.override.yml", "etc", "data")


def inside(path, parent):
    return path == parent or parent in path.parents


def resolve_link_target(base, linkname, root, *, allow_absolute=False, require_root_child=False, error):
    target = PurePosixPath(linkname)
    resolved = None if target.is_absolute() and not allow_absolute else Path(os.path.abspath(base / target))
    valid = resolved is not None and inside(resolved, root)
    if valid and require_root_child:
        valid = resolved != root and resolved.relative_to(root).parts[0] in ROOTS
    if not valid:
        raise ValueError(error)
    return resolved


def archives(directory, project):
    return sorted(directory.glob(f"{project}-backup-*.tar.gz"),
                  key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)


def backup(root, destination):
    sources = [root / name for name in ROOTS if os.path.lexists(root / name)]
    if not sources:
        raise ValueError("No configuration or data found to back up")
    if any(inside(destination.resolve(), (root / name).resolve()) for name in ("etc", "data")):
        raise ValueError("BACKUP_DIR/BACKUP_FILE must be outside etc/ and data/")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.path.lexists(destination):
        raise ValueError(f"Refusing to overwrite existing backup: {destination}")
    fd, temporary = tempfile.mkstemp(prefix=".selvedge-backup-", dir=destination.parent)
    os.close(fd)
    try:
        with tarfile.open(temporary, "w:gz", compresslevel=1, dereference=False) as archive:
            def add(path):
                info = path.lstat()
                if stat.S_ISSOCK(info.st_mode):
                    print(f"Skipping runtime socket: {path.relative_to(root)}")
                    return
                member = archive.gettarinfo(str(path), arcname=str(path.relative_to(root)))
                if member.issym():
                    # make enable historically created absolute checkout-local links.
                    target = resolve_link_target(
                        path.parent, os.readlink(path), root,
                        allow_absolute=True, require_root_child=True,
                        error=f"External symlink requires a separate backup: {path}")
                    member.linkname = os.path.relpath(target, path.parent)
                if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    raise ValueError(f"Unsupported special file: {path}")
                if member.isfile():
                    with path.open("rb") as stream:
                        archive.addfile(member, stream)
                    after = path.stat()
                    if (info.st_size, info.st_mtime_ns, info.st_ino) != (
                            after.st_size, after.st_mtime_ns, after.st_ino):
                        raise ValueError(f"File changed during backup; stop the stack: {path}")
                else:
                    archive.addfile(member)
                if member.isdir():
                    for child in sorted(path.iterdir()):
                        add(child)
            for source in sources:
                add(source)
        # Publish only complete archives, without replacing an existing file.
        os.link(temporary, destination)
    finally:
        os.unlink(temporary)
    print(f"Backup created: {destination}")


def restore(root, source):
    # tarfile only reads headers in getmembers(); it will not notice a
    # truncated/corrupt gzip trailer until mid-extraction. Validate the
    # whole compressed stream up front, before any destination file is touched.
    with gzip.open(source, "rb") as stream:
        while stream.read(1024 * 1024):
            pass
    with tarfile.open(source, "r:gz", errorlevel=2) as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("Backup is empty")
        links = set()
        names = set()
        by_name = {m.name: m for m in members}
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or not path.parts
                    or path.parts[0] not in ROOTS):
                raise ValueError(f"Unsafe or unexpected archive path: {member.name}")
            if path in names:
                raise ValueError(f"Duplicate archive path: {member.name}")
            names.add(path)
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError(f"Unsupported archive entry: {member.name}")
            if member.issym() or member.islnk():
                base = root / path.parent if member.issym() else root
                resolve_link_target(base, member.linkname, root,
                                     error=f"Unsafe archive link: {member.name}")
                links.add(path)
        for member in members:
            path = PurePosixPath(member.name)
            if member.islnk():
                target = PurePosixPath(member.linkname)
                target_member = by_name.get(str(target))
                if target_member is None or not target_member.isfile():
                    raise ValueError(f"Hard link must target an archived regular file: {member.name}")
            for parent in path.parents:
                if parent in links or (root / parent).is_symlink():
                    raise ValueError(f"Cannot extract through symlink: {member.name}")
            destination = root / path
            if destination.is_symlink():
                continue  # Leaf links are replaced below, never followed.
            if destination.exists() and destination.is_dir() != member.isdir():
                raise ValueError(f"File/directory conflict: {destination}")
            if destination.exists() and not (destination.is_dir() or destination.is_file()):
                raise ValueError(f"Unsupported destination file: {destination}")
        # Extract links last, so existing links cannot redirect file writes.
        for member in sorted(members, key=lambda m: m.issym() or m.islnk()):
            destination = root / member.name
            if destination.is_symlink() or (not member.isdir() and destination.is_file()):
                destination.unlink()
            kwargs = {"filter": "fully_trusted"} if hasattr(tarfile, "data_filter") else {}
            archive.extract(member, root, numeric_owner=True,
                            set_attrs=not member.isdir(), **kwargs)
        # Child extraction changes directory mtimes; apply directory metadata last.
        for member in reversed(members):
            if member.isdir():
                path = root / member.name
                archive.chown(member, str(path), numeric_owner=True)
                archive.chmod(member, str(path))
                archive.utime(member, str(path))
    print(f"Restore completed: {source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("backup", "restore", "list"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--project", default="selvedge")
    parser.add_argument("--file", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    directory = args.directory.resolve()
    if args.action == "list":
        found = archives(directory, args.project)
        for path in found:
            print(f"{path.stat().st_size:>12,} bytes  {path}")
        if not found:
            print(f"No backups found in {directory}")
        return
    print("Stop the stack before backing up or restoring persistent service data.")
    if args.action == "backup":
        stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S-%f")
        destination = args.file or directory / f"{args.project}-backup-{stamp}.tar.gz"
        backup(root, destination.absolute())
    else:
        found = archives(directory, args.project) if not args.file else [args.file]
        if not found:
            raise ValueError(f"No backups found in {directory}")
        restore(root, found[0])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tarfile.TarError, EOFError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
