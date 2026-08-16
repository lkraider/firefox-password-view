import CFfpw
import Foundation

enum FFPWError: Error, Sendable, Equatable {
    case noProfile
    case openFailed
    case needsPassword
    case wrongPassword
    case legacy3DES
    case outOfMemory
    case io
    case range
    case unknown(UInt32)

    init(_ status: ffpw_status) {
        switch status {
        case FFPW_ERR_NO_PROFILE: self = .noProfile
        case FFPW_ERR_OPEN: self = .openFailed
        case FFPW_ERR_NEEDS_PASSWORD: self = .needsPassword
        case FFPW_ERR_WRONG_PASSWORD: self = .wrongPassword
        case FFPW_ERR_LEGACY_3DES: self = .legacy3DES
        case FFPW_ERR_OOM: self = .outOfMemory
        case FFPW_ERR_IO: self = .io
        case FFPW_ERR_RANGE: self = .range
        default: self = .unknown(status.rawValue)
        }
    }
}

extension FFPWError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noProfile: "No Firefox profile was found at that path."
        case .openFailed: "Could not open key4.db for this profile."
        case .needsPassword: "This profile needs its Primary Password."
        case .wrongPassword: "Wrong Primary Password. Try again."
        case .legacy3DES: "This entry is still 3DES, which this app cannot decrypt."
        case .outOfMemory: "Out of memory."
        case .io: "Could not read this profile's files."
        case .range: "That entry does not exist."
        case .unknown(let code): "Unexpected error (\(code))."
        }
    }
}

/// Wraps one ffpw_store. Every method here is actor-isolated, so Swift
/// itself serializes every call onto the store, matching the header's rule:
/// one ffpw_store belongs to one thread at a time. Loading and decrypting
/// happen here, off whichever thread the caller (the main actor) runs on.
actor FFPWStore {
    private var handle: OpaquePointer?

    /// Opens `profilePath`. Since most profiles carry no Primary Password,
    /// this also tries an empty one; `needsPassword` on the result tells the
    /// caller whether to show a prompt before anything else works.
    func open(profilePath: String) -> (needsPassword: Bool, error: FFPWError?) {
        var newHandle: OpaquePointer?
        let status = profilePath.withCString { cPath in
            ffpw_open(cPath, &newHandle)
        }
        handle = newHandle
        if status == FFPW_OK {
            return (false, nil)
        }
        if status == FFPW_ERR_NEEDS_PASSWORD {
            return (true, nil)
        }
        return (false, FFPWError(status))
    }

    func unlock(password: String) -> FFPWError? {
        guard let handle else { return .noProfile }
        let status = password.withCString { cPassword in
            ffpw_unlock(handle, cPassword, password.utf8.count)
        }
        return status == FFPW_OK ? nil : FFPWError(status)
    }

    func close() {
        if let handle {
            ffpw_close(handle)
        }
        handle = nil
    }

    func count() -> Int {
        guard let handle else { return 0 }
        return ffpw_count(handle)
    }

    /// Every matching index, not just a page: the list is virtualized by
    /// SwiftUI, not by this call. Sized to `count()` up front rather than
    /// calling `ffpw_search` once just for the total and again to fill it,
    /// since no query can match more entries than the store holds.
    func search(_ query: String) -> [UInt32] {
        guard let handle else { return [] }
        let capacity = ffpw_count(handle)
        guard capacity > 0 else { return [] }
        var out = [UInt32](repeating: 0, count: capacity)
        let total = query.withCString { cQuery in
            out.withUnsafeMutableBufferPointer { buf in
                ffpw_search(handle, cQuery, query.utf8.count, buf.baseAddress, buf.count)
            }
        }
        return Array(out.prefix(min(total, capacity)))
    }

    /// Every entry's display data (hostname, username, kind, timestamp) in
    /// one round trip. Hostnames and usernames are already decrypted by the
    /// time `open`/`unlock` returns, so this is a struct copy per entry, not
    /// real work worth an async fetch or a loading state per row.
    func entries() -> [Entry] {
        guard let handle else { return [] }
        let count = ffpw_count(handle)
        guard count > 0 else { return [] }
        var raw = [ffpw_entry](repeating: ffpw_entry(), count: count)
        let written = raw.withUnsafeMutableBufferPointer { buf in
            ffpw_entries(handle, buf.baseAddress, buf.count)
        }
        return (0..<min(written, count)).map { decodeEntry(raw[$0], id: $0) }
    }

    /// The caller must call `Secret.forget()` once done with the result,
    /// which wipes and frees it through this same actor.
    func reveal(at index: UInt32) -> Result<Secret, FFPWError> {
        guard let handle else { return .failure(.noProfile) }
        var buf: UnsafeMutablePointer<CChar>?
        var len: Int = 0
        let status = ffpw_reveal(handle, index, &buf, &len)
        guard status == FFPW_OK, let buf else { return .failure(FFPWError(status)) }
        let value = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(buf).assumingMemoryBound(to: UInt8.self), count: len), as: UTF8.self)
        return .success(Secret(store: self, buf: buf, len: len, value: value))
    }

    fileprivate func freeSecret(buf: UnsafeMutablePointer<CChar>, len: Int) {
        guard let handle else { return }
        ffpw_secret_free(handle, buf, len)
    }
}

/// A revealed password. Holds the raw buffer alive until `forget()` runs, so
/// the store can wipe it rather than leaving it to Swift's own deallocation.
/// `@unchecked Sendable`: the raw pointer only ever crosses into `store`,
/// which is itself an actor and re-serializes access to it.
struct Secret: @unchecked Sendable {
    let value: String
    private let store: FFPWStore
    private let buf: UnsafeMutablePointer<CChar>
    private let len: Int

    init(store: FFPWStore, buf: UnsafeMutablePointer<CChar>, len: Int, value: String) {
        self.store = store
        self.buf = buf
        self.len = len
        self.value = value
    }

    func forget() async {
        await store.freeSecret(buf: buf, len: len)
    }
}

private func decodeEntry(_ raw: ffpw_entry, id: Int) -> Entry {
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
        isAccountCredential: flags & UInt32(FFPW_FLAG_ACCOUNT_CREDENTIAL) != 0,
        isExtension: flags & UInt32(FFPW_FLAG_EXTENSION) != 0
    )
}

func listProfiles() -> [Profile] {
    let count = ffpw_profile_count()
    guard count > 0 else { return [] }
    var result: [Profile] = []
    for i in 0..<UInt32(count) {
        var needed: Int = 0
        guard ffpw_profile_at(i, nil, 0, &needed) == FFPW_OK, needed > 0 else { continue }
        var buf = [CChar](repeating: 0, count: needed + 1)
        let status = buf.withUnsafeMutableBufferPointer { bufPtr -> ffpw_status in
            bufPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: bufPtr.count) { u8 in
                ffpw_profile_at(i, UnsafeMutableRawPointer(u8).assumingMemoryBound(to: CChar.self), needed, &needed)
            }
        }
        guard status == FFPW_OK else { continue }
        let path = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        result.append(Profile(id: Int(i), path: path))
    }
    return result
}
