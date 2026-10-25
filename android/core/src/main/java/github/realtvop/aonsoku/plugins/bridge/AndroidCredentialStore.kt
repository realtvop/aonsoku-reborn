package github.realtvop.aonsoku.plugins.bridge

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

class AndroidCredentialStore(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun store(credentials: ServerCredentials) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(
            credentials.toStorageJson().toString().toByteArray(Charsets.UTF_8),
        )

        val payload = JSONObject().apply {
            put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            put("data", Base64.encodeToString(encrypted, Base64.NO_WRAP))
        }

        prefs.edit().putString(KEY_CREDENTIALS, payload.toString()).apply()
    }

    fun retrieve(): ServerCredentials? {
        val raw = prefs.getString(KEY_CREDENTIALS, null) ?: return null

        return try {
            val payload = JSONObject(raw)
            val iv = Base64.decode(payload.getString("iv"), Base64.NO_WRAP)
            val encrypted = Base64.decode(payload.getString("data"), Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv),
            )
            val decrypted = cipher.doFinal(encrypted).toString(Charsets.UTF_8)
            ServerCredentials.fromStorageJson(decrypted)
        } catch (e: Exception) {
            Log.e("AndroidCredentialStore", "Failed to decrypt credentials", e)
            null
        }
    }

    fun delete() {
        prefs.edit().remove(KEY_CREDENTIALS).apply()
    }

    fun exists(): Boolean = prefs.contains(KEY_CREDENTIALS) && retrieve() != null

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
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "aonsoku_native_bridge_credentials"
        private const val PREFERENCES_NAME = "aonsoku_native_bridge"
        private const val KEY_CREDENTIALS = "credentials"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH_BITS = 128
    }
}
