"""Environment-driven configuration.

Every value the server needs comes from the environment so the container can be
reconfigured without rebuilding the image.
"""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path

# Must stay in sync with MediaItem.imageExtensions / videoExtensions in the iOS app.
IMAGE_EXTENSIONS: frozenset[str] = frozenset(
    {"jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"}
)
VIDEO_EXTENSIONS: frozenset[str] = frozenset(
    {"mp4", "mov", "m4v", "avi", "mkv", "wmv"}
)

# Folder at the media root that deleted files are moved into. Skipped when scanning
# so it never shows up as a profile.
TRASH_DIR_NAME = "Trash"


def _env_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default)).expanduser()


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    media_root: Path
    password: str
    secret_key: str
    thumb_cache_dir: Path
    session_max_age: int
    scan_cache_ttl: int
    thumb_size: int
    https_only: bool
    #: Where deleted files go. `None` means `<media_root>/Trash`.
    #:
    #: Worth overriding when each profile is its own bind mount: in that setup
    #: `/media` itself is the container's own filesystem, so a trash folder inside
    #: it would be destroyed the next time the container is recreated — turning
    #: "move to Trash" into a permanent delete.
    trash_dir: Path | None = None

    @property
    def trash_root(self) -> Path:
        return self.trash_dir or self.media_root / TRASH_DIR_NAME

    @classmethod
    def from_env(cls) -> "Settings":
        password = os.environ.get("MEDIAVAULT_PASSWORD", "").strip()
        if not password:
            raise RuntimeError(
                "MEDIAVAULT_PASSWORD is not set. Refusing to start an unprotected "
                "server that exposes your media library."
            )

        secret_key = os.environ.get("MEDIAVAULT_SECRET_KEY", "").strip()
        if not secret_key:
            # Usable, but every restart invalidates existing sessions and forces the
            # phone to sign in again. Set it explicitly in production.
            secret_key = secrets.token_urlsafe(32)
            print(
                "[mediavault] WARNING: MEDIAVAULT_SECRET_KEY unset, generated an "
                "ephemeral key. Sessions will not survive a restart."
            )

        trash_raw = os.environ.get("MEDIAVAULT_TRASH_DIR", "").strip()

        return cls(
            media_root=_env_path("MEDIAVAULT_MEDIA_ROOT", "/media"),
            trash_dir=Path(trash_raw).expanduser() if trash_raw else None,
            password=password,
            secret_key=secret_key,
            thumb_cache_dir=_env_path("MEDIAVAULT_THUMB_CACHE", "/cache/thumbs"),
            session_max_age=_env_int("MEDIAVAULT_SESSION_MAX_AGE", 60 * 60 * 24 * 30),
            scan_cache_ttl=_env_int("MEDIAVAULT_SCAN_CACHE_TTL", 300),
            thumb_size=_env_int("MEDIAVAULT_THUMB_SIZE", 400),
            https_only=os.environ.get("MEDIAVAULT_HTTPS_ONLY", "").lower()
            in {"1", "true", "yes"},
        )


def media_type_for(extension: str) -> str | None:
    """Returns "image", "video", or None for an unsupported extension."""
    lowered = extension.lower().lstrip(".")
    if lowered in IMAGE_EXTENSIONS:
        return "image"
    if lowered in VIDEO_EXTENSIONS:
        return "video"
    return None
