# MediaVault Server

Serves a folder of media to the MediaVault iOS app. Each immediate subfolder of the
media root becomes a profile.

```
/media
├── alice/            → profile "alice"
│   ├── cover.jpg     → item, no subfolder
│   └── beach/        → subfolder "beach"
│       └── swim.jpg
├── bob/              → profile "bob"
└── Trash/            → deletes land here; never shown as a profile
```

## Running it

```bash
cp .env.example .env
# edit .env: set MEDIAVAULT_MEDIA_DIR, MEDIAVAULT_PASSWORD, MEDIAVAULT_SECRET_KEY
docker compose up -d
```

Generate a secret key with:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Then in the iOS app: **Settings → Remote Server → on**, enter the server URL, tap
**Sign In**, enter the password, tap **Done**.

### File ownership

The container runs as uid 1000. That user needs read access to your library, and
write access for deletes to work. If your NAS uses a different uid, either adjust the
ownership of the media folder or add `user: "<uid>:<gid>"` to the service in
`compose.yml`.

### Exposing it beyond your LAN

Put a TLS-terminating reverse proxy in front of it and set `MEDIAVAULT_HTTPS_ONLY=1`
so the session cookie is marked Secure. The container already trusts
`X-Forwarded-*`. Do not expose port 8000 directly — the session cookie would travel
in the clear, and it is the only thing protecting your library.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `MEDIAVAULT_PASSWORD` | — | **Required.** Sign-in password. The server refuses to start without it. |
| `MEDIAVAULT_SECRET_KEY` | random | Signs the session cookie. Unset means sessions die on restart. |
| `MEDIAVAULT_MEDIA_ROOT` | `/media` | Library path *inside* the container. |
| `MEDIAVAULT_THUMB_CACHE` | `/cache/thumbs` | Thumbnail cache path inside the container. |
| `MEDIAVAULT_SESSION_MAX_AGE` | `2592000` | Session lifetime in seconds (30 days). |
| `MEDIAVAULT_SCAN_CACHE_TTL` | `300` | Seconds a library scan stays fresh. |
| `MEDIAVAULT_THUMB_SIZE` | `400` | Thumbnail longest edge, in pixels. |
| `MEDIAVAULT_HTTPS_ONLY` | `0` | `1` marks the session cookie Secure. |

## API

Everything under `/api` except `/api/auth/check`'s failure path requires the session
cookie. This is the contract `RemoteServerService.swift` depends on — changing a
response shape means changing the client too.

| Method | Path | Returns |
|---|---|---|
| `GET` | `/` | Sign-in page (opened in the app's WKWebView) |
| `POST` | `/login` | Sets the session cookie |
| `POST` | `/logout` | Clears it |
| `GET` | `/api/auth/check` | `200` when signed in, `401` otherwise |
| `GET` | `/api/profiles` | `{"profiles": [{id, name, imageCount, videoCount, subfolders, thumbnailPath}]}` |
| `POST` | `/api/profiles/refresh` | Same, forcing a rescan |
| `GET` | `/api/profiles/{id}/items` | `{"items": [{fileName, mediaType, subfolder, path}]}` |
| `GET`/`HEAD` | `/api/files/{path}` | Raw media. Honours `Range`, so video seeks. |
| `GET`/`HEAD` | `/api/thumbnails/{path}` | Cached JPEG thumbnail |
| `DELETE` | `/api/media/{path}` | Moves the file to `Trash/`, preserving its subpath |

Paths are relative to the media root, e.g. `/api/files/alice/beach/swim.jpg`.

### Notes

- **Range support is load-bearing.** AVPlayer will not scrub, and for some
  containers will not play at all, without `206` responses.
- **Deletes are moves, not unlinks.** A file goes to `Trash/<original/sub/path>`; a
  name collision gets a UTC timestamp suffix rather than overwriting.
- **The library scan is cached** for `MEDIAVAULT_SCAN_CACHE_TTL` seconds. Deletes
  invalidate it immediately; `POST /api/profiles/refresh` forces a rescan.
- **Thumbnails are keyed on path + mtime + size**, so replacing a file on disk
  regenerates its thumbnail with no cache-busting needed.

## Development

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt pytest httpx
MEDIAVAULT_PASSWORD=dev MEDIAVAULT_MEDIA_ROOT=/path/to/media \
  uvicorn app.main:create_app --factory --reload
```

Run the tests (they cover the client contract, Range handling, path traversal, and
deletion) with:

```bash
pytest
```

Video thumbnail tests skip automatically when `ffmpeg` is not on `PATH`.

> On Python 3.14 `pillow-heif` has no prebuilt wheel and will try to compile from
> source. The container pins 3.13, where wheels exist for both amd64 and arm64. For
> local dev on 3.14, install without it — HEIC thumbnails degrade gracefully.
