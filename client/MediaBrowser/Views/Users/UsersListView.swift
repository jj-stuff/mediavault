import SwiftUI

struct UsersListView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @State private var searchText = ""

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
