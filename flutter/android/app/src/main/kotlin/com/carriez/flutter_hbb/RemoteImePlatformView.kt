package com.carriez.flutter_hbb

import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Log
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.CompletionInfo
import android.view.inputmethod.CorrectionInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.TextAttribute
import android.widget.EditText
import androidx.annotation.RequiresApi
import androidx.core.view.ContentInfoCompat
import androidx.core.view.ViewCompat
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputContentInfoCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.concurrent.thread

private const val REMOTE_IME_VIEW_TYPE = "rustdesk/remote-ime"
private const val MAX_IMAGE_BYTES = 16 * 1024 * 1024
private const val LOG_TAG = "RemoteImePlatformView"

class RemoteImeViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        val initialText = params?.get("initialText") as? String ?: ""
        return RemoteImePlatformView(context, messenger, viewId, initialText)
    }

    companion object {
        const val VIEW_TYPE: String = REMOTE_IME_VIEW_TYPE
    }
}

private class RemoteImePlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    initialText: String
) : PlatformView {
    private val channel = MethodChannel(messenger, "$REMOTE_IME_VIEW_TYPE/$viewId")
    private val editText = RemoteImeEditText(context)
    @Volatile
    private var disposed = false

    init {
        editText.initialize(
            initialText,
            ::emitEditingState,
            ::handleRichContent,
            ::handleCommittedContent,
            ::handleClipboardImagePaste
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    editText.post {
                        if (!disposed) {
                            editText.requestFocus()
                            val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE)
                                as InputMethodManager
                            imm.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
                        }
                    }
                    result.success(true)
                }

                "hide" -> {
                    val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE)
                        as InputMethodManager
                    imm.hideSoftInputFromWindow(editText.windowToken, 0)
                    editText.clearFocus()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = editText

    override fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        val imm = editText.context.getSystemService(Context.INPUT_METHOD_SERVICE)
            as InputMethodManager
        imm.hideSoftInputFromWindow(editText.windowToken, 0)
        editText.clearFocus()
        editText.dispose()
    }

    private fun emitEditingState() {
        if (disposed) return
        val editable = editText.editableText ?: return
        val composingStart = BaseInputConnection.getComposingSpanStart(editable)
        val composingEnd = BaseInputConnection.getComposingSpanEnd(editable)
        channel.invokeMethod(
            "editing_state",
            mapOf(
                "text" to editable.toString(),
                "selectionBase" to editText.selectionStart,
                "selectionExtent" to editText.selectionEnd,
                "composingBase" to composingStart,
                "composingExtent" to composingEnd
            )
        )
    }

    private fun handleRichContent(payload: ContentInfoCompat): ContentInfoCompat? {
        val clip = payload.clip
        if (clip.itemCount == 0) return payload
        val item = clip.getItemAt(0)
        val uri = item.uri ?: item.intent?.data ?: return payload
        val advertisedMimeTypes = (0 until clip.description.mimeTypeCount)
            .map(clip.description::getMimeType)
        val resolvedMimeType = selectImageMimeType(resolveMimeType(uri), advertisedMimeTypes)
        if (resolvedMimeType == null) {
            channel.invokeMethod(
                "image_error",
                mapOf("message" to "Gboard did not provide a supported image type")
            )
            return null
        }

        scheduleImageRead(uri, resolvedMimeType, "receive-content", retain = {
            // Retain the ContentInfoCompat object until the asynchronous read finishes.
            payload.clip.itemCount
        })
        return null
    }

    private fun handleCommittedContent(
        content: InputContentInfoCompat,
        flags: Int,
        opts: Bundle?
    ): Boolean {
        val advertisedMimeTypes = (0 until content.description.mimeTypeCount)
            .map(content.description::getMimeType)
        val resolvedMimeType = selectImageMimeType(
            resolveMimeType(content.contentUri),
            advertisedMimeTypes
        ) ?: return false

        val permissionRequested =
            flags and InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION != 0
        if (permissionRequested) {
            try {
                content.requestPermission()
            } catch (error: Exception) {
                Log.w(LOG_TAG, "Unable to acquire IME content permission", error)
                emitImageError("Gboard did not grant access to the pasted image")
                return true
            }
        }

        // Keep both the content object and optional metadata alive while its temporary URI
        // permission is in use. releasePermission() must run after, not before, the read.
        scheduleImageRead(content.contentUri, resolvedMimeType, "commit-content", {
            content.description.mimeTypeCount
            opts?.size()
        }) {
            if (permissionRequested) {
                try {
                    content.releasePermission()
                } catch (error: Exception) {
                    Log.w(LOG_TAG, "Unable to release IME content permission", error)
                }
            }
        }
        return true
    }

    private fun handleClipboardImagePaste(): Boolean {
        val clipboard = MainActivity.rdClipboardManager ?: return false
        if (!clipboard.primaryClipHasImage()) return false

        thread(name = "rustdesk-ime-clipboard-image") {
            val image = try {
                clipboard.readPrimaryImage(MAX_IMAGE_BYTES)
            } catch (error: Exception) {
                Log.w(LOG_TAG, "Unable to read clipboard image", error)
                null
            }
            deliverImage(image, "Unable to read the pasted clipboard image")
        }
        return true
    }

    private fun scheduleImageRead(
        uri: android.net.Uri,
        mimeType: String,
        source: String,
        retain: () -> Unit,
        finished: () -> Unit = {}
    ) {
        thread(name = "rustdesk-ime-image") {
            val image = try {
                retain()
                MainActivity.rdClipboardManager?.readImageUri(
                    uri,
                    mimeType,
                    MAX_IMAGE_BYTES
                )
            } catch (error: Exception) {
                Log.w(LOG_TAG, "Unable to read $source image", error)
                null
            } finally {
                finished()
            }
            deliverImage(image, "Unable to read Gboard image content")
        }
    }

    private fun deliverImage(image: Map<String, Any>?, errorMessage: String) {
        editText.post {
            if (!disposed) {
                if (image == null) {
                    emitImageError(errorMessage)
                } else {
                    channel.invokeMethod("image_content", image)
                }
            }
        }
    }

    private fun emitImageError(message: String) {
        if (!disposed) {
            channel.invokeMethod("image_error", mapOf("message" to message))
        }
    }

    private fun resolveMimeType(uri: android.net.Uri): String? = try {
        editText.context.contentResolver.getType(uri)
    } catch (error: Exception) {
        Log.w(LOG_TAG, "Unable to resolve image MIME type", error)
        null
    }
}

private class RemoteImeEditText(context: Context) : EditText(context) {
    private var stateChanged: (() -> Unit)? = null
    private var contentReceived: ((ContentInfoCompat) -> ContentInfoCompat?)? = null
    private var contentCommitted: ((InputContentInfoCompat, Int, Bundle?) -> Boolean)? = null
    private var clipboardImagePaste: (() -> Boolean)? = null
    private var suppressEvents = false
    private val emitRunnable = Runnable {
        if (!suppressEvents) stateChanged?.invoke()
    }
    private val stateDispatch = ImeStateDispatchCoordinator(
        cancelPending = { removeCallbacks(emitRunnable) },
        postPending = { post(emitRunnable) },
        emitNow = {
            if (!suppressEvents) stateChanged?.invoke()
        }
    )

    fun initialize(
        initialText: String,
        onStateChanged: () -> Unit,
        onContentReceived: (ContentInfoCompat) -> ContentInfoCompat?,
        onContentCommitted: (InputContentInfoCompat, Int, Bundle?) -> Boolean,
        onClipboardImagePaste: () -> Boolean
    ) {
        stateChanged = onStateChanged
        contentReceived = onContentReceived
        contentCommitted = onContentCommitted
        clipboardImagePaste = onClipboardImagePaste
        setTextColor(Color.TRANSPARENT)
        setHintTextColor(Color.TRANSPARENT)
        setBackgroundColor(Color.TRANSPARENT)
        background = null
        isCursorVisible = false
        isSingleLine = false
        setPadding(0, 0, 0, 0)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or
            InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI

        suppressEvents = true
        setText(initialText)
        setSelection(text.length)
        suppressEvents = false

        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) =
                Unit

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) =
                Unit

            override fun afterTextChanged(s: Editable?) {
                scheduleStateChanged()
            }
        })

        ViewCompat.setOnReceiveContentListener(this, CONTENT_MIME_TYPES) { _, payload ->
            val handler = contentReceived
            if (handler == null) payload else handler(payload)
        }
    }

    fun dispose() {
        removeCallbacks(emitRunnable)
        stateChanged = null
        contentReceived = null
        contentCommitted = null
        clipboardImagePaste = null
        ViewCompat.setOnReceiveContentListener(this, null, null)
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        scheduleStateChanged()
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val base = super.onCreateInputConnection(outAttrs) ?: return null
        EditorInfoCompat.setContentMimeTypes(outAttrs, CONTENT_MIME_TYPES)
        @Suppress("DEPRECATION")
        val richContent = InputConnectionCompat.createWrapper(base, outAttrs) {
                inputContentInfo, flags, opts ->
            contentCommitted?.invoke(inputContentInfo, flags, opts) ?: false
        }
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                Api34StateReportingInputConnection(richContent)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                Api33StateReportingInputConnection(richContent)
            else -> StateReportingInputConnection(richContent)
        }
    }

    private fun scheduleStateChanged() {
        if (suppressEvents) return
        stateDispatch.schedule()
    }

    private open inner class StateReportingInputConnection(target: InputConnection) :
        InputConnectionWrapper(target, false) {
        protected fun report(result: Boolean): Boolean {
            scheduleStateChanged()
            return result
        }

        protected fun reportCommitBoundary(result: Boolean): Boolean {
            // TextWatcher schedules a provisional callback from inside the
            // wrapped operation. Emit the final state synchronously before a
            // following setComposingText call can replace that callback.
            return stateDispatch.commitBoundary(result)
        }

        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean =
            reportCommitBoundary(super.commitText(text, newCursorPosition))

        override fun commitCompletion(text: CompletionInfo?): Boolean =
            reportCommitBoundary(super.commitCompletion(text))

        override fun commitCorrection(correctionInfo: CorrectionInfo?): Boolean =
            reportCommitBoundary(super.commitCorrection(correctionInfo))

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean =
            report(super.setComposingText(text, newCursorPosition))

        override fun setComposingRegion(start: Int, end: Int): Boolean =
            report(super.setComposingRegion(start, end))

        override fun finishComposingText(): Boolean =
            reportCommitBoundary(super.finishComposingText())

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
            report(super.deleteSurroundingText(beforeLength, afterLength))

        override fun deleteSurroundingTextInCodePoints(
            beforeLength: Int,
            afterLength: Int
        ): Boolean = report(super.deleteSurroundingTextInCodePoints(beforeLength, afterLength))

        override fun setSelection(start: Int, end: Int): Boolean =
            report(super.setSelection(start, end))

        override fun performContextMenuAction(id: Int): Boolean {
            if (id == android.R.id.paste && clipboardImagePaste?.invoke() == true) {
                return report(true)
            }
            return report(super.performContextMenuAction(id))
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private open inner class Api33StateReportingInputConnection(target: InputConnection) :
        StateReportingInputConnection(target) {
        override fun commitText(
            text: CharSequence,
            newCursorPosition: Int,
            textAttribute: TextAttribute?
        ): Boolean = reportCommitBoundary(
            super.commitText(text, newCursorPosition, textAttribute)
        )

        override fun setComposingText(
            text: CharSequence,
            newCursorPosition: Int,
            textAttribute: TextAttribute?
        ): Boolean = report(
            super.setComposingText(text, newCursorPosition, textAttribute)
        )

        override fun setComposingRegion(
            start: Int,
            end: Int,
            textAttribute: TextAttribute?
        ): Boolean = report(super.setComposingRegion(start, end, textAttribute))
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private inner class Api34StateReportingInputConnection(target: InputConnection) :
        Api33StateReportingInputConnection(target) {
        override fun replaceText(
            start: Int,
            end: Int,
            text: CharSequence,
            newCursorPosition: Int,
            textAttribute: TextAttribute?
        ): Boolean = reportCommitBoundary(
            super.replaceText(start, end, text, newCursorPosition, textAttribute)
        )
    }

    companion object {
        private val CONTENT_MIME_TYPES = arrayOf(
            "image/*",
            "image/png",
            "image/bmp",
            "image/jpg",
            "image/tiff",
            "image/gif",
            "image/jpeg",
            "image/webp",
            "image/heic",
            "image/heif",
            "image/avif"
        )
    }
}
