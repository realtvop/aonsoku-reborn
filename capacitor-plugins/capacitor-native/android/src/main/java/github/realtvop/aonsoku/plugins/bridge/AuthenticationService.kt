package github.realtvop.aonsoku.plugins.bridge

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class AuthenticationResult(
    val success: Boolean,
    val authType: String? = null,
    val protocolVersion: String? = null,
    val serverType: String? = null,
    val activeUrl: String? = null,
    val activeServerType: String? = null,
    val password: String? = null,
    val error: String? = null,
)

/** Application-scoped typed boundary for credentials and Subsonic requests. */
class AuthenticationService private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val credentialStore = AndroidCredentialStore(appContext)
    val httpClient = SubsonicHttpClient()

    fun getCredentials(): ServerCredentials? = credentialStore.retrieve()

    fun hasCredentials(): Boolean = credentialStore.exists()

    fun storeCredentials(credentials: ServerCredentials) = credentialStore.store(credentials)

    fun clearCredentials() = credentialStore.delete()

    suspend fun login(
        primaryUrl: String,
        fallbackUrl: String?,
        username: String,
        rawPassword: String,
    ): AuthenticationResult = withContext(Dispatchers.IO) {
        attemptLogin(primaryUrl, fallbackUrl, username, rawPassword, "primary")
            ?: if (!fallbackUrl.isNullOrBlank()) {
                attemptLogin(fallbackUrl, null, username, rawPassword, "fallback")
            } else {
                null
            }
            ?: AuthenticationResult(success = false, error = "auth_failed")
    }

    suspend fun ping(
        url: String,
        username: String,
        password: String,
        authType: String,
    ): PingResult = httpClient.ping(url, username, password, authType)

    suspend fun queryServerInfo(url: String): ServerInfoResult =
        httpClient.queryServerInfo(url)

    suspend fun request(
        credentials: ServerCredentials,
        path: String,
        extraQuery: Map<String, String> = emptyMap(),
        method: String = "GET",
        body: String? = null,
    ): SubsonicResponse = httpClient.request(
        baseUrl = credentials.serverUrl,
        path = path,
        credentials = credentials,
        extraQuery = extraQuery,
        method = method,
        body = body,
    )

    private suspend fun attemptLogin(
        url: String,
        fallbackUrl: String?,
        username: String,
        rawPassword: String,
        activeServerType: String,
    ): AuthenticationResult? {
        for (authType in listOf("token", "password")) {
            val storedPassword = SubsonicAuthBuilder.hashPasswordForStorage(
                rawPassword,
                authType,
            )
            val ping = httpClient.ping(
                baseUrl = url,
                username = username,
                password = storedPassword,
                authType = authType,
            )
            if (!ping.reachable) continue

            val serverInfo = httpClient.queryServerInfo(url)
            val credentials = ServerCredentials(
                serverUrl = url,
                username = username,
                password = storedPassword,
                authType = authType,
                protocolVersion = serverInfo.protocolVersion,
                serverType = serverInfo.serverType,
                fallbackUrl = fallbackUrl,
            )
            return try {
                credentialStore.store(credentials)
                AuthenticationResult(
                    success = true,
                    authType = authType,
                    protocolVersion = serverInfo.protocolVersion,
                    serverType = serverInfo.serverType,
                    activeUrl = url,
                    activeServerType = activeServerType,
                    password = storedPassword,
                )
            } catch (_: Exception) {
                AuthenticationResult(success = false, error = "keystore_store_failed")
            }
        }
        return null
    }

    companion object {
        @Volatile
        private var instance: AuthenticationService? = null

        fun getInstance(context: Context): AuthenticationService = instance ?: synchronized(this) {
            instance ?: AuthenticationService(context.applicationContext).also { instance = it }
        }
    }
}
