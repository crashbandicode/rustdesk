package com.carriez.flutter_hbb

import android.content.ClipDescription
import android.content.Context
import android.graphics.Color
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.core.view.ContentInfoCompat
import androidx.core.view.ViewCompat
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.concurrent.thread

private const val REMOTE_IME_VIEW_TYPE = "rustdesk/remote-ime"
private const val MAX_IMAGE_BYTES = 16 * 1024 * 1024

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
        editText.initialize(initialText, ::emitEditingState, ::handleRichContent)
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
        var mimeType: String? = null
        for (i in 0 until clip.description.mimeTypeCount) {
            val candidate = clip.description.getMimeType(i)
            if (ClipDescription.compareMimeTypes(candidate, "image/*")) {
                mimeType = candidate
                break
            }
        }
        val resolvedMimeType = editText.context.contentResolver.getType(uri)
            ?: mimeType
            ?: return payload
        if (!ClipDescription.compareMimeTypes(resolvedMimeType, "image/*")) {
            return payload
        }

        // Retain the ContentInfoCompat object in this closure so Android keeps URI read
        // permission alive until the background read is complete.
        val retainedPayload = payload
        thread(name = "rustdesk-ime-image") {
            val image = try {
                retainedPayload.clip.itemCount // keep the permission-holding payload referenced
                MainActivity.rdClipboardManager?.readImageUri(
                    uri,
                    resolvedMimeType,
                    MAX_IMAGE_BYTES
                )
            } catch (_: Exception) {
                null
            }
            editText.post {
                if (!disposed) {
                    if (image == null) {
                        channel.invokeMethod(
                            "image_error",
                            mapOf("message" to "Unable to read Gboard image content")
                        )
                    } else {
                        channel.invokeMethod("image_content", image)
                    }
                }
            }
        }
        return null
    }
}

private class RemoteImeEditText(context: Context) : EditText(context) {
    private var stateChanged: (() -> Unit)? = null
    private var contentReceived: ((ContentInfoCompat) -> ContentInfoCompat?)? = null
    private var suppressEvents = false
    private val emitRunnable = Runnable {
        if (!suppressEvents) stateChanged?.invoke()
    }

    fun initialize(
        initialText: String,
        onStateChanged: () -> Unit,
        onContentReceived: (ContentInfoCompat) -> ContentInfoCompat?
    ) {
        stateChanged = onStateChanged
        contentReceived = onContentReceived
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
            contentReceived?.invoke(payload) ?: payload
        }
    }

    fun dispose() {
        removeCallbacks(emitRunnable)
        stateChanged = null
        contentReceived = null
        ViewCompat.setOnReceiveContentListener(this, null, null)
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        scheduleStateChanged()
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val base = super.onCreateInputConnection(outAttrs) ?: return null
        EditorInfoCompat.setContentMimeTypes(outAttrs, CONTENT_MIME_TYPES)
        val richContent = InputConnectionCompat.createWrapper(this, base, outAttrs)
        return StateReportingInputConnection(richContent)
    }

    private fun scheduleStateChanged() {
        if (suppressEvents) return
        removeCallbacks(emitRunnable)
        post(emitRunnable)
    }

    private inner class StateReportingInputConnection(target: InputConnection) :
        InputConnectionWrapper(target, false) {
        private fun report(result: Boolean): Boolean {
            scheduleStateChanged()
            return result
        }

        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean =
            report(super.commitText(text, newCursorPosition))

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean =
            report(super.setComposingText(text, newCursorPosition))

        override fun setComposingRegion(start: Int, end: Int): Boolean =
            report(super.setComposingRegion(start, end))

        override fun finishComposingText(): Boolean = report(super.finishComposingText())

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
            report(super.deleteSurroundingText(beforeLength, afterLength))

        override fun deleteSurroundingTextInCodePoints(
            beforeLength: Int,
            afterLength: Int
        ): Boolean = report(super.deleteSurroundingTextInCodePoints(beforeLength, afterLength))

        override fun setSelection(start: Int, end: Int): Boolean =
            report(super.setSelection(start, end))

        override fun performContextMenuAction(id: Int): Boolean =
            report(super.performContextMenuAction(id))
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
