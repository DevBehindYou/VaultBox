package com.vaultbox.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.vaultbox.app.pigeon.AndroidStorageApi
import com.vaultbox.app.pigeon.ServerControlApi
import com.vaultbox.app.pigeon.ServerStateListener
import com.vaultbox.app.pigeon.ServerStateMessage
import com.vaultbox.app.server.ServerControlHost
import com.vaultbox.app.server.ServerStateStore
import com.vaultbox.app.storage.ActivityDocumentPickerLauncher
import com.vaultbox.app.storage.ActivityTreePickerLauncher
import com.vaultbox.app.storage.SafStorageHostApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private val treePicker = ActivityTreePickerLauncher()
    private val documentPicker = ActivityDocumentPickerLauncher()
    private var stateListener: ((ServerStateMessage) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Storage / pickers
        treePicker.bind { intent -> startActivityForResult(intent, REQUEST_OPEN_TREE) }
        documentPicker.bind { intent -> startActivityForResult(intent, REQUEST_PICK_DOCUMENTS) }
        AndroidStorageApi.setUp(messenger, SafStorageHostApi(applicationContext, treePicker, documentPicker))

        // Server host: this (UI) engine controls the service and receives its state.
        ServerControlApi.setUp(
            messenger,
            ServerControlHost(applicationContext) { requestNotificationPermissionIfNeeded() },
        )
        val dartListener = ServerStateListener(messenger)
        val listener: (ServerStateMessage) -> Unit = { state ->
            // Pigeon 29 generates FlutterApi calls as `suspend fun`; launch on Main
            // (the platform thread, which is where they must be made).
            CoroutineScope(Dispatchers.Main).launch {
                try {
                    dartListener.onStateChanged(state)
                } catch (e: Exception) {
                    // The UI engine may be gone or mid-teardown; the service must not care.
                }
            }
        }
        stateListener?.let { ServerStateStore.removeListener(it) }
        stateListener = listener
        ServerStateStore.addListener(listener)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The service outlives this Activity; only detach OUR listener.
        stateListener?.let { ServerStateStore.removeListener(it) }
        stateListener = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Android 13+ hides a foreground service's notification until this runtime
     * permission is granted (seen on a real phone: granted=false). Non-blocking:
     * the service starts regardless; the notification appears once allowed.
     */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQUEST_OPEN_TREE -> {
                treePicker.onResult(if (resultCode == RESULT_OK) data?.data else null)
                return
            }
            REQUEST_PICK_DOCUMENTS -> {
                documentPicker.onResult(if (resultCode == RESULT_OK) data else null)
                return
            }
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private companion object {
        const val REQUEST_OPEN_TREE = 0x5AF
        const val REQUEST_PICK_DOCUMENTS = 0x5B0
        const val REQUEST_NOTIFICATIONS = 0x5B1
    }
}
