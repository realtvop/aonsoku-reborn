package github.realtvop.aonsoku.plugins.bridge

import org.json.JSONObject

data class ServerCredentials(
    val serverUrl: String,
    val username: String,
    val password: String,
    val authType: String,
    val protocolVersion: String,
    val serverType: String,
    val fallbackUrl: String?,
) {
    fun toStorageJson(): JSONObject = JSONObject().apply {
        put("serverUrl", serverUrl)
        put("username", username)
        put("password", password)
        put("authType", authType)
        put("protocolVersion", protocolVersion)
        put("serverType", serverType)
        if (!fallbackUrl.isNullOrBlank()) {
            put("fallbackUrl", fallbackUrl)
        }
    }

    fun toPublicJson(): JSONObject = JSONObject().apply {
        put("serverUrl", serverUrl)
        put("username", username)
        put("authType", authType)
        put("protocolVersion", protocolVersion)
        put("serverType", serverType)
        if (!fallbackUrl.isNullOrBlank()) {
            put("fallbackUrl", fallbackUrl)
        }
    }

    companion object {
        fun fromStorageJson(raw: String): ServerCredentials {
            val json = JSONObject(raw)
            return ServerCredentials(
                serverUrl = json.getString("serverUrl"),
                username = json.getString("username"),
                password = json.getString("password"),
                authType = json.getString("authType"),
                protocolVersion = json.optString(
                    "protocolVersion",
                    SubsonicAuthBuilder.DEFAULT_VERSION,
                ),
                serverType = json.optString("serverType", "subsonic"),
                fallbackUrl = json.optString("fallbackUrl")
                    .takeIf { it.isNotBlank() },
            )
        }
    }
}
