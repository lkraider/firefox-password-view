// Draws Icon.icns, and the PNG the README shows. Run it after changing the
// artwork:
//
//     swift macos/scripts/make-icon.swift macos/Icon.icns docs/images/icon.png
//
// The .icns is committed, so a build needs neither this script nor a
// designer. Every shape is a CoreGraphics path. SF Symbols are excluded by
// their own licence from appearing in an app icon.
import AppKit
import CoreGraphics
import Foundation

let side = 1024.0

func drawIcon(into ctx: CGContext) {
    // macOS draws app icons inside a rounded square that leaves a margin on
    // all four sides. 100/1024 matches the grid Apple's own icons use.
    let inset = 100.0
    let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.20, green: 0.20, blue: 0.24, alpha: 1),
            CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: side),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // The key reads at 16 pt: a ring, a shaft, two teeth. Amber matches the
    // badge the app puts on the Firefox Accounts row.
    let amber = CGColor(red: 0.95, green: 0.66, blue: 0.24, alpha: 1)
    ctx.setFillColor(amber)

    let midY = 512.0
    let shaftWidth = 80.0

    let ringCenter = CGPoint(x: 355, y: midY)
    let ringOuter = 160.0
    let ringInner = 74.0
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(
        x: ringCenter.x - ringOuter, y: ringCenter.y - ringOuter,
        width: ringOuter * 2, height: ringOuter * 2
    ))
    ring.addEllipse(in: CGRect(
        x: ringCenter.x - ringInner, y: ringCenter.y - ringInner,
        width: ringInner * 2, height: ringInner * 2
    ))
    ctx.addPath(ring)
    ctx.fillPath(using: .evenOdd)

    // The shaft starts inside the ring, so the two read as one piece.
    let shaftStart = ringCenter.x + ringInner
    ctx.addPath(CGPath(
        roundedRect: CGRect(
            x: shaftStart, y: midY - shaftWidth / 2,
            width: 830 - shaftStart, height: shaftWidth
        ),
        cornerWidth: shaftWidth / 2, cornerHeight: shaftWidth / 2,
        transform: nil
    ))
    ctx.fillPath()

    // Two teeth hang off the bottom edge of the shaft.
    for x in [596.0, 702.0] {
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: x, y: midY - 175, width: shaftWidth, height: 150),
            cornerWidth: 24, cornerHeight: 24,
            transform: nil
        ))
        ctx.fillPath()
    }
}

func renderPNG(size: Double) -> Data {
    let scale = size / side
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(into: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ffpw-icon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// The names iconutil expects. 16 through 512, each at 1x and 2x.
for base in [16.0, 32.0, 128.0, 256.0, 512.0] {
    try renderPNG(size: base)
        .write(to: iconset.appendingPathComponent("icon_\(Int(base))x\(Int(base)).png"))
    try renderPNG(size: base * 2)
        .write(to: iconset.appendingPathComponent("icon_\(Int(base))x\(Int(base))@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output)")

// A flat PNG next to the .icns, for a look without opening Preview.
try renderPNG(size: 512).write(to: URL(fileURLWithPath: output + ".preview.png"))

// The README shows this one inline with its h1. Markdown sets no width, so
// the file ships at the size it displays.
if CommandLine.arguments.count > 2 {
    let readmeIcon = CommandLine.arguments[2]
    try renderPNG(size: 96).write(to: URL(fileURLWithPath: readmeIcon))
    print("wrote \(readmeIcon)")
}
