import Foundation

public enum SubsonicHTTPError: Error {
    case networkUnreachable(String)
    case httpError(Int, String)
    case parseError(String)
    case serverError(String)
    case authFailed(String)
}

public struct SubsonicResponse {
    public let data: [String: Any]
    public let count: Int
}

public final class SubsonicHTTPClient {
    private let session: URLSession

    public convenience init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.init(session: URLSession(configuration: config))
    }

    init(session: URLSession) {
        self.session = session
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
            (data, response) = try await session.data(for: request)
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
            _ = try await request(
                baseUrl: baseUrl,
                path: "ping.view",
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
            let response = try await request(
                baseUrl: baseUrl,
                path: "ping.view",
                credentials: dummyCredentials
            )
            let version = response.data["version"] as? String ?? SubsonicAuthBuilder.defaultVersion
            let serverType = response.data["type"] as? String ?? "subsonic"
            return (version, serverType)
        } catch SubsonicHTTPError.authFailed {
            return (SubsonicAuthBuilder.defaultVersion, "subsonic")
        } catch {
            return (SubsonicAuthBuilder.defaultVersion, "subsonic")
        }
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
