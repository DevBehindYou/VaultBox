package com.vaultbox.app.server

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.vaultbox.app.MainActivity
import com.vaultbox.app.pigeon.ServerRunStateMessage
import com.vaultbox.app.pigeon.ServerRuntimeApi
import com.vaultbox.app.pigeon.ServerStateMessage
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Hosts the server (ADR-006): a foreground service that owns a HEADLESS Flutter
 * engine running the Dart entrypoint `serverMain`, so the server keeps running
 * when the Activity/UI is gone.
 *
 * STATUS: compiles in CI. NEVER RUN ON A DEVICE. Known gaps: no runtime prompt
 * for POST_NOTIFICATIONS (Android 13+), START_NOT_STICKY (an OEM kill is not
 * auto-recovered — deliberate until the Phase 10 OEM hardening), the service
 * type is `specialUse` (no Android 15 six-hour cap; needs a Play declaration if
 * ever published there).
 */
class ServerForegroundService : Service() {
    private var engine: FlutterEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startServer()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engine?.destroy()
        engine = null
        // A failure must stay visible: don't overwrite FAILED with STOPPED.
        if (ServerStateStore.current.state != ServerRunStateMessage.FAILED) {
            ServerStateStore.update(ServerStateMessage(state = ServerRunStateMessage.STOPPED))
        }
        super.onDestroy()
    }

    private fun startServer() {
        if (engine != null) return // already running

        ensureChannel()
        // Must be called promptly after startForegroundService(), before anything slow.
        publish(ServerStateMessage(state = ServerRunStateMessage.STARTING), promote = true)

        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val newEngine = FlutterEngine(applicationContext)
            ServerRuntimeApi.setUp(newEngine.dartExecutor.binaryMessenger, RuntimeHost())
            newEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    ENTRYPOINT_LIBRARY,
                    ENTRYPOINT_FUNCTION,
                ),
            )
            engine = newEngine
        } catch (t: Throwable) {
            publish(
                ServerStateMessage(
                    state = ServerRunStateMessage.FAILED,
                    detail = t.message ?: t.javaClass.simpleName,
                ),
            )
            stopSelf()
        }
    }

    /** Called (on the platform thread) by the headless Dart runtime. */
    private inner class RuntimeHost : ServerRuntimeApi {
        override fun reportState(state: ServerStateMessage) {
            publish(state)
        }
    }

    private fun publish(state: ServerStateMessage, promote: Boolean = false) {
        ServerStateStore.update(state)
        val notification = buildNotification(describe(state))
        if (promote) {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        }
    }

    private fun describe(state: ServerStateMessage): String = when (state.state) {
        ServerRunStateMessage.RUNNING -> "Running" + (state.endpoint?.let { " · $it" } ?: "")
        ServerRunStateMessage.FAILED -> "Failed: ${state.detail ?: "unknown error"}"
        else -> "Starting…"
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "VaultBox server", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    private fun buildNotification(text: String): Notification {
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, ServerForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val open = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("VaultBox server")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }

    companion object {
        const val ACTION_STOP = "com.vaultbox.app.server.STOP"
        private const val CHANNEL_ID = "vaultbox_server"
        private const val NOTIFICATION_ID = 1001
        private const val ENTRYPOINT_LIBRARY = "package:vaultbox/server/server_main.dart"
        private const val ENTRYPOINT_FUNCTION = "serverMain"
    }
}
