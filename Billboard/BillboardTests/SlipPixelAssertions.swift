import CoreGraphics
import XCTest
@testable import Billboard

/// Pixel checks for Civic Record's slip (spec 1.1, 3.4, 10.1), shared by the render tests. A slip is
/// drawn at `inset` points from every edge of an image rendered at scale 1 on paper:
///
/// - No shadow: the pixels just outside the slip's rule, at the middle of each side, are the ground
///   (and so are the pixels 3 pt out, where R2's offset shadows fell).
/// - A 1 pt rule: the slip's outermost pixels are `rule` over `sheet`.
/// - No stripe, glow or wash: just inside the rule, at the middle of each side, the pixels are the
///   plain `sheet`. R2's 4 pt status stripe, 2 pt glow border and topic gradient all drew there.
@MainActor
enum SlipPixels {
    typealias RGB = BillboardColorMath.RGB

    /// One colour step either way, for rounding in the renderer.
    static let accuracy = 2.5 / 255

    static func assertPlainSlip(
        in image: CGImage,
        inset: Int,
        dark: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let ground = BillboardPalette.background.resolved(dark: dark).rgb
        let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
        let ruleToken = BillboardPalette.separator.resolved(dark: dark)
        let rule = BillboardColorMath.composite(ruleToken.rgb, alpha: ruleToken.alpha, over: sheet)

        let minX = inset
        let maxX = image.width - 1 - inset
        let minY = inset
        let maxY = image.height - 1 - inset
        let midX = image.width / 2
        let midY = image.height / 2
        XCTAssertGreaterThan(maxX - minX, 40, "\(message): the slip is wide enough to sample", file: file, line: line)
        XCTAssertGreaterThan(maxY - minY, 40, "\(message): the slip is tall enough to sample", file: file, line: line)

        for distance in [1, 3] {
            let outside = [
                ("above", midX, minY - distance),
                ("below", midX, maxY + distance),
                ("left of", minX - distance, midY),
                ("right of", maxX + distance, midY)
            ]
            for (side, x, y) in outside {
                try assertColor(image, x: x, y: y, ground, "\(message): \(distance) pt \(side) the slip is the ground (no shadow)", file: file, line: line)
            }
        }

        let edges = [("left", minX, midY), ("right", maxX, midY), ("top", midX, minY), ("bottom", midX, maxY)]
        for (side, x, y) in edges {
            try assertColor(image, x: x, y: y, rule, "\(message): the \(side) edge is the 1 pt rule", file: file, line: line)
        }

        // Just inside the rule: where R2's 4 pt stripe (left) and 2 pt glow (every side) drew.
        let inside = [
            ("left", minX + 1, midY), ("left", minX + 3, midY),
            ("right", maxX - 1, midY), ("right", maxX - 3, midY),
            ("top", midX, minY + 1), ("top", midX, minY + 3),
            ("bottom", midX, maxY - 1), ("bottom", midX, maxY - 3)
        ]
        for (side, x, y) in inside {
            try assertColor(image, x: x, y: y, sheet, "\(message): inside the \(side) edge is the plain sheet (no stripe, glow or wash)", file: file, line: line)
        }
    }

    private static func assertColor(
        _ image: CGImage,
        x: Int,
        y: Int,
        _ expected: RGB,
        _ message: String,
        file: StaticString,
        line: UInt
    ) throws {
        let sample = try pixel(of: image, x: x, y: y)
        let matches = abs(sample.red - expected.red) <= accuracy
            && abs(sample.green - expected.green) <= accuracy
            && abs(sample.blue - expected.blue) <= accuracy
        XCTAssertTrue(matches, "\(message) at (\(x), \(y)): got \(hex(sample)), expected \(hex(expected))", file: file, line: line)
    }

    private static func hex(_ rgb: RGB) -> String {
        String(format: "#%02X%02X%02X", Int((rgb.red * 255).rounded()), Int((rgb.green * 255).rounded()), Int((rgb.blue * 255).rounded()))
    }

    /// The sRGB colour of one pixel, `x` and `y` from the top left.
    static func pixel(of image: CGImage, x: Int, y: Int) throws -> RGB {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(
                    x: -CGFloat(x),
                    y: -CGFloat(image.height - 1 - y),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return (red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
    }
}
