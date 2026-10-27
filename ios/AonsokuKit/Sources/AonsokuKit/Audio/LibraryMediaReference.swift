import Foundation

/// An account-scoped library identity, never a transport/proxy address. The
/// existing aonsoku-media wire format is shared with queue/coordination clients.
struct LibraryMediaReference: Equatable, Sendable {
    let songID: String
    let options: [String: String]
    private static let streamOptions: Set<String> = ["maxBitRate", "format", "timeOffset", "size"]

    init(songID: String, options: [String: String] = [:]) {
        self.songID = songID
        self.options = options.filter { Self.streamOptions.contains($0.key) }
    }

    /// Migrates both logical references and old authenticated Subsonic URLs.
    /// External audio URLs are deliberately left outside this identity format.
    init?(streamURL: String, fallbackSongID: String) {
        guard let components = URLComponents(string: streamURL) else { return nil }
        let isReference = components.scheme?.lowercased() == "aonsoku-media"
            && components.host?.lowercased() == "stream"
            && (components.path.isEmpty || components.path == "/")
        let isLegacyStream = ["http", "https"].contains(components.scheme?.lowercased() ?? "")
            && (components.path.hasSuffix("/rest/stream")
                || components.path.hasSuffix("/rest/stream.view"))
        guard isReference || isLegacyStream else { return nil }
        let values = Dictionary(
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { _, last in last }
        )
        // A matching path alone can also be an arbitrary external stream.
        // Aonsoku's old authenticated URLs always carry a Subsonic username.
        guard isReference || values["u"] != nil else { return nil }
        let songID = values["id"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (isReference ? fallbackSongID : "")
        guard !songID.isEmpty else { return nil }
        self.init(songID: songID, options: values)
    }

    var urlString: String {
        var components = URLComponents()
        components.scheme = "aonsoku-media"
        components.host = "stream"
        components.queryItems = [URLQueryItem(name: "id", value: songID)]
            + options.keys.sorted().map { URLQueryItem(name: $0, value: options[$0]) }
        // URLSearchParams on other runtimes interprets a literal + as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        // Fixed scheme/host and queryItems always form a valid encoded URL.
        return components.string!
    }

    static func canonicalStreamURL(_ url: String, songID: String) -> String {
        Self(streamURL: url, fallbackSongID: songID)?.urlString ?? url
    }
}
