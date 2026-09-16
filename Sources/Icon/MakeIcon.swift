import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the Oral English app icon at every size the iconset needs.
//
//   ./make-icon.sh
//
// The icon is code rather than a binary blob so it can be reviewed in a diff, regenerated
// after a palette change, and re-rendered at whatever sizes a future macOS wants. It links
// nothing from Sources/ — CoreGraphics and ImageIO only — so it cannot drift with the app
// or drag Speech into a build that does not need it.
//
// ## The mark
//
// A reference waveform above a row of word marks, one of them hollow. That is the whole
// product in two elements: hear a sentence read properly, then see which words were
// actually understood. A microphone would have said "this app records", which is the least
// interesting thing about it.
//
// ## Why it is drawn per size rather than scaled
//
// A single 1024 master downsampled to 16px turns six dots into grey mush. So detail is a
// function of size: the full mark at 128 and above, fewer and fatter elements at 32-64, and
// at 16 just the waveform over a single bar, which is the silhouette that still reads.

// MARK: - Geometry

/// The macOS icon plate.
///
/// A rounded rectangle at Apple's corner ratio — 0.225 of the plate's width, which is the
/// 185/824 the system uses on a 1024 canvas.
///
/// A superellipse was tried first, on the theory that continuous curvature would sit better
/// beside system icons. Rendered at 256 it read as an organic, petal-like blob rather than
/// an app icon: at this corner ratio the shape is mostly corner, so the superellipse's
/// flattening dominates the silhouette instead of refining it. The plain rounded rect is
/// both closer to the system shape and more predictable across sizes.
func platePath(in rect: CGRect) -> CGPath {
    let r = rect.width * 0.225
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: - Palette
//
// Indigo rather than the blue every voice app uses, and deliberately not red: this app
// shows you your mistakes, and a red icon would set that tone before it is earned.

struct RGBA {
    var r, g, b, a: Double
    static let backTop    = RGBA(r: 0.36, g: 0.33, b: 0.78, a: 1)
    static let backBottom = RGBA(r: 0.17, g: 0.15, b: 0.44, a: 1)
    static let ink        = RGBA(r: 1.00, g: 1.00, b: 1.00, a: 1)
    static let inkSoft    = RGBA(r: 1.00, g: 1.00, b: 1.00, a: 0.55)
}

extension CGContext {
    func setFill(_ c: RGBA) { setFillColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
    func setStroke(_ c: RGBA) { setStrokeColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
}

// MARK: - Drawing

/// Relative bar heights of the waveform, as a fraction of the available half-height.
///
/// Two bursts with a gap, so it reads as a spoken phrase rather than a flat tone: speech has
/// pauses and a generic "sound" glyph does not.
let waveform: [Double] = [0.24, 0.52, 0.80, 1.00, 0.72, 0.38,
                          0.00, 0.00,
                          0.30, 0.62, 0.86, 0.54, 0.26]

func drawIcon(size: Int, into ctx: CGContext) {
    let s = Double(size)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icons do not fill their canvas; the shadow and optical margin live in the inset.
    let inset = s * 0.094
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    // Background plate
    ctx.saveGState()
    ctx.addPath(platePath(in: plate))
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let top = RGBA.backTop, bottom = RGBA.backBottom
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [top.r, top.g, top.b, 1])!,
            CGColor(colorSpace: space, components: [bottom.r, bottom.g, bottom.b, 1])!,
        ] as CFArray,
        locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: [])
    }
    ctx.restoreGState()

    // Detail tier. Chosen by what survives, not by taste.
    let tier: Int = size >= 128 ? 2 : (size >= 32 ? 1 : 0)

    let content = plate.insetBy(dx: plate.width * 0.15, dy: plate.height * 0.19)
    // The waveform sits above centre so the word row below is not cramped.
    let waveCenterY = tier == 0 ? content.midY : content.midY + content.height * 0.19
    let waveMaxHalf = content.height * (tier == 0 ? 0.44 : 0.38)

    // Waveform
    let bars: [Double]
    switch tier {
    case 2: bars = waveform
    case 1: bars = [0.34, 0.74, 1.00, 0.62, 0.00, 0.48, 0.86, 0.42]
    default: bars = [0.42, 0.82, 1.00, 0.66, 0.36]
    }
    let slot = content.width / Double(bars.count)
    let barW = slot * (tier == 0 ? 0.52 : 0.50)
    ctx.setFill(.ink)
    for (i, h) in bars.enumerated() {
        guard h > 0 else { continue }
        let half = max(waveMaxHalf * h, barW * 0.5)
        let x = content.minX + slot * Double(i) + (slot - barW) / 2
        let r = CGRect(x: x, y: waveCenterY - half, width: barW, height: half * 2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2,
                           transform: nil))
    }
    ctx.fillPath()

    // Word row: filled marks for understood words, one hollow for the missed one.
    guard tier > 0 else {
        // At 16px the dots cannot survive, so the row becomes one bar — the silhouette
        // still reads as "sound, then a line of words".
        let h = content.height * 0.085
        let r = CGRect(x: content.minX, y: content.minY - h * 0.2,
                       width: content.width, height: h)
        ctx.setFill(.inkSoft)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2,
                           transform: nil))
        ctx.fillPath()
        return
    }

    let count = tier == 2 ? 6 : 4
    let missedIndex = tier == 2 ? 3 : 2
    let rowY = content.minY + content.height * 0.10
    let dotD = min(content.width / Double(count) * 0.56, content.height * 0.19)
    let gap = (content.width - dotD * Double(count)) / Double(count - 1)
    // Per tier, because the two sizes want opposite things: at 128+ a thin ring shows a
    // clear hole, and that same ring disappears at 32 where the dot is a few pixels across.
    let lineW = max(dotD * (tier == 2 ? 0.19 : 0.30), s * 0.010)

    for i in 0..<count {
        let x = content.minX + (dotD + gap) * Double(i)
        let r = CGRect(x: x, y: rowY - dotD / 2, width: dotD, height: dotD)
        if i == missedIndex {
            ctx.setStroke(.ink)
            ctx.setLineWidth(lineW)
            ctx.strokeEllipse(in: r.insetBy(dx: lineW / 2, dy: lineW / 2))
        } else {
            ctx.setFill(.ink)
            ctx.fillEllipse(in: r)
        }
    }
}

// MARK: - Output

func render(size: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure("could not create a \(size)x\(size) context")
    }
    drawIcon(size: size, into: ctx)
    guard let image = ctx.makeImage() else { throw Failure("could not snapshot \(size)") }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("could not open \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("could not write \(url.lastPathComponent)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// iconutil's required names. A missing or misnamed entry makes it fail with a message that
// does not say which one, so the list is explicit.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",     32),
    ("icon_32x32",      32), ("icon_32x32@2x",     64),
    ("icon_128x128",   128), ("icon_128x128@2x",  256),
    ("icon_256x256",   256), ("icon_256x256@2x",  512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
              ?? "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for v in variants {
    try render(size: v.size, to: out.appendingPathComponent("\(v.name).png"))
    print("  \(v.name).png  \(v.size)x\(v.size)")
}
print("wrote \(variants.count) sizes to \(out.path)")
