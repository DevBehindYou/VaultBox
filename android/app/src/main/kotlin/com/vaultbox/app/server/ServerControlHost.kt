package com.vaultbox.app.server

import android.content.Context
import android.content.Intent
import com.vaultbox.app.pigeon.ServerControlApi
import com.vaultbox.app.pigeon.ServerStateMessage

/** UI-engine side of the server control contract: start/stop the service, read state. */
class ServerControlHost(private val context: Context) : ServerControlApi {

    override fun start() {
        // startForegroundService: the service must call startForeground() promptly
        // (it does, first thing in startServer()).
        context.startForegroundService(Intent(context, ServerForegroundService::class.java))
    }

    override fun stop() {
        context.stopService(Intent(context, ServerForegroundService::class.java))
    }

    override fun getState(): ServerStateMessage = ServerStateStore.current
}
