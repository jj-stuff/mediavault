"""Contract tests for the API the iOS client consumes.

The response shapes here are asserted in camelCase on purpose: they must match the
Codable DTOs in app/MediaVault/Services/RemoteServerService.swift exactly.
"""

from __future__ import annotations

import shutil
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
        "id", "name", "imageCount", "videoCount", "subfolders", "thumbnailPath"
    }
    assert alice["name"] == "alice"
    assert alice["imageCount"] == 3  # cover + swim + nested
    assert alice["videoCount"] == 0
    assert alice["subfolders"] == ["beach"]
    assert alice["thumbnailPath"].startswith("alice/")


def test_items_shape_and_subfolder_attribution(auth_client: TestClient) -> None:
    items = auth_client.get("/api/profiles/alice/items").json()["items"]
    assert {i["fileName"] for i in items} == {"cover.jpg", "swim.jpg", "nested.jpg"}

    by_name = {i["fileName"]: i for i in items}
    assert set(by_name["cover.jpg"]) == {"fileName", "mediaType", "subfolder", "path"}
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
