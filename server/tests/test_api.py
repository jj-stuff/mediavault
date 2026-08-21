"""Contract tests for the API the iOS client consumes.

The response shapes here are asserted in camelCase on purpose: they must match the
Codable DTOs in app/MediaVault/Services/RemoteServerService.swift exactly.
"""

from __future__ import annotations

import shutil
from dataclasses import replace
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app

PASSWORD = "test-password"


def _write_image(path: Path, color: str = "red") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (64, 48), color).save(path, format="JPEG")


@pytest.fixture
def media_root(tmp_path: Path) -> Path:
    root = tmp_path / "media"
    _write_image(root / "alice" / "cover.jpg")
    _write_image(root / "alice" / "beach" / "swim.jpg", "blue")
    _write_image(root / "alice" / "beach" / "deep" / "nested.jpg", "green")
    _write_image(root / "bob" / "portrait.png")
    (root / "bob" / "notes.txt").write_text("ignored")
    (root / "empty").mkdir()
    (root / ".hidden").mkdir()
    _write_image(root / ".hidden" / "secret.jpg")
    return root


@pytest.fixture
def settings(media_root: Path, tmp_path: Path) -> Settings:
    return Settings(
        media_root=media_root,
        password=PASSWORD,
        secret_key="test-secret-key",
        thumb_cache_dir=tmp_path / "thumbs",
        session_max_age=3600,
        scan_cache_ttl=300,
        thumb_size=200,
        https_only=False,
    )


@pytest.fixture
def client(settings: Settings):
    with TestClient(create_app(settings)) as test_client:
        yield test_client


@pytest.fixture
def auth_client(client: TestClient) -> TestClient:
    response = client.post("/login", data={"password": PASSWORD}, follow_redirects=False)
    assert response.status_code == 303
    return client


# MARK: - Auth


def test_api_requires_auth(client: TestClient) -> None:
    assert client.get("/api/profiles").status_code == 401
    assert client.get("/api/auth/check").status_code == 401
    assert client.get("/api/files/alice/cover.jpg").status_code == 401


def test_wrong_password_rejected(client: TestClient) -> None:
    response = client.post("/login", data={"password": "nope"}, follow_redirects=False)
    assert response.status_code == 401
    assert client.get("/api/auth/check").status_code == 401


def test_login_grants_session(auth_client: TestClient) -> None:
    assert auth_client.get("/api/auth/check").status_code == 200


def test_logout_clears_session(auth_client: TestClient) -> None:
    auth_client.post("/logout", follow_redirects=False)
    assert auth_client.get("/api/auth/check").status_code == 401


def test_login_throttles_repeated_failures(client: TestClient) -> None:
    codes = [
        client.post("/login", data={"password": "bad"}, follow_redirects=False).status_code
        for _ in range(10)
    ]
    assert 429 in codes


# MARK: - Profiles


def test_profiles_shape_and_contents(auth_client: TestClient) -> None:
    payload = auth_client.get("/api/profiles").json()
    profiles = payload["profiles"]

    # "empty" has no media and ".hidden" is hidden, so neither is a profile.
    assert [p["id"] for p in profiles] == ["alice", "bob"]

    alice = profiles[0]
    assert set(alice) == {
        "id", "name", "imageCount", "videoCount", "subfolders", "thumbnailPath", "path"
    }
    assert alice["name"] == "alice"
    assert alice["path"] == "alice"
    assert alice["imageCount"] == 3  # cover + swim + nested
    assert alice["videoCount"] == 0
    assert alice["subfolders"] == ["beach"]
    assert alice["thumbnailPath"].startswith("alice/")


def test_items_shape_and_subfolder_attribution(auth_client: TestClient) -> None:
    items = auth_client.get("/api/profiles/alice/items").json()["items"]
    assert {i["fileName"] for i in items} == {"cover.jpg", "swim.jpg", "nested.jpg"}

    by_name = {i["fileName"]: i for i in items}
    assert set(by_name["cover.jpg"]) == {
        "fileName", "mediaType", "subfolder", "path", "byteSize", "modifiedAt"
    }
    assert by_name["cover.jpg"]["subfolder"] is None
    assert by_name["cover.jpg"]["path"] == "alice/cover.jpg"
    assert by_name["swim.jpg"]["subfolder"] == "beach"
    # Nested folders are attributed to their top-level subfolder, matching the app.
    assert by_name["nested.jpg"]["subfolder"] == "beach"
    assert by_name["nested.jpg"]["path"] == "alice/beach/deep/nested.jpg"
    assert all(i["mediaType"] == "image" for i in items)


def test_unsupported_extensions_excluded(auth_client: TestClient) -> None:
    items = auth_client.get("/api/profiles/bob/items").json()["items"]
    assert [i["fileName"] for i in items] == ["portrait.png"]


def test_unknown_profile_404(auth_client: TestClient) -> None:
    assert auth_client.get("/api/profiles/nobody/items").status_code == 404


# MARK: - Library root


def test_folders_lists_candidate_roots(auth_client: TestClient) -> None:
    payload = auth_client.get("/api/folders").json()

    assert payload["path"] == ""
    # Nothing above the media root, so the picker has nowhere to go back to.
    assert payload["parent"] is None

    by_name = {f["name"]: f for f in payload["folders"]}
    # "empty" is listed even though it is not a profile: a folder you might grow a
    # library in is still a folder you can point the app at.
    assert set(by_name) == {"alice", "bob", "empty"}
    assert by_name["alice"]["path"] == "alice"
    assert by_name["alice"]["folderCount"] == 1  # beach
    assert by_name["alice"]["itemCount"] == 1  # cover.jpg, not the nested ones
    assert by_name["empty"] == {
        "name": "empty", "path": "empty", "folderCount": 0, "itemCount": 0
    }


def test_folders_descends_and_reports_its_parent(auth_client: TestClient) -> None:
    payload = auth_client.get("/api/folders", params={"path": "alice"}).json()

    assert payload["path"] == "alice"
    assert payload["parent"] == ""
    assert [f["path"] for f in payload["folders"]] == ["alice/beach"]

    deeper = auth_client.get("/api/folders", params={"path": "alice/beach"}).json()
    assert deeper["parent"] == "alice"


def test_trash_is_not_offered_as_a_root(auth_client: TestClient) -> None:
    auth_client.delete("/api/media/alice/cover.jpg")
    names = [f["name"] for f in auth_client.get("/api/folders").json()["folders"]]
    assert "Trash" not in names


@pytest.mark.parametrize("path", ["../..", "alice/../../etc", "/etc"])
def test_folders_traversal_blocked(auth_client: TestClient, path: str) -> None:
    assert auth_client.get("/api/folders", params={"path": path}).status_code == 404


def test_unknown_root_is_404_not_an_empty_library(auth_client: TestClient) -> None:
    """A renamed folder should say so rather than look like an empty library."""
    assert auth_client.get("/api/profiles", params={"root": "nope"}).status_code == 404
    assert auth_client.get("/api/folders", params={"path": "nope"}).status_code == 404


def test_root_scopes_the_profile_list(auth_client: TestClient) -> None:
    profiles = auth_client.get("/api/profiles", params={"root": "alice"}).json()["profiles"]

    # Inside alice, the profiles are alice's own subfolders.
    assert [p["id"] for p in profiles] == ["beach"]
    assert profiles[0]["path"] == "alice/beach"
    assert profiles[0]["imageCount"] == 2  # swim + nested


def test_paths_stay_relative_to_the_media_root_under_a_root(
    auth_client: TestClient,
) -> None:
    """The whole point of the design: choosing a root must not move any file.

    Item paths address /api/files, /api/thumbnails and DELETE /api/media, and they
    are also what likes are stored as on the client. If they were relative to the
    chosen root instead, changing it would orphan every like and break every URL.
    """
    items = auth_client.get(
        "/api/profiles/beach/items", params={"root": "alice"}
    ).json()["items"]

    by_name = {i["fileName"]: i for i in items}
    assert by_name["swim.jpg"]["path"] == "alice/beach/swim.jpg"
    assert by_name["swim.jpg"]["subfolder"] is None
    # Attribution is relative to the chosen root too: under alice, "deep" is a
    # subfolder of the beach profile in its own right.
    assert by_name["nested.jpg"]["subfolder"] == "deep"

    assert auth_client.get(f"/api/files/{by_name['swim.jpg']['path']}").status_code == 200


def test_each_root_is_cached_separately(auth_client: TestClient) -> None:
    """One root's cached scan must never be served for another."""
    top = [p["id"] for p in auth_client.get("/api/profiles").json()["profiles"]]
    inside = [
        p["id"]
        for p in auth_client.get("/api/profiles", params={"root": "alice"}).json()[
            "profiles"
        ]
    ]
    top_again = [p["id"] for p in auth_client.get("/api/profiles").json()["profiles"]]

    assert top == ["alice", "bob"]
    assert inside == ["beach"]
    assert top_again == top


def test_refresh_accepts_a_root(auth_client: TestClient) -> None:
    response = auth_client.post("/api/profiles/refresh", params={"root": "alice"})
    assert response.status_code == 200
    assert [p["id"] for p in response.json()["profiles"]] == ["beach"]


def test_root_cache_is_bounded(settings: Settings, media_root: Path) -> None:
    """A client walking the tree must not be able to pin every scan in memory."""
    from app.library import LibraryCache

    for index in range(LibraryCache.max_cached_roots + 3):
        (media_root / f"root{index}").mkdir()

    cache = LibraryCache(settings)
    for index in range(LibraryCache.max_cached_roots + 3):
        cache.profiles(f"root{index}")

    assert len(cache._scans) <= LibraryCache.max_cached_roots


# MARK: - File serving


def test_full_file_download(auth_client: TestClient, media_root: Path) -> None:
    response = auth_client.get("/api/files/alice/cover.jpg")
    assert response.status_code == 200
    assert response.headers["accept-ranges"] == "bytes"
    assert response.headers["content-type"] == "image/jpeg"
    assert response.content == (media_root / "alice" / "cover.jpg").read_bytes()


def test_head_reports_size_without_body(auth_client: TestClient, media_root: Path) -> None:
    size = (media_root / "alice" / "cover.jpg").stat().st_size
    response = auth_client.head("/api/files/alice/cover.jpg")
    assert response.status_code == 200
    assert response.headers["content-length"] == str(size)
    assert response.content == b""


def test_range_request_returns_partial_content(
    auth_client: TestClient, media_root: Path
) -> None:
    source = (media_root / "alice" / "cover.jpg").read_bytes()
    response = auth_client.get(
        "/api/files/alice/cover.jpg", headers={"Range": "bytes=10-19"}
    )
    assert response.status_code == 206
    assert response.headers["content-range"] == f"bytes 10-19/{len(source)}"
    assert response.headers["content-length"] == "10"
    assert response.content == source[10:20]


def test_open_ended_range(auth_client: TestClient, media_root: Path) -> None:
    source = (media_root / "alice" / "cover.jpg").read_bytes()
    response = auth_client.get(
        "/api/files/alice/cover.jpg", headers={"Range": "bytes=5-"}
    )
    assert response.status_code == 206
    assert response.content == source[5:]


def test_suffix_range(auth_client: TestClient, media_root: Path) -> None:
    source = (media_root / "alice" / "cover.jpg").read_bytes()
    response = auth_client.get(
        "/api/files/alice/cover.jpg", headers={"Range": "bytes=-16"}
    )
    assert response.status_code == 206
    assert response.content == source[-16:]


def test_unsatisfiable_range_416(auth_client: TestClient) -> None:
    response = auth_client.get(
        "/api/files/alice/cover.jpg", headers={"Range": "bytes=999999-"}
    )
    assert response.status_code == 416
    assert response.headers["content-range"].startswith("bytes */")


def test_missing_file_404(auth_client: TestClient) -> None:
    assert auth_client.get("/api/files/alice/nope.jpg").status_code == 404


@pytest.mark.parametrize(
    "path",
    [
        "../../../../etc/passwd",
        "alice/../../etc/passwd",
        "alice/../../../etc/hosts",
    ],
)
def test_path_traversal_blocked(auth_client: TestClient, path: str) -> None:
    response = auth_client.get(f"/api/files/{path}")
    assert response.status_code == 404


def test_symlink_out_of_root_blocked(
    auth_client: TestClient, media_root: Path, tmp_path: Path
) -> None:
    outside = tmp_path / "outside.jpg"
    _write_image(outside)
    (media_root / "alice" / "escape.jpg").symlink_to(outside)
    assert auth_client.get("/api/files/alice/escape.jpg").status_code == 404


# MARK: - Thumbnails


def test_thumbnail_is_jpeg_and_downscaled(auth_client: TestClient) -> None:
    response = auth_client.get("/api/thumbnails/alice/cover.jpg")
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/jpeg"
    assert response.content[:2] == b"\xff\xd8"  # JPEG SOI marker


def test_thumbnail_is_cached_on_disk(auth_client: TestClient, settings: Settings) -> None:
    auth_client.get("/api/thumbnails/alice/cover.jpg")
    cached = list(settings.thumb_cache_dir.rglob("*.jpg"))
    assert len(cached) == 1

    auth_client.get("/api/thumbnails/alice/cover.jpg")
    assert len(list(settings.thumb_cache_dir.rglob("*.jpg"))) == 1


def test_thumbnail_traversal_blocked(auth_client: TestClient) -> None:
    assert auth_client.get("/api/thumbnails/../../etc/passwd").status_code == 404


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_video_thumbnail(auth_client: TestClient, media_root: Path) -> None:
    import subprocess

    video = media_root / "alice" / "clip.mp4"
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=2:size=128x96:rate=15",
            str(video),
        ],
        check=True,
    )
    response = auth_client.get("/api/thumbnails/alice/clip.mp4")
    assert response.status_code == 200
    assert response.content[:2] == b"\xff\xd8"


# MARK: - Deletion


def test_delete_moves_into_trash_preserving_structure(
    auth_client: TestClient, media_root: Path
) -> None:
    response = auth_client.delete("/api/media/alice/beach/swim.jpg")
    assert response.status_code == 200

    assert not (media_root / "alice" / "beach" / "swim.jpg").exists()
    assert (media_root / "Trash" / "alice" / "beach" / "swim.jpg").is_file()


def test_delete_invalidates_the_library_cache(
    auth_client: TestClient
) -> None:
    before = auth_client.get("/api/profiles").json()["profiles"][0]["imageCount"]
    auth_client.delete("/api/media/alice/cover.jpg")
    after = auth_client.get("/api/profiles").json()["profiles"][0]["imageCount"]
    assert after == before - 1


def test_trash_is_not_a_profile(auth_client: TestClient) -> None:
    auth_client.delete("/api/media/alice/cover.jpg")
    ids = [p["id"] for p in auth_client.get("/api/profiles").json()["profiles"]]
    assert "Trash" not in ids


def test_delete_collision_keeps_both_files(
    auth_client: TestClient, media_root: Path
) -> None:
    auth_client.delete("/api/media/alice/cover.jpg")
    _write_image(media_root / "alice" / "cover.jpg", "purple")
    auth_client.delete("/api/media/alice/cover.jpg")

    trashed = list((media_root / "Trash" / "alice").glob("cover*.jpg"))
    assert len(trashed) == 2


def test_delete_traversal_blocked(auth_client: TestClient) -> None:
    assert auth_client.delete("/api/media/../../etc/passwd").status_code == 404


def test_trash_dir_can_live_outside_the_media_root(
    media_root: Path, tmp_path: Path
) -> None:
    """The multi-mount setup needs this: when every profile is its own bind mount,
    a trash folder inside /media would be lost when the container is recreated."""
    external_trash = tmp_path / "external-trash"
    settings = Settings(
        media_root=media_root,
        password=PASSWORD,
        secret_key="test-secret-key",
        thumb_cache_dir=tmp_path / "thumbs",
        session_max_age=3600,
        scan_cache_ttl=300,
        thumb_size=200,
        https_only=False,
        trash_dir=external_trash,
    )

    with TestClient(create_app(settings)) as client:
        client.post("/login", data={"password": PASSWORD}, follow_redirects=False)
        assert client.delete("/api/media/alice/beach/swim.jpg").status_code == 200

    assert (external_trash / "alice" / "beach" / "swim.jpg").is_file()
    assert not (media_root / "Trash").exists()


def test_relocated_trash_inside_root_is_not_a_profile(
    media_root: Path, tmp_path: Path
) -> None:
    inside_trash = media_root / "deleted"
    settings = Settings(
        media_root=media_root,
        password=PASSWORD,
        secret_key="test-secret-key",
        thumb_cache_dir=tmp_path / "thumbs",
        session_max_age=3600,
        scan_cache_ttl=300,
        thumb_size=200,
        https_only=False,
        trash_dir=inside_trash,
    )

    with TestClient(create_app(settings)) as client:
        client.post("/login", data={"password": PASSWORD}, follow_redirects=False)
        client.delete("/api/media/alice/cover.jpg")
        ids = [p["id"] for p in client.get("/api/profiles").json()["profiles"]]

    assert (inside_trash / "alice" / "cover.jpg").is_file()
    assert "deleted" not in ids


def test_delete_missing_file_404(auth_client: TestClient) -> None:
    assert auth_client.delete("/api/media/alice/nope.jpg").status_code == 404


def _client_with(settings: Settings, **overrides):
    """A signed-in client against a copy of `settings` with fields replaced."""
    return replace(settings, **overrides)


def test_delete_reports_that_it_trashed(auth_client: TestClient) -> None:
    body = auth_client.delete("/api/media/alice/cover.jpg").json()
    assert body["status"] == "trashed"
    assert body["path"] == "alice/cover.jpg"


def test_permanent_mode_unlinks(settings: Settings, media_root: Path) -> None:
    with TestClient(create_app(_client_with(settings, delete_mode="permanent"))) as client:
        client.post("/login", data={"password": PASSWORD}, follow_redirects=False)
        body = client.delete("/api/media/alice/cover.jpg").json()

    assert body["status"] == "deleted"
    assert not (media_root / "alice" / "cover.jpg").exists()
    assert not (media_root / "Trash").exists()


def test_auto_mode_falls_back_when_the_trash_cannot_be_created(
    settings: Settings, media_root: Path, tmp_path: Path
) -> None:
    """The bug this covers: a media root the container cannot write to.

    Creating `<root>/Trash` raised PermissionError, which surfaced as a bare 500 on
    a button the user had already confirmed twice. Here the same failure is produced
    portably — a trash path whose parent is a regular file, so `mkdir` raises
    NotADirectoryError for every user, root included.
    """
    blocked = tmp_path / "not-a-directory"
    blocked.write_text("this is a file")

    with TestClient(create_app(_client_with(settings, trash_dir=blocked / "Trash"))) as client:
        client.post("/login", data={"password": PASSWORD}, follow_redirects=False)
        response = client.delete("/api/media/alice/cover.jpg")

    assert response.status_code == 200
    assert response.json()["status"] == "deleted"
    assert not (media_root / "alice" / "cover.jpg").exists()


def test_trash_mode_refuses_rather_than_deleting(
    settings: Settings, media_root: Path, tmp_path: Path
) -> None:
    blocked = tmp_path / "not-a-directory"
    blocked.write_text("this is a file")
    overrides = {"trash_dir": blocked / "Trash", "delete_mode": "trash"}

    with TestClient(
        create_app(_client_with(settings, **overrides)), raise_server_exceptions=False
    ) as client:
        client.post("/login", data={"password": PASSWORD}, follow_redirects=False)
        response = client.delete("/api/media/alice/cover.jpg")

    assert response.status_code == 500
    # The client shows this verbatim, so it has to name the way out.
    assert "MEDIAVAULT_DELETE_MODE=permanent" in response.json()["detail"]
    # The whole point of this mode: nothing was destroyed.
    assert (media_root / "alice" / "cover.jpg").is_file()


# MARK: - Sort metadata


def test_items_carry_size_and_modification_date(auth_client: TestClient) -> None:
    """The client sorts on these; a missing field silently collapses the order."""
    items = auth_client.get("/api/profiles/alice/items").json()["items"]
    for item in items:
        assert item["byteSize"] > 0
        assert item["modifiedAt"] > 0
