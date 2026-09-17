package io.mynote.core

import kotlinx.serialization.Serializable

/**
 * A folder in storage the user already owns and pays for.
 *
 * MyNote has no server. Notes are backed up into the user's own Google Drive,
 * which is why there is no hosting bill, no account to create with us, and
 * nothing of theirs sitting on hardware we control.
 *
 * Implementations are thin: list, read, write, delete. Everything about merging
 * and conflict resolution lives above this, so adding another provider later is
 * four methods and no new sync logic.
 */
interface RemoteFolder {
    /** Human-readable name for the UI ("Google Drive"). */
    val displayName: String

    /** Files directly inside the MyNote folder. */
    suspend fun list(): List<RemoteFile>

    suspend fun read(name: String): ByteArray
    suspend fun write(name: String, data: ByteArray)
    suspend fun delete(name: String)
}

data class RemoteFile(
    val name: String,
    val modifiedAt: Long,
    val size: Long,
    /**
     * Provider's change marker — an etag, a revision id, a content hash.
     *
     * Used to skip downloading a device file that has not changed since the last
     * merge. Without it every sync would pull every other device's whole file,
     * which on a metered connection is the difference between a usable app and
     * an uninstall.
     */
    val version: String,
)

sealed interface RemoteFolderError {
    /** The user has not connected a storage provider yet. */
    data object NotConnected : RemoteFolderError
    /** Signed out, token expired, or access revoked in Google's settings. */
    data object NeedsReauthentication : RemoteFolderError
    data class NotFound(val name: String) : RemoteFolderError
    /** The user's Drive is full. Their storage, their quota. */
    data object StorageFull : RemoteFolderError
    data object Offline : RemoteFolderError
    data class Provider(val message: String) : RemoteFolderError
}

class RemoteFolderException(val error: RemoteFolderError) : Exception(error.toString())

/**
 * One device's contribution to the shared folder.
 *
 * Each device writes exactly one of these and never touches another's, which is
 * what makes concurrent edits safe without any locking: there is no file two
 * devices can both write, so there is no write conflict to resolve. Merging
 * happens on read, by hybrid logical clock.
 */
@Serializable
data class DeviceFile(
    val format: Int = CURRENT_FORMAT,
    val deviceId: String,
    val updatedAt: Long,
    /** Every record whose newest known version was authored by this device. */
    val changes: List<Change>,
) {
    fun encoded(): ByteArray =
        MyNoteJson.encodeToString(serializer(), this).toByteArray()

    companion object {
        const val CURRENT_FORMAT = 1

        /**
         * `device-<id>.json`. The device id is also the HLC node, so a record's
         * clock already says which file it belongs in.
         */
        fun fileName(deviceId: String) = "device-$deviceId.json"

        fun deviceIdFromFileName(name: String): String? =
            if (name.startsWith("device-") && name.endsWith(".json")) {
                name.removePrefix("device-").removeSuffix(".json")
            } else {
                null
            }

        fun decode(data: ByteArray): DeviceFile {
            val file = MyNoteJson.decodeFromString(serializer(), data.decodeToString())
            // A newer app may add fields; Codable-style leniency handles those.
            // Only a genuinely newer *format* is a problem.
            if (file.format > CURRENT_FORMAT) {
                throw RemoteFolderException(
                    RemoteFolderError.Provider(
                        "This backup was written by a newer version of MyNote. Update the app to read it."
                    )
                )
            }
            return file
        }
    }
}
