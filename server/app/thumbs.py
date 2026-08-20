"""Thumbnail generation with an on-disk cache.

Images go through Pillow, videos through ffmpeg. Results are cached under a key
derived from the file's identity (path + mtime + size) and the configured size, so
replacing a file on disk transparently invalidates its thumbnail.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageOps

from .config import Settings, media_type_for

try:  # HEIC/HEIF is common on iPhone libraries but needs a Pillow plugin.
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:  # pragma: no cover - the Docker image always installs it
    print("[mediavault] WARNING: pillow-heif missing, HEIC thumbnails unavailable.")

THUMB_MEDIA_TYPE = "image/jpeg"
_JPEG_QUALITY = 82
_FFMPEG_TIMEOUT_SECONDS = 30


def _cache_key(source: Path, relative: str, size: int) -> str:
    try:
        stat = source.stat()
        identity = f"{relative}:{stat.st_mtime_ns}:{stat.st_size}:{size}"
    except OSError:
        identity = f"{relative}:missing:{size}"
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _write_atomically(destination: Path, write) -> None:
    """Writes via a temp file in the same directory, then renames.

    Concurrent requests for the same thumbnail each render into their own temp file;
    the rename is atomic so a reader never sees a half-written JPEG.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(dir=destination.parent, suffix=".tmp")
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        write(temp_path)
        temp_path.replace(destination)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def _render_image(source: Path, destination: Path, size: int) -> None:
    def write(target: Path) -> None:
        with Image.open(source) as image:
            # Honours the EXIF orientation tag so portrait photos are not sideways.
            image = ImageOps.exif_transpose(image)
            image.thumbnail((size, size), Image.Resampling.LANCZOS)
            if image.mode not in ("RGB", "L"):
                image = image.convert("RGB")
            image.save(target, format="JPEG", quality=_JPEG_QUALITY, optimize=True)

    _write_atomically(destination, write)


def _render_video(source: Path, destination: Path, size: int) -> None:
    def write(target: Path) -> None:
        # Try one second in first: the very first frame of a video is often black.
        for seek in ("1", "0"):
            result = subprocess.run(
                [
                    "ffmpeg",
                    "-nostdin",
                    "-loglevel", "error",
                    "-ss", seek,
                    "-i", str(source),
                    "-frames:v", "1",
                    "-vf", f"scale={size}:{size}:force_original_aspect_ratio=decrease",
                    "-q:v", "3",
                    "-f", "image2",
                    "-y",
                    str(target),
                ],
                capture_output=True,
                timeout=_FFMPEG_TIMEOUT_SECONDS,
                check=False,
            )
            if result.returncode == 0 and target.stat().st_size > 0:
                return
        raise RuntimeError(f"ffmpeg could not extract a frame from {source.name}")

    _write_atomically(destination, write)


def thumbnail_for(source: Path, relative: str, settings: Settings) -> Path | None:
    """Returns a cached thumbnail path, rendering it on first request.

    Blocking (Pillow decode / ffmpeg subprocess) — call it off the event loop.
    Returns None when the file is unsupported or cannot be rendered.
    """
    kind = media_type_for(source.suffix)
    if kind is None or not source.is_file():
        return None

    size = settings.thumb_size
    key = _cache_key(source, relative, size)
    # Two-level fan-out keeps any single cache directory from growing unbounded.
    destination = settings.thumb_cache_dir / key[:2] / f"{key}.jpg"

    if destination.is_file() and destination.stat().st_size > 0:
        return destination

    try:
        if kind == "image":
            _render_image(source, destination, size)
        else:
            _render_video(source, destination, size)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"[mediavault] thumbnail failed for {relative}: {error}")
        return None

    return destination if destination.is_file() else None
