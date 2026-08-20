"""Scans the media root into profiles.

Mirrors MediaScannerService on the iOS side: each immediate subfolder of the media
root is a profile, media directly inside it is un-foldered, and every nested folder
below that is a subfolder (recursively, attributed to its top-level subfolder name).
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .config import TRASH_DIR_NAME, Settings, media_type_for
from .paths import relative_to_root


@dataclass(frozen=True)
class MediaItem:
    file_name: str
    media_type: str  # "image" | "video"
    subfolder: str | None
    path: str  # POSIX path relative to the media root, e.g. "alice/photo.jpg"


@dataclass
class Profile:
    id: str  # top-level folder name, used in URL paths
    name: str  # display name
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
    directory: Path, root: Path, subfolder: str | None
) -> list[MediaItem]:
    """Media files directly inside `directory` (non-recursive)."""
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
        items.append(
            MediaItem(
                file_name=entry.name,
                media_type=kind,
                subfolder=subfolder,
                path=relative_to_root(root, entry),
            )
        )
    return items


def _collect_recursive(
    directory: Path, root: Path, subfolder: str
) -> list[MediaItem]:
    """Media in `directory` and everything below it, all tagged with `subfolder`."""
    items = _collect_media(directory, root, subfolder)
    try:
        entries = sorted(directory.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return items

    for entry in entries:
        if entry.is_dir() and not _is_hidden(entry):
            items.extend(_collect_recursive(entry, root, subfolder))
    return items


def _scan_profile(folder: Path, root: Path) -> Profile:
    profile = Profile(id=folder.name, name=folder.name)
    profile.items.extend(_collect_media(folder, root, None))

    try:
        entries = sorted(folder.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        entries = []

    for entry in entries:
        if not entry.is_dir() or _is_hidden(entry):
            continue
        profile.subfolders.append(entry.name)
        profile.items.extend(_collect_recursive(entry, root, entry.name))

    return profile


def scan(root: Path) -> list[Profile]:
    """Full scan of the media root. Profiles with no media are omitted."""
    if not root.is_dir():
        return []

    profiles: list[Profile] = []
    for entry in sorted(root.iterdir(), key=lambda p: p.name.lower()):
        if not entry.is_dir() or _is_hidden(entry):
            continue
        if entry.name == TRASH_DIR_NAME:
            continue
        profile = _scan_profile(entry, root)
        if profile.items:
            profiles.append(profile)

    profiles.sort(key=lambda p: p.name.lower())
    return profiles


class LibraryCache:
    """Caches the scan result.

    A full walk of a large library is expensive and the client refetches on every
    launch and toggle, so results are held for `scan_cache_ttl` seconds. Deletes
    invalidate the cache directly rather than waiting for expiry.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._lock = threading.Lock()
        self._profiles: list[Profile] | None = None
        self._scanned_at: float = 0.0

    def profiles(self, *, force: bool = False) -> list[Profile]:
        with self._lock:
            age = time.monotonic() - self._scanned_at
            stale = self._profiles is None or age > self._settings.scan_cache_ttl
            if force or stale:
                self._profiles = scan(self._settings.media_root)
                self._scanned_at = time.monotonic()
            return self._profiles or []

    def profile(self, profile_id: str) -> Profile | None:
        return next((p for p in self.profiles() if p.id == profile_id), None)

    def invalidate(self) -> None:
        with self._lock:
            self._profiles = None
            self._scanned_at = 0.0
