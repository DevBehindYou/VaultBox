package com.vaultbox.app

import android.content.Intent
import com.vaultbox.app.pigeon.AndroidStorageApi
import com.vaultbox.app.storage.ActivityDocumentPickerLauncher
import com.vaultbox.app.storage.ActivityTreePickerLauncher
import com.vaultbox.app.storage.SafStorageHostApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val treePicker = ActivityTreePickerLauncher()
    private val documentPicker = ActivityDocumentPickerLauncher()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        treePicker.bind { intent -> startActivityForResult(intent, REQUEST_OPEN_TREE) }
        documentPicker.bind { intent -> startActivityForResult(intent, REQUEST_PICK_DOCUMENTS) }
        AndroidStorageApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            SafStorageHostApi(applicationContext, treePicker, documentPicker),
        )
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
    }
}
