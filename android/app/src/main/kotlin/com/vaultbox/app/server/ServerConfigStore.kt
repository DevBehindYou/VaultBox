package com.vaultbox.app.server

import android.content.Context
import com.vaultbox.app.pigeon.ServerConfigMessage

/**
 * Persisted server settings, shared by the UI engine (which edits them) and the
 * service's headless engine (which reads them at start). Native owns them so
 * the server can start with no UI running.
 *
 * Safe defaults: network access OFF (loopback only), HTTPS on (8443), plain
 * HTTP OFF (8080). HTTP sends passwords in clear text on the network, so it is
 * always an explicit opt-in.
 */
class ServerConfigStore(context: Context) {
    private val prefs = context.getSharedPreferences("vaultbox_server", Context.MODE_PRIVATE)

    fun get(): ServerConfigMessage = ServerConfigMessage(
        allowNetworkAccess = prefs.getBoolean(KEY_NETWORK, false),
        port = prefs.getInt(KEY_PORT, DEFAULT_HTTPS_PORT).toLong(),
        httpsEnabled = prefs.getBoolean(KEY_HTTPS, true),
        httpEnabled = prefs.getBoolean(KEY_HTTP, false),
        httpPort = prefs.getInt(KEY_HTTP_PORT, DEFAULT_HTTP_PORT).toLong(),
    )

    fun set(config: ServerConfigMessage) {
        val httpsPort = (config.port ?: DEFAULT_HTTPS_PORT.toLong()).toInt()
        val httpPort = (config.httpPort ?: DEFAULT_HTTP_PORT.toLong()).toInt()
        val https = config.httpsEnabled ?: true
        val http = config.httpEnabled ?: false

        require(httpsPort in 1024..65535) { "HTTPS port must be between 1024 and 65535" }
        require(httpPort in 1024..65535) { "HTTP port must be between 1024 and 65535" }
        require(https || http) { "Turn on at least one of HTTPS and HTTP" }
        require(!(https && http && httpsPort == httpPort)) { "HTTPS and HTTP need different ports" }

        prefs.edit()
            .putBoolean(KEY_NETWORK, config.allowNetworkAccess == true)
            .putInt(KEY_PORT, httpsPort)
            .putBoolean(KEY_HTTPS, https)
            .putBoolean(KEY_HTTP, http)
            .putInt(KEY_HTTP_PORT, httpPort)
            .apply()
    }

    private companion object {
        const val KEY_NETWORK = "allow_network_access"
        const val KEY_PORT = "port"
        const val KEY_HTTPS = "https_enabled"
        const val KEY_HTTP = "http_enabled"
        const val KEY_HTTP_PORT = "http_port"
        const val DEFAULT_HTTPS_PORT = 8443
        const val DEFAULT_HTTP_PORT = 8080
    }
}
