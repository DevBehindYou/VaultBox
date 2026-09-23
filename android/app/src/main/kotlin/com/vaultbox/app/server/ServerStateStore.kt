package com.vaultbox.app.server

import com.vaultbox.app.pigeon.ServerRunStateMessage
import com.vaultbox.app.pigeon.ServerStateMessage
import java.util.concurrent.CopyOnWriteArraySet

/**
 * The single source of truth for the server's state, owned by native code so it
 * outlives any Activity/Flutter UI (ADR-006: the Foreground Service, not the
 * UI, owns the server lifecycle). The service writes it; whichever UI engine is
 * attached listens and pushes it to Dart.
 */
object ServerStateStore {
    @Volatile
    var current: ServerStateMessage = ServerStateMessage(state = ServerRunStateMessage.STOPPED)
        private set

    private val listeners = CopyOnWriteArraySet<(ServerStateMessage) -> Unit>()

    fun update(state: ServerStateMessage) {
        current = state
        for (listener in listeners) listener(state)
    }

    fun addListener(listener: (ServerStateMessage) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (ServerStateMessage) -> Unit) {
        listeners.remove(listener)
    }
}
