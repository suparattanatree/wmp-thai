// Draws the app icon and writes an .icns.
//
// Kept as code rather than a binary asset so the icon can be adjusted and
// regenerated: run ./Tools/make_icon.sh
//
// The shape follows what macOS 26 expects of every app icon - the same rounded
// square, filled edge to edge, with the meaning carried by the glyph. Here that
// is the two letters the input menu itself uses for these layouts: A and ก.

import AppKit
import CoreText

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outputDirectory)/wmp.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// Apple's continuous-curve corner: 22.37% of the side.
func squirclePath(in rect: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.height * 0.2237)
}

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    context.setShouldAntialias(true)

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icons do not touch the edge of their canvas: the art sits inside,
    // leaving room for the shadow the Dock draws behind it.
    let shape = squirclePath(in: rect.insetBy(dx: size * 0.08, dy: size * 0.08))
    context.saveGState()
    shape.addClip()

    // Body: a deep indigo lifting to blue, the way system icons carry light from
    // the top edge rather than sitting flat.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.44, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.24, blue: 0.72, alpha: 1),
    ])
    gradient?.draw(in: rect, angle: -90)

    // Light gathering at the top, fading out well before the middle. Drawn over
    // the full height so no band shows where it ends.
    let sheen = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.22),
        NSColor(white: 1, alpha: 0.06),
        NSColor(white: 1, alpha: 0.0),
    ])
    sheen?.draw(in: rect, angle: -90)
    context.restoreGState()

    // Inner rim: a hairline of light on the top edge, shadow at the bottom.
    context.saveGState()
    shape.addClip()
    context.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
    context.setLineWidth(size * 0.012)
    shape.stroke()
    context.restoreGState()

    // The glyphs: "A" and "ก", the same pair the input menu shows.
    //
    // Drawn as one CoreText line rather than two separate strings: the Thai
    // glyph comes from a fallback font whose metrics differ from the Latin one,
    // so laying them out separately leaves them sitting on different baselines.
    // One line means one baseline, and centring uses the ink they actually
    // cover rather than the boxes their fonts declare.
    let pointSize = size * 0.40
    let text = NSMutableAttributedString(string: "Aก")
    text.addAttributes([
        .font: NSFont.systemFont(ofSize: pointSize, weight: .semibold),
        .foregroundColor: NSColor.white,
        .kern: size * 0.05,
    ], range: NSRange(location: 0, length: 1))
    text.addAttributes([
        .font: NSFont.systemFont(ofSize: pointSize * 1.06, weight: .semibold),
        .foregroundColor: NSColor.white,
    ], range: NSRange(location: 1, length: 1))

    let line = CTLineCreateWithAttributedString(text)
    let ink = CTLineGetImageBounds(line, context)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.008),
                      blur: size * 0.025,
                      color: NSColor(white: 0, alpha: 0.18).cgColor)
    context.textPosition = CGPoint(
        x: (size - ink.width) / 2 - ink.minX,
        y: (size - ink.height) / 2 - ink.minY
    )
    CTLineDraw(line, context)
    context.restoreGState()

    image.unlockFocus()
    return image
}

let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    let image = draw(size: pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

print("wrote \(iconset)")
