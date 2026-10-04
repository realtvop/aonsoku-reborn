import Foundation
import CommonCrypto

public struct SubsonicAuthBuilder {
    public static let salt = "40n50kuPl4y3r"
    public static let clientName = "Aonsoku"
    public static let defaultVersion = "1.16.0"

    public static func generateToken(password: String) -> String {
        let input = password + salt
        return md5(input)
    }

    public static func encodePassword(password: String) -> String {
        let hex = password.utf8.map { String(format: "%02x", $0) }.joined()
        return "enc:\(hex)"
    }

    public static func buildQueryParams(
        username: String,
        password: String,
        authType: String,
        protocolVersion: String?
    ) -> [String: String] {
        var params: [String: String] = [
            "u": username,
            "v": protocolVersion ?? defaultVersion,
            "c": clientName,
            "f": "json",
        ]

        if authType == "token" {
            params["t"] = password
            params["s"] = salt
        } else {
            params["p"] = password
        }

        return params
    }

    public static func hashPasswordForStorage(rawPassword: String, authType: String) -> String {
        if authType == "token" {
            return generateToken(password: rawPassword)
        } else {
            return encodePassword(password: rawPassword)
        }
    }

    public static func parseVersionNumber(_ version: String) -> Int {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return 0 }
        let major = Int(parts[0]) ?? 0
        let minor = Int(parts[1]) ?? 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return major * 10_000 + minor * 100 + patch
    }

    private static func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
