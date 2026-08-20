"""MediaVault server.

Serves the API that the iOS client's RemoteServerService expects:

    GET    /                          login page (opened in the app's WKWebView)
    POST   /login                     sets the session cookie
    GET    /api/auth/check            200 when signed in
    GET    /api/profiles              profile list
    GET    /api/profiles/{id}/items   every media item in a profile
    GET    /api/files/{path}          raw media, with Range support
    GET    /api/thumbnails/{path}     cached JPEG thumbnail
    DELETE /api/media/{path}          moves a file to <root>/Trash
"""

from __future__ import annotations

import shutil
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel
from starlette.middleware.sessions import SessionMiddleware

from . import auth, media, thumbs
from .config import TRASH_DIR_NAME, Settings
from .library import LibraryCache, Profile
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


class ProfilesResponse(CamelModel):
    profiles: list[ProfileDTO]


class ItemDTO(CamelModel):
    file_name: str
    media_type: str
    subfolder: str | None
    path: str


class ItemsResponse(CamelModel):
    items: list[ItemDTO]


def _profile_dto(profile: Profile) -> ProfileDTO:
    return ProfileDTO(
        id=profile.id,
        name=profile.name,
        image_count=profile.image_count,
        video_count=profile.video_count,
        subfolders=profile.subfolders,
        thumbnail_path=profile.thumbnail_path,
    )


# MARK: - App


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings: Settings = app.state.settings
    settings.thumb_cache_dir.mkdir(parents=True, exist_ok=True)
    if not settings.media_root.is_dir():
        print(
            f"[mediavault] WARNING: media root {settings.media_root} does not exist. "
            "Check the volume mount."
        )
    else:
        print(f"[mediavault] serving {settings.media_root}")
    yield


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

    @router.get("/profiles", response_model=ProfilesResponse)
    async def list_profiles(request: Request) -> ProfilesResponse:
        profiles = await run_in_threadpool(_library(request).profiles)
        return ProfilesResponse(profiles=[_profile_dto(p) for p in profiles])

    @router.post("/profiles/refresh", response_model=ProfilesResponse)
    async def refresh_profiles(request: Request) -> ProfilesResponse:
        library = _library(request)
        profiles = await run_in_threadpool(lambda: library.profiles(force=True))
        return ProfilesResponse(profiles=[_profile_dto(p) for p in profiles])

    @router.get("/profiles/{profile_id}/items", response_model=ItemsResponse)
    async def list_items(request: Request, profile_id: str) -> ItemsResponse:
        library = _library(request)
        profile = await run_in_threadpool(library.profile, profile_id)
        if profile is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        return ItemsResponse(
            items=[
                ItemDTO(
                    file_name=item.file_name,
                    media_type=item.media_type,
                    subfolder=item.subfolder,
                    path=item.path,
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

        destination = await run_in_threadpool(
            _move_to_trash, settings.media_root, target, path
        )
        _library(request).invalidate()
        return {"status": "trashed", "path": destination}

    return router


def _move_to_trash(root: Path, source: Path, relative: str) -> str:
    """Moves a file into <root>/Trash, preserving its folder structure.

    Keeping the relative path means `alice/1.jpg` and `bob/1.jpg` do not collide,
    and a mistaken delete can be put back where it came from.
    """
    trash_root = root / TRASH_DIR_NAME
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
    return destination.relative_to(root).as_posix()
