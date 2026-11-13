package dev.apnum.android.link

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import uniffi.apnum_link.generateKeypair
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class Identity(val deviceId: String, val name: String, val privateKey: ByteArray, val publicKey: ByteArray)

class PairedMac(val id: String, val name: String, val publicKey: ByteArray, val host: String, val port: Int)

interface MacStore {
    fun load(): PairedMac?
    fun save(mac: PairedMac)
    fun clear()
}

/**
 * Device identity and the paired Mac, in private preferences. The static private key is encrypted
 * with an AES-GCM key that lives in the Android Keystore and never leaves it.
 */
class PrefsStore(context: Context) : MacStore {
    private val prefs = context.applicationContext.getSharedPreferences("apnum_link", Context.MODE_PRIVATE)

    @Synchronized
    fun identity(): Identity {
        val id = prefs.getString("deviceId", null)
        val pub = prefs.getString("pub", null)
        val enc = prefs.getString("priv", null)
        val name = prefs.getString("name", null) ?: defaultName()
        if (id != null && pub != null && enc != null) {
            val priv = runCatching { decrypt(enc) }.getOrNull()
            if (priv != null) return Identity(id, name, priv, b64d(pub))
        }
        val pair = generateKeypair()
        val fresh = Identity(UUID.randomUUID().toString(), name, pair.privateKey, pair.publicKey)
        prefs.edit().putString("deviceId", fresh.deviceId).putString("name", name)
            .putString("pub", b64(fresh.publicKey)).putString("priv", encrypt(fresh.privateKey)).apply()
        return fresh
    }

    override fun load(): PairedMac? {
        val id = prefs.getString("mac.id", null) ?: return null
        val pk = prefs.getString("mac.pk", null) ?: return null
        return PairedMac(id, prefs.getString("mac.name", "Mac") ?: "Mac", b64d(pk), prefs.getString("mac.host", "") ?: "", prefs.getInt("mac.port", 47800))
    }

    override fun save(mac: PairedMac) {
        prefs.edit().putString("mac.id", mac.id).putString("mac.name", mac.name).putString("mac.pk", b64(mac.publicKey))
            .putString("mac.host", mac.host).putInt("mac.port", mac.port).apply()
    }

    override fun clear() {
        prefs.edit().remove("mac.id").remove("mac.name").remove("mac.pk").remove("mac.host").remove("mac.port").apply()
    }

    private fun defaultName(): String = Build.MODEL.lowercase().ifBlank { "android phone" }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build()
        )
        return gen.generateKey()
    }

    private fun encrypt(plain: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        return b64(c.iv) + ":" + b64(c.doFinal(plain))
    }

    private fun decrypt(text: String): ByteArray {
        val (iv, ct) = text.split(":").map(::b64d)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv)) }
        return c.doFinal(ct)
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun b64d(s: String) = Base64.decode(s, Base64.NO_WRAP)

    private companion object {
        const val ALIAS = "apnum_identity"
    }
}
