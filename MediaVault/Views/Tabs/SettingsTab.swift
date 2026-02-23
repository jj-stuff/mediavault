import SwiftUI

struct SettingsTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LikesService.self) private var likesService
    @Environment(RemoteServerService.self) private var remoteService
    @Binding var rootFolderURL: URL?
    @AppStorage("flattenFolders") private var flattenFolders = true
    @State private var showFolderPicker = false
    @State private var showClearConfirmation = false
    @State private var showLoginSheet = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: Remote Server
                Section {
                    Toggle(isOn: Bindable(remoteService).isEnabled) {
                        HStack {
                            Image(systemName: "server.rack").foregroundStyle(.purple).frame(width: 28)
                            Text("Remote Server")
                        }
                    }

                    if remoteService.isEnabled {
                        HStack {
                            Image(systemName: "link").foregroundStyle(.purple).frame(width: 28)
                            TextField("https://your-server.com", text: Bindable(remoteService).serverURL)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }

                        HStack {
                            Image(systemName: remoteService.isAuthenticated ? "checkmark.shield.fill" : "shield.slash")
                                .foregroundStyle(remoteService.isAuthenticated ? .green : .orange)
                                .frame(width: 28)
                            Text(remoteService.isAuthenticated ? "Authenticated" : "Not signed in")
                                .foregroundStyle(remoteService.isAuthenticated ? .primary : .secondary)
                            Spacer()
                            Button("Sign In") { showLoginSheet = true }
                                .font(.caption)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .tint(.purple)
                        }

                        if remoteService.isAuthenticated {
                            Button {
                                Task { await scanner.fetchFromRemote(service: remoteService) }
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.clockwise").foregroundStyle(.purple).frame(width: 28)
                                    Text("Refresh from Server").foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                } header: { Text("Remote Server") } footer: {
                    Text("Connect to a MediaVault server over the network. Sign in via the web page to authenticate.")
                }

                // MARK: Local Media Source
                if !remoteService.isEnabled {
                    Section {
                        Button { showFolderPicker = true } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus").foregroundStyle(.blue).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Select Media Folder").foregroundStyle(.primary)
                                    if let url = rootFolderURL {
                                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if rootFolderURL != nil {
                            Button {
                                Task { if let url = rootFolderURL { await scanner.scan(rootURL: url) } }
                            } label: {
                                HStack { Image(systemName: "arrow.clockwise").foregroundStyle(.blue).frame(width: 28); Text("Rescan Folder").foregroundStyle(.primary) }
                            }
                            Button(role: .destructive) { showClearConfirmation = true } label: {
                                HStack { Image(systemName: "folder.badge.minus").frame(width: 28); Text("Remove Folder") }
                            }
                        }
                    } header: { Text("Media Source") } footer: {
                        Text("Select a folder where each subfolder represents a profile. Supports local storage and connected external drives.")
                    }
                }

                if !scanner.profiles.isEmpty {
                    Section("Library Stats") {
                        StatRow(icon: "person.2", label: "Profiles", value: "\(scanner.profiles.count)")
                        StatRow(icon: "photo.stack", label: "Total Media", value: "\(scanner.profiles.reduce(0) { $0 + $1.totalCount })")
                        StatRow(icon: "photo", label: "Images", value: "\(scanner.profiles.reduce(0) { $0 + $1.imageCount })")
                        StatRow(icon: "video", label: "Videos", value: "\(scanner.profiles.reduce(0) { $0 + $1.videoCount })")
                        StatRow(icon: "heart.fill", label: "Liked Items", value: "\(likesService.likedItems.count)")
                    }
                }

                Section {
                    Toggle(isOn: $flattenFolders) {
                        HStack {
                            Image(systemName: "square.3.layers.3d").foregroundStyle(.blue).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Flatten Subfolders")
                                Text("Show all subfolder contents in the main gallery").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Browse") } footer: {
                    Text("When off, subfolders appear as navigable folders inside each profile.")
                }

                Section("Supported Formats") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Image(systemName: "photo").foregroundStyle(.blue).frame(width: 28); Text("JPG, JPEG, PNG, HEIC, HEIF, WebP, GIF, BMP, TIFF").font(.caption) }
                        HStack { Image(systemName: "video").foregroundStyle(.blue).frame(width: 28); Text("MP4, MOV, M4V, AVI, MKV, WMV").font(.caption) }
                    }.padding(.vertical, 4)
                }

                Section("Cache") {
                    Button {
                        ThumbnailService.shared.clearCache()
                    } label: {
                        HStack { Image(systemName: "xmark.bin").foregroundStyle(.orange).frame(width: 28); Text("Clear Thumbnail Cache").foregroundStyle(.primary) }
                    }
                }

                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                    HStack { Text("MediaVault"); Spacer(); Text("Local Media Browser").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    rootFolderURL = url
                    Task { await scanner.scan(rootURL: url) }
                }
            }
            .sheet(isPresented: $showLoginSheet) {
                if let url = remoteService.baseURL {
                    LoginSheetView(serverURL: url)
                }
            }
            .alert("Remove Folder?", isPresented: $showClearConfirmation) {
                Button("Remove", role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: "selectedFolderBookmark")
                    rootFolderURL = nil
                    scanner.profiles = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the folder reference. Your files will not be deleted.")
            }
        }
    }
}

struct StatRow: View {
    let icon: String; let label: String; let value: String
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 28)
            Text(label); Spacer()
            Text(value).foregroundStyle(.secondary).fontWeight(.medium)
        }
    }
}
