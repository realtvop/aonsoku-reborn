package github.realtvop.aonsoku.plugins.bridge

import java.security.MessageDigest

object SubsonicAuthBuilder {
    const val SALT = "40n50kuPl4y3r"
    const val CLIENT_NAME = "Aonsoku"
    const val DEFAULT_VERSION = "1.16.0"

    fun generateToken(password: String): String = md5(password + SALT)

    fun encodePassword(password: String): String =
        "enc:" + password.toByteArray(Charsets.UTF_8).joinToString("") {
            (it.toInt() and 0xff).toString(16).padStart(2, '0')
        }

    fun hashPasswordForStorage(rawPassword: String, authType: String): String =
        if (authType == "token") {
            generateToken(rawPassword)
        } else {
            encodePassword(rawPassword)
        }

    fun buildQueryParams(
        username: String,
        password: String,
        authType: String,
        protocolVersion: String? = null,
    ): Map<String, String> {
        val params = linkedMapOf(
            "u" to username,
            "v" to (protocolVersion ?: DEFAULT_VERSION),
            "c" to CLIENT_NAME,
            "f" to "json",
        )

        if (authType == "token") {
            params["t"] = password
            params["s"] = SALT
        } else {
            params["p"] = password
        }

        return params
    }

    fun parseVersionNumber(version: String): Int {
        val parts = version.split(".")
        if (parts.size < 2) return 0

        val major = parts.getOrNull(0)?.toIntOrNull() ?: 0
        val minor = parts.getOrNull(1)?.toIntOrNull() ?: 0
        val patch = parts.getOrNull(2)?.toIntOrNull() ?: 0
        return major * 10000 + minor * 100 + patch
    }

    private fun md5(input: String): String {
        val digest = MessageDigest.getInstance("MD5")
            .digest(input.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") {
            (it.toInt() and 0xff).toString(16).padStart(2, '0')
        }
    }
}
