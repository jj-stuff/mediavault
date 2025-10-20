import SwiftUI

struct SettingsView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var localManager: LocalFileManager

    @State private var serverSettings = ServerSettings.load()
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingFolderPicker = false

    @AppStorage("skipDuration") private var skipDuration: Double = 5.0
    @AppStorage("useLocalMode") private var useLocalMode = false

    var body: some View {
        NavigationStack {
            List {
                sourceSection
                videoControlsSection
                cacheSection
                aboutSection
            }
            .navigationTitle("Settings")
            .alert("Notice", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
        }
        .onReceive(networkManager.$serverSettings) { updatedSettings in
            serverSettings = updatedSettings
        }
        .onChange(of: useLocalMode) { _, newValue in
            if newValue {
                if localManager.selectedFolder == nil {
                    showingFolderPicker = true
                } else {
                    localManager.refresh()
                }
            } else {
                Task {
                    await networkManager.fetchUsers()
                }
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                localManager.updateSelectedFolder(url)
            } onCancel: {
                if localManager.selectedFolder == nil {
                    useLocalMode = false
                }
            }
        }
    }

    private var sourceSection: some View {
        Section("Content Source") {
            Toggle("Use Local Files", isOn: $useLocalMode)

            if useLocalMode {
                localConfiguration
            } else {
                remoteConfiguration
            }
        }
    }

    private var remoteConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Server")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(networkManager.baseURL)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)

            TextField("http://192.168.1.123:3000", text: $serverSettings.address)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .textContentType(.URL)

            Text("Include http/https and port if required. Local addresses default to port 3000.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: updateServer) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Update Connection")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding(.vertical, 4)
    }

    private var localConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected Folder")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let folder = localManager.selectedFolder {
                    Text(folder.lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text("No folder selected")
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Select Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }

                Button {
                    localManager.refresh()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                }
                .disabled(localManager.selectedFolder == nil)
            }

            if localManager.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning media…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("\(localManager.mediaItems.count) items indexed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = localManager.lastScanError {
                Text("Last scan error: \(error.localizedDescription)")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let folder = localManager.selectedFolder {
                Text(folder.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else {
                Text("Choose a folder from an attached drive or “On My iPhone” to browse locally.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var videoControlsSection: some View {
        Section("Video Controls") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Skip Duration")
                    Spacer()
                    Text("\(Int(skipDuration)) seconds")
                        .foregroundColor(.secondary)
                }

                Slider(value: $skipDuration, in: 1...60, step: 1)
                    .accentColor(.blue)
            }
        }
    }

    private var cacheSection: some View {
        Section("Cache Management") {
            Button(action: clearImageCache) {
                Label("Clear Image Cache", systemImage: "photo")
            }

            if !useLocalMode {
                Button(action: clearServerCache) {
                    Label("Clear Server Cache", systemImage: "server.rack")
                }

                Button(action: refreshServerCache) {
                    Label("Refresh Server Cache", systemImage: "arrow.clockwise")
                }
            }

            Button(action: clearAllData) {
                Label("Clear All Data", systemImage: "trash")
                    .foregroundColor(.red)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("2.0.0")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Cache Size")
                Spacer()
                Text(formatBytes(ImageCache.shared.diskUsage))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func updateServer() {
        let normalizedSettings = serverSettings.normalized()
        serverSettings = normalizedSettings
        networkManager.serverSettings = normalizedSettings
        alertMessage = "Server updated to \(normalizedSettings.fullURL)"
        showingAlert = true

        Task {
            await networkManager.fetchUsers()
        }
    }

    private func clearImageCache() {
        ImageCache.shared.clear()
        alertMessage = "Image cache cleared"
        showingAlert = true
    }

    private func clearServerCache() {
        guard !useLocalMode else { return }
        Task {
            await networkManager.clearCache()
            alertMessage = "Server cache cleared"
            showingAlert = true
        }
    }

    private func refreshServerCache() {
        guard !useLocalMode else { return }
        Task {
            await networkManager.refreshCache()
            await networkManager.fetchUsers()
            alertMessage = "Server cache refreshed"
            showingAlert = true
        }
    }

    private func clearAllData() {
        ImageCache.shared.clear()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        let defaultSettings = ServerSettings().normalized()
        serverSettings = defaultSettings
        networkManager.serverSettings = defaultSettings
        localManager.clearSelection()
        useLocalMode = false

        alertMessage = "All data cleared"
        showingAlert = true
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
