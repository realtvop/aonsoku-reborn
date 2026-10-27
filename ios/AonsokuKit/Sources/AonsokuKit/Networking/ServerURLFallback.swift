import Foundation

extension Notification.Name {
    static let serverURLDidChange = Notification.Name("Aonsoku.serverURLDidChange")
}

/// Routes only signed requests within the configured Subsonic base paths.
/// No host/query URLs are logged: their query strings contain credentials.
struct ServerURLFallback: Sendable {
    struct Configuration: Sendable {
        let credentials: ServerCredentials
        let primaryURL: String

        var addresses: [String] {
            [primaryURL, credentials.fallbackUrl].compactMap { $0 }
        }
    }

    let configuration: @Sendable () -> Configuration?
    let activate: @Sendable (String, Configuration) async throws -> Void

    static let live = Self(
        configuration: {
            guard let credentials = KeychainManager.retrieve(),
                  let account = PreferencesService.shared.getJSON(
                    SessionStore.accountStorageKey, as: ServerAccount.self
                  ),
                  account.username == credentials.username,
                  [account.primaryUrl, account.fallbackUrl].contains(credentials.serverUrl)
            else { return nil }
            return Configuration(credentials: credentials, primaryURL: account.primaryUrl)
        },
        activate: { address, original in
            try await MainActor.run {
                // A late response must never restore a signed-out/replaced account.
                guard KeychainManager.retrieve() == original.credentials,
                      var account = PreferencesService.shared.getJSON(
                        SessionStore.accountStorageKey, as: ServerAccount.self
                      ),
                      account.primaryUrl == original.primaryURL,
                      account.fallbackUrl == original.credentials.fallbackUrl,
                      account.username == original.credentials.username else { return }
                let old = original.credentials
                try KeychainManager.store(ServerCredentials(
                    serverUrl: address, username: old.username, password: old.password,
                    authType: old.authType, protocolVersion: old.protocolVersion,
                    serverType: old.serverType, fallbackUrl: old.fallbackUrl
                ))
                account.activeUrl = address
                try PreferencesService.shared.setJSON(account, for: SessionStore.accountStorageKey)
                NativeLogger.shared.info("Switched active server address", source: "Network")
                NotificationCenter.default.post(name: .serverURLDidChange, object: nil)
            }
        }
    )

    func data(
        for request: URLRequest,
        transport: HTTPClient.Transport
    ) async throws -> (Data, URLResponse) {
        guard let config = configuration(),
              let url = request.url,
              isSigned(url, with: config.credentials),
              let source = config.addresses.first(where: { replacing(url, from: $0, to: $0) != nil }),
              let alternate = config.addresses.first(where: { $0 != config.credentials.serverUrl }),
              let activeURL = replacing(url, from: source, to: config.credentials.serverUrl),
              let alternateURL = replacing(url, from: source, to: alternate) else {
            return try await transport(request)
        }

        var active = request
        active.url = activeURL
        let canReplay = isRead(request)
        // A black-holed primary should not hold every Home section for 30s.
        if canReplay { active.timeoutInterval = min(active.timeoutInterval, 10) }
        let result: (Data, URLResponse)
        do {
            try Task.checkCancellation()
            result = try await transport(active)
        } catch {
            try Task.checkCancellation()
            if let readiness = error as? TailscaleReadinessError {
                // No HTTP request was dispatched. Only connection readiness
                // failures may try the separately configured backup address.
                switch readiness {
                case .connectionTimedOut, .missingSubnetRoute, .peerUnavailable, .proxyUnavailable: break
                default: throw error
                }
            } else {
                guard let error = error as? URLError,
                      shouldRetry(error.code, canReplay: canReplay) else { throw error }
            }
            return try await retry(request, at: alternateURL, address: alternate, config: config, transport: transport)
        }
        try Task.checkCancellation()
        if canReplay, let response = result.1 as? HTTPURLResponse,
           [502, 503, 504].contains(response.statusCode) {
            return try await retry(request, at: alternateURL, address: alternate, config: config, transport: transport)
        }
        return result
    }

    private func retry(
        _ request: URLRequest, at url: URL, address: String,
        config: Configuration, transport: HTTPClient.Transport
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        // Do not send an old account's signed URL after logout/address edits.
        guard let current = configuration(), current.primaryURL == config.primaryURL,
              current.credentials.username == config.credentials.username,
              current.credentials.password == config.credentials.password,
              current.credentials.authType == config.credentials.authType,
              current.credentials.fallbackUrl == config.credentials.fallbackUrl else {
            throw CancellationError()
        }
        var retry = request
        retry.url = url
        NativeLogger.shared.info("Active server unavailable; trying alternate address", source: "Network")
        let result = try await transport(retry)
        try Task.checkCancellation()
        if let response = result.1 as? HTTPURLResponse, (200...299).contains(response.statusCode) {
            // An HTTP 200 Subsonic authentication/error payload is not success.
            let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
            let payload = json?["subsonic-response"] as? [String: Any]
            if payload?["status"] as? String == "ok"
                || response.mimeType?.hasPrefix("image/") == true {
                try await activate(address, config)
            }
        }
        return result
    }

    private func shouldRetry(_ code: URLError.Code, canReplay: Bool) -> Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: true
        case .timedOut, .networkConnectionLost, .notConnectedToInternet: canReplay
        default: false
        }
    }

    private func isRead(_ request: URLRequest) -> Bool {
        guard ["GET", "HEAD"].contains(request.httpMethod ?? "GET"),
              let endpoint = request.url?.deletingPathExtension().lastPathComponent.lowercased() else { return false }
        // Subsonic also uses GET for writes; an HTTP method alone isn't enough.
        return endpoint.hasPrefix("get") || endpoint.hasPrefix("search")
            || ["ping", "stream", "download", "hls"].contains(endpoint)
    }

    private func isSigned(_ url: URL, with credentials: ServerCredentials) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard value("u") == credentials.username else { return false }
        return credentials.authType == "token"
            ? value("t") == credentials.password && value("s") == SubsonicAuthBuilder.salt
            : value("p") == credentials.password
    }

    private func replacing(_ url: URL, from source: String, to destination: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let from = URLComponents(string: source),
              let to = URLComponents(string: destination),
              components.scheme == from.scheme, components.host == from.host,
              components.port == from.port else { return nil }
        let prefix = from.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = prefix.isEmpty ? "" : "/" + prefix
        guard components.percentEncodedPath.hasPrefix(basePath + "/rest/") else { return nil }
        let suffix = String(components.percentEncodedPath.dropFirst(basePath.count))
        components.scheme = to.scheme
        components.host = to.host
        components.port = to.port
        let path = to.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = (path.isEmpty ? "" : "/" + path) + suffix
        return components.url
    }
}
