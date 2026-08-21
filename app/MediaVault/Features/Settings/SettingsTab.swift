import SwiftUI

struct SettingsTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LikesService.self) private var likes
    @Environment(RemoteServerService.self) private var remote
    @Environment(ImageLoader.self) private var imageLoader
    @Environment(LibraryController.self) private var library

    @AppStorage(StorageKey.flattenFolders) private var flattenFolders = true
    @State private var showFolderPicker = false
    @State private var showRootPicker = false
    @State private var showRemoveConfirmation = false
    @State private var showLoginSheet = false

    var body: some View {
        NavigationStack {
            List {
                remoteSection
                if !remote.isEnabled { localSection }
                if !scanner.profiles.isEmpty { statsSection }
                browseSection
                formatsSection
                cacheSection
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    Task { await library.selectFolder(url) }
                }
            }
            .sheet(isPresented: $showRootPicker) {
                RemoteRootPicker()
            }
            .sheet(isPresented: $showLoginSheet) {
                if let url = remote.baseURL {
                    LoginSheetView(serverURL: url)
                }
            }
            .confirmationDialog(
                "Remove Folder?",
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) { library.removeFolder() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes the folder reference. Your files are not deleted.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var remoteSection: some View {
        @Bindable var remote = remote

        Section {
            Toggle(isOn: $remote.isEnabled) {
                Label("Remote Server", systemImage: "server.rack")
            }

            if remote.isEnabled {
                TextField("192.168.1.10:8000", text: $remote.serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)

                LabeledContent {
                    Button("Sign In") { showLoginSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } label: {
                    Label(
                        remote.isAuthenticated ? "Authenticated" : "Not signed in",
                        systemImage: remote.isAuthenticated ? "checkmark.shield.fill" : "shield.slash"
                    )
                    .foregroundStyle(remote.isAuthenticated ? .green : .orange)
                }

                Button {
                    Task { await remote.testConnection() }
                } label: {
                    Label("Test Connection", systemImage: "stethoscope")
                }

                if let diagnosis = remote.diagnosis {
                    Text(diagnosis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if remote.isAuthenticated {
                    Button {
                        showRootPicker = true
                    } label: {
                        LabeledContent {
                            Text(Self.rootLabel(remote.libraryRootPath))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Library Root", systemImage: "folder")
                        }
                    }

                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Label("Refresh from Server", systemImage: "arrow.clockwise")
                    }
                }
            }
        } header: {
            Text("Remote Server")
        } footer: {
            Text("Connect to a MediaVault server over the network, then sign in through the web page. A local address like 192.168.1.10:8000 is reached over HTTP; anything else uses HTTPS. Library Root picks which folder on the server your profiles come from.")
        }
    }

    private var localSection: some View {
        Section {
            Button {
                showFolderPicker = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Select Media Folder", systemImage: "folder.badge.plus")
                    if let url = library.localFolderURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if library.localFolderURL != nil {
                Button {
                    Task { await library.refresh() }
                } label: {
                    Label("Rescan Folder", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove Folder", systemImage: "folder.badge.minus")
                }
            }
        } header: {
            Text("Media Source")
        } footer: {
            Text("Pick a folder where each subfolder is a profile. Local storage and connected external drives both work.")
        }
    }

    private var statsSection: some View {
        Section("Library") {
            LabeledContent("Profiles", value: scanner.profiles.count, format: .number)
            LabeledContent(
                "Total Media",
                value: scanner.profiles.reduce(0) { $0 + $1.totalCount },
                format: .number
            )
            LabeledContent(
                "Images",
                value: scanner.profiles.reduce(0) { $0 + $1.imageCount },
                format: .number
            )
            LabeledContent(
                "Videos",
                value: scanner.profiles.reduce(0) { $0 + $1.videoCount },
                format: .number
            )
            LabeledContent("Liked", value: likes.likedItems.count, format: .number)
        }
    }

    private var browseSection: some View {
        Section {
            Toggle(isOn: $flattenFolders) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Flatten Subfolders", systemImage: "square.3.layers.3d")
                    Text("Show all subfolder contents in the main gallery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Browse")
        } footer: {
            Text("When off, subfolders appear as folders you can open inside each profile.")
        }
    }

    private var formatsSection: some View {
        Section("Supported Formats") {
            LabeledContent {
                Text(Self.formatList(MediaItem.imageExtensions))
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Images", systemImage: "photo")
            }

            LabeledContent {
                Text(Self.formatList(MediaItem.videoExtensions))
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Videos", systemImage: "video")
            }
        }
    }

    private var cacheSection: some View {
        Section("Cache") {
            Button {
                imageLoader.clearCache()
            } label: {
                Label("Clear Image Cache", systemImage: "xmark.bin")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.appVersion)
            LabeledContent("MediaVault", value: "Media Browser")
        }
    }

    // MARK: - Helpers

    /// Derived from the bundle so it cannot drift from the shipped build the way a
    /// hard-coded string does.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// Server-relative library root, as a row value.
    private static func rootLabel(_ path: String) -> String {
        path.isEmpty ? "Whole library" : path
    }

    private static func formatList(_ extensions: Set<String>) -> String {
        extensions.sorted().map { $0.uppercased() }.joined(separator: ", ")
    }
}
