import SwiftUI

struct ZoomableImageView: View {
    let url: String
    @Binding var aspectMode: ContentMode

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: URL(string: url)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: aspectMode)
            } placeholder: {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
