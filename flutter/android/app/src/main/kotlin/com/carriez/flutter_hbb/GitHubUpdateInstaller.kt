package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Downloads only this fork's signed GitHub Release APK, verifies that it is an
 * update for this package signed by the same certificate, and opens Android's
 * normal package-installer confirmation. Android intentionally does not allow
 * a regular sideloaded app to silently install itself.
 */
class GitHubUpdateInstaller(private val activity: Activity) {
    companion object {
        private const val MAX_APK_BYTES = 250L * 1024L * 1024L
        private val RELEASE_APK_URL = Regex(
            """^https://github\.com/crashbandicode/rustdesk/releases/download/(\d+\.\d+\.\d+-\d+)/rustdesk-\1-aarch64\.apk$"""
        )
    }

    fun downloadAndPrompt(url: String, result: MethodChannel.Result) {
        if (!RELEASE_APK_URL.matches(url)) {
            result.error("invalid-update-url", "Update is not a signed fork release", null)
            return
        }
        thread(name = "rustdesk-github-updater") {
            try {
                val apk = download(url)
                verifyPackageAndSigner(apk)
                activity.runOnUiThread {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !activity.packageManager.canRequestPackageInstalls()
                    ) {
                        activity.startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:${activity.packageName}")
                            }
                        )
                        result.success(mapOf("status" to "permission-required"))
                    } else {
                        val contentUri = FileProvider.getUriForFile(
                            activity,
                            "${activity.packageName}.fileprovider",
                            apk
                        )
                        activity.startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(
                                    contentUri,
                                    "application/vnd.android.package-archive"
                                )
                                .addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                                )
                        )
                        result.success(mapOf("status" to "installer-started"))
                    }
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("update-failed", e.message ?: "Unable to install update", null)
                }
            }
        }
    }

    private fun download(url: String): File {
        val updateDir = File(activity.cacheDir, "updates")
        if (!updateDir.exists() && !updateDir.mkdirs()) {
            error("Unable to create update cache")
        }
        val destination = File(updateDir, "rustdesk-update.apk")
        val partial = File(updateDir, "rustdesk-update.apk.part")
        partial.delete()

        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            requestMethod = "GET"
        }
        try {
            connection.connect()
            check(connection.url.protocol == "https") { "Update download was redirected off HTTPS" }
            check(connection.responseCode in 200..299) {
                "Update download failed: HTTP ${connection.responseCode}"
            }
            val contentLength = connection.contentLengthLong
            check(contentLength in 1..MAX_APK_BYTES) { "Invalid update size" }

            var copied = 0L
            BufferedInputStream(connection.inputStream).use { input ->
                FileOutputStream(partial).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count == -1) break
                        copied += count
                        check(copied <= MAX_APK_BYTES) { "Update is too large" }
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            check(copied == contentLength) { "Incomplete update download" }
            if (destination.exists() && !destination.delete()) {
                error("Unable to replace previous update")
            }
            check(partial.renameTo(destination)) { "Unable to finalize update download" }
            return destination
        } catch (e: Exception) {
            partial.delete()
            throw e
        } finally {
            connection.disconnect()
        }
    }

    private fun verifyPackageAndSigner(apk: File) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val candidate = activity.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: error("Downloaded update is not an Android package")
        check(candidate.packageName == activity.packageName) { "Update package does not match RustDesk" }
        val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
        check(signingDigests(candidate).isNotEmpty()) { "Update has no signing certificate" }
        check(signingDigests(candidate) == signingDigests(installed)) {
            "Update signing certificate does not match the installed app"
        }
    }

    private fun signingDigests(packageInfo: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners ?: emptyArray()
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures ?: emptyArray()
        }
        return signatures.map { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }.toSet()
    }
}
