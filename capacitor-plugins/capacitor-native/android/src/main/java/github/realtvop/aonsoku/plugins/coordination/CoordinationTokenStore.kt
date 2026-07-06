package github.realtvop.aonsoku.plugins.coordination

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/// Design §6.3: coordination tokens must be stored in the Android Keystore,
/// not in plain SharedPreferences. This store wraps the token payload with
/// AES-GCM using a Keystore-backed key, then persists the ciphertext in
/// SharedPreferences. Mirrors AndroidCredentialStore in the bridge package.
///
/// Config keys (server_url, identity_url) are non-secret and stay in plain
/// SharedPreferences; only credential fields go through this store.
internal data class CoordinationTokenBundle(
    val accessToken: String,
    val refreshToken: String,
    val accessTokenExpiresAt: Long,
    val deviceId: String,
    val accountId: String,
    val historyLimit: Int,
)

internal class CoordinationTokenStore(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun store(bundle: CoordinationTokenBundle) {
        val payload = JSONObject().apply {
            put("accessToken", bundle.accessToken)
            put("refreshToken", bundle.refreshToken)
            put("accessTokenExpiresAt", bundle.accessTokenExpiresAt)
            put("deviceId", bundle.deviceId)
            put("accountId", bundle.accountId)
            put("historyLimit", bundle.historyLimit)
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8))
        val box = JSONObject().apply {
            put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            put("data", Base64.encodeToString(encrypted, Base64.NO_WRAP))
        }
        prefs.edit().putString(KEY_TOKENS, box.toString()).apply()
    }

    fun retrieve(): CoordinationTokenBundle? {
        val raw = prefs.getString(KEY_TOKENS, null) ?: return null
        return try {
            val box = JSONObject(raw)
            val iv = Base64.decode(box.getString("iv"), Base64.NO_WRAP)
            val encrypted = Base64.decode(box.getString("data"), Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv),
            )
            val decrypted = cipher.doFinal(encrypted).toString(Charsets.UTF_8)
            val payload = JSONObject(decrypted)
            CoordinationTokenBundle(
                accessToken = payload.getString("accessToken"),
                refreshToken = payload.getString("refreshToken"),
                accessTokenExpiresAt = payload.optLong("accessTokenExpiresAt", 0L),
                deviceId = payload.getString("deviceId"),
                accountId = payload.getString("accountId"),
                historyLimit = payload.optInt("historyLimit", 100),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decrypt coordination tokens", e)
            null
        }
    }

    fun delete() {
        prefs.edit().remove(KEY_TOKENS).apply()
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    companion object {
        private const val TAG = "CoordTokenStore"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "aonsoku_coordination_tokens"
        internal const val PREFS_NAME = "aonsoku_coordination"
        private const val KEY_TOKENS = "tokens_encrypted"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH_BITS = 128
    }
}
