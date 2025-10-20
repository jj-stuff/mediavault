import UIKit

extension UIImage {
    func resized(toWidth width: CGFloat) -> UIImage? {
        guard width > 0 else { return nil }

        let scale = width / size.width
        let newHeight = size.height * scale
        let size = CGSize(width: width, height: newHeight)

        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        draw(in: CGRect(origin: .zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resizedImage
    }

    func resizedIfNeeded(maxDimension: CGFloat) -> UIImage {
        guard size.width > maxDimension || size.height > maxDimension else { return self }

        let maxSide = max(size.width, size.height)
        let scale = maxDimension / maxSide
        let targetWidth = size.width * scale
        return resized(toWidth: targetWidth) ?? self
    }

    var diskCost: Int {
        pngData()?.count ?? (jpegData(compressionQuality: 0.9)?.count ?? 0)
    }
}
