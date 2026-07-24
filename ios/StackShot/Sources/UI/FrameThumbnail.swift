import ImageIO
import SwiftUI

/// Small square thumbnail for a frame or merged result on disk (DNG/HEIC/PNG),
/// decoded off the main actor. Used by the review filmstrip and the library.
struct FrameThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            let loaded = await Task.detached(priority: .utility) {
                Self.thumbnail(for: url)
            }.value
            image = loaded
        }
    }

    static func thumbnail(for url: URL, side: CGFloat = 120) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
