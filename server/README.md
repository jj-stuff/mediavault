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

## Running it with Docker

Only the `server/` folder is ever sent to Docker — the build context is this
directory, so the iOS app in `app/` never enters the image. Run every command below
from `server/`.

```bash
git clone git@github.com:jj-stuff/mediavault.git
cd mediavault/server

cp .env.example .env
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # paste as SECRET_KEY
$EDITOR .env

docker compose up -d
docker compose logs -f          # confirm it found your media
```

Check it is alive, then point the app at `http://<host-ip>:<port>`:

```bash
curl -I http://localhost:8000/   # expect 200
```

In the app: **Settings → Remote Server → on**, enter the URL, **Sign In**, enter the
password, **Done**.

Everyday operations:

```bash
docker compose restart              # after changing .env
docker compose up -d --build        # after pulling new code
docker compose down                 # stop (volumes survive)
docker compose logs --tail=50       # recent output
```

### Choosing the port

Set `MEDIAVAULT_PORT` in `.env` and restart. The container always listens on 8000
internally; only the host side changes, so nothing else needs touching.

```bash
MEDIAVAULT_PORT=9000
```

### Pointing at one folder vs several

**One folder that already holds a subfolder per person** — the normal case. Set
`MEDIAVAULT_MEDIA_DIR` and you are done:

```bash
MEDIAVAULT_MEDIA_DIR=/srv/media
```

```
/srv/media/alice/…      → profile "alice"
/srv/media/bob/…        → profile "bob"
```

**Several folders scattered around the host.** Comment out the single `- ${MEDIAVAULT_MEDIA_DIR}:/media`
line in `compose.yml` and uncomment the multi-mount block, mapping each host folder
to a name under `/media`. The name on the right becomes the profile name:

```yaml
volumes:
  - /mnt/ssd/photos/alice:/media/alice
  - /mnt/nas/media/bob:/media/bob
  - /srv/downloads/charlie:/media/charlie
```

Append `:ro` to any mount to keep it read-only — but deleting from that folder in
the app will then fail, because a delete is a move out of it.

### Where deleted files go

Deletes are moves into a trash folder, never unlinks. By default that is a Docker
named volume mounted at `/trash`, which survives restarts. To keep it browsable from
the host, point it at a real path:

```bash
MEDIAVAULT_TRASH_DIR=/srv/media-trash
```

The trash is deliberately kept off `/media`. In the several-folders setup above,
`/media` itself is not a mounted volume — it is the container's own filesystem — so a
trash folder inside it would be destroyed the next time the container is recreated,
turning every "move to Trash" into a permanent delete.

The server prints its trash location on every boot. Check it in `docker compose logs`
before you rely on deletes.

### File ownership

The container runs as uid 1000. That user needs read access to your library, and
write access wherever the trash lives. If your NAS uses a different uid, either
adjust ownership of the media folder or pin the container to your uid:

```yaml
services:
  mediavault:
    user: "1027:100"    # your uid:gid, from `id -u` / `id -g`
```

Symptom of getting this wrong: browsing works, deletes fail with a permission error.

### Exposing it beyond your LAN

Put a TLS-terminating reverse proxy in front of it and set `MEDIAVAULT_HTTPS_ONLY=1`
so the session cookie is marked Secure. The container already trusts
`X-Forwarded-*`. Do not expose the port directly — the session cookie would travel
in the clear, and it is the only thing protecting your library.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `MEDIAVAULT_PASSWORD` | — | **Required.** Sign-in password. The server refuses to start without it. |
| `MEDIAVAULT_SECRET_KEY` | random | Signs the session cookie. Unset means sessions die on restart. |
| `MEDIAVAULT_PORT` | `8000` | Host port. The container always listens on 8000 inside. |
| `MEDIAVAULT_MEDIA_DIR` | — | Host path to your library, mounted at `/media`. |
| `MEDIAVAULT_TRASH_DIR` | named volume | Where deletes go. A host path keeps them browsable. |
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
