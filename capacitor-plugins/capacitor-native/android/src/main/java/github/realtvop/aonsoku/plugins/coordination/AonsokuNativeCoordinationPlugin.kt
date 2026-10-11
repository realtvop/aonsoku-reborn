package github.realtvop.aonsoku.plugins.coordination

import com.getcapacitor.*
import com.getcapacitor.annotation.CapacitorPlugin
import kotlinx.coroutines.*
import org.json.JSONObject

/** Compatibility payload adapter. Destroying a WebView does not stop native networking. */
@CapacitorPlugin(name = "AonsokuNativeCoordination")
class AonsokuNativeCoordinationPlugin : Plugin() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val service by lazy { NativeCoordinationService.getInstance(context) }
    override fun load() { scope.launch { service.events.collect { notifyListeners(it.name, JSObject(it.payload.toString())) } } }
    override fun handleOnDestroy() { scope.cancel(); super.handleOnDestroy() }
    private fun adapt(call: PluginCall, block: suspend () -> JSONObject?) { scope.launch { try { val result = block(); if (result == null) call.resolve() else call.resolve(JSObject(result.toString())) } catch (e: Exception) { call.reject(e.message ?: "Coordination failed") } } }
    private fun PluginCall.required(key: String): String = getString(key) ?: error("Missing $key")
    @PluginMethod fun storeTokens(call: PluginCall) = adapt(call) { service.storeTokens(CoordinationTokenBundle(call.required("accessToken"), call.required("refreshToken"), call.getDouble("accessTokenExpiresAt", 0.0)!!.toLong(), call.required("deviceId"), call.required("accountId"), call.getInt("historyLimit", 100)!!)); null }
    @PluginMethod fun loadTokens(call: PluginCall) = adapt(call) { service.loadTokens()?.let { b -> JSONObject().put("accessToken", b.accessToken).put("refreshToken", b.refreshToken).put("accessTokenExpiresAt", b.accessTokenExpiresAt).put("deviceId", b.deviceId).put("accountId", b.accountId).put("historyLimit", b.historyLimit) } }
    @PluginMethod fun clearTokens(call: PluginCall) = adapt(call) { service.clearTokens(); null }
    @PluginMethod fun storeConfig(call: PluginCall) = adapt(call) { service.storeConfig(call.required("serverUrl"), call.required("identityUrl")); null }
    @PluginMethod fun loadConfig(call: PluginCall) = adapt(call) { service.loadConfig()?.let { JSONObject().put("serverUrl", it.first).put("identityUrl", it.second) } }
    @PluginMethod fun request(call: PluginCall) = adapt(call) { val headers = call.getObject("headers"); val map = headers?.keys()?.asSequence()?.associateWith { headers.optString(it) }.orEmpty(); val r = service.request(call.required("url"), call.getString("method", "GET")!!, call.getString("body"), map); JSONObject().put("status", r.status).put("statusText", r.statusText).put("body", r.body) }
    @PluginMethod fun connect(call: PluginCall) = adapt(call) { service.connect(call.required("wsUrl"), call.required("ticket"), call.required("deviceId"), call.getInt("capabilities", 0)!!, call.getInt("protocolVersion", 1)!!, call.getDouble("lastSeq", 0.0)!!.toLong()); null }
    @PluginMethod fun disconnect(call: PluginCall) = adapt(call) { service.disconnect(); null }
    @PluginMethod fun getState(call: PluginCall) = adapt(call) { service.connectionState() }
    @PluginMethod fun requestSnapshots(call: PluginCall) = adapt(call) { service.requestPeerSnapshots(); null }
    @PluginMethod fun publishSnapshot(call: PluginCall) = adapt(call) { service.submitEnvelope(JSONObject().put("type", "snapshot").put("snapshot", JSONObject(call.required("snapshotJson"))).put("sessionId", call.getString("sessionId", "")).put("generation", call.getInt("generation", 0)).put("snapshotRevision", call.getInt("snapshotRevision", 0))); null }
    @PluginMethod fun sendCommand(call: PluginCall) = adapt(call) { service.submitEnvelope(JSONObject().put("type", "command").put("messageId", call.getString("messageId") ?: java.util.UUID.randomUUID().toString()).put("command", JSONObject(call.required("commandJson"))).put("targetDeviceId", call.required("targetDeviceId")).put("expectedGeneration", call.getInt("expectedGeneration", 0))); null }
    @PluginMethod fun sendActiveControlCommand(call: PluginCall) = adapt(call) { check(service.sendActiveCommand(JSONObject(call.required("commandJson")))) { "No active control target" }; null }
    @PluginMethod fun sendControlSessionBegin(call: PluginCall) = adapt(call) { service.beginControl(call.required("targetDeviceId")); null }
    @PluginMethod fun sendControlSessionEnd(call: PluginCall) = adapt(call) { service.endControl(); null }
    @PluginMethod fun requestHandoffCandidateFromCache(call: PluginCall) = adapt(call) { check(service.handoffFromCache(call.required("sourceDeviceId"))) { "Missing cached handoff snapshot" }; null }
    @PluginMethod fun requestHandoffCandidate(call: PluginCall) = adapt(call) { service.submitEnvelope(JSONObject().put("type", "handoff_candidate_request").put("sourceDeviceId", call.required("sourceDeviceId")).put("expectedGeneration", call.getInt("expectedGeneration", 0)).put("expectedSnapshotRevision", call.getInt("expectedSnapshotRevision", 0))); null }
    @PluginMethod fun sendTargetReady(call: PluginCall) = adapt(call) { service.submitEnvelope(NativeCoordinationService.buildTargetReadyEnvelope(1, call.required("transactionId"), call.getInt("generation", 0)!!, call.getInt("snapshotRevision", 0)!!, call.required("sourceDeviceId"), call.required("sessionId"))); null }
    @PluginMethod fun sendRelinquishAck(call: PluginCall) = adapt(call) { service.submitEnvelope(NativeCoordinationService.buildRelinquishAckEnvelope(1, call.required("transactionId"), JSONObject(call.required("snapshotJson")))); null }
}
