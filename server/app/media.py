"""Byte-range file serving.

AVPlayer will not scrub — and for some containers will not play at all — unless the
server honours `Range`. Starlette's FileResponse handles the simple case, but this
does the parsing explicitly so seeking, suffix ranges, and 416 all behave.
"""

from __future__ import annotations

import mimetypes
import re
from pathlib import Path
from typing import Iterator

from fastapi import HTTPException, Request, status
from fastapi.responses import FileResponse, Response, StreamingResponse

_CHUNK_SIZE = 1024 * 512  # 512 KiB
_RANGE_PATTERN = re.compile(r"^bytes=(\d*)-(\d*)$")

# mimetypes misses several container formats that matter for an iOS media library.
_EXTRA_TYPES = {
    ".mkv": "video/x-matroska",
    ".m4v": "video/x-m4v",
    ".mov": "video/quicktime",
    ".heic": "image/heic",
    ".heif": "image/heif",
    ".webp": "image/webp",
    ".avi": "video/x-msvideo",
    ".wmv": "video/x-ms-wmv",
}


def content_type_for(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in _EXTRA_TYPES:
        return _EXTRA_TYPES[suffix]
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "application/octet-stream"


def _parse_range(header: str, file_size: int) -> tuple[int, int] | None:
    """Returns an inclusive (start, end) pair, or None if the header is malformed.

    Raises HTTPException(416) when the header parses but cannot be satisfied.
    """
    match = _RANGE_PATTERN.match(header.strip())
    if match is None:
        return None  # Multi-range and unknown units: fall back to the full body.

    raw_start, raw_end = match.group(1), match.group(2)

    if raw_start == "" and raw_end == "":
        return None

    if raw_start == "":
        # Suffix form: "bytes=-500" means the final 500 bytes.
        length = int(raw_end)
        if length <= 0:
            raise HTTPException(
                status_code=status.HTTP_416_RANGE_NOT_SATISFIABLE,
                headers={"Content-Range": f"bytes */{file_size}"},
            )
        start = max(0, file_size - length)
        end = file_size - 1
    else:
        start = int(raw_start)
        end = int(raw_end) if raw_end else file_size - 1
        end = min(end, file_size - 1)

    if start >= file_size or start > end:
        raise HTTPException(
            status_code=status.HTTP_416_RANGE_NOT_SATISFIABLE,
            headers={"Content-Range": f"bytes */{file_size}"},
        )

    return start, end


def _iter_range(path: Path, start: int, end: int) -> Iterator[bytes]:
    remaining = end - start + 1
    with path.open("rb") as handle:
        handle.seek(start)
        while remaining > 0:
            chunk = handle.read(min(_CHUNK_SIZE, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


def file_response(request: Request, path: Path, *, download_name: str | None = None) -> Response:
    """Serves `path`, honouring Range and HEAD."""
    if not path.is_file():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)

    file_size = path.stat().st_size
    media_type = content_type_for(path)
    headers = {"Accept-Ranges": "bytes"}
    if download_name:
        headers["Content-Disposition"] = f'inline; filename="{download_name}"'

    range_header = request.headers.get("range")
    resolved = _parse_range(range_header, file_size) if range_header else None

    if resolved is None:
        if request.method == "HEAD":
            return Response(
                status_code=status.HTTP_200_OK,
                media_type=media_type,
                headers={**headers, "Content-Length": str(file_size)},
            )
        return FileResponse(path, media_type=media_type, headers=headers)

    start, end = resolved
    headers |= {
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Content-Length": str(end - start + 1),
    }

    if request.method == "HEAD":
        return Response(
            status_code=status.HTTP_206_PARTIAL_CONTENT,
            media_type=media_type,
            headers=headers,
        )

    return StreamingResponse(
        _iter_range(path, start, end),
        status_code=status.HTTP_206_PARTIAL_CONTENT,
        media_type=media_type,
        headers=headers,
    )
