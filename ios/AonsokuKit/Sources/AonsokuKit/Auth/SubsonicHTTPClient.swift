import Foundation

public enum SubsonicHTTPError: Error {
    case networkUnreachable(String)
    case httpError(Int, String)
    case parseError(String)
    case protocolIncompatible(version: String?, message: String)
    case serverError(String)
    case authFailed(String)
}

public struct SubsonicResponse {
    public let data: [String: Any]
    public let count: Int
}

public final class SubsonicHTTPClient {
    private let client: HTTPClient

    public init(client: HTTPClient = NetworkService.shared.client(for: .subsonic)) {
        self.client = client
    }

    convenience init(session: URLSession) {
        self.init(client: HTTPClient(session: session))
    }

    public func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String] = [:],
        method: String = "GET"
    ) async throws -> SubsonicResponse {
        let url = try buildURL(
            baseUrl: baseUrl,
            path: path,
            credentials: credentials,
            extraQuery: extraQuery
        )

        var request = URLRequest(url: url)
        request.httpMethod = method

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await client.data(for: request)
        } catch {
            throw SubsonicHTTPError.networkUnreachable(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubsonicHTTPError.parseError("Invalid response type")
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw SubsonicHTTPError.httpError(
                httpResponse.statusCode,
                "HTTP \(httpResponse.statusCode)"
            )
        }

        let count = Int(httpResponse.value(forHTTPHeaderField: "x-total-count") ?? "0") ?? 0

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubsonicHTTPError.parseError("Failed to parse JSON response")
        }

        guard let subsonicResponse = json["subsonic-response"] as? [String: Any] else {
            throw SubsonicHTTPError.parseError("Missing subsonic-response payload")
        }

        if let status = subsonicResponse["status"] as? String, status == "failed" {
            let errorDict = subsonicResponse["error"] as? [String: Any]
            let message = errorDict?["message"] as? String ?? "Server returned a failed response"
            let code = errorDict?["code"] as? Int ?? 0

            if code == 40 || code == 41 {
                throw SubsonicHTTPError.authFailed(message)
            }
            if code == 30 {
                throw SubsonicHTTPError.protocolIncompatible(
                    version: subsonicResponse["version"] as? String,
                    message: message
                )
            }
            throw SubsonicHTTPError.serverError(message)
        }

        return SubsonicResponse(data: subsonicResponse, count: count)
    }

    public func ping(
        baseUrl: String,
        username: String,
        password: String,
        authType: String,
        protocolVersion: String? = nil
    ) async -> (reachable: Bool, error: String?) {
        let credentials = ServerCredentials(
            serverUrl: baseUrl,
            username: username,
            password: password,
            authType: authType,
            protocolVersion: protocolVersion ?? SubsonicAuthBuilder.defaultVersion,
            serverType: "subsonic",
            fallbackUrl: nil
        )

        do {
            _ = try await queryServerInfo(
                baseUrl: baseUrl,
                credentials: credentials
            )
            return (true, nil)
        } catch SubsonicHTTPError.authFailed {
            return (false, "auth_failed")
        } catch SubsonicHTTPError.networkUnreachable {
            return (false, "network_unreachable")
        } catch {
            return (false, "server_error")
        }
    }

    public func queryServerInfo(baseUrl: String) async -> (protocolVersion: String, serverType: String) {
        let dummyCredentials = ServerCredentials(
            serverUrl: baseUrl,
            username: "probe",
            password: SubsonicAuthBuilder.generateToken(password: "probe"),
            authType: "token",
            protocolVersion: SubsonicAuthBuilder.defaultVersion,
            serverType: "subsonic",
            fallbackUrl: nil
        )

        do {
            return try await queryServerInfo(
                baseUrl: baseUrl,
                credentials: dummyCredentials
            )
        } catch {
            return (SubsonicAuthBuilder.defaultVersion, "subsonic")
        }
    }

    func queryServerInfo(
        baseUrl: String,
        credentials: ServerCredentials
    ) async throws -> (protocolVersion: String, serverType: String) {
        let response: SubsonicResponse
        do {
            response = try await request(
                baseUrl: baseUrl,
                path: "ping.view",
                credentials: credentials
            )
        } catch SubsonicHTTPError.protocolIncompatible(let version, let message) {
            guard let version = validProtocolVersion(version),
                  version != credentials.protocolVersion else {
                throw SubsonicHTTPError.protocolIncompatible(
                    version: version,
                    message: message
                )
            }
            let compatibleCredentials = ServerCredentials(
                serverUrl: credentials.serverUrl,
                username: credentials.username,
                password: credentials.password,
                authType: credentials.authType,
                protocolVersion: version,
                serverType: credentials.serverType,
                fallbackUrl: credentials.fallbackUrl
            )
            response = try await request(
                baseUrl: baseUrl,
                path: "ping.view",
                credentials: compatibleCredentials
            )
        }
        guard let protocolVersion = response.data["version"] as? String,
              !protocolVersion.isEmpty else {
            throw SubsonicHTTPError.parseError("Missing protocol version")
        }
        return (
            protocolVersion,
            response.data["type"] as? String ?? "subsonic"
        )
    }

    private func validProtocolVersion(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        let components = version.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return version
    }

    func buildURL(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String]
    ) throws -> URL {
        let authParams = SubsonicAuthBuilder.buildQueryParams(
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: credentials.protocolVersion
        )

        let cleanBaseUrl = baseUrl.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let baseString = "\(cleanBaseUrl)/rest/\(cleanPath)"

        guard var components = URLComponents(string: baseString) else {
            throw SubsonicHTTPError.parseError("Invalid URL: \(baseString)")
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: authParams.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })
        for (key, value) in extraQuery {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SubsonicHTTPError.parseError("Failed to construct URL")
        }

        return url
    }
}
