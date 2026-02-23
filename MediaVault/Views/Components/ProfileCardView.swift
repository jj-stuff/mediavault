import SwiftUI

struct ProfileCardView: View {
    let profile: MediaProfile
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .aspectRatio(1, contentMode: .fit)

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "person.crop.square.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 8) {
                    if profile.imageCount > 0 { Label("\(profile.imageCount)", systemImage: "photo") }
                    if profile.videoCount > 0 { Label("\(profile.videoCount)", systemImage: "video") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let url = profile.thumbnailURL else { return }
        let item = MediaItem(id: UUID(), url: url, fileName: url.lastPathComponent, mediaType: .image, profileID: profile.id, profileName: profile.name, subfolder: nil)
        thumbnail = await ThumbnailService.shared.thumbnail(for: item, size: CGSize(width: 300, height: 300))
    }
}
