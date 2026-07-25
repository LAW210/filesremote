import CoreGraphics

extension CGRect {
    /// The rect an aspect-fit image occupies inside a view, i.e. the content area
    /// excluding letterbox bars. Shared by the tap-to-loupe mapping and the 1:1 crop
    /// guide so the two can never disagree about where the image actually is.
    static func aspectFit(_ imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (viewSize.width - fitted.width) / 2,
                      y: (viewSize.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}
