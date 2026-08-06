package com.carriez.flutter_hbb

import java.util.Locale

/**
 * Selects a trustworthy image MIME type for Android clipboard and IME content.
 *
 * Some content providers expose a valid image in ClipDescription but return
 * application/octet-stream from ContentResolver.getType(). Prefer a resolved
 * image type when available, then fall back to the IME/clipboard-advertised
 * image type instead of rejecting content negotiated with an image wildcard.
 */
internal fun selectImageMimeType(
    resolvedMimeType: String?,
    advertisedMimeTypes: Iterable<String?>
): String? {
    if (resolvedMimeType.isImageMimeType()) {
        return resolvedMimeType!!.trim()
    }
    return advertisedMimeTypes.firstNotNullOfOrNull { candidate ->
        candidate?.trim()?.takeIf { it.isImageMimeType() }
    }
}

private fun String?.isImageMimeType(): Boolean {
    val normalized = this?.trim()?.lowercase(Locale.ROOT) ?: return false
    return normalized == "image/*" || normalized.startsWith("image/")
}
