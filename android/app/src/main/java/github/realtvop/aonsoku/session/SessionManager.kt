package github.realtvop.aonsoku.session

import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.settings.ServerUrlSettings
import github.realtvop.aonsoku.settings.SettingsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import java.net.URI

sealed interface SessionState {
    data object SignedOut : SessionState

    data class SignedIn(val credentials: ServerCredentials) : SessionState
}

sealed interface LoginResult {
    data object Success : LoginResult

    /** The server speaks a Subsonic protocol older than 1.15.0. */
    data object IncompatibleServer : LoginResult

    data object Failed : LoginResult
}

/**
 * Owns the signed-in server session. Credentials stay in the encrypted native
 * store shared with playback and sync; the configured primary/fallback URLs
 * live in the app settings so the active server can be re-selected at startup.
 */
class SessionManager(
    private val authentication: AuthenticationService,
    private val settings: SettingsRepository,
    private val beforePrimaryServerChange: suspend () -> Unit = {},
) {
    private val _state = MutableStateFlow<SessionState>(SessionState.SignedOut)

    val state: StateFlow<SessionState> = _state.asStateFlow()

    val credentials: ServerCredentials?
        get() = (_state.value as? SessionState.SignedIn)?.credentials

    /** Restores the stored session without touching the network. */
    suspend fun restore() = withContext(Dispatchers.IO) {
        val stored = authentication.getCredentials()
        if (stored == null) {
            _state.value = SessionState.SignedOut
            return@withContext
        }
        val server = settings.current.server
        if (server.primaryUrl.isEmpty()) {
            settings.update {
                it.copy(
                    server = ServerUrlSettings(
                        primaryUrl = stored.serverUrl,
                        fallbackUrl = stored.fallbackUrl.orEmpty(),
                        activeServerType = "primary",
                    ),
                )
            }
        }
        _state.value = SessionState.SignedIn(stored)
    }

    suspend fun login(
        url: String,
        username: String,
        password: String,
        allowIncompatible: Boolean = false,
    ): LoginResult {
        val serverUrl = normalizeServerUrl(url)
        if (!isValidServerUrl(serverUrl)) return LoginResult.Failed

        val info = authentication.queryServerInfo(serverUrl)
        val version = SubsonicAuthBuilder.parseVersionNumber(info.protocolVersion)
        if (version < MIN_PROTOCOL_VERSION && !allowIncompatible) {
            return LoginResult.IncompatibleServer
        }

        val result = authentication.login(serverUrl, null, username, password)
        if (!result.success) return LoginResult.Failed

        val stored = withContext(Dispatchers.IO) { authentication.getCredentials() }
            ?: return LoginResult.Failed
        settings.update {
            it.copy(
                server = ServerUrlSettings(
                    primaryUrl = serverUrl,
                    fallbackUrl = "",
                    activeServerType = "primary",
                ),
            )
        }
        _state.value = SessionState.SignedIn(stored)
        return LoginResult.Success
    }

    /**
     * Picks the server to use for this session: the primary URL when it
     * answers, otherwise the fallback. Returns false when neither is reachable.
     */
    suspend fun selectConfiguredServer(): Boolean {
        val current = credentials ?: return false
        val server = settings.current.server
        val primary = server.primaryUrl.ifEmpty { current.serverUrl }
        val candidates = listOf("primary" to primary, "fallback" to server.fallbackUrl)
            .filter { it.second.isNotEmpty() }

        for ((type, url) in candidates) {
            val ping = authentication.ping(url, current.username, current.password, current.authType)
            if (!ping.reachable) continue
            activate(current, url, server.fallbackUrl, type)
            return true
        }
        settings.update { it.copy(server = it.server.copy(activeServerType = null)) }
        return false
    }

    /** Whether any configured URL currently answers an authenticated ping. */
    suspend fun isServerReachable(): Boolean {
        val current = credentials ?: return true
        val server = settings.current.server
        return setOf(server.primaryUrl, server.fallbackUrl, current.serverUrl)
            .filter { it.isNotEmpty() }
            .any { url ->
                authentication.ping(url, current.username, current.password, current.authType)
                    .reachable
            }
    }

    suspend fun saveServerUrls(primaryUrl: String, fallbackUrl: String): Boolean {
        val current = credentials ?: return false
        val primary = normalizeServerUrl(primaryUrl)
        val fallback = normalizeServerUrl(fallbackUrl)
        if (!isValidServerUrl(primary)) return false
        if (fallback.isNotEmpty() && !isValidServerUrl(fallback)) return false

        for ((type, url) in listOf("primary" to primary, "fallback" to fallback)) {
            if (url.isEmpty()) continue
            val ping = authentication.ping(url, current.username, current.password, current.authType)
            if (!ping.reachable) continue
            val previousPrimary = settings.current.server.primaryUrl.ifEmpty { current.serverUrl }
            if (primary != normalizeServerUrl(previousPrimary)) beforePrimaryServerChange()
            settings.update {
                it.copy(server = ServerUrlSettings(primary, fallback, type))
            }
            activate(current, url, fallback, type)
            return true
        }
        return false
    }

    suspend fun logout() = withContext(Dispatchers.IO) {
        authentication.clearCredentials()
        settings.update { it.copy(server = ServerUrlSettings()) }
        _state.value = SessionState.SignedOut
    }

    private suspend fun activate(
        current: ServerCredentials,
        url: String,
        fallbackUrl: String,
        type: String,
    ) {
        val info = if (url != current.serverUrl) authentication.queryServerInfo(url) else null
        val next = current.copy(
            serverUrl = url,
            fallbackUrl = fallbackUrl.takeIf { it.isNotEmpty() },
            protocolVersion = info?.protocolVersion ?: current.protocolVersion,
            serverType = info?.serverType ?: current.serverType,
        )
        if (next != current) {
            withContext(Dispatchers.IO) { authentication.storeCredentials(next) }
        }
        settings.update {
            it.copy(
                server = it.server.copy(
                    primaryUrl = it.server.primaryUrl.ifEmpty { url },
                    activeServerType = type,
                ),
            )
        }
        _state.value = SessionState.SignedIn(next)
    }

    companion object {
        /** Subsonic 1.15.0, encoded like [SubsonicAuthBuilder.parseVersionNumber]. */
        private const val MIN_PROTOCOL_VERSION = 11500

        fun normalizeServerUrl(url: String): String = url.trim().trimEnd('/')

        fun isValidServerUrl(url: String): Boolean = runCatching {
            val uri = URI(url)
            (uri.scheme == "http" || uri.scheme == "https") && !uri.host.isNullOrEmpty()
        }.getOrDefault(false)
    }
}
