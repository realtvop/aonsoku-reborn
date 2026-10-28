import Foundation

/// Diagnostics must never interpolate an NSError description/userInfo or an
/// authenticated URL: any of those can contain a password, token or auth key.
enum NetworkDiagnostics {
    private static let endpoints: Set<String> = [
        "ping", "stream", "download", "hls", "scrobble", "star", "unstar",
        "getAlbum", "getAlbumList", "getAlbumList2", "getArtist", "getArtistInfo", "getArtistInfo2",
        "getArtists", "getGenres", "getInternetRadioStations", "getLyrics", "getLyricsBySongId",
        "getPlaylist", "getPlaylists", "getRandomSongs", "getScanStatus", "getSong", "getSongsByGenre",
        "getTopSongs", "getUser", "getStarred", "getStarred2", "getCoverArt", "getAvatar",
        "getNowPlaying", "getMusicFolders", "getIndexes", "getMusicDirectory", "getOpenSubsonicExtensions",
        "search", "search2", "search3", "startScan", "createPlaylist", "updatePlaylist", "deletePlaylist",
        "createInternetRadioStation", "updateInternetRadioStation", "deleteInternetRadioStation"
    ]

    static func endpoint(_ url: URL) -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.path.contains("/rest/"),
              endpoints.contains(url.deletingPathExtension().lastPathComponent) else { return "other" }
        return url.lastPathComponent
    }

    static func target(_ url: URL?) -> String {
        guard let url else { return "target=missing" }
        return "scheme=\(url.scheme ?? "none") host=\(url.host ?? "none") port=\(url.port.map(String.init) ?? "default") endpoint=\(endpoint(url))"
    }

    static func failure(_ error: Error, taskCancelled: Bool? = nil) -> String {
        let failure = error as NSError
        var result = "reason=\(reason(error)) domain=\(failure.domain) code=\(failure.code) taskCancelled=\(taskCancelled.map(String.init) ?? "unknown")"
        let failingURL = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (failure.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if let failingURL { result += " failingTarget={\(target(failingURL))}" }
        var underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        for _ in 0..<3 {
            guard let current = underlying else { break }
            result += " underlying=\(current.domain):\(current.code)"
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private static func reason(_ error: Error) -> String {
        if error is CancellationError { return "taskCancelled" }
        if let error = error as? URLError {
            switch error.code {
            case .badURL: return "badURL"
            case .unsupportedURL: return "unsupportedURL"
            case .cancelled: return "urlSessionCancelled"
            case .timedOut: return "timedOut"
            default: return "urlError"
            }
        }
        if let error = error as? TailscaleReadinessError {
            switch error {
            case .loginRequired: return "tailscaleLoginRequired"
            case .approvalRequired: return "tailscaleApprovalRequired"
            case .connectionTimedOut: return "tailscaleReadinessTimedOut"
            case .subnetRoutesDisabled: return "subnetRoutesDisabled"
            case .missingSubnetRoute: return "missingSubnetRoute"
            case .peerUnavailable: return "peerUnavailable"
            case .proxyUnavailable: return "proxyUnavailable"
            }
        }
        if let error = error as? SubsonicAPIError {
            switch error {
            case .cancelled: return "apiCancelled"
            case .http(let status): return "http\(status)"
            case .authenticationFailed: return "authenticationFailed"
            case .notAuthorized: return "notAuthorized"
            default: return "subsonicAPIError"
            }
        }
        if let error = error as? SubsonicHTTPError {
            switch error {
            case .httpError(let status, _): return "http\(status)"
            case .authFailed: return "authenticationFailed"
            case .parseError: return "invalidSubsonicResponse"
            case .protocolIncompatible: return "protocolIncompatible"
            case .networkUnreachable: return "subsonicTransportError"
            case .serverError: return "subsonicServerError"
            }
        }
        return "error"
    }
}
