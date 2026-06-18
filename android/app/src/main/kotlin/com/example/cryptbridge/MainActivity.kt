package com.example.cryptbridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.cryptbridge/engine"
    private val PICK_CONTAINER_REQUEST = 1001
    private var pendingFlutterResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "pickContainer") {
                pendingResultCheck(result)
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                startActivityForResult(intent, PICK_CONTAINER_REQUEST)

            } else if (call.method == "unlockContainer") {
                val uriString = call.argument<String>("filePath")
                val password = call.argument<String>("password")
                val pim = call.argument<Int>("pim") ?: 0

                if (uriString != null && password != null) {
                    Thread {
                        try {
                            // Find an available slot (0-3)
                            val volId = VeraCryptSession.getFreeVolumeId()
                            if (volId == null) {
                                runOnUiThread { result.error("LIMIT_REACHED", "Maximum 4 containers mounted", null) }
                                return@Thread
                            }

                            val uri = Uri.parse(uriString)
                            val pfd = contentResolver.openFileDescriptor(uri, "r") ?: throw Exception("PFD Null")
                            val fd = pfd.detachFd()

                            // Pass the assigned volId to C++
                            val files = VeraCryptEngine.unlockAndListNative(fd, password, pim, volId)

                            runOnUiThread {
                                if (files != null) {
                                    // Save the multi-session map
                                    VeraCryptSession.activeSessions[volId] = ContainerSession(
                                        uri = uriString,
                                        password = password,
                                        pim = pim,
                                        volId = volId,
                                        cachedFilesList = files.toList()
                                    )

                                    // Notify OS of system sidebar additions!
                                    val rootsUri = DocumentsContract.buildRootsUri("com.example.cryptbridge.documents")
                                    contentResolver.notifyChange(rootsUri, null)

                                    result.success(files.toList())
                                } else {
                                    result.error("AUTH_FAIL", "Incorrect password", null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("C++_ERROR", e.message, null) }
                        }
                    }.start()
                }
            } else if (call.method == "lockContainer") {
                val uriString = call.argument<String>("filePath")
                if (uriString != null) {
                    val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                    if (volId != null) {
                        // 1. Tell C++ to unmount and clear keys for this volume!
                        VeraCryptEngine.lockNative(volId)

                        // 2. Remove from active Kotlin sessions
                        VeraCryptSession.removeSession(volId)

                        // 3. Notify Android file manager to remove the drive!
                        val rootsUri = DocumentsContract.buildRootsUri("com.example.cryptbridge.documents")
                        contentResolver.notifyChange(rootsUri, null)

                        result.success(true)
                    } else {
                        result.success(false)
                    }
                } else {
                    result.error("INVALID_ARGS", "Path required to lock", null)
                }
            } else if (call.method == "decryptFile") {
                val uriString = call.argument<String>("filePath")
                val password = call.argument<String>("password")
                val pim = call.argument<Int>("pim") ?: 0
                val fileName = call.argument<String>("fileName")
                val destPath = call.argument<String>("destPath")

                if (uriString != null && password != null && fileName != null && destPath != null) {
                    Thread {
                        try {
                            val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                            val uri = Uri.parse(uriString)
                            val pfd = contentResolver.openFileDescriptor(uri, "r") ?: throw Exception("PFD Null")
                            val fd = pfd.detachFd()

                            val success = VeraCryptEngine.unlockAndExtractNative(fd, password, pim, fileName, destPath, volId)
                            runOnUiThread { result.success(success) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("C++_CRASH", e.message, null) }
                        }
                    }.start()
                }
            }
        }
    }

    private fun pendingResultCheck(result: MethodChannel.Result) {
        pendingFlutterResult?.error("PICK_CANCELLED", "Another picking operation started", null)
        pendingFlutterResult = result
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_CONTAINER_REQUEST) {
            val result = pendingFlutterResult ?: return
            pendingFlutterResult = null

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri: Uri = data.data!!
                val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                contentResolver.takePersistableUriPermission(uri, takeFlags)
                result.success(uri.toString())
            } else {
                result.success(null)
            }
        }
    }
}