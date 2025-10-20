import SwiftUI
import UIKit

struct ZoomableImageView: View {
    let url: String
    @Binding var aspectMode: ContentMode

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let fileURL = URL(string: url), fileURL.isFileURL {
                    if let data = try? Data(contentsOf: fileURL), let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: aspectMode)
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                } else {
                    AsyncImage(url: URL(string: url)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: aspectMode)
                    } placeholder: {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
