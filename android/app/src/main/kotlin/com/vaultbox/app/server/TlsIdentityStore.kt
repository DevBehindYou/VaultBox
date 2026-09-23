package com.vaultbox.app.server

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.Date
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.security.auth.x500.X500Principal
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.ExtendedKeyUsage
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.x509.KeyPurposeId
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder

/**
 * The server's TLS identity: a self-signed EC P-256 certificate and its private key.
 *
 * - The certificate is stored as plain PEM (it is public).
 * - The PRIVATE KEY is stored only ENCRYPTED, with an AES-256-GCM key that lives
 *   in the Android Keystore (hardware-backed where the device has it) and never
 *   leaves it. Copying the app's files off the phone yields ciphertext.
 * - If the Keystore key is lost (e.g. after a factory reset restore) the pair
 *   can't be decrypted and is regenerated — clients must re-trust the new
 *   fingerprint, which is the correct, visible outcome.
 *
 * STATUS: compiles in CI; never run on a device before this commit.
 */
class TlsIdentityStore(private val context: Context) {

    data class Identity(
        val certificatePem: String,
        val privateKeyPem: String,
        val sha256Fingerprint: String,
    )

    @Synchronized
    fun loadOrCreate(): Identity {
        val certFile = File(directory(), CERT_FILE)
        val keyFile = File(directory(), KEY_FILE)
        if (certFile.exists() && keyFile.exists()) {
            try {
                val certPem = certFile.readText()
                val keyPem = String(decrypt(keyFile.readBytes()), Charsets.UTF_8)
                return Identity(certPem, keyPem, fingerprintOf(certPem))
            } catch (e: Exception) {
                // Corrupt file or lost Keystore key: fall through and regenerate.
            }
        }
        return generate(certFile, keyFile)
    }

    private fun directory(): File = File(context.filesDir, "tls").apply { mkdirs() }

    private fun generate(certFile: File, keyFile: File): Identity {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()

        val subject = X500Principal("CN=VaultBox,O=VaultBox personal server")
        val now = System.currentTimeMillis()
        val serial = BigInteger(64, SecureRandom()).add(BigInteger.ONE)
        val builder = JcaX509v3CertificateBuilder(
            subject,
            serial,
            Date(now - DAY_MS), // tolerate small clock skew on the client
            Date(now + VALIDITY_DAYS * DAY_MS),
            subject,
            pair.public,
        )
        builder.addExtension(Extension.basicConstraints, true, BasicConstraints(false))
        builder.addExtension(Extension.keyUsage, true, KeyUsage(KeyUsage.digitalSignature))
        builder.addExtension(
            Extension.extendedKeyUsage,
            false,
            ExtendedKeyUsage(KeyPurposeId.id_kp_serverAuth),
        )
        builder.addExtension(
            Extension.subjectAlternativeName,
            false,
            GeneralNames(
                arrayOf(
                    GeneralName(GeneralName.dNSName, "localhost"),
                    GeneralName(GeneralName.iPAddress, "127.0.0.1"),
                ),
            ),
        )

        // No provider name on purpose: use the platform's default JCA provider and
        // do NOT register BouncyCastle globally (it would clash with Android's own).
        val signer = JcaContentSignerBuilder("SHA256withECDSA").build(pair.private)
        val certificate = JcaX509CertificateConverter().getCertificate(builder.build(signer))

        val certPem = pem("CERTIFICATE", certificate.encoded)
        val keyPem = pem("PRIVATE KEY", pair.private.encoded) // PKCS#8

        certFile.writeText(certPem)
        keyFile.writeBytes(encrypt(keyPem.toByteArray(Charsets.UTF_8)))
        return Identity(certPem, keyPem, fingerprintOf(certPem))
    }

    // --- Keystore-wrapped storage of the private key ---

    private fun wrapKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /** iv (12 bytes) || ciphertext+tag. */
    private fun encrypt(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        return cipher.iv + cipher.doFinal(plain)
    }

    private fun decrypt(blob: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob.copyOfRange(0, IV_BYTES)))
        return cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
    }

    // --- helpers ---

    private fun pem(type: String, der: ByteArray): String {
        val body = Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(der)
        return "-----BEGIN $type-----\n$body\n-----END $type-----\n"
    }

    /** SHA-256 of the certificate's DER, as upper-case colon-separated hex (what a browser shows). */
    private fun fingerprintOf(certPem: String): String {
        val base64 = certPem.lines().filter { !it.startsWith("-----") }.joinToString("")
        val der = Base64.getDecoder().decode(base64)
        return MessageDigest.getInstance("SHA-256").digest(der)
            .joinToString(":") { "%02X".format(it) }
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "vaultbox_tls_wrap"
        const val CERT_FILE = "server-cert.pem"
        const val KEY_FILE = "server-key.enc"
        const val IV_BYTES = 12
        const val DAY_MS = 24L * 60 * 60 * 1000
        const val VALIDITY_DAYS = 825L
    }
}
