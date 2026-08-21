"""MediaVault server.

Serves the API that the iOS client's RemoteServerService expects:

    GET    /                          login page (opened in the app's WKWebView)
    POST   /login                     sets the session cookie
    GET    /api/auth/check            200 when signed in
    GET    /api/folders               subfolders of one folder, for the root picker
    GET    /api/profiles              profile list
    GET    /api/profiles/{id}/items   every media item in a profile
    GET    /api/files/{path}          raw media, with Range support
    GET    /api/thumbnails/{path}     cached JPEG thumbnail
    DELETE /api/media/{path}          moves a file to <root>/Trash

`/api/folders`, `/api/profiles`, and `/api/profiles/{id}/items` all take an optional
`root=` — a folder below the media root that the client wants to treat as its
library. Paths in every response stay relative to the media root regardless, so the
file, thumbnail, and delete routes are unaffected by the choice.
"""

from __future__ import annotations

import shutil
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel
from starlette.middleware.sessions import SessionMiddleware

from . import auth, media, thumbs
from .config import Settings
from .library import FolderEntry, LibraryCache, Profile, list_folders
from .paths import UnsafePathError, resolve_under_root


# MARK: - Response models
# Field names are snake_case here and serialized to camelCase, matching the Codable
# DTOs in RemoteServerService.swift.


class CamelModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)


class ProfileDTO(CamelModel):
    id: str
    name: str
    image_count: int
    video_count: int
    subfolders: list[str]
    thumbnail_path: str | None
    # Relative to the media root, so it survives the client changing library root.
    # Only equal to `id` when the library root is the media root.
    path: str


class ProfilesResponse(CamelModel):
    profiles: list[ProfileDTO]


class ItemDTO(CamelModel):
    file_name: str
    media_type: str
    subfolder: str | None
    path: str
    # Optional so a file the server cannot stat still reaches the client. Seconds
    # since the epoch rather than a formatted date: a date format is one more thing
    # for the two halves to disagree about.
    byte_size: int | None = None
    modified_at: float | None = None


class ItemsResponse(CamelModel):
    items: list[ItemDTO]


class FolderDTO(CamelModel):
    name: str
    path: str
    folder_count: int
    item_count: int


class FoldersResponse(CamelModel):
    #: The folder that was listed, relative to the media root. Empty at the top.
    path: str
    #: Parent of `path`, or `None` when already at the media root — the picker uses
    #: it for its back step rather than doing path arithmetic of its own.
    parent: str | None
    folders: list[FolderDTO]


def _profile_dto(profile: Profile) -> ProfileDTO:
    return ProfileDTO(
        id=profile.id,
        name=profile.name,
        image_count=profile.image_count,
        video_count=profile.video_count,
        subfolders=profile.subfolders,
        thumbnail_path=profile.thumbnail_path,
        path=profile.path,
    )


def _folder_dto(entry: FolderEntry) -> FolderDTO:
    return FolderDTO(
        name=entry.name,
        path=entry.path,
        folder_count=entry.folder_count,
        item_count=entry.item_count,
    )


# MARK: - App


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings: Settings = app.state.settings
    settings.thumb_cache_dir.mkdir(parents=True, exist_ok=True)

    # Reported on every boot. "Is the path right?" is the most common setup
    # question, and the answer is knowable at startup — so say it rather than
    # leaving an empty library in the app as the only symptom.
    _report_library(app)

    # If this path is not on a mounted volume, deleted files are written into the
    # container's own filesystem and are gone when it is next recreated.
    if settings.delete_mode == "permanent":
        print("[mediavault] delete mode: permanent — deleted files are not recoverable")
    else:
        print(
            f"[mediavault] deleted files go to {settings.trash_root} "
            f"(delete mode: {settings.delete_mode})"
        )
    yield


def _report_library(app: FastAPI) -> None:
    settings: Settings = app.state.settings
    root = settings.media_root

    if not root.is_dir():
        print(
            f"[mediavault] WARNING: {root} does not exist inside the container.\n"
            f"[mediavault]   MEDIAVAULT_MEDIA_ROOT is a path *inside* the container,\n"
            f"[mediavault]   not on the NAS. Mount your media folder to {root},\n"
            f"[mediavault]   or set MEDIAVAULT_MEDIA_ROOT to wherever you mounted it."
        )
        return

    profiles = app.state.library.profiles(force=True)
    if not profiles:
        entries = sorted(p.name for p in root.iterdir() if not p.name.startswith("."))
        print(
            f"[mediavault] WARNING: {root} exists but contains no profiles.\n"
            f"[mediavault]   Each immediate subfolder becomes a profile, and only\n"
            f"[mediavault]   folders containing supported media count.\n"
            f"[mediavault]   Found in {root}: {entries[:10] or 'nothing'}"
        )
        return

    total = sum(len(p.items) for p in profiles)
    names = ", ".join(p.name for p in profiles[:5])
    suffix = ", …" if len(profiles) > 5 else ""
    print(
        f"[mediavault] serving {root} — "
        f"{len(profiles)} profiles, {total} items ({names}{suffix})"
    )


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()

    app = FastAPI(title="MediaVault", lifespan=lifespan)
    app.state.settings = settings
    app.state.library = LibraryCache(settings)
    app.state.login_throttle = auth.LoginThrottle()

    # Signed cookie session. `same_site="lax"` keeps it attached to the top-level
    # requests AVPlayer makes; `https_only` should be on behind a TLS proxy.
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.secret_key,
        session_cookie="mediavault_session",
        max_age=settings.session_max_age,
        same_site="lax",
        https_only=settings.https_only,
    )

    app.include_router(auth.router)
    app.include_router(_api_router())
    return app


def _library(request: Request) -> LibraryCache:
    return request.app.state.library


def _settings(request: Request) -> Settings:
    return request.app.state.settings


#: Folder below the media root that the client wants to treat as its library.
#: Empty — the default — means the media root itself, which is what every client
#: did before the setting existed.
#:
#: `Annotated` rather than a shared `Query(...)` default: FastAPI binds a bare
#: `Query` instance to the *first* parameter that uses it and reuses that name
#: everywhere after, so sharing one silently made every route read `?path=`.
LibraryRoot = Annotated[
    str,
    Query(description="Folder below the media root to treat as the library root."),
]


def _library_root(request: Request, root: str) -> str:
    """Validates a client-nominated library root and returns its normalised key.

    A missing folder is a 404 rather than an empty library: a root that has been
    renamed on the NAS should say so, not look like a library with nothing in it.
    """
    try:
        resolved = _library(request).root_for(root)
    except UnsafePathError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from None

    if not resolved.is_dir():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No folder named {root!r} on the server.",
        )
    return (root or "").strip("/")


def _resolve(request: Request, relative: str) -> Path:
    """Resolves a client-supplied relative path to a real file under the media root."""
    try:
        return resolve_under_root(_settings(request).media_root, relative)
    except UnsafePathError:
        # Deliberately a 404, not a 403: do not confirm that a path exists elsewhere.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from None


def _api_router():
    from fastapi import APIRouter

    router = APIRouter(prefix="/api", dependencies=[Depends(auth.require_auth)])

    @router.get("/folders", response_model=FoldersResponse)
    async def list_library_folders(
        request: Request, path: LibraryRoot = ""
    ) -> FoldersResponse:
        """Subfolders of one folder, so the app can walk the tree and pick a root."""
        key = _library_root(request, path)
        settings = _settings(request)
        directory = _library(request).root_for(key)

        folders = await run_in_threadpool(
            list_folders, directory, settings.media_root, settings.trash_root
        )

        parent: str | None = None
        if key:
            above = PurePosixPath(key).parent.as_posix()
            parent = "" if above == "." else above

        return FoldersResponse(
            path=key,
            parent=parent,
            folders=[_folder_dto(entry) for entry in folders],
        )

    @router.get("/profiles", response_model=ProfilesResponse)
    async def list_profiles(request: Request, root: LibraryRoot = "") -> ProfilesResponse:
        key = _library_root(request, root)
        profiles = await run_in_threadpool(_library(request).profiles, key)
        return ProfilesResponse(profiles=[_profile_dto(p) for p in profiles])

    @router.post("/profiles/refresh", response_model=ProfilesResponse)
    async def refresh_profiles(
        request: Request, root: LibraryRoot = ""
    ) -> ProfilesResponse:
        key = _library_root(request, root)
        library = _library(request)
        profiles = await run_in_threadpool(lambda: library.profiles(key, force=True))
        return ProfilesResponse(profiles=[_profile_dto(p) for p in profiles])

    @router.get("/profiles/{profile_id}/items", response_model=ItemsResponse)
    async def list_items(
        request: Request, profile_id: str, root: LibraryRoot = ""
    ) -> ItemsResponse:
        key = _library_root(request, root)
        library = _library(request)
        profile = await run_in_threadpool(library.profile, profile_id, key)
        if profile is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        return ItemsResponse(
            items=[
                ItemDTO(
                    file_name=item.file_name,
                    media_type=item.media_type,
                    subfolder=item.subfolder,
                    path=item.path,
                    byte_size=item.byte_size,
                    modified_at=item.modified_at,
                )
                for item in profile.items
            ]
        )

    @router.api_route("/files/{path:path}", methods=["GET", "HEAD"])
    def get_file(request: Request, path: str) -> Response:
        target = _resolve(request, path)
        return media.file_response(request, target, download_name=target.name)

    @router.api_route("/thumbnails/{path:path}", methods=["GET", "HEAD"])
    async def get_thumbnail(request: Request, path: str) -> Response:
        target = _resolve(request, path)
        thumbnail = await run_in_threadpool(
            thumbs.thumbnail_for, target, path, _settings(request)
        )
        if thumbnail is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        return media.file_response(request, thumbnail)

    @router.delete("/media/{path:path}")
    async def delete_media(request: Request, path: str) -> dict[str, str]:
        settings = _settings(request)
        target = _resolve(request, path)
        if not target.is_file():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)

        try:
            outcome, destination = await run_in_threadpool(
                _dispose, settings, target, path
            )
        except OSError as error:
            # The client shows this string verbatim, so it has to say what to do
            # about it rather than repeat errno.
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=(
                    f"Could not delete {path}: {error.strerror or error}. "
                    f"The media root may be mounted read-only, or owned by a "
                    f"different user than the server runs as. Point "
                    f"MEDIAVAULT_TRASH_DIR at a writable volume, or set "
                    f"MEDIAVAULT_DELETE_MODE=permanent."
                ),
            ) from error

        _library(request).invalidate()
        return {"status": outcome, "path": destination}

    return router


def _dispose(settings: Settings, source: Path, relative: str) -> tuple[str, str]:
    """Gets rid of one file, and reports how.

    Returns `("trashed", <path under the trash root>)` or `("deleted", <path>)`.

    A trash move is preferred, but it is not always available: a media root that is
    bind-mounted read-only, or owned by a different uid than the server runs as,
    cannot have a `Trash` folder created inside it. That used to surface as a bare
    500 on a button the user had already confirmed, with the real reason —
    `PermissionError` on `mkdir` — buried in the traceback. Under the default `auto`
    mode the file is unlinked instead, which is what the user asked for either way.
    """
    if settings.delete_mode == "permanent":
        source.unlink()
        return "deleted", relative

    try:
        return "trashed", _move_to_trash(settings.trash_root, source, relative)
    except OSError as error:
        if settings.delete_mode == "trash":
            raise
        print(
            f"[mediavault] trash unavailable ({error.strerror or error}); "
            f"deleting {relative} outright. Set MEDIAVAULT_TRASH_DIR to a writable "
            f"volume to keep deletes recoverable."
        )
        source.unlink()
        return "deleted", relative


def _move_to_trash(trash_root: Path, source: Path, relative: str) -> str:
    """Moves a file into the trash, preserving its folder structure.

    Keeping the relative path means `alice/1.jpg` and `bob/1.jpg` do not collide,
    and a mistaken delete can be put back where it came from.
    """
    destination = trash_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)

    if destination.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
        destination = destination.with_name(
            f"{destination.stem}_{stamp}{destination.suffix}"
        )

    # shutil.move rather than Path.rename: the trash may be on a different filesystem
    # from the media itself when the library spans mounts.
    shutil.move(str(source), str(destination))
    return destination.relative_to(trash_root).as_posix()
