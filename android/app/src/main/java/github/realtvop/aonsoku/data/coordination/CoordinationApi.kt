package github.realtvop.aonsoku.data.coordination

import github.realtvop.aonsoku.data.api.await
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.coordination.CoordinationTokenBundle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/** A request the coordination server turned down, with its error code. */
class CoordinationApiException(
    val code: String,
    message: String,
    val status: Int,
) : IOException(message)

/**
 * Proof that this device holds the music-server account (design §6.2): the
 * stored Subsonic token with its fixed salt, or the stored `enc:` password.
 */
data class SubsonicProof(
    val identityUrl: String,
    val username: String,
    val authMode: String,
    val token: String? = null,
    val salt: String? = null,
    val password: String? = null,
) {
    companion object {
        fun from(credentials: ServerCredentials, identityUrl: String): SubsonicProof? =
            when (credentials.authType) {
                "token" -> SubsonicProof(
                    identityUrl = identityUrl,
                    username = credentials.username,
                    authMode = "token",
                    token = credentials.password,
                    salt = SubsonicAuthBuilder.SALT,
                )
                "password" -> SubsonicProof(
                    identityUrl = identityUrl,
                    username = credentials.username,
                    authMode = "password",
                    password = credentials.password,
                )
                else -> null
            }
    }
}

/**
 * HTTP client of the coordination server's `/v1` endpoints (`src/coordination/httpClient.ts`).
 * It keeps the device tokens fresh: an access token about to expire is
 * refreshed before a request, one the server rejects is refreshed once and
 * the request repeated, and a refresh token the server no longer accepts is
 * replaced by signing in again with [recovery]. A revoked device loses its
 * tokens. Every change is handed to [onTokensChanged] to be stored.
 */
class CoordinationApi(
    serverUrl: String,
    private val client: OkHttpClient,
    tokens: CoordinationTokenBundle?,
    private val onTokensChanged: (CoordinationTokenBundle?) -> Unit,
    private val recovery: () -> SubsonicProof?,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    val baseUrl: String = serverUrl.trimEnd('/')

    @Volatile
    var tokens: CoordinationTokenBundle? = tokens
        private set

    private val refreshLock = Mutex()

    /** The address of the realtime socket. */
    val realtimeUrl: String get() = baseUrl.replaceFirst(Regex("^http", RegexOption.IGNORE_CASE), "ws") +
        "/v1/realtime"

    suspend fun challenge(identityUrl: String, username: String): String =
        post<ChallengeResponse>(
            "/v1/auth/challenge",
            CoordinationJson.encodeToString(
                ChallengeRequest.serializer(),
                ChallengeRequest(identityUrl, username),
            ),
            authenticated = false,
        ).challengeId

    /** Registers this device and keeps the tokens it receives. */
    suspend fun register(
        proof: SubsonicProof,
        deviceName: String,
        platform: String,
        clientVersion: String,
    ): CoordinationTokenBundle {
        val challengeId = challenge(proof.identityUrl, proof.username)
        val request = RegisterRequest(
            challengeId = challengeId,
            identityUrl = proof.identityUrl,
            username = proof.username,
            authMode = proof.authMode,
            token = proof.token,
            salt = proof.salt,
            password = proof.password,
            deviceName = deviceName,
            platform = platform,
            clientVersion = clientVersion,
            capabilities = COORDINATION_CAPABILITIES,
        )
        val response = post<RegisterResponse>(
            "/v1/auth/register",
            CoordinationJson.encodeToString(RegisterRequest.serializer(), request),
            authenticated = false,
        )
        val bundle = CoordinationTokenBundle(
            accessToken = response.accessToken,
            refreshToken = response.refreshToken,
            accessTokenExpiresAt = clock() + response.expiresIn * 1000,
            deviceId = response.deviceId,
            accountId = response.accountId,
            historyLimit = response.historyLimit,
        )
        setTokens(bundle)
        return bundle
    }

    /** A one-time ticket for opening the realtime socket. */
    suspend fun wsTicket(): String {
        ensureValidAccessToken()
        return post<WsTicketResponse>("/v1/auth/ws-ticket", "{}").ticket
    }

    suspend fun devices(): List<DeviceDto> {
        ensureValidAccessToken()
        val body = send("GET", "/v1/devices", null, authenticated = true).orEmpty()
        return CoordinationJson.decodeFromString(ListSerializer(DeviceDto.serializer()), body)
    }

    suspend fun renameDevice(id: String, name: String) {
        ensureValidAccessToken()
        send(
            "PATCH",
            "/v1/devices/$id",
            CoordinationJson.encodeToString(RenameDeviceRequest.serializer(), RenameDeviceRequest(name)),
            authenticated = true,
        )
    }

    suspend fun revokeDevice(id: String) {
        ensureValidAccessToken()
        send("DELETE", "/v1/devices/$id", null, authenticated = true)
    }

    suspend fun deleteAccount() {
        ensureValidAccessToken()
        send("DELETE", "/v1/account", null, authenticated = true)
    }

    /** Refreshes the access token when it expires within a minute. */
    suspend fun ensureValidAccessToken() {
        val current = tokens ?: return
        if (current.accessTokenExpiresAt - clock() > REFRESH_MARGIN_MS) return
        refresh(current.accessToken)
    }

    /**
     * Replaces the access token [stale]; whoever waited for a refresh already
     * under way takes its result instead of asking again.
     */
    private suspend fun refresh(stale: String) = refreshLock.withLock {
        val current = tokens ?: return@withLock
        if (current.accessToken != stale) return@withLock
        val request = TokenRefreshRequest(current.deviceId, current.refreshToken)
        try {
            applyRefresh(requestTokens(request))
        } catch (error: CoordinationApiException) {
            when (error.code) {
                "device_revoked" -> {
                    setTokens(null)
                    throw error
                }
                "authentication_failed" -> recover(request)
                else -> throw error
            }
        }
    }

    /** The refresh token is no longer valid: prove the account again. */
    private suspend fun recover(request: TokenRefreshRequest) {
        val proof = recovery()
            ?: throw CoordinationApiException("authentication_failed", "invalid refresh token", 401)
        try {
            val challengeId = challenge(proof.identityUrl, proof.username)
            applyRefresh(
                requestTokens(
                    request.copy(
                        challengeId = challengeId,
                        identityUrl = proof.identityUrl,
                        username = proof.username,
                        authMode = proof.authMode,
                        token = proof.token,
                        salt = proof.salt,
                        password = proof.password,
                    ),
                ),
            )
        } catch (error: CoordinationApiException) {
            if (error.code == "device_revoked") setTokens(null)
            throw error
        }
    }

    private suspend fun requestTokens(request: TokenRefreshRequest): TokenRefreshResponse = post(
        "/v1/auth/token",
        CoordinationJson.encodeToString(TokenRefreshRequest.serializer(), request),
        authenticated = false,
    )

    private fun applyRefresh(response: TokenRefreshResponse) {
        val current = tokens ?: return
        setTokens(
            current.copy(
                accessToken = response.accessToken,
                refreshToken = response.refreshToken,
                accessTokenExpiresAt = clock() + response.expiresIn * 1000,
            ),
        )
    }

    private fun setTokens(bundle: CoordinationTokenBundle?) {
        tokens = bundle
        onTokensChanged(bundle)
    }

    private suspend inline fun <reified T> post(
        path: String,
        body: String,
        authenticated: Boolean = true,
    ): T {
        val text = send("POST", path, body, authenticated).orEmpty()
        return CoordinationJson.decodeFromString(text)
    }

    /** Sends one request; the response body, or null when there is none. */
    private suspend fun send(
        method: String,
        path: String,
        body: String?,
        authenticated: Boolean,
        retried: Boolean = false,
    ): String? {
        val accessToken = tokens?.accessToken.takeIf { authenticated }
        val request = Request.Builder()
            .url(baseUrl + path)
            .header("Content-Type", JSON_TYPE)
            .apply { if (accessToken != null) header("Authorization", "Bearer $accessToken") }
            .method(method, body?.toRequestBody(JSON_MEDIA_TYPE))
            .build()
        val (status, text) = client.newCall(request).await().use { response ->
            response.code to withContext(Dispatchers.IO) { response.body?.string().orEmpty() }
        }
        if (status == 401 && accessToken != null && !retried && tokens?.refreshToken != null) {
            refresh(accessToken)
            return send(method, path, body, authenticated, retried = true)
        }
        if (status !in 200..299) {
            val error = runCatching {
                CoordinationJson.decodeFromString(ErrorBody.serializer(), text)
            }.getOrNull()
            throw CoordinationApiException(
                code = error?.code ?: "internal",
                message = error?.reason ?: "HTTP $status",
                status = status,
            )
        }
        return text.takeIf { status != 204 && it.isNotBlank() }
    }

    private companion object {
        const val JSON_TYPE = "application/json"
        val JSON_MEDIA_TYPE = JSON_TYPE.toMediaType()

        /** Tokens are refreshed when they expire within this time. */
        const val REFRESH_MARGIN_MS = 60_000L
    }
}
