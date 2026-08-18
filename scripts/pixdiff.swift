// Counts the pixels that differ between two PNG captures inside one rectangle.
//
// scripts/wine-check.sh compares one list cell across three captures of the
// same window. A whole-image hash is too strict: two captures of an idle
// window differ in about 5000 of 2119392 pixels, and the status bar's size
// grip differs by up to 43 in one channel.
//
// Usage:
//   pixdiff <a.png> <b.png> <window-width-points> <x> <y> <w> <h>
//
// The rectangle is in screen points with a top-left origin, measured from the
// window's own top-left corner. This file reads the scale from the image
// width against <window-width-points>, so it works on a 1x display and on a
// 2x one. It prints the count of pixels whose largest channel difference runs
// over 30.

import CoreGraphics
import Foundation
import ImageIO

func pixels(_ path: String) -> (data: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

let args = CommandLine.arguments
guard args.count == 8,
      let a = pixels(args[1]), let b = pixels(args[2]),
      let windowWidth = Double(args[3])
else {
    FileHandle.standardError.write(
        "usage: pixdiff <a.png> <b.png> <window-width-points> <x> <y> <w> <h>\n"
            .data(using: .utf8)!)
    exit(2)
}
guard a.w == b.w, a.h == b.h else {
    FileHandle.standardError.write("the two captures differ in size\n".data(using: .utf8)!)
    exit(1)
}

let scale = Double(a.w) / windowWidth
let rect = args[4...7].map { Int((Double($0)! * scale).rounded()) }
let x0 = max(0, rect[0]), y0 = max(0, rect[1])
let x1 = min(a.w, x0 + rect[2]), y1 = min(a.h, y0 + rect[3])

var differing = 0
for y in y0..<y1 {
    for x in x0..<x1 {
        let i = (y * a.w + x) * 4
        var worst = 0
        for c in 0..<3 { worst = max(worst, abs(Int(a.data[i + c]) - Int(b.data[i + c]))) }
        if worst > 30 { differing += 1 }
    }
}
print(differing)
