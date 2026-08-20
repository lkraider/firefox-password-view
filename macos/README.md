# Keywise — macOS app

This is a Swift package. Xcode Command Line Tools are enough to build,
test and run it. `swift build` ad-hoc signs its output, so this needs no
signing identity. A full Xcode install also opens this package directly.

## Building

```
zig build            # from the repo root: builds zig-out/lib/libkeywise.a first
cd macos
swift build
```

`Package.swift` links `libkeywise.a` through a raw `-L`/`-l` flag. That puts
the file outside SwiftPM's dependency graph, so SwiftPM keeps the binary it
linked last even after `libkeywise.a` changes. Run `rm -rf macos/.build`
before `swift build` any time `libkeywise.a` changes.

## Running

`swift build`'s output is a plain executable. Running it directly
(`.build/debug/Keywise`) launches it outside LaunchServices.
The window opens. It cannot take keyboard focus from the terminal. Use
`scripts/bundle.sh` to wrap it in a minimal ad-hoc-signed bundle, and
launch that with `open`:

```
scripts/bundle.sh          # builds core and app in release, produces .build/release/Keywise.app
open .build/release/Keywise.app
```

`scripts/bundle.sh` builds release by default, the Zig core with
`-Doptimize=ReleaseSafe` and the app with `swift build -c release`. Debug
turns off Zig's inlining and Swift's whole-module optimization, and
filtering and reveal slow down. Measure performance on a release build.
Pass `debug` for a fast dev rebuild: `scripts/bundle.sh debug`.

## Testing

Under Command Line Tools, `swift-testing`'s runtime lives in a Frameworks
directory the dynamic linker does not search by default. `Package.swift`
bakes in an `-rpath` for it. The compiler still needs `-F <path>` on the
command line to find the module:

```
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

A full Xcode install would not need this.

## Known issue

AppKit logs "reentrant operation in its NSTableView delegate" once during
the initial load of a large profile. No crash has followed it in any run
so far. macOS's message says the same call will assert in a future
release. Finding the call needs Instruments.
