package com.vaultbox.app.server

import android.content.Context
import com.vaultbox.app.pigeon.ServerConfigMessage

/**
 * Persisted server settings, shared by the UI engine (which edits them) and the
 * service's headless engine (which reads them at start). Native owns them so
 * the server can start with no UI running.
 *
 * Safe defaults: network access OFF (loopback only), port 8443.
 */
class ServerConfigStore(context: Context) {
    private val prefs = context.getSharedPreferences("vaultbox_server", Context.MODE_PRIVATE)

    fun get(): ServerConfigMessage = ServerConfigMessage(
        allowNetworkAccess = prefs.getBoolean(KEY_NETWORK, false),
        port = prefs.getInt(KEY_PORT, DEFAULT_PORT).toLong(),
    )

    fun set(config: ServerConfigMessage) {
        val port = (config.port ?: DEFAULT_PORT.toLong()).toInt()
        require(port in 1024..65535) { "Port must be between 1024 and 65535" }
        prefs.edit()
            .putBoolean(KEY_NETWORK, config.allowNetworkAccess == true)
            .putInt(KEY_PORT, port)
            .apply()
    }

    private companion object {
        const val KEY_NETWORK = "allow_network_access"
        const val KEY_PORT = "port"
        const val DEFAULT_PORT = 8443
    }
}
