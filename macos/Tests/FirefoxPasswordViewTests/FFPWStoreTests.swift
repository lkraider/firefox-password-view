import Testing
@testable import FirefoxPasswordView

/// Exercises the Swift bridging layer against the same fixtures the Zig
/// tests use. The crypto itself is proven at the Zig level; this only
/// checks that FFPWStore marshals the C ABI correctly.
struct FFPWStoreTests {
    private func fixture(_ name: String) -> String {
        "../core/testdata/\(name)"
    }

    @Test func freshFixtureOpensAndDecrypts() async {
        let store = FFPWStore()
        let (needsPassword, error) = await store.open(profilePath: fixture("fresh"))
        #expect(error == nil)
        #expect(!needsPassword)

        let count = await store.count()
        #expect(count == 3)

        let matches = await store.search("")
        #expect(matches.count == 3)

        let narrowed = await store.search("sub.example.org")
        #expect(narrowed.count == 1)

        let entries = await store.entries()
        let entry = entries[Int(narrowed[0])]
        #expect(entry.hostname == "https://sub.example.org")
        #expect(entry.username == "fixture-user-2")
        #expect(entry.isAccountCredential == false)
        #expect(entry.isExtension == false)

        switch await store.reveal(at: narrowed[0]) {
        case .success(let secret):
            #expect(secret.value == "fixture-pass-2")
            await secret.forget()
        case .failure(let err):
            Issue.record("reveal failed: \(err)")
        }

        await store.close()
    }

    @Test func primaryFixtureNeedsPasswordAndRejectsWrongOne() async {
        let store = FFPWStore()
        let (needsPassword, error) = await store.open(profilePath: fixture("primary"))
        #expect(error == nil)
        #expect(needsPassword)

        let wrong = await store.unlock(password: "not-the-password")
        #expect(wrong == .wrongPassword)

        let right = await store.unlock(password: "fixture-primary-password-1")
        #expect(right == nil)

        let count = await store.count()
        #expect(count == 3)
        await store.close()
    }

    @Test func unmigratedFixtureReportsLegacy3DES() async {
        let store = FFPWStore()
        let (needsPassword, error) = await store.open(profilePath: fixture("unmigrated"))
        #expect(error == nil)
        #expect(!needsPassword)

        let matches = await store.search("")
        #expect(matches.count == 3)

        let entries = await store.entries()
        #expect(entries[Int(matches[0])].username == "")

        switch await store.reveal(at: matches[0]) {
        case .success:
            Issue.record("a 3DES-only entry should not decrypt")
        case .failure(let err):
            #expect(err == .legacy3DES)
        }
        await store.close()
    }

    @Test func syncShapedFixtureLabelsAccountAndExtensionRows() async {
        let store = FFPWStore()
        let (needsPassword, error) = await store.open(profilePath: fixture("sync-shaped"))
        #expect(error == nil)
        #expect(!needsPassword)

        // 7 rows on disk, 2 of them tombstones: the store's count excludes them.
        let count = await store.count()
        #expect(count == 5)

        let matches = await store.search("")
        let entries = await store.entries()
        var accountCount = 0
        var extensionCount = 0
        for index in matches {
            let entry = entries[Int(index)]
            if entry.isAccountCredential { accountCount += 1 }
            if entry.isExtension { extensionCount += 1 }
        }
        #expect(accountCount == 1)
        #expect(extensionCount == 1)
        await store.close()
    }

    @Test func everyFFPWErrorCaseHasItsOwnMessage() {
        let cases: [FFPWError] = [
            .noProfile, .openFailed, .needsPassword, .wrongPassword,
            .legacy3DES, .outOfMemory, .io, .range, .unknown(99),
        ]
        var seen = Set<String>()
        for error in cases {
            let message = error.localizedDescription
            #expect(!message.isEmpty, "\(error) has no message")
            #expect(!seen.contains(message), "\(error) shares a message with another case")
            seen.insert(message)
        }
    }
}
