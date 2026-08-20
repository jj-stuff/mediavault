import SwiftUI

struct ProfileCardView: View {
    let profile: MediaProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaThumbnail(
                item: profile.coverItem,
                size: CGSize(width: 300, height: 300),
                cornerRadius: 12
            ) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .overlay {
                        Image(systemName: "person.crop.square.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if profile.imageCount > 0 {
                        Label("\(profile.imageCount)", systemImage: "photo")
                    }
                    if profile.videoCount > 0 {
                        Label("\(profile.videoCount)", systemImage: "video")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(profile.name), \(profile.imageCount) photos, \(profile.videoCount) videos"
        )
    }
}
