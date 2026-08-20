import SwiftUI

struct ProfilesTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @State private var searchText = ""
    @State private var sortOption: SortOption = .alphabetical

    private static let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    enum SortOption: String, CaseIterable, Identifiable {
        case alphabetical = "A-Z"
        case mostContent = "Most Content"
        case mostImages = "Most Images"
        case mostVideos = "Most Videos"

        var id: Self { self }
    }

    private var filteredProfiles: [MediaProfile] {
        var result = scanner.profiles

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        switch sortOption {
        case .alphabetical:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .mostContent:
            result.sort { $0.totalCount > $1.totalCount }
        case .mostImages:
            result.sort { $0.imageCount > $1.imageCount }
        case .mostVideos:
            result.sort { $0.videoCount > $1.videoCount }
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
                ProfileDetailView(profile: profile)
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
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}
