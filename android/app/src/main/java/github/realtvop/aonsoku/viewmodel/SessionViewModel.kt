package github.realtvop.aonsoku.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.bridge.AuthenticationResult
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.data.LibrarySyncOptions
import github.realtvop.aonsoku.plugins.data.LibrarySyncState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class SessionViewModel(application: Application) : AndroidViewModel(application) {
    private val appServices = AppServices.getInstance(application)
    private val authService = appServices.authentication
    private val libraryService = appServices.library
    private val preferencesService = appServices.preferences

    private val _isAuthenticated = MutableStateFlow(authService.hasCredentials())
    val isAuthenticated: StateFlow<Boolean> = _isAuthenticated.asStateFlow()

    private val _credentials = MutableStateFlow<ServerCredentials?>(authService.getCredentials())
    val credentials: StateFlow<ServerCredentials?> = _credentials.asStateFlow()

    val syncState: StateFlow<LibrarySyncState> = libraryService.syncState

    private val _themeMode = MutableStateFlow("system") // "system", "dark", "light"
    val themeMode: StateFlow<String> = _themeMode.asStateFlow()

    private val _dynamicColor = MutableStateFlow(true)
    val dynamicColor: StateFlow<Boolean> = _dynamicColor.asStateFlow()

    init {
        viewModelScope.launch {
            val prefs = preferencesService.getAllPreferences()
            _themeMode.value = prefs["theme"] ?: "system"
            _dynamicColor.value = prefs["dynamic_color"]?.toBooleanStrictOrNull() ?: true

            // Automatically check and initialize library if logged in
            if (authService.hasCredentials()) {
                libraryService.initialize()
            }
        }
    }

    fun setThemeMode(mode: String) {
        _themeMode.value = mode
        viewModelScope.launch {
            preferencesService.setPreference("theme", mode)
        }
    }

    fun setDynamicColor(enabled: Boolean) {
        _dynamicColor.value = enabled
        viewModelScope.launch {
            preferencesService.setPreference("dynamic_color", enabled.toString())
        }
    }

    fun login(
        url: String,
        fallbackUrl: String? = null,
        username: String,
        password: String,
        onResult: (AuthenticationResult) -> Unit,
    ) {
        viewModelScope.launch {
            val result = authService.login(
                primaryUrl = url.trimEnd('/'),
                fallbackUrl = fallbackUrl?.takeIf { it.isNotBlank() }?.trimEnd('/'),
                username = username,
                rawPassword = password,
            )
            if (result.success) {
                _isAuthenticated.value = true
                _credentials.value = authService.getCredentials()
                libraryService.initialize()
                libraryService.syncIncremental()
            }
            onResult(result)
        }
    }

    fun logout(onLoggedOut: () -> Unit = {}) {
        viewModelScope.launch {
            authService.clearCredentials()
            _isAuthenticated.value = false
            _credentials.value = null
            onLoggedOut()
        }
    }

    fun triggerSync(mode: String = "incremental") {
        libraryService.syncAll(LibrarySyncOptions(mode = mode))
    }

    fun cancelSync() {
        libraryService.cancelSync()
    }
}
