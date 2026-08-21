import SwiftUI

/// Browses the server's folders and nominates one of them as the library root.
///
/// The server serves one media root, but a media root is often a shelf rather than
/// a library: `/media` holding `peeps` and `peeps2`, each of which is the thing you
/// actually want to browse. Without this, those two show up as a pair of profiles
/// with everything buried a level down.
struct RemoteRootPicker: View {
    @Environment(RemoteServerService.self) private var remote
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Folder currently being listed, relative to the server's media root.
    @State private var path = ""
    @State private var listing: RemoteFolderListing?
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                locationSection
                foldersSection
            }
            .navigationTitle("Library Root")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Folder", action: applyCurrentFolder)
                        .disabled(isLoading)
                }
            }
            .task { await load(path: remote.libraryRootPath) }
        }
    }

    // MARK: - Sections

    private var locationSection: some View {
        Section {
            LabeledContent {
                if isLoading { ProgressView() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.displayName(for: path))
                        .fontWeight(.semibold)
                    Text(path.isEmpty ? "The server's whole media folder" : path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let parent = listing?.parent {
                Button {
                    Task { await load(path: parent) }
                } label: {
                    Label("Up to \(Self.displayName(for: parent))", systemImage: "arrow.up.left")
                }
            }
        } header: {
            Text("Current Folder")
        } footer: {
            Text("The folders inside this one become your profiles. Likes and deletes are unaffected by the choice.")
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        if let loadError {
            Section {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try Again") { Task { await load(path: path) } }
            }
        } else if let listing, listing.folders.isEmpty {
            Section {
                Text(isLoading ? "Loading…" : "No folders inside this one.")
                    .foregroundStyle(.secondary)
            }
        } else if let listing {
            Section("Folders Inside") {
                ForEach(listing.folders) { folder in
                    Button {
                        Task { await load(path: folder.path) }
                    } label: {
                        folderRow(folder)
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: RemoteFolder) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .foregroundStyle(.primary)
                Text(Self.summary(for: folder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func load(path newPath: String) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let result = try await remote.fetchFolders(at: newPath)
            path = result.path
            listing = result
        } catch {
            // A root that has been renamed on the NAS answers 404 here, which is
            // worth saying plainly rather than showing as an empty folder list.
            loadError = error.localizedDescription
            // Keep whatever was on screen; there is nothing better to show.
            if listing == nil { path = newPath }
        }
    }

    private func applyCurrentFolder() {
        remote.libraryRootPath = path
        dismiss()
        Task { await library.refresh() }
    }

    // MARK: - Formatting

    private static func displayName(for path: String) -> String {
        path.isEmpty ? "Server Media Folder" : (path.split(separator: "/").last.map(String.init) ?? path)
    }

    private static func summary(for folder: RemoteFolder) -> String {
        let folders = folder.folderCount == 1 ? "1 folder" : "\(folder.folderCount) folders"
        let items = folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items"
        return "\(folders) · \(items)"
    }
}
