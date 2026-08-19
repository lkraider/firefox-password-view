// Posts synthetic mouse and keyboard events through CGEvent.
//
// System Events leaves `click at` unposted for a wine window, and it delivers
// Option as a literal character. Every synthetic input that has to reach wine
// goes through the CGEvent HID tap here. scripts/docs-screenshots.sh and
// scripts/wine-check.sh both compile this file with `swiftc -O`.
//
// Usage:
//   macinput drag <x1> <y1> <x2> <y2>   press, drag in 8 steps, release
//   macinput click <x> <y>              move, left press, left release
//   macinput rclick <x> <y>             move, right press, right release
//   macinput key <keycode> [alt|shift|cmd|ctrl ...]
//
// Every coordinate is a screen point with a top-left origin, the same
// coordinates scripts/docs-window-list.swift reports. A keycode is a Carbon virtual
// keycode: 35 is P, 36 is Return, 48 is Tab, 53 is Escape, 125 is Down.
//
// Both TCC permissions belong to the terminal that runs the caller.
// Accessibility posts the events. Screen Recording reads the window list.

import CoreGraphics
import Foundation

let settle: UInt32 = 60_000

func postMouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
        .post(tap: .cghidEventTap)
    usleep(settle)
}

func postKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(settle)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    FileHandle.standardError.write("usage: macinput drag|click|rclick|key ...\n".data(using: .utf8)!)
    exit(2)
}

switch command {
case "drag":
    let n = args.dropFirst().map { Double($0)! }
    let from = CGPoint(x: n[0], y: n[1])
    let to = CGPoint(x: n[2], y: n[3])
    postMouse(.mouseMoved, from, .left)
    postMouse(.leftMouseDown, from, .left)
    // AppKit reads the edge under the cursor on the first drag event, so the
    // path runs in steps.
    for i in 1...8 {
        let t = Double(i) / 8.0
        postMouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t,
                                             y: from.y + (to.y - from.y) * t), .left)
    }
    postMouse(.leftMouseUp, to, .left)

case "click", "rclick":
    let n = args.dropFirst().map { Double($0)! }
    let at = CGPoint(x: n[0], y: n[1])
    let left = command == "click"
    let button: CGMouseButton = left ? .left : .right
    postMouse(.mouseMoved, at, button)
    postMouse(left ? .leftMouseDown : .rightMouseDown, at, button)
    postMouse(left ? .leftMouseUp : .rightMouseUp, at, button)

case "key":
    guard let raw = args.dropFirst().first, let code = CGKeyCode(raw) else { exit(2) }
    var flags: CGEventFlags = []
    for name in args.dropFirst(2) {
        switch name {
        case "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "cmd": flags.insert(.maskCommand)
        case "ctrl": flags.insert(.maskControl)
        default:
            FileHandle.standardError.write("unknown modifier \(name)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    postKey(code, flags)

default:
    FileHandle.standardError.write("unknown command \(command)\n".data(using: .utf8)!)
    exit(2)
}
