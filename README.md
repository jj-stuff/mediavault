# MediaVault

A local media browser for iOS 26, built with Swift 6.2 and SwiftUI's Liquid Glass design.

## Features

- **Profiles** — Each subfolder = a person. Instagram-style 3-column grid with type/subfolder filters.
- **For You** — TikTok-style vertical feed with spread algorithm (no consecutive same-profile items).
- **Liked** — Favorites stored in-app (read-only source folders). Filter, search, context-menu unlike.
- **Settings** — Folder picker for local storage + external drives (SSD/USB). Persistent via security-scoped bookmarks.

## Requirements

- **iOS 26.0+**
- **Xcode 26+**
- **Swift 6.2**

## Build Settings (auto-configured)

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — everything is MainActor by default
- `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES`
- `IPHONEOS_DEPLOYMENT_TARGET = 26.0`
- Uses `PBXFileSystemSynchronizedRootGroup` (Xcode 26 auto-discovers files)

## Architecture

- **@Observable** instead of ObservableObject/StateObject
- **@Environment** instead of @EnvironmentObject
- **@concurrent** for off-main-actor file I/O and thumbnail generation
- **nonisolated** on pure data models (Sendable structs/enums)
- **Tab API** with `Tab("Name", systemImage:, value:)` for Liquid Glass tab bar
- `.tabBarMinimizeBehavior(.onScrollDown)` for the iOS 26 collapsing tab bar
- Security-scoped URL kept alive for the session (not released after scan)

## Setup

1. Open `MediaVault.xcodeproj` in Xcode 26
2. Set your **Development Team** in Signing & Capabilities
3. Build and run on a physical iPhone running iOS 26
4. Go to **Settings** → **Select Media Folder** → pick a folder from Files
