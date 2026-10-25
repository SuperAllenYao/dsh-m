import SwiftUI

/// The pinned-session mark: Lucide pin (pin-d.svg, ISC) rendered as an embedded
/// SwiftUI Path - the official 24x24 path data, stroked single-color accent at
/// 13pt (design 3.2). The stroke width is optically nudged up from the 1.08pt
/// the SVG geometry would naively yield, so the line-art stays crisp at @2x.
struct PinMark: View {
    var size: CGFloat = 13
    var color: Color = Theme.Palette.accent

 /// Lucide pin, 24x24 viewBox, two subpaths: the needle and the pin body.
    private static let needlePath = "M12 17v5"
    private static let bodyPath = "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"

    var body: some View {
        let scale = size / 24
        return ZStack {
            SVGPath.path(from: Self.needlePath)
                .stroke(color, style: Self.strokeStyle)
            SVGPath.path(from: Self.bodyPath)
                .stroke(color, style: Self.strokeStyle)
        }
        .scaleEffect(scale)
        .frame(width: size, height: size)
    }

    private static let strokeStyle = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
}
