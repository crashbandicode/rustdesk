package com.carriez.flutter_hbb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImageContentMimeTest {
    @Test
    fun resolvedImageTypeWins() {
        assertEquals(
            "image/webp",
            selectImageMimeType("image/webp", listOf("image/png"))
        )
    }

    @Test
    fun advertisedImageTypeSurvivesGenericProviderType() {
        assertEquals(
            "image/png",
            selectImageMimeType("application/octet-stream", listOf("image/png"))
        )
    }

    @Test
    fun wildcardNegotiationSurvivesMissingProviderType() {
        assertEquals(
            "image/*",
            selectImageMimeType(null, listOf("text/plain", "image/*"))
        )
    }

    @Test
    fun rejectsContentWithNoAdvertisedOrResolvedImageType() {
        assertNull(
            selectImageMimeType("application/octet-stream", listOf("text/plain"))
        )
    }
}
