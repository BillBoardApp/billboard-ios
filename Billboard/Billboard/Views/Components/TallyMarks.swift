import SwiftUI
import UIKit

/// Tally marks, the clerk's count (Civic Record spec 3.23): `count` upright strokes, at most four,
/// struck through by one diagonal. `TallyMarks(count: 4)` is the streak's glyph on the Bills
/// masthead, in place of R2's flame; Civic Rank's 30-day record (4.65) is drawn from the same marks.
///
/// The marks sit on a 24-unit square centred in the frame, as the mockup's glyph does: uprights
/// 4 units apart and 14 tall, the diagonal running past the first and last. Stroke the shape; it
/// has no fill. `TallyMarksGlyph` is the stroked glyph at a size.
struct TallyMarks: Shape {
    /// Uprights, 0 to 4 (a fifth mark is the diagonal).
    var count: Int = 4
    /// Whether the diagonal is drawn.
    var struck: Bool = true

    static let maximumCount = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let uprights = min(max(count, 0), Self.maximumCount)
        guard uprights > 0 else { return path }

        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 12) * unit, y: rect.midY + (y - 12) * unit)
        }

        // Four uprights fall at 5.5, 9.5, 13.5 and 17.5; fewer stay centred on the same middle.
        let first = 11.5 - CGFloat(uprights - 1) * 2
        let last = first + CGFloat(uprights - 1) * 4
        for index in 0..<uprights {
            let x = first + CGFloat(index) * 4
            path.move(to: point(x, 5))
            path.addLine(to: point(x, 19))
        }
        if struck {
            path.move(to: point(first - 2.5, 16.6))
            path.addLine(to: point(last + 3, 7.4))
        }
        return path
    }
}

/// `TallyMarks` stroked as a glyph: four uprights and the diagonal in 1.8 pt round-capped lines,
/// 17 pt square by default (spec 3.23), in the foreground style. Decoration: hidden from VoiceOver,
/// so the control that shows it says what it counts ("4-day streak").
struct TallyMarksGlyph: View {
    var count: Int = 4
    var size: CGFloat = 17
    var lineWidth: CGFloat = 1.8

    var body: some View {
        TallyMarks(count: count)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension TallyMarksGlyph {
    /// The size the Large Content Viewer is handed, as large as the system symbols it shows (the score
    /// chip's star arrives at about 68 pt), so the marks are not enlarged from a 17 pt picture.
    static let largeContentSize: CGFloat = 68

    /// The streak's tally marks as a template image, for the Large Content Viewer (spec 3.23:
    /// `HeaderMetricBadge`'s viewer stays). SwiftUI hands the viewer a picture only for an `Image`, so a
    /// stroked `Shape` would leave the viewer with the words alone. The stroke keeps the glyph's
    /// proportion (1.8 pt at 17 pt).
    static func largeContentImage(count: Int = 4) -> UIImage {
        let side = largeContentSize
        let lineWidth = 1.8 * side / 17
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let path = TallyMarks(count: count).path(in: CGRect(x: 0, y: 0, width: side, height: side))
            let cg = context.cgContext
            cg.addPath(path.cgPath)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(UIColor.label.cgColor)
            cg.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}
