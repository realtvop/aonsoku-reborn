package github.realtvop.aonsoku.plugins.bridge

import android.os.Handler
import android.os.Looper
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import com.google.android.material.color.DynamicColors
import com.google.android.material.color.MaterialColors

@CapacitorPlugin(name = "AonsokuNativeBridge")
class BridgePlugin : Plugin() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val authenticationService: AuthenticationService by lazy {
        AuthenticationService.getInstance(context)
    }

    @PluginMethod
    fun storeCredentials(call: PluginCall) {
        val serverUrl = call.getString("serverUrl")
        val username = call.getString("username")
        val authType = call.getString("authType")
        val protocolVersion = call.getString("protocolVersion")
        val serverType = call.getString("serverType")

        if (
            serverUrl.isNullOrBlank() ||
            username.isNullOrBlank() ||
            authType.isNullOrBlank() ||
            protocolVersion.isNullOrBlank() ||
            serverType.isNullOrBlank()
        ) {
            reject(call, "Missing required credential fields")
            return
        }

        val password = call.getString("password")
            ?.takeIf { it.isNotEmpty() }
            ?: authenticationService.getCredentials()?.password

        if (password.isNullOrEmpty()) {
            reject(call, "Missing password and no existing credentials found")
            return
        }

        try {
            authenticationService.storeCredentials(
                ServerCredentials(
                    serverUrl = serverUrl,
                    username = username,
                    password = password,
                    authType = authType,
                    protocolVersion = protocolVersion,
                    serverType = serverType,
                    fallbackUrl = call.getString("fallbackUrl"),
                ),
            )
            resolve(call)
        } catch (_: Exception) {
            reject(call, "Failed to store credentials")
        }
    }

    @PluginMethod
    fun getCredentials(call: PluginCall) {
        val credentials = authenticationService.getCredentials()
        if (credentials == null) {
            resolve(call, JSObject())
            return
        }

        resolve(call, credentials.toPublicJsObject())
    }

    @PluginMethod
    fun clearCredentials(call: PluginCall) {
        authenticationService.clearCredentials()
        resolve(call)
    }

    @PluginMethod
    fun hasCredentials(call: PluginCall) {
        resolve(call, JSObject().apply { put("stored", authenticationService.hasCredentials()) })
    }

    @PluginMethod
    fun login(call: PluginCall) {
        val primaryUrl = call.getString("url")
        val username = call.getString("username")
        val rawPassword = call.getString("password")

        if (
            primaryUrl.isNullOrBlank() ||
            username.isNullOrBlank() ||
            rawPassword.isNullOrEmpty()
        ) {
            reject(call, "Missing required login fields")
            return
        }

        val fallbackUrl = call.getString("fallbackUrl")

        pluginScope.launch {
            val result = authenticationService.login(
                primaryUrl = primaryUrl,
                fallbackUrl = fallbackUrl,
                username = username,
                rawPassword = rawPassword,
            )
            resolve(call, result.toJsObject())
        }
    }

    @PluginMethod
    fun ping(call: PluginCall) {
        val url = call.getString("url")
        val username = call.getString("username")
        val password = call.getString("password")
        val authType = call.getString("authType")

        if (
            url.isNullOrBlank() ||
            username.isNullOrBlank() ||
            password.isNullOrEmpty() ||
            authType.isNullOrBlank()
        ) {
            reject(call, "Missing required ping fields")
            return
        }

        pluginScope.launch {
            val result = authenticationService.ping(
                url = url,
                username = username,
                password = password,
                authType = authType,
            )
            val response = JSObject().apply {
                put("reachable", result.reachable)
                result.error?.let { put("error", it) }
            }
            resolve(call, response)
        }
    }

    @PluginMethod
    fun queryServerInfo(call: PluginCall) {
        val url = call.getString("url")
        if (url.isNullOrBlank()) {
            reject(call, "Missing url parameter")
            return
        }

        pluginScope.launch {
            val info = authenticationService.queryServerInfo(url)
            resolve(
                call,
                JSObject().apply {
                    put("protocolVersion", info.protocolVersion)
                    put(
                        "protocolVersionNumber",
                        SubsonicAuthBuilder.parseVersionNumber(
                            info.protocolVersion,
                        ),
                    )
                    put("serverType", info.serverType)
                },
            )
        }
    }

    @PluginMethod
    fun request(call: PluginCall) {
        val path = call.getString("path")
        if (path.isNullOrBlank()) {
            reject(call, "Missing path parameter")
            return
        }

        val credentials = authenticationService.getCredentials()
        if (credentials == null) {
            reject(call, "No stored credentials")
            return
        }

        val extraQuery = mutableMapOf<String, String>()
        call.getObject("query")?.let { query ->
            val keys = query.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = query.opt(key)
                if (value != null) {
                    extraQuery[key] = value.toString()
                }
            }
        }

        val method = call.getString("method") ?: "GET"
        val body = call.getString("body")

        pluginScope.launch {
            try {
                val response = authenticationService.request(
                    credentials = credentials,
                    path = path,
                    extraQuery = extraQuery,
                    method = method,
                    body = body,
                )
                resolve(
                    call,
                    JSObject().apply {
                        put("count", response.count)
                        put("data", response.data)
                    },
                )
            } catch (error: SubsonicHttpError) {
                reject(call, errorMessage(error))
            } catch (_: Exception) {
                reject(call, "server_error: Unexpected native request error")
            }
        }
    }

    override fun handleOnDestroy() {
        pluginScope.cancel()
        super.handleOnDestroy()
    }

    private fun errorMessage(error: SubsonicHttpError): String = when (error) {
        is SubsonicHttpError.AuthFailed -> "auth_failed: ${error.message}"
        is SubsonicHttpError.HttpError -> "http_error: ${error.statusCode}"
        is SubsonicHttpError.NetworkUnreachable -> {
            "network_unreachable: ${error.message}"
        }
        is SubsonicHttpError.ParseError -> "parse_error: ${error.message}"
        is SubsonicHttpError.ServerError -> "server_error: ${error.message}"
    }

    private fun resolve(call: PluginCall) {
        mainHandler.post { call.resolve() }
    }

    private fun resolve(call: PluginCall, data: JSObject) {
        mainHandler.post { call.resolve(data) }
    }

    private fun reject(call: PluginCall, message: String) {
        mainHandler.post { call.reject(message) }
    }

    private fun AuthenticationResult.toJsObject(): JSObject = JSObject().apply {
        put("success", success)
        authType?.let { put("authType", it) }
        protocolVersion?.let { put("protocolVersion", it) }
        serverType?.let { put("serverType", it) }
        activeUrl?.let { put("activeUrl", it) }
        activeServerType?.let { put("activeServerType", it) }
        password?.let { put("password", it) }
        error?.let { put("error", it) }
    }

    private fun ServerCredentials.toPublicJsObject(): JSObject = JSObject().apply {
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

    @PluginMethod
    fun getMaterialYouColors(call: PluginCall) {
        val isDark = call.getBoolean("isDark", false) ?: false
        try {
            val supported = DynamicColors.isDynamicColorAvailable()
            val response = JSObject().apply {
                put("supported", supported)
                if (supported) {
                    val config = android.content.res.Configuration(context.resources.configuration)
                    config.uiMode = (config.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK.inv()) or
                            if (isDark) android.content.res.Configuration.UI_MODE_NIGHT_YES else android.content.res.Configuration.UI_MODE_NIGHT_NO

                    val nightContext = context.createConfigurationContext(config)
                    val themedContext = android.view.ContextThemeWrapper(
                        nightContext,
                        com.google.android.material.R.style.Theme_Material3_DayNight
                    )
                    val dynamicContext = DynamicColors.wrapContextIfAvailable(themedContext)

                    val colorsObj = JSObject().apply {
                        val attrs = mapOf(
                            "colorPrimary" to com.google.android.material.R.attr.colorPrimary,
                            "colorOnPrimary" to com.google.android.material.R.attr.colorOnPrimary,
                            "colorSecondary" to com.google.android.material.R.attr.colorSecondary,
                            "colorOnSecondary" to com.google.android.material.R.attr.colorOnSecondary,
                            "colorBackground" to android.R.attr.colorBackground,
                            "colorOnBackground" to com.google.android.material.R.attr.colorOnBackground,
                            "colorSurface" to com.google.android.material.R.attr.colorSurface,
                            "colorOnSurface" to com.google.android.material.R.attr.colorOnSurface,
                            "colorSurfaceVariant" to com.google.android.material.R.attr.colorSurfaceVariant,
                            "colorOnSurfaceVariant" to com.google.android.material.R.attr.colorOnSurfaceVariant,
                            "colorSurfaceContainerLowest" to com.google.android.material.R.attr.colorSurfaceContainerLowest,
                            "colorSurfaceContainerLow" to com.google.android.material.R.attr.colorSurfaceContainerLow,
                            "colorSurfaceContainer" to com.google.android.material.R.attr.colorSurfaceContainer,
                            "colorSurfaceContainerHigh" to com.google.android.material.R.attr.colorSurfaceContainerHigh,
                            "colorSurfaceContainerHighest" to com.google.android.material.R.attr.colorSurfaceContainerHighest,
                            "colorOutline" to com.google.android.material.R.attr.colorOutline,
                            "colorOutlineVariant" to com.google.android.material.R.attr.colorOutlineVariant
                        )
                        for ((name, attr) in attrs) {
                            val resolvedColor = MaterialColors.getColor(
                                dynamicContext,
                                attr,
                                android.graphics.Color.BLACK
                            )
                            val hexStr = String.format("#%06X", 0xFFFFFF and resolvedColor)
                            put(name, hexStr)
                        }
                    }
                    put("colors", colorsObj)
                }
            }
            resolve(call, response)
        } catch (e: Exception) {
            val response = JSObject().apply {
                put("supported", false)
            }
            resolve(call, response)
        }
    }
}
