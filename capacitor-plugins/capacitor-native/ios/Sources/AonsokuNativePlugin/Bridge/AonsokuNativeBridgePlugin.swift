import Foundation
import Capacitor

@objc(AonsokuNativeBridgePlugin)
public class AonsokuNativeBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AonsokuNativeBridgePlugin"
    public let jsName = "AonsokuNativeBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "storeCredentials", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCredentials", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCredentials", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hasCredentials", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "login", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ping", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "queryServerInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "request", returnType: CAPPluginReturnPromise),
    ]

    private let httpClient = SubsonicHTTPClient()

    // MARK: - Credential Management

    @objc func storeCredentials(_ call: CAPPluginCall) {
        guard let serverUrl = call.getString("serverUrl"),
              let username = call.getString("username"),
              let authType = call.getString("authType"),
              let protocolVersion = call.getString("protocolVersion"),
              let serverType = call.getString("serverType") else {
            call.reject("Missing required credential fields")
            return
        }

        let existingCredentials = KeychainManager.retrieve()
        let password: String
        if let callPassword = call.getString("password"), !callPassword.isEmpty {
            password = callPassword
        } else if let existingPassword = existingCredentials?.password {
            password = existingPassword
        } else {
            call.reject("Missing password and no existing credentials found")
            return
        }

        let credentials = ServerCredentials(
            serverUrl: serverUrl,
            username: username,
            password: password,
            authType: authType,
            protocolVersion: protocolVersion,
            serverType: serverType,
            fallbackUrl: call.getString("fallbackUrl")
        )

        do {
            try KeychainManager.store(credentials)
            call.resolve()
        } catch {
            call.reject("Failed to store credentials: \(error.localizedDescription)")
        }
    }

    @objc func getCredentials(_ call: CAPPluginCall) {
        guard let credentials = KeychainManager.retrieve() else {
            call.resolve([:])
            return
        }

        var result: [String: Any] = [
            "serverUrl": credentials.serverUrl,
            "username": credentials.username,
            "password": credentials.password,
            "authType": credentials.authType,
            "protocolVersion": credentials.protocolVersion,
            "serverType": credentials.serverType,
        ]

        if let fallbackUrl = credentials.fallbackUrl {
            result["fallbackUrl"] = fallbackUrl
        }

        call.resolve(result)
    }

    @objc func clearCredentials(_ call: CAPPluginCall) {
        KeychainManager.delete()
        call.resolve()
    }

    @objc func hasCredentials(_ call: CAPPluginCall) {
        call.resolve(["stored": KeychainManager.exists()])
    }

    // MARK: - Login & Server Validation

    @objc func login(_ call: CAPPluginCall) {
        guard let url = call.getString("url"),
              let username = call.getString("username"),
              let rawPassword = call.getString("password") else {
            call.reject("Missing required login fields")
            return
        }

        let fallbackUrl = call.getString("fallbackUrl")

        Task {
            let result = await performLogin(
                primaryUrl: url,
                fallbackUrl: fallbackUrl,
                username: username,
                rawPassword: rawPassword
            )
            DispatchQueue.main.async {
                call.resolve(result)
            }
        }
    }

    @objc func ping(_ call: CAPPluginCall) {
        guard let url = call.getString("url"),
              let username = call.getString("username"),
              let password = call.getString("password"),
              let authType = call.getString("authType") else {
            call.reject("Missing required ping fields")
            return
        }

        Task {
            let result = await httpClient.ping(
                baseUrl: url,
                username: username,
                password: password,
                authType: authType
            )
            DispatchQueue.main.async {
                var response: [String: Any] = ["reachable": result.reachable]
                if let error = result.error {
                    response["error"] = error
                }
                call.resolve(response)
            }
        }
    }

    @objc func queryServerInfo(_ call: CAPPluginCall) {
        guard let url = call.getString("url") else {
            call.reject("Missing url parameter")
            return
        }

        Task {
            let info = await httpClient.queryServerInfo(baseUrl: url)
            let versionNumber = parseVersionNumber(info.protocolVersion)
            DispatchQueue.main.async {
                call.resolve([
                    "protocolVersion": info.protocolVersion,
                    "protocolVersionNumber": versionNumber,
                    "serverType": info.serverType,
                ])
            }
        }
    }

    // MARK: - API Request Proxy

    @objc func request(_ call: CAPPluginCall) {
        guard let path = call.getString("path") else {
            call.reject("Missing path parameter")
            return
        }

        guard let credentials = KeychainManager.retrieve() else {
            call.reject("No stored credentials")
            return
        }

        let method = call.getString("method") ?? "GET"
        var extraQuery: [String: String] = [:]

        if let query = call.getObject("query") {
            for (key, value) in query {
                if let strVal = value as? String {
                    extraQuery[key] = strVal
                } else if let numVal = value as? NSNumber {
                    extraQuery[key] = numVal.stringValue
                }
            }
        }

        Task {
            do {
                let response = try await httpClient.request(
                    baseUrl: credentials.serverUrl,
                    path: path,
                    credentials: credentials,
                    extraQuery: extraQuery,
                    method: method
                )
                DispatchQueue.main.async {
                    call.resolve([
                        "count": response.count,
                        "data": response.data,
                    ])
                }
            } catch let error as SubsonicHTTPError {
                DispatchQueue.main.async {
                    call.reject(self.errorMessage(error))
                }
            } catch {
                DispatchQueue.main.async {
                    call.reject(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func performLogin(
        primaryUrl: String,
        fallbackUrl: String?,
        username: String,
        rawPassword: String
    ) async -> [String: Any] {
        for authType in ["token", "password"] {
            let hashedPassword = SubsonicAuthBuilder.hashPasswordForStorage(
                rawPassword: rawPassword,
                authType: authType
            )

            let result = await httpClient.ping(
                baseUrl: primaryUrl,
                username: username,
                password: hashedPassword,
                authType: authType
            )

            if result.reachable {
                let serverInfo = await httpClient.queryServerInfo(baseUrl: primaryUrl)

                let credentials = ServerCredentials(
                    serverUrl: primaryUrl,
                    username: username,
                    password: hashedPassword,
                    authType: authType,
                    protocolVersion: serverInfo.protocolVersion,
                    serverType: serverInfo.serverType,
                    fallbackUrl: fallbackUrl
                )
                do {
                    try KeychainManager.store(credentials)
                } catch {
                    return [
                        "success": false,
                        "error": "keychain_store_failed: \(error.localizedDescription)",
                    ]
                }

                return [
                    "success": true,
                    "authType": authType,
                    "protocolVersion": serverInfo.protocolVersion,
                    "serverType": serverInfo.serverType,
                    "activeUrl": primaryUrl,
                    "activeServerType": "primary",
                    "password": hashedPassword,
                ]
            }
        }

        if let fallbackUrl = fallbackUrl, !fallbackUrl.isEmpty {
            for authType in ["token", "password"] {
                let hashedPassword = SubsonicAuthBuilder.hashPasswordForStorage(
                    rawPassword: rawPassword,
                    authType: authType
                )

                let result = await httpClient.ping(
                    baseUrl: fallbackUrl,
                    username: username,
                    password: hashedPassword,
                    authType: authType
                )

                if result.reachable {
                    let serverInfo = await httpClient.queryServerInfo(baseUrl: fallbackUrl)

                    let credentials = ServerCredentials(
                        serverUrl: fallbackUrl,
                        username: username,
                        password: hashedPassword,
                        authType: authType,
                        protocolVersion: serverInfo.protocolVersion,
                        serverType: serverInfo.serverType,
                        fallbackUrl: nil
                    )
                    do {
                        try KeychainManager.store(credentials)
                    } catch {
                        return [
                            "success": false,
                            "error": "keychain_store_failed: \(error.localizedDescription)",
                        ]
                    }

                    return [
                        "success": true,
                        "authType": authType,
                        "protocolVersion": serverInfo.protocolVersion,
                        "serverType": serverInfo.serverType,
                        "activeUrl": fallbackUrl,
                        "activeServerType": "fallback",
                        "password": hashedPassword,
                    ]
                }
            }
        }

        return [
            "success": false,
            "error": "auth_failed",
        ]
    }

    private func parseVersionNumber(_ version: String) -> Int {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return 0 }
        let major = Int(parts[0]) ?? 0
        let minor = Int(parts[1]) ?? 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return major * 10000 + minor * 100 + patch
    }

    private func errorMessage(_ error: SubsonicHTTPError) -> String {
        switch error {
        case .networkUnreachable(let msg):
            return "network_unreachable: \(msg)"
        case .httpError(let code, let msg):
            return "http_error: \(code) \(msg)"
        case .parseError(let msg):
            return "parse_error: \(msg)"
        case .serverError(let msg):
            return "server_error: \(msg)"
        case .authFailed(let msg):
            return "auth_failed: \(msg)"
        }
    }
}
