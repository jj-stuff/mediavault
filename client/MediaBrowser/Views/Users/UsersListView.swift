import SwiftUI
import UIKit

struct UsersListView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var localManager: LocalFileManager
    @State private var searchText = ""
    @AppStorage("useLocalMode") private var useLocalMode = false

    private var filteredUsers: [User] {
        if searchText.isEmpty {
            return networkManager.users
        } else {
            return networkManager.users.filter {
                $0.username.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        if useLocalMode {
            LocalLibraryView()
                .environmentObject(localManager)
        } else {
            NavigationStack {
                List(filteredUsers) { user in
                    NavigationLink(destination: UserProfileView(user: user)) {
                        userRow(for: user)
                    }
                }
                .navigationTitle("Users")
                .searchable(text: $searchText, prompt: "Search users")
                .refreshable {
                    await networkManager.fetchUsers()
                }
                .task {
                    await networkManager.fetchUsers()
                }
            }
        }
    }

    private func userRow(for user: User) -> some View {
        HStack(spacing: 16) {
            CachedAsyncImage(
                url: avatarURL(for: user),
                placeholder: {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                }
            )
            .frame(width: 60, height: 60)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(user.username)
                    .font(.headline)
                Text("\(user.mediaCount) media files")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func avatarURL(for user: User) -> URL? {
        guard let avatar = user.avatar else { return nil }
        return URL(string: "\(networkManager.baseURL)\(avatar)")
    }
}

private struct LocalLibraryView: View {
    @EnvironmentObject private var localManager: LocalFileManager
    @AppStorage("useLocalMode") private var useLocalMode = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if localManager.selectedFolder == nil {
                    emptyState(
                        systemImage: "externaldrive.connected.to.line.below",
                        message: "Select a folder in Settings to browse local media."
                    )
                } else if filteredGroups.isEmpty && !localManager.isScanning {
                    emptyState(
                        systemImage: "folder",
                        message: "No supported media found in the selected folder."
                    )
                } else {
                    listContent
                }
            }
            .navigationTitle("Local Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if localManager.isScanning {
                        ProgressView()
                    } else {
                        Button {
                            localManager.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(localManager.selectedFolder == nil)
                    }
                }
            }
            .refreshable {
                localManager.refresh()
            }
            .searchable(text: $searchText, prompt: "Search folders")
        }
    }

    private var listContent: some View {
        List {
            ForEach(filteredGroups) { group in
                NavigationLink(destination: LocalGroupView(group: group)) {
                    LocalGroupRow(group: group)
                }
            }
        }
        .listStyle(.plain)
    }

    private var filteredGroups: [LocalMediaGroup] {
        let groups = groupedItems
        guard !searchText.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var groupedItems: [LocalMediaGroup] {
        let baseURL = localManager.selectedFolder
        let dictionary = Dictionary(grouping: localManager.mediaItems) { item -> String in
            guard let basePath = baseURL?.path else { return "All Files" }
            let relative = item.fullPath?.replacingOccurrences(of: basePath, with: "") ?? ""
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let first = trimmed.split(separator: "/").first, !first.isEmpty {
                return String(first)
            }
            return "All Files"
        }

        return dictionary
            .map { key, value in
                LocalMediaGroup(
                    id: key,
                    name: key,
                    items: value.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                )
            }
            .sorted { lhs, rhs in
                if lhs.name == "All Files" { return true }
                if rhs.name == "All Files" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func emptyState(systemImage: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct LocalMediaGroup: Identifiable {
        let id: String
        let name: String
        let items: [MediaItem]
    }

    private struct LocalGroupRow: View {
        let group: LocalMediaGroup

        private var previewItems: [MediaItem] {
            Array(group.items.prefix(3))
        }

        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    if previewItems.isEmpty {
                        Color.gray.opacity(0.2)
                            .frame(width: 56, height: 56)
                            .cornerRadius(8)
                    } else {
                        ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
                            LocalPreviewImage(item: item)
                                .frame(width: 56, height: 56)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.1), lineWidth: 1))
                                .cornerRadius(8)
                                .offset(x: CGFloat(index) * 14)
                        }
                    }
                }
                .frame(width: 56 + CGFloat(max(0, previewItems.count - 1)) * 14, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.headline)
                    Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private struct LocalPreviewImage: View {
        let item: MediaItem
        @State private var image: UIImage?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .clipped()
            .task(id: item.uniqueID) {
                if let thumb = await LocalFileManager.shared.thumbnail(for: item, maxDimension: 120) {
                    await MainActor.run {
                        image = thumb
                    }
                }
            }
        }
    }

    private struct LocalGroupView: View {
        let group: LocalMediaGroup

        var body: some View {
            ScrollView {
                MediaGridView(mediaItems: group.items)
                    .padding(.top, 8)
            }
            .navigationTitle(group.name)
        }
    }
}
