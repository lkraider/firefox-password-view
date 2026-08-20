import CKeywise
import Foundation

enum KeywiseError: Error, Sendable, Equatable {
    case noProfile
    case openFailed
    case needsPassword
    case wrongPassword
    case legacy3DES
    case outOfMemory
    case io
    case range
    case unknown(UInt32)

    init(_ status: keywise_status) {
        switch status {
        case KEYWISE_ERR_NO_PROFILE: self = .noProfile
        case KEYWISE_ERR_OPEN: self = .openFailed
        case KEYWISE_ERR_NEEDS_PASSWORD: self = .needsPassword
        case KEYWISE_ERR_WRONG_PASSWORD: self = .wrongPassword
        case KEYWISE_ERR_LEGACY_3DES: self = .legacy3DES
        case KEYWISE_ERR_OOM: self = .outOfMemory
        case KEYWISE_ERR_IO: self = .io
        case KEYWISE_ERR_RANGE: self = .range
        default: self = .unknown(status.rawValue)
        }
    }
}

extension KeywiseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noProfile: "No Firefox profile was found at that path."
        case .openFailed: "Could not open key4.db for this profile."
        case .needsPassword: "This profile needs its Primary Password."
        case .wrongPassword: "Wrong Primary Password. Try again."
        case .legacy3DES: "This entry is still 3DES. This app cannot decrypt it."
        case .outOfMemory: "Out of memory."
        case .io: "Could not read this profile's files."
        case .range: "That entry does not exist."
        case .unknown(let code): "Unexpected error (\(code))."
        }
    }
}

/// Wraps one keywise_store. keywise.h gives one store to one thread at a time.
/// Every method here is actor-isolated, so Swift serializes the calls onto
/// it. Opening a profile and decrypting a password run on this actor, off
/// the main actor the caller runs on.
actor KeywiseStore {
    private var handle: OpaquePointer?

    /// keywise_open tries an empty Primary Password on the way, since most
    /// profiles carry none. `needsPassword` on the result tells the caller
    /// to prompt. `count`, `entries` and `search` stay empty until `unlock`
    /// succeeds.
    func open(profilePath: String) -> (needsPassword: Bool, error: KeywiseError?) {
        var newHandle: OpaquePointer?
        let status = profilePath.withCString { cPath in
            keywise_open(cPath, &newHandle)
        }
        handle = newHandle
        if status == KEYWISE_OK {
            return (false, nil)
        }
        if status == KEYWISE_ERR_NEEDS_PASSWORD {
            return (true, nil)
        }
        return (false, KeywiseError(status))
    }

    func unlock(password: String) -> KeywiseError? {
        guard let handle else { return .noProfile }
        let status = password.withCString { cPassword in
            keywise_unlock(handle, cPassword, password.utf8.count)
        }
        return status == KEYWISE_OK ? nil : KeywiseError(status)
    }

    func close() {
        if let handle {
            keywise_close(handle)
        }
        handle = nil
    }

    func count() -> Int {
        guard let handle else { return 0 }
        return keywise_count(handle)
    }

    /// Every matching index. NSTableView draws the visible rows only, so
    /// handing back the whole match set costs one UInt32 per match. The
    /// buffer is sized to `count()`, since no query matches more entries
    /// than the store holds, and that takes one `keywise_search` call.
    func search(_ query: String) -> [UInt32] {
        guard let handle else { return [] }
        let capacity = keywise_count(handle)
        guard capacity > 0 else { return [] }
        var out = [UInt32](repeating: 0, count: capacity)
        let total = query.withCString { cQuery in
            out.withUnsafeMutableBufferPointer { buf in
                keywise_search(handle, cQuery, query.utf8.count, buf.baseAddress, buf.count)
            }
        }
        return Array(out.prefix(min(total, capacity)))
    }

    /// Every entry's display data (hostname, username, kind, timestamp) in
    /// one round trip. `open` and `unlock` decrypt the hostnames and
    /// usernames before they return, so this call copies one struct per
    /// entry. A row needs no fetch of its own and no loading state.
    func entries() -> [Entry] {
        guard let handle else { return [] }
        let count = keywise_count(handle)
        guard count > 0 else { return [] }
        var raw = [keywise_entry](repeating: keywise_entry(), count: count)
        let written = raw.withUnsafeMutableBufferPointer { buf in
            keywise_entries(handle, buf.baseAddress, buf.count)
        }
        return (0..<min(written, count)).map { decodeEntry(raw[$0], id: $0) }
    }

    /// The caller must call `Secret.forget()` on the result. That wipes the
    /// C buffer and frees it through this actor.
    func reveal(at index: UInt32) -> Result<Secret, KeywiseError> {
        guard let handle else { return .failure(.noProfile) }
        var buf: UnsafeMutablePointer<CChar>?
        var len: Int = 0
        let status = keywise_reveal(handle, index, &buf, &len)
        guard status == KEYWISE_OK, let buf else { return .failure(KeywiseError(status)) }
        let value = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(buf).assumingMemoryBound(to: UInt8.self), count: len), as: UTF8.self)
        return .success(Secret(store: self, buf: buf, len: len, value: value))
    }

    fileprivate func freeSecret(buf: UnsafeMutablePointer<CChar>, len: Int) {
        guard let handle else { return }
        keywise_secret_free(handle, buf, len)
    }
}

/// A revealed password. It holds the C buffer alive until `forget()` runs,
/// and `forget()` is what wipes the bytes. Releasing the pointer any other
/// way leaves the password in memory.
///
/// `@unchecked Sendable` holds because the pointer only ever crosses into
/// `store`, and that actor serializes the access.
struct Secret: @unchecked Sendable {
    let value: String
    private let store: KeywiseStore
    private let buf: UnsafeMutablePointer<CChar>
    private let len: Int

    init(store: KeywiseStore, buf: UnsafeMutablePointer<CChar>, len: Int, value: String) {
        self.store = store
        self.buf = buf
        self.len = len
        self.value = value
    }

    func forget() async {
        await store.freeSecret(buf: buf, len: len)
    }
}

private func decodeEntry(_ raw: keywise_entry, id: Int) -> Entry {
    let hostname = raw.hostname.map { ptr in
        String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: raw.hostname_len), as: UTF8.self)
    } ?? ""
    let username = raw.username.map { ptr in
        String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: raw.username_len), as: UTF8.self)
    } ?? ""
    let flags = UInt32(raw.flags)
    return Entry(
        id: id,
        hostname: hostname,
        username: username,
        timePasswordChanged: raw.time_password_changed,
        isAccountCredential: flags & UInt32(KEYWISE_FLAG_ACCOUNT_CREDENTIAL) != 0,
        isExtension: flags & UInt32(KEYWISE_FLAG_EXTENSION) != 0
    )
}

func listProfiles() -> [Profile] {
    let count = keywise_profile_count()
    guard count > 0 else { return [] }
    var result: [Profile] = []
    for i in 0..<UInt32(count) {
        var needed: Int = 0
        guard keywise_profile_at(i, nil, 0, &needed) == KEYWISE_OK, needed > 0 else { continue }
        var buf = [CChar](repeating: 0, count: needed + 1)
        let status = buf.withUnsafeMutableBufferPointer { bufPtr -> keywise_status in
            bufPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: bufPtr.count) { u8 in
                keywise_profile_at(i, UnsafeMutableRawPointer(u8).assumingMemoryBound(to: CChar.self), needed, &needed)
            }
        }
        guard status == KEYWISE_OK else { continue }
        let path = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        result.append(Profile(id: Int(i), path: path))
    }
    return result
}
