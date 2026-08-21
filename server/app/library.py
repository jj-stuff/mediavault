"""Scans the media root into profiles.

Mirrors MediaScannerService on the iOS side: each immediate subfolder of the scan
root is a profile, media directly inside it is un-foldered, and every nested folder
below that is a subfolder (recursively, attributed to its top-level subfolder name).

The scan root is not always the media root. A client can nominate any folder below
it — `peeps`, `peeps/2024` — as its library, and then that folder's subfolders are
the profiles. Paths in the result stay relative to the *media* root either way, so
`/api/files/...`, likes, and deletes do not change meaning when the client switches
roots.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .config import TRASH_DIR_NAME, Settings, media_type_for
from .paths import relative_to_root, resolve_under_root


@dataclass(frozen=True)
class MediaItem:
    file_name: str
    media_type: str  # "image" | "video"
    subfolder: str | None
    path: str  # POSIX path relative to the media root, e.g. "alice/photo.jpg"
    #: Size in bytes and mtime in epoch seconds, so the client can sort by either.
    #: `None` when the file could not be stat'ed — a broken symlink, a share that
    #: went away mid-scan — which is not a reason to hide it from the library.
    byte_size: int | None = None
    modified_at: float | None = None


@dataclass
class Profile:
    id: str  # folder name, used to ask for this profile's items
    name: str  # display name
    #: POSIX path relative to the media root, e.g. "peeps/alice". Only equal to the
    #: id when the scan root *is* the media root, which is why the client builds
    #: folder URLs from this rather than from the id.
    path: str = ""
    items: list[MediaItem] = field(default_factory=list)
    subfolders: list[str] = field(default_factory=list)

    @property
    def image_count(self) -> int:
        return sum(1 for item in self.items if item.media_type == "image")

    @property
    def video_count(self) -> int:
        return sum(1 for item in self.items if item.media_type == "video")

    @property
    def thumbnail_path(self) -> str | None:
        for item in self.items:
            if item.media_type == "image":
                return item.path
        # An all-video profile still deserves a cover; the thumbnailer can render a
        # frame from a video just as well as from a still.
        return self.items[0].path if self.items else None


def _is_hidden(path: Path) -> bool:
    return path.name.startswith(".")


def _collect_media(
    directory: Path, path_root: Path, subfolder: str | None
) -> list[MediaItem]:
    """Media files directly inside `directory` (non-recursive).

    `path_root` is what reported paths are relative to — the media root, which is
    not necessarily the folder being scanned.
    """
    items: list[MediaItem] = []
    try:
        entries = sorted(directory.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return items

    for entry in entries:
        if _is_hidden(entry) or not entry.is_file():
            continue
        kind = media_type_for(entry.suffix)
        if kind is None:
            continue
        try:
            stat = entry.stat()
            byte_size: int | None = stat.st_size
            modified_at: float | None = stat.st_mtime
        except OSError:
            byte_size = modified_at = None
        items.append(
            MediaItem(
                file_name=entry.name,
                media_type=kind,
                subfolder=subfolder,
                path=relative_to_root(path_root, entry),
                byte_size=byte_size,
                modified_at=modified_at,
            )
        )
    return items


def _collect_recursive(
    directory: Path, path_root: Path, subfolder: str
) -> list[MediaItem]:
    """Media in `directory` and everything below it, all tagged with `subfolder`."""
    items = _collect_media(directory, path_root, subfolder)
    try:
        entries = sorted(directory.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return items

    for entry in entries:
        if entry.is_dir() and not _is_hidden(entry):
            items.extend(_collect_recursive(entry, path_root, subfolder))
    return items


def _scan_profile(folder: Path, path_root: Path) -> Profile:
    profile = Profile(
        id=folder.name,
        name=folder.name,
        path=relative_to_root(path_root, folder),
    )
    profile.items.extend(_collect_media(folder, path_root, None))

    try:
        entries = sorted(folder.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        entries = []

    for entry in entries:
        if not entry.is_dir() or _is_hidden(entry):
            continue
        profile.subfolders.append(entry.name)
        profile.items.extend(_collect_recursive(entry, path_root, entry.name))

    return profile


def scan(
    root: Path,
    trash_root: Path | None = None,
    path_root: Path | None = None,
) -> list[Profile]:
    """Full scan of `root`. Profiles with no media are omitted.

    `path_root` is what item paths are reported relative to, defaulting to `root`
    itself. It differs when the client has nominated a subfolder as its library.
    """
    if not root.is_dir():
        return []

    path_root = path_root or root

    # Compared by resolved path, not by name: the trash can be relocated, and when
    # it lives outside the media root there is nothing to exclude at all.
    excluded = (trash_root or root / TRASH_DIR_NAME).resolve()

    profiles: list[Profile] = []
    for entry in sorted(root.iterdir(), key=lambda p: p.name.lower()):
        if not entry.is_dir() or _is_hidden(entry):
            continue
        if entry.resolve() == excluded:
            continue
        profile = _scan_profile(entry, path_root)
        if profile.items:
            profiles.append(profile)

    profiles.sort(key=lambda p: p.name.lower())
    return profiles


@dataclass(frozen=True)
class FolderEntry:
    """One candidate library root, as offered to the folder picker in the app."""

    name: str
    path: str  # POSIX path relative to the media root
    #: Immediate subdirectories, and media files directly inside. Between them the
    #: picker can say whether a folder holds profiles or holds the photos itself,
    #: without the server walking the whole subtree to find out.
    folder_count: int
    item_count: int


def list_folders(
    directory: Path, path_root: Path, exclude: Path | None = None
) -> list[FolderEntry]:
    """Immediate subdirectories of `directory`, with a shallow count of each.

    `exclude` drops one folder from the listing — the trash, which is no more a
    candidate library root than it is a profile.
    """
    excluded = exclude.resolve() if exclude else None
    try:
        entries = sorted(directory.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return []

    folders: list[FolderEntry] = []
    for entry in entries:
        if not entry.is_dir() or _is_hidden(entry):
            continue
        if excluded is not None and entry.resolve() == excluded:
            continue
        folder_count = 0
        item_count = 0
        try:
            for child in entry.iterdir():
                if _is_hidden(child):
                    continue
                if child.is_dir():
                    folder_count += 1
                elif media_type_for(child.suffix) is not None:
                    item_count += 1
        except OSError:
            pass
        folders.append(
            FolderEntry(
                name=entry.name,
                path=relative_to_root(path_root, entry),
                folder_count=folder_count,
                item_count=item_count,
            )
        )
    return folders


class LibraryCache:
    """Caches the scan result, per library root.

    A full walk of a large library is expensive and the client refetches on every
    launch and toggle, so results are held for `scan_cache_ttl` seconds. Deletes
    invalidate the cache directly rather than waiting for expiry.

    Keyed by root because the client chooses which folder its library starts at, and
    two clients — or one client changing its mind — must not be served each other's
    profiles. Only a handful of roots are kept; a client that walks the whole tree
    picking roots should not be able to pin every scan it ever asked for in memory.
    """

    #: How many roots keep a cached scan. Oldest scan is dropped past this.
    max_cached_roots = 8

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._lock = threading.Lock()
        self._scans: dict[str, tuple[list[Profile], float]] = {}

    def root_for(self, subpath: str = "") -> Path:
        """Absolute path of a client-nominated library root.

        Raises `UnsafePathError` for anything that escapes the media root — the
        caller turns that into a 404, the same as any other bad path.
        """
        cleaned = (subpath or "").strip("/")
        if not cleaned:
            return self._settings.media_root
        return resolve_under_root(self._settings.media_root, cleaned)

    def profiles(self, subpath: str = "", *, force: bool = False) -> list[Profile]:
        key = (subpath or "").strip("/")
        root = self.root_for(key)

        with self._lock:
            cached = self._scans.get(key)
            if cached is not None and not force:
                if time.monotonic() - cached[1] <= self._settings.scan_cache_ttl:
                    return cached[0]

            profiles = scan(
                root,
                trash_root=self._settings.trash_root,
                # Paths stay relative to the media root whatever the scan root is,
                # so /api/files, likes, and deletes mean the same thing in every
                # root the client might pick.
                path_root=self._settings.media_root,
            )
            self._scans[key] = (profiles, time.monotonic())
            self._evict_oldest_locked()
            return profiles

    def profile(self, profile_id: str, subpath: str = "") -> Profile | None:
        return next(
            (p for p in self.profiles(subpath) if p.id == profile_id),
            None,
        )

    def invalidate(self) -> None:
        with self._lock:
            self._scans.clear()

    def _evict_oldest_locked(self) -> None:
        while len(self._scans) > self.max_cached_roots:
            oldest = min(self._scans, key=lambda key: self._scans[key][1])
            del self._scans[oldest]
