package github.realtvop.aonsoku.smoke

import android.security.keystore.KeyGenParameterSpec
import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyStoreSpi
import java.security.Provider
import java.security.SecureRandom
import java.security.Security
import java.security.cert.Certificate
import java.security.spec.AlgorithmParameterSpec
import java.util.Collections
import java.util.Date
import java.util.Enumeration
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.KeyGeneratorSpi
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

/**
 * In-memory stand-in for the `AndroidKeyStore` provider, which does not exist
 * on the JVM. It lets the real credential store encrypt and decrypt in tests.
 */
object FakeAndroidKeyStore {
    private const val NAME = "AndroidKeyStore"
    private val keys = ConcurrentHashMap<String, Key>()

    /** Registers the provider (once) and forgets every key. */
    fun install() {
        keys.clear()
        if (Security.getProvider(NAME) == null) Security.addProvider(FakeProvider())
    }

    class FakeProvider : Provider(NAME, 1.0, "In-memory AndroidKeyStore for JVM tests") {
        init {
            put("KeyStore.$NAME", FakeKeyStore::class.java.name)
            put("KeyGenerator.AES", FakeAesKeyGenerator::class.java.name)
        }
    }

    class FakeKeyStore : KeyStoreSpi() {
        override fun engineGetKey(alias: String, password: CharArray?): Key? = keys[alias]

        override fun engineContainsAlias(alias: String): Boolean = keys.containsKey(alias)

        override fun engineIsKeyEntry(alias: String): Boolean = keys.containsKey(alias)

        override fun engineAliases(): Enumeration<String> = Collections.enumeration(keys.keys)

        override fun engineSize(): Int = keys.size

        override fun engineDeleteEntry(alias: String) {
            keys.remove(alias)
        }

        override fun engineSetKeyEntry(
            alias: String,
            key: Key,
            password: CharArray?,
            chain: Array<out Certificate>?,
        ) {
            keys[alias] = key
        }

        override fun engineSetKeyEntry(alias: String, key: ByteArray, chain: Array<out Certificate>?) = Unit

        override fun engineSetCertificateEntry(alias: String, cert: Certificate) = Unit

        override fun engineGetCertificateChain(alias: String): Array<Certificate>? = null

        override fun engineGetCertificate(alias: String): Certificate? = null

        override fun engineGetCreationDate(alias: String): Date = Date()

        override fun engineIsCertificateEntry(alias: String): Boolean = false

        override fun engineGetCertificateAlias(cert: Certificate): String? = null

        override fun engineStore(stream: OutputStream?, password: CharArray?) = Unit

        override fun engineLoad(stream: InputStream?, password: CharArray?) = Unit
    }

    class FakeAesKeyGenerator : KeyGeneratorSpi() {
        private var alias: String? = null

        override fun engineInit(random: SecureRandom?) = Unit

        override fun engineInit(params: AlgorithmParameterSpec?, random: SecureRandom?) {
            alias = (params as? KeyGenParameterSpec)?.keystoreAlias
        }

        override fun engineInit(keySize: Int, random: SecureRandom?) = Unit

        override fun engineGenerateKey(): SecretKey {
            val key = SecretKeySpec(ByteArray(32).also(SecureRandom()::nextBytes), "AES")
            alias?.let { keys[it] = key }
            return key
        }
    }
}
