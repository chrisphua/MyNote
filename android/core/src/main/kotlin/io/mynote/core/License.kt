package io.mynote.core

import kotlinx.serialization.Serializable

/**
 * Proof of purchase, carried in the user's own cloud folder.
 *
 * With no server there is nowhere neutral to record that someone paid, so the
 * receipt rides along with the notes. Buy on an iPhone, connect the same Google
 * Drive on an Android tablet, and Pro is already unlocked.
 *
 * **Threat model, stated plainly.** The store's own receipt is the strong proof,
 * and each platform verifies its own: Play's signature on Android, StoreKit on
 * iOS. This file is the weaker, cross-platform path — it lives in storage the
 * user controls, so a determined person could forge it. That buys them a
 * one-time purchase they could have made for the price of a sandwich, and the
 * alternative is running a server purely to police it. Not worth it.
 */
@Serializable
data class License(
    val format: Int = CURRENT_FORMAT,
    /**
     * Entitlement ids, e.g. `["pro"]`. A list so a future split into separate
     * products does not need a new file format.
     */
    val entitlements: List<String>,
    val productId: String,
    /** Which store the purchase was made in — for support, not for gating. */
    val platform: String,
    val purchasedAt: Long,
    /** The store's own receipt, kept verbatim for support and disputes. */
    val receipt: String? = null,
) {
    fun encoded(): ByteArray = MyNoteJson.encodeToString(serializer(), this).toByteArray()

    companion object {
        const val FILE_NAME = "license.json"
        const val CURRENT_FORMAT = 1

        fun decode(data: ByteArray): License? =
            runCatching { MyNoteJson.decodeFromString(serializer(), data.decodeToString()) }
                .getOrNull()
                ?.takeIf { it.format <= CURRENT_FORMAT }

        /**
         * Merge what the folder says with what this device's store says.
         *
         * Union, never intersection: a purchase made on the other platform exists
         * only in the file, and a purchase made here may not have been uploaded
         * yet. Taking the union means neither can revoke the other.
         */
        fun combine(local: Set<String>, remote: License?): Set<String> =
            local + (remote?.entitlements ?: emptyList())
    }
}
