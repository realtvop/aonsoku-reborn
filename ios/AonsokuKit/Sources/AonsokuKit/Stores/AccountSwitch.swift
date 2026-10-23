import Foundation

/// Why signing in needs the user's decision before the library on this
/// device is used. Nothing is erased until the user confirms.
public enum AccountSwitchReason: Equatable, Sendable {
    /// The library belongs to another user. Signing in can only erase it.
    case differentAccount(previousServer: String, previousUsername: String)
    /// The library belongs to the same user name at another server address
    /// (a LAN address versus a domain, or a server that moved). The user
    /// decides whether to keep it.
    case differentServer(previousServer: String)
    /// A library exists but nobody recorded whose it is, for example data
    /// from the previous app. The user decides whether to keep it.
    case unknownOwner
}

/// A sign-in waiting for the user to keep or erase the library on this
/// device. `serverUrl` and `username` are the new account's stored primary
/// address and user name; `reason.previousServer` is the previous owner's.
public struct AccountSwitchRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let reason: AccountSwitchReason
    public let serverUrl: String
    public let username: String

    public init(
        id: UUID = UUID(),
        reason: AccountSwitchReason,
        serverUrl: String,
        username: String
    ) {
        self.id = id
        self.reason = reason
        self.serverUrl = serverUrl
        self.username = username
    }
}

public enum AccountSwitchError: Error, Equatable, Sendable {
    /// `keepLibraryData()` was called for a library that belongs to another
    /// user, which must never be adopted.
    case libraryBelongsToAnotherAccount
    /// The server address cannot change while a sign-in waits for the
    /// user's decision.
    case decisionPending
}

/// What signing in as an account does with the library already on the
/// device.
enum AccountSwitchDecision: Equatable, Sendable {
    /// Use the library as it is and record the account as its owner.
    case adopt
    /// Ask the user first; the library stays untouched until they decide.
    case confirm(AccountSwitchReason)
}

/// The account that owns the library on this device, as the primary server
/// address and user name it was recorded with. The synthesized `Equatable`
/// compares the stored strings exactly; `isSameAccount(as:)` and the
/// related methods compare what identifies the account.
struct LibraryAccountIdentity: Codable, Equatable, Sendable {
    var serverUrl: String
    var username: String

    init(account: ServerAccount) {
        serverUrl = account.primaryUrl
        username = account.username
    }

    init(serverUrl: String, username: String) {
        self.serverUrl = serverUrl
        self.username = username
    }

    /// The address without the parts that do not change which server
    /// answers: the scheme, the case of the host, a default port (80 for
    /// http, 443 for https), trailing slashes, the query and the fragment.
    /// The path keeps its case. Text that is not a URL with a host compares
    /// lowercased, without surrounding blanks and trailing slashes.
    var normalizedServer: String {
        let trimmed = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return Self.droppingTrailingSlashes(trimmed.lowercased())
        }
        var result = host
        if let port = components.port, port != Self.defaultPort(scheme: scheme) {
            result += ":\(port)"
        }
        return result + Self.droppingTrailingSlashes(components.percentEncodedPath)
    }

    /// The user name without surrounding blanks, in lowercase.
    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isSameServer(as other: Self) -> Bool {
        normalizedServer == other.normalizedServer
    }

    func isSameUsername(as other: Self) -> Bool {
        normalizedUsername == other.normalizedUsername
    }

    func isSameAccount(as other: Self) -> Bool {
        isSameServer(as: other) && isSameUsername(as: other)
    }

    private static func defaultPort(scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }

    private static func droppingTrailingSlashes(_ value: String) -> String {
        var value = value
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// The pending request as stored in preferences, so a relaunch during the
/// dialog asks again. The reason is a flat kind plus its previous owner
/// fields, independent of the Swift enum's layout.
struct PendingAccountSwitchRecord: Codable, Equatable {
    enum Kind: String, Codable {
        case differentAccount
        case differentServer
        case unknownOwner
    }

    var id: UUID
    var kind: Kind
    var previousServer: String?
    var previousUsername: String?
    var serverUrl: String
    var username: String

    init(_ request: AccountSwitchRequest) {
        id = request.id
        serverUrl = request.serverUrl
        username = request.username
        switch request.reason {
        case let .differentAccount(server, name):
            kind = .differentAccount
            previousServer = server
            previousUsername = name
        case let .differentServer(server):
            kind = .differentServer
            previousServer = server
            previousUsername = nil
        case .unknownOwner:
            kind = .unknownOwner
            previousServer = nil
            previousUsername = nil
        }
    }

    /// The request, or nil when the record lacks a field its kind needs.
    var request: AccountSwitchRequest? {
        let reason: AccountSwitchReason
        switch kind {
        case .differentAccount:
            guard let previousServer, let previousUsername else { return nil }
            reason = .differentAccount(
                previousServer: previousServer,
                previousUsername: previousUsername
            )
        case .differentServer:
            guard let previousServer else { return nil }
            reason = .differentServer(previousServer: previousServer)
        case .unknownOwner:
            reason = .unknownOwner
        }
        return AccountSwitchRequest(
            id: id,
            reason: reason,
            serverUrl: serverUrl,
            username: username
        )
    }

    var identity: LibraryAccountIdentity {
        LibraryAccountIdentity(serverUrl: serverUrl, username: username)
    }
}
