import SwiftUI

struct ProfilesTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LibraryController.self) private var library

    @AppStorage(StorageKey.profileSortOrder) private var sortRaw = SortOption.alphabetical.rawValue
    @State private var searchText = ""

    private static let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    enum SortOption: String, CaseIterable, Identifiable {
        case alphabetical = "Name (A–Z)"
        case reverseAlphabetical = "Name (Z–A)"
        case newest = "Recently Updated"
        case largest = "Largest on Disk"
        case mostContent = "Most Content"
        case mostImages = "Most Images"
        case mostVideos = "Most Videos"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .alphabetical, .reverseAlphabetical: "textformat"
            case .newest: "calendar"
            case .largest: "internaldrive"
            case .mostContent: "square.grid.2x2"
            case .mostImages: "photo"
            case .mostVideos: "video"
            }
        }
    }

    private var sortOption: SortOption {
        SortOption(rawValue: sortRaw) ?? .alphabetical
    }

    private var filteredProfiles: [MediaProfile] {
        var result = scanner.profiles

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        // Every comparison falls back to the name so the order is total: without it,
        // profiles that tie — and a library of same-sized folders ties constantly —
        // reshuffle on each redraw.
        func byName(_ lhs: MediaProfile, _ rhs: MediaProfile) -> Bool {
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        switch sortOption {
        case .alphabetical:
            result.sort(by: byName)
        case .reverseAlphabetical:
            result.sort { byName($1, $0) }
        case .newest:
            result.sort {
                let (a, b) = ($0.lastModified ?? .distantPast, $1.lastModified ?? .distantPast)
                return a == b ? byName($0, $1) : a > b
            }
        case .largest:
            result.sort {
                $0.totalByteSize == $1.totalByteSize
                    ? byName($0, $1)
                    : $0.totalByteSize > $1.totalByteSize
            }
        case .mostContent:
            result.sort { $0.totalCount == $1.totalCount ? byName($0, $1) : $0.totalCount > $1.totalCount }
        case .mostImages:
            result.sort { $0.imageCount == $1.imageCount ? byName($0, $1) : $0.imageCount > $1.imageCount }
        case .mostVideos:
            result.sort { $0.videoCount == $1.videoCount ? byName($0, $1) : $0.videoCount > $1.videoCount }
        }

        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanner.isScanning {
                    ProgressView("Scanning folders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = scanner.scanError {
                    ContentUnavailableView {
                        Label("Couldn't Read That Folder", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if scanner.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Select a folder in Settings to get started.\nEach subfolder becomes a profile.")
                    }
                } else if filteredProfiles.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    profilesGrid
                }
            }
            .navigationTitle("Profiles")
            .searchable(text: $searchText, prompt: "Search profiles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
            }
            .navigationDestination(for: MediaProfile.self) { profile in
                ProfileDetailView(pushedProfile: profile)
            }
        }
    }

    private var profilesGrid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(filteredProfiles) { profile in
                    NavigationLink(value: profile) {
                        ProfileCardView(profile: profile)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, ScreenInsets.gridBottomClearance)
        }
        .refreshable { await library.refresh() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(SortOption.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option.rawValue)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort, currently \(sortOption.rawValue)")
    }
}
