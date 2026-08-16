# Firefox Password Viewer — macOS app

A Swift package rather than an `.xcodeproj`: this machine has only the
Command Line Tools, no full Xcode and no codesigning identity, and
`swift build` ad-hoc signs its output, which is enough to run locally. Open
this in Xcode once a full install exists; nothing here depends on SwiftPM
specifically.

## Building

```
zig build            # from the repo root: builds zig-out/lib/libffpw.a first
cd macos
swift build
```

SwiftPM does not know `libffpw.a` is a build input (it is linked through a
raw `-L`/`-l` flag, outside SwiftPM's own dependency graph), so it will not
relink after a Zig-side change on its own. Run `rm -rf macos/.build` before
`swift build` any time `libffpw.a` changes.

## Testing

Only Command Line Tools is installed, and `swift-testing`'s runtime lives
under a Frameworks directory the dynamic linker does not search by default
in that configuration. `Package.swift` bakes in an `-rpath` for it, and
`-F <path>` still needs to be passed at the command line for the compiler
itself to find the module:

```
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

A full Xcode install would not need this.

## Known issue

AppKit logs "reentrant operation in its NSTableView delegate" once during
the initial load of a large profile. It has not been observed to crash, but
macOS's own message marks it a future assert. Chasing it further needs
Instruments, which this environment does not have; do this before the
release milestone.
