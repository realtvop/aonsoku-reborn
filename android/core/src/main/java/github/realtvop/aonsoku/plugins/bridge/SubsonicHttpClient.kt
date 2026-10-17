package github.realtvop.aonsoku.plugins.bridge

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

sealed class SubsonicHttpError(message: String) : Exception(message) {
    class NetworkUnreachable(message: String) : SubsonicHttpError(message)
    class HttpError(val statusCode: Int) : SubsonicHttpError("HTTP $statusCode")
    class ParseError(message: String) : SubsonicHttpError(message)
    class ServerError(message: String) : SubsonicHttpError(message)
    class AuthFailed(message: String) : SubsonicHttpError(message)
}

data class SubsonicResponse(
    val data: JSONObject,
    val count: Int,
)

data class PingResult(
    val reachable: Boolean,
    val error: String?,
)

data class ServerInfoResult(
    val protocolVersion: String,
    val serverType: String,
)

class SubsonicHttpClient {
    suspend fun request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: Map<String, String> = emptyMap(),
        method: String = "GET",
        body: String? = null,
    ): SubsonicResponse = withContext(Dispatchers.IO) {
        val raw = execute(
            url = buildUrl(baseUrl, path, credentials, extraQuery),
            method = method,
            body = body,
        )

        if (raw.statusCode !in 200..299) {
            throw SubsonicHttpError.HttpError(raw.statusCode)
        }

        val json = try {
            JSONObject(raw.body)
        } catch (_: Exception) {
            throw SubsonicHttpError.ParseError("Failed to parse JSON response")
        }

        val subsonicResponse = json.optJSONObject("subsonic-response")
            ?: throw SubsonicHttpError.ParseError(
                "Missing subsonic-response payload",
            )

        if (subsonicResponse.optString("status") == "failed") {
            val error = subsonicResponse.optJSONObject("error")
            val code = error?.optInt("code") ?: 0
            val message = error?.optString("message")
                ?.takeIf { it.isNotBlank() }
                ?: "Server returned a failed response"

            if (code == 40 || code == 41) {
                throw SubsonicHttpError.AuthFailed(message)
            }
            throw SubsonicHttpError.ServerError(message)
        }

        SubsonicResponse(
            data = subsonicResponse,
            count = raw.headers["x-total-count"]?.toIntOrNull() ?: 0,
        )
    }

    suspend fun ping(
        baseUrl: String,
        username: String,
        password: String,
        authType: String,
        protocolVersion: String? = null,
    ): PingResult {
        val credentials = ServerCredentials(
            serverUrl = baseUrl,
            username = username,
            password = password,
            authType = authType,
            protocolVersion = protocolVersion ?: SubsonicAuthBuilder.DEFAULT_VERSION,
            serverType = "subsonic",
            fallbackUrl = null,
        )

        return try {
            request(baseUrl, "ping.view", credentials)
            PingResult(reachable = true, error = null)
        } catch (_: SubsonicHttpError.AuthFailed) {
            PingResult(reachable = false, error = "auth_failed")
        } catch (_: SubsonicHttpError.NetworkUnreachable) {
            PingResult(reachable = false, error = "network_unreachable")
        } catch (_: Exception) {
            PingResult(reachable = false, error = "server_error")
        }
    }

    suspend fun queryServerInfo(baseUrl: String): ServerInfoResult =
        withContext(Dispatchers.IO) {
            val credentials = ServerCredentials(
                serverUrl = baseUrl,
                username = "probe",
                password = SubsonicAuthBuilder.generateToken("probe"),
                authType = "token",
                protocolVersion = SubsonicAuthBuilder.DEFAULT_VERSION,
                serverType = "subsonic",
                fallbackUrl = null,
            )

            try {
                val raw = execute(buildUrl(baseUrl, "ping.view", credentials))
                val subsonicResponse = JSONObject(raw.body)
                    .optJSONObject("subsonic-response")
                val version = subsonicResponse?.optString("version")
                    ?.takeIf { it.isNotBlank() }
                    ?: SubsonicAuthBuilder.DEFAULT_VERSION
                val serverType = subsonicResponse?.optString("type")
                    ?.takeIf { it.isNotBlank() }
                    ?.lowercase(Locale.US)
                    ?: "subsonic"

                ServerInfoResult(version, serverType)
            } catch (_: Exception) {
                ServerInfoResult(
                    SubsonicAuthBuilder.DEFAULT_VERSION,
                    "subsonic",
                )
            }
        }

    internal fun buildUrl(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: Map<String, String> = emptyMap(),
    ): URL {
        val cleanBaseUrl = baseUrl.trimEnd('/')
        val cleanPath = path.trimStart('/')
        val authParams = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion,
        )
        val query = encodeQuery(authParams + extraQuery)
        val separator = if (cleanPath.contains("?")) "&" else "?"

        return URL("$cleanBaseUrl/rest/$cleanPath$separator$query")
    }

    private fun execute(
        url: URL,
        method: String = "GET",
        body: String? = null,
    ): RawResponse {
        val connection = try {
            url.openConnection() as HttpURLConnection
        } catch (error: IOException) {
            throw SubsonicHttpError.NetworkUnreachable(
                error.message ?: "Unable to open connection",
            )
        }

        try {
            connection.connectTimeout = REQUEST_TIMEOUT_MS
            connection.readTimeout = RESOURCE_TIMEOUT_MS
            connection.requestMethod = method.uppercase(Locale.US)
            connection.setRequestProperty("Accept", "application/json")

            if (body != null && connection.requestMethod != "GET") {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { output ->
                    output.write(body.toByteArray(Charsets.UTF_8))
                }
            }

            val statusCode = connection.responseCode
            val stream = if (statusCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val responseBody = stream?.bufferedReader(Charsets.UTF_8)?.use {
                it.readText()
            }.orEmpty()
            val headers = mutableMapOf<String, String>()
            for ((name, values) in connection.headerFields) {
                if (name != null) {
                    headers[name.lowercase(Locale.US)] =
                        values.firstOrNull().orEmpty()
                }
            }

            return RawResponse(statusCode, headers, responseBody)
        } catch (error: IOException) {
            throw SubsonicHttpError.NetworkUnreachable(
                error.message ?: "Request failed",
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun encodeQuery(params: Map<String, String>): String =
        params.entries.joinToString("&") { (key, value) ->
            "${encode(key)}=${encode(value)}"
        }

    private fun encode(value: String): String =
        URLEncoder.encode(value, "UTF-8")

    private data class RawResponse(
        val statusCode: Int,
        val headers: Map<String, String>,
        val body: String,
    )

    companion object {
        private const val REQUEST_TIMEOUT_MS = 30_000
        private const val RESOURCE_TIMEOUT_MS = 300_000
    }
}
