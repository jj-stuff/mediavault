"""Path resolution with traversal protection.

Every request-supplied path goes through `resolve_under_root`. Nothing else in the
codebase should build a filesystem path from user input.
"""

from __future__ import annotations

from pathlib import Path


class UnsafePathError(Exception):
    """Raised when a request path escapes the media root."""


def resolve_under_root(root: Path, relative: str) -> Path:
    """Resolves `relative` against `root`, rejecting anything that escapes it.

    Guards against `../` traversal, absolute paths, and symlinks pointing outside
    the library. `strict=False` so we can still resolve paths that do not exist and
    return a clean 404 rather than leaking the difference between "outside the root"
    and "missing".
    """
    cleaned = relative.strip("/")
    if not cleaned:
        raise UnsafePathError("empty path")

    resolved_root = root.resolve()
    candidate = (resolved_root / cleaned).resolve(strict=False)

    if candidate != resolved_root and resolved_root not in candidate.parents:
        raise UnsafePathError(f"path escapes media root: {relative!r}")

    return candidate


def relative_to_root(root: Path, path: Path) -> str:
    """POSIX-style path relative to the root, as the iOS client expects."""
    return path.resolve().relative_to(root.resolve()).as_posix()
