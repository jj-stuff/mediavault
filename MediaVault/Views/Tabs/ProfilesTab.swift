import SwiftUI

struct ProfilesTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @State private var searchText = ""
    @State private var sortOption: SortOption = .alphabetical
    let rootURL: URL?

    enum SortOption: String, CaseIterable {
        case alphabetical = "A-Z"
        case mostContent = "Most Content"
        case mostImages = "Most Images"
        case mostVideos = "Most Videos"
    }

    private var filteredProfiles: [MediaProfile] {
        var result = scanner.profiles
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOption {
        case .alphabetical: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .mostContent: result.sort { $0.totalCount > $1.totalCount }
        case .mostImages: result.sort { $0.imageCount > $1.imageCount }
        case .mostVideos: result.sort { $0.videoCount > $1.videoCount }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanner.isScanning {
                    ProgressView("Scanning folders...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scanner.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Select a folder in Settings to get started.\nEach subfolder will become a profile.")
                    }
                } else {
                    profilesGrid
                }
            }
            .navigationTitle("Profiles")
            .searchable(text: $searchText, prompt: "Search profiles...")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button {
                                sortOption = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if sortOption == option { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }

    private var profilesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
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
        .navigationDestination(for: MediaProfile.self) { profile in
            ProfileDetailView(profile: profile, rootURL: rootURL)
        }
    }
}
