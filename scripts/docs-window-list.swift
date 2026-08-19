// Lists every on-screen window as one tab-separated line.
//
// CGWindowListCopyWindowInfo has no CLI. JXA's ObjC bridge does not resolve
// its signature, so scripts/screenshots.sh and scripts/wine-check.sh compile
// this file with `swiftc -O` and read its output.
//
// "<windowNumber>\t<ownerPID>\t<ownerName>\t<windowName>\t<x>\t<y>\t<w>\t<h>"
// The four bounds fields are screen points with a top-left origin, the same
// coordinates System Events and CGEvent take.

import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for w in list {
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    var r = CGRect.zero
    if let b = w[kCGWindowBounds as String] as? [String: Any] {
        r = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
    }
    print("\(num)\t\(pid)\t\(owner)\t\(name)\t\(Int(r.minX))\t\(Int(r.minY))\t\(Int(r.width))\t\(Int(r.height))")
}
