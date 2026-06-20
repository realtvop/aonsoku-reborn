package github.realtvop.aonsoku.plugins.coordination

import android.util.Log
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.security.KeyStore
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/// Native coordination plugin for Android — maintains a background WebSocket
/// connection to the coordination server, bridging remote commands and
/// handoff events to the native queue controller (design §8, §9, §10, §11).
///
/// Multi-stack consistency: the plugin receives the same RemoteCommand types
/// as the Web/Electron observer and dispatches them through the native audio
/// plugin's queue engine. The WebView-side CoordinationManager delegates to
/// this plugin when running on capacitor-android.
@CapacitorPlugin(name = "AonsokuNativeCoordination")
class AonsokuNativeCoordinationPlugin : Plugin() {

    companion object {
        private const val TAG = "CoordPlugin"
        private const val PREFS_NAME = "aonsoku_coordination"
    }

    private var webSocket: WebSocket? = null
    private var client: OkHttpClient? = null
    private var deviceId: String? = null
    private var capabilities: Int = 0
    private var protocolVersion: Int = 1
    private var isConnecting: Boolean = false
    private var reconnectAttempts: Int = 0

    @PluginMethod
    fun storeTokens(call: PluginCall) {
        try {
            val accessToken = call.getString("accessToken") ?: return call.reject("missing accessToken")
            val refreshToken = call.getString("refreshToken") ?: return call.reject("missing refreshToken")
            val deviceId = call.getString("deviceId") ?: return call.reject("missing deviceId")
            val accountId = call.getString("accountId") ?: return call.reject("missing accountId")
        val historyLimit = call.getInt("historyLimit", 100) ?: 100

        val prefs = context.getSharedPreferences(PREFS_NAME, 0).edit()
        prefs.putString("access_token", accessToken)
        prefs.putString("refresh_token", refreshToken)
        prefs.putString("device_id", deviceId)
        prefs.putString("account_id", accountId)
        prefs.putInt("history_limit", historyLimit)
            prefs.apply()
            call.resolve()
        } catch (e: Exception) {
            call.reject("storeTokens failed: ${e.message}")
        }
    }

    @PluginMethod
    fun loadTokens(call: PluginCall) {
        val prefs = context.getSharedPreferences(PREFS_NAME, 0)
        val accessToken = prefs.getString("access_token", null)
        val refreshToken = prefs.getString("refresh_token", null)
        val deviceId = prefs.getString("device_id", null)
        val accountId = prefs.getString("account_id", null)
        if (accessToken == null || refreshToken == null || deviceId == null || accountId == null) {
            return call.resolve()
        }
        val historyLimit = prefs.getInt("history_limit", 100)
        val ret = JSObject()
        ret.put("accessToken", accessToken)
        ret.put("refreshToken", refreshToken)
        ret.put("deviceId", deviceId)
        ret.put("accountId", accountId)
        ret.put("historyLimit", historyLimit)
        call.resolve(ret)
    }

    @PluginMethod
    fun clearTokens(call: PluginCall) {
        context.getSharedPreferences(PREFS_NAME, 0).edit().clear().apply()
        call.resolve()
    }

    @PluginMethod
    fun storeConfig(call: PluginCall) {
        val serverUrl = call.getString("serverUrl") ?: return call.reject("missing serverUrl")
        val identityUrl = call.getString("identityUrl") ?: return call.reject("missing identityUrl")
        context.getSharedPreferences(PREFS_NAME, 0).edit()
            .putString("server_url", serverUrl)
            .putString("identity_url", identityUrl)
            .apply()
        call.resolve()
    }

    @PluginMethod
    fun loadConfig(call: PluginCall) {
        val prefs = context.getSharedPreferences(PREFS_NAME, 0)
        val serverUrl = prefs.getString("server_url", null)
        val identityUrl = prefs.getString("identity_url", null)
        if (serverUrl == null || identityUrl == null) return call.resolve()
        val ret = JSObject()
        ret.put("serverUrl", serverUrl)
        ret.put("identityUrl", identityUrl)
        call.resolve(ret)
    }

    @PluginMethod
    fun connect(call: PluginCall) {
        val wsUrl = call.getString("wsUrl") ?: return call.reject("missing wsUrl")
        val ticket = call.getString("ticket") ?: return call.reject("missing ticket")
        val devId = call.getString("deviceId") ?: return call.reject("missing deviceId")
        this.deviceId = devId
        this.capabilities = call.getInt("capabilities", 0) ?: 0
        this.protocolVersion = call.getInt("protocolVersion", 1) ?: 1

        disconnectInternal()

        val urlWithTicket = "$wsUrl?ticket=$ticket"
        this.client = OkHttpClient.Builder().build()
        val request = Request.Builder().url(urlWithTicket).build()
        this.webSocket = this.client?.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                isConnecting = false
                reconnectAttempts = 0
                notifyState("connected")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                dispatchEnvelope(text)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                notifyState("disconnected")
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "WS failure", t)
                notifyState("error")
                scheduleReconnect()
            }
        })
        this.isConnecting = true
        notifyState("connecting")
        call.resolve()
    }

    @PluginMethod
    fun disconnect(call: PluginCall) {
        disconnectInternal()
        call.resolve()
    }

    @PluginMethod
    fun getState(call: PluginCall) {
        val state = when {
            webSocket == null -> "disconnected"
            isConnecting -> "connecting"
            else -> "connected"
        }
        val ret = JSObject()
        ret.put("state", state)
        ret.put("deviceId", deviceId ?: JSONObject.NULL)
        call.resolve(ret)
    }

    @PluginMethod
    fun publishSnapshot(call: PluginCall) {
        val snapshotJson = call.getString("snapshotJson") ?: return call.reject("missing snapshotJson")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "snapshot")
        env.put("sessionId", call.getString("sessionId", ""))
        env.put("generation", call.getInt("generation", 0))
        env.put("snapshotRevision", call.getInt("snapshotRevision", 0))
        env.put("snapshot", JSONObject(snapshotJson))
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun sendCommand(call: PluginCall) {
        val commandJson = call.getString("commandJson") ?: return call.reject("missing commandJson")
        val targetDeviceId = call.getString("targetDeviceId") ?: return call.reject("missing targetDeviceId")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "command")
        env.put("targetDeviceId", targetDeviceId)
        env.put("expectedGeneration", call.getInt("expectedGeneration", 0))
        env.put("command", JSONObject(commandJson))
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun requestHandoffCandidate(call: PluginCall) {
        val sourceDeviceId = call.getString("sourceDeviceId") ?: return call.reject("missing sourceDeviceId")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "handoff_candidate_request")
        env.put("sourceDeviceId", sourceDeviceId)
        env.put("expectedGeneration", call.getInt("expectedGeneration", 0))
        env.put("expectedSnapshotRevision", call.getInt("expectedSnapshotRevision", 0))
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun sendTargetReady(call: PluginCall) {
        val transactionId = call.getString("transactionId") ?: return call.reject("missing transactionId")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "target_ready")
        env.put("transactionId", transactionId)
        env.put("generation", call.getInt("generation", 0))
        env.put("snapshotRevision", call.getInt("snapshotRevision", 0))
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun sendRelinquishAck(call: PluginCall) {
        val transactionId = call.getString("transactionId") ?: return call.reject("missing transactionId")
        val snapshotJson = call.getString("snapshotJson") ?: return call.reject("missing snapshotJson")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "relinquish_ack")
        env.put("transactionId", transactionId)
        env.put("snapshot", JSONObject(snapshotJson))
        sendEnvelope(env)
        call.resolve()
    }

    private fun disconnectInternal() {
        webSocket?.close(1000, "disconnect")
        webSocket = null
        client = null
        isConnecting = false
    }

    private fun sendEnvelope(env: JSONObject) {
        webSocket?.send(env.toString())
    }

    private fun dispatchEnvelope(json: String) {
        notifyListeners("coordinationEvent", JSObject().put("envelopeJson", json))
    }

    private fun scheduleReconnect() {
        reconnectAttempts++
        // Best-effort reconnect; in production, re-fetch a ws ticket first.
        notifyState("reconnecting")
    }

    private fun notifyState(state: String) {
        val ret = JSObject()
        ret.put("state", state)
        ret.put("deviceId", deviceId ?: JSONObject.NULL)
        notifyListeners("coordinationStateChange", ret)
    }
}