# MediaVault

A media browser for iOS 26, with an optional self-hosted server so the same library
can be browsed from your phone without copying it there.

```
mex-media-app/
├── app/       iOS client (Swift 6.2, SwiftUI, Xcode 26)
└── server/    FastAPI server, Docker-ready — see server/README.md
```

Both halves read the same library shape: each immediate subfolder of the root is a
profile, and folders below that are its subfolders.

## The app

- **Profiles** — Instagram-style grid, one profile per subfolder, with type and
  subfolder filters, and sorting by name, date, or size. Pull down to rescan.
- **For You** — vertical paging feed that spreads items so the same profile does not
  appear twice in a row. Players for the next items are prepared before you reach
  them, so swiping does not stall on buffering. Pull down on the first item to
  reshuffle.
- **Liked** — favourites stored in the app as paths relative to the library root, so
  source folders stay read-only and likes survive the root moving.
- **Settings** — pick a local folder (including external drives) or point the app at
  a MediaVault server, and choose which folder on that server your profiles come
  from: a server serving `/media` can be browsed as `media/peeps` or `media/peeps2`
  without touching its configuration.

Any grid — a profile, one of its subfolders, or Liked — has a **Select** button, and
a long press on a photo starts the same mode. Ticked items go to the Trash together;
in Liked they can also just be unliked, which leaves the files alone.

Deletes are moves: a file goes to `Trash/<its original subpath>` in the library.
When the library has nowhere writable for a `Trash` folder — a read-only volume, a
server whose container runs as a different user — the file is deleted outright
rather than the delete failing.

### Requirements

iOS 26.0+, Xcode 26+, Swift 6.2.

### Running it

1. Open `app/MediaVault.xcodeproj`.
2. Set your Development Team under Signing & Capabilities.
3. Build to a device or simulator.
4. **Settings → Select Media Folder**, or turn on **Remote Server** and sign in.

### Architecture

The project targets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so everything is
main-actor unless it opts out; `@concurrent` marks the work that must not be
(directory walks, image decoding, the trash move).

```
App/         entry point, composition root, root tab view
Models/      pure Sendable value types, all nonisolated
Services/    shared state and I/O, injected from the composition root
Features/    one folder per screen: ForYou, Profiles, Liked, Viewer, Settings, Shared
```

Some choices worth knowing before changing things:

- **No `.shared` singletons.** Every service is built once in `AppDependencies` and
  passed down through the environment. They are single instances because one is
  created, not because the type prevents a second — which is what lets tests or a
  future extension assemble the graph with a different store.
- **`UserDefaults` sits behind `KeyValueStore`.** Nothing calls `.standard` directly
  except the composition root, so moving to an App Group suite is a one-line change.
- **Feed playback lives outside the view tree.** SwiftUI's lazy stacks destroy and
  rebuild rows rather than recycling them, so `FeedPlayerPool` holds a window of
  `AVPlayer`s around the current item. That, not view recycling, is what makes the
  feed smooth.
- **The feed is addressed by slot, not by file.** It repeats content deliberately
  once a small library runs out, so the same `MediaItem` occupies several positions.
  `FeedEntry` gives each position its own id; `MediaItem.id` still identifies the
  file. Keying rows on the file instead is what made `scrollPosition` resolve a
  later repeat back to the first copy — the wrong video playing, and paging that
  would not snap.
- **Only one player is ever audible.** `FeedPlayerPool.suspend()` covers every way
  the feed can stop being what the user is looking at — another tab, a profile
  sheet on top of it, the app backgrounding — without forgetting the position, and
  the paged viewer plays only its current page.
- **`AppLog` over `print`.** `os.Logger`, one category per area. Filter the Xcode
  console on `subsystem:com.mediavault.app`, and add `category:playback` to watch
  the player pool decide what plays.
- **Deletion is one service.** `MediaDeletionService` owns the local and remote
  paths and reconciles the scanner and the like list afterwards.
- **Paths compare through `MediaPath`.** The same item is addressed as a file URL, as
  an HTTPS URL under `/api/files`, and as a stored like; every comparison normalises
  through that one type. Destructive operations use `strictRelative`, which returns
  `nil` instead of guessing when an item is not under the root.

The app and server share a contract that is asserted on both sides: the response
shapes in `server/app/main.py` are covered by `server/tests/test_api.py`, and the
matching `Decodable` types live in `app/MediaVault/Services/RemoteServerService.swift`.
Changing one means changing the other.

## The server

Only `server/` is sent to Docker — the build context is that folder, so `app/` never
enters the image. Clone the repo anywhere on the host and work from `server/`:

```bash
git clone git@github.com:jj-stuff/mediavault.git
cd mediavault/server

cp .env.example .env
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # paste as SECRET_KEY
$EDITOR .env                # set MEDIAVAULT_MEDIA_DIR, PASSWORD, SECRET_KEY, PORT

docker compose up -d
docker compose logs -f      # confirm it found your media
```

Then point the app at `http://<host-ip>:<port>` under **Settings → Remote Server**.

- **Port**: set `MEDIAVAULT_PORT` in `.env`; the container always listens on 8000
  internally.
- **Several source folders**: `compose.yml` has a commented multi-mount block —
  map each host folder to a name under `/media`, and that name becomes the profile.
- **Deletes** are moves into a trash volume, never unlinks. Keep it on a real
  volume; the server prints its location on every boot.

Full configuration, the API reference, and reverse-proxy notes are in
[`server/README.md`](server/README.md).
