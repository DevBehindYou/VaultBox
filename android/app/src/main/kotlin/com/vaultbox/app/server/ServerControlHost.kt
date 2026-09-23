package com.vaultbox.app.server

import android.content.Context
import android.content.Intent
import com.vaultbox.app.pigeon.ServerConfigMessage
import com.vaultbox.app.pigeon.ServerControlApi
import com.vaultbox.app.pigeon.ServerStateMessage

/** UI-engine side of the server control contract: start/stop the service, read state. */
class ServerControlHost(
    private val context: Context,
    /** Runs on the UI thread just before the service starts (e.g. to ask for the notification permission). */
    private val beforeStart: () -> Unit = {},
) : ServerControlApi {

    override fun start() {
        beforeStart()
        // startForegroundService: the service must call startForeground() promptly
        // (it does, first thing in startServer()).
        context.startForegroundService(Intent(context, ServerForegroundService::class.java))
    }

    override fun stop() {
        context.stopService(Intent(context, ServerForegroundService::class.java))
    }

    override fun getState(): ServerStateMessage = ServerStateStore.current

    override fun getConfig(): ServerConfigMessage = ServerConfigStore(context).get()

    override fun setConfig(config: ServerConfigMessage) = ServerConfigStore(context).set(config)

    override fun getTlsFingerprint(): String = TlsIdentityStore(context).loadOrCreate().sha256Fingerprint
}
