import SwiftUI
import Combine

struct SettingsView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @State private var serverSettings = ServerSettings.load()
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @AppStorage("skipDuration") private var skipDuration: Double = 5.0

    var body: some View {
        NavigationStack {
            List {
                connectionSection
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
    }

    private var connectionSection: some View {
        Section("Server Connection") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current Server")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(networkManager.baseURL)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
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

            Button(action: clearServerCache) {
                Label("Clear Server Cache", systemImage: "server.rack")
            }

            Button(action: refreshServerCache) {
                Label("Refresh Server Cache", systemImage: "arrow.clockwise")
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
        Task {
            await networkManager.clearCache()
            alertMessage = "Server cache cleared"
            showingAlert = true
        }
    }

    private func refreshServerCache() {
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
        alertMessage = "All data cleared"
        showingAlert = true
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
