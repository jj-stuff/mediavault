import Foundation
import SwiftUI

@MainActor
final class DeletionManager: ObservableObject {
    static let shared = DeletionManager()

    @Published private(set) var markedForDeletion: Set<String> = []
    @Published private(set) var isUpdating = false

    private init() {}

    func reset() {
        markedForDeletion.removeAll()
    }

    func toggleDeletion(_ item: MediaItem) async {
        let path = item.fullPath ?? item.url

        isUpdating = true

        do {
            if markedForDeletion.contains(path) {
                try await removeFromDeletionList(path)
                markedForDeletion.remove(path)
            } else {
                try await addToDeletionList(path)
                markedForDeletion.insert(path)
            }
        } catch {
            print("Error updating deletion list: \(error)")
        }

        isUpdating = false
    }

    func isMarkedForDeletion(_ item: MediaItem) -> Bool {
        markedForDeletion.contains(item.fullPath ?? item.url)
    }

    func loadDeletionList() async {
        guard let url = URL(string: "\(NetworkManager.shared.baseURL)/api/deletion-list") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(DeletionListResponse.self, from: data)
            markedForDeletion = Set(response.paths)
        } catch {
            print("Error loading deletion list: \(error)")
        }
    }

    private func addToDeletionList(_ path: String) async throws {
        try await updateDeletionList(path: path, endpoint: "/api/deletion-list/add")
    }

    private func removeFromDeletionList(_ path: String) async throws {
        try await updateDeletionList(path: path, endpoint: "/api/deletion-list/remove")
    }

    private func updateDeletionList(path: String, endpoint: String) async throws {
        guard let url = URL(string: "\(NetworkManager.shared.baseURL)\(endpoint)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
