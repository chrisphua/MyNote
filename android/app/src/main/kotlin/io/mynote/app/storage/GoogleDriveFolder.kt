package io.mynote.app.storage

import io.mynote.core.MyNoteJson
import io.mynote.core.RemoteFile
import io.mynote.core.RemoteFolder
import io.mynote.core.RemoteFolderError
import io.mynote.core.RemoteFolderException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.IOException

/**
 * Backup into a "MyNote" folder in the user's Google Drive.
 *
 * The cross-platform option: the same folder is read by the iOS app, so a note
 * written on an Android phone shows up on an iPhone. The file format is defined
 * once in `:core` and shared by both.
 */
class GoogleDriveFolder(
    private val auth: GoogleDriveAuth,
    private val client: OkHttpClient = OkHttpClient(),
) : RemoteFolder {

    override val displayName = "Google Drive"

    private var folderId: String? = null

    /** Drive addresses files by opaque id, not by name. */
    private val fileIds = mutableMapOf<String, String>()

    override suspend fun list(): List<RemoteFile> = withContext(Dispatchers.IO) {
        val folder = folder()
        val items = mutableListOf<RemoteFile>()
        var pageToken: String? = null

        do {
            val url = "$API/files".toHttpUrl().newBuilder()
                .addQueryParameter("q", "'$folder' in parents and trashed=false")
                .addQueryParameter("fields", "nextPageToken,files(id,name,modifiedTime,size,version)")
                .addQueryParameter("pageSize", "200")
                .apply { pageToken?.let { addQueryParameter("pageToken", it) } }
                .build()

            val listing = MyNoteJson.decodeFromString(
                FileList.serializer(),
                send(Request.Builder().url(url).get()),
            )
            for (file in listing.files) {
                fileIds[file.name] = file.id
                items += RemoteFile(
                    name = file.name,
                    modifiedAt = 0L,
                    size = file.size?.toLongOrNull() ?: 0L,
                    // Drive bumps `version` on every content or metadata change,
                    // which is exactly the "has this changed" signal we need.
                    version = file.version ?: file.modifiedTime ?: "0",
                )
            }
            pageToken = listing.nextPageToken
        } while (pageToken != null)

        items
    }

    override suspend fun read(name: String): ByteArray = withContext(Dispatchers.IO) {
        val id = id(name) ?: throw RemoteFolderException(RemoteFolderError.NotFound(name))
        sendBytes(Request.Builder().url("$API/files/$id?alt=media").get())
    }

    override suspend fun write(name: String, data: ByteArray) = withContext(Dispatchers.IO) {
        val existing = id(name)
        if (existing != null) {
            // Replace the contents, keeping the same id so other devices' notion
            // of the file and Drive's revision history stay intact.
            send(
                Request.Builder()
                    .url("$UPLOAD/files/$existing?uploadType=media")
                    .patch(data.toRequestBody(JSON))
            )
            return@withContext
        }

        // New file: metadata and content in one multipart request.
        val boundary = "mynote-${System.nanoTime()}"
        val metadata = MyNoteJson.encodeToString(
            NewFile.serializer(),
            NewFile(name = name, parents = listOf(folder())),
        )
        val body = buildString {
            append("--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
            append(metadata)
            append("\r\n--$boundary\r\nContent-Type: application/json\r\n\r\n")
        }.toByteArray() + data + "\r\n--$boundary--\r\n".toByteArray()

        val created = MyNoteJson.decodeFromString(
            DriveFile.serializer(),
            send(
                Request.Builder()
                    .url("$UPLOAD/files?uploadType=multipart&fields=id")
                    .post(body.toRequestBody("multipart/related; boundary=$boundary".toMediaType()))
            ),
        )
        fileIds[name] = created.id
    }

    override suspend fun delete(name: String) {
        withContext(Dispatchers.IO) {
            val id = id(name) ?: return@withContext
            send(Request.Builder().url("$API/files/$id").delete())
            fileIds.remove(name)
        }
    }

    // MARK: - Folder resolution

    /** Find the MyNote folder, creating it on first use. */
    private suspend fun folder(): String {
        folderId?.let { return it }

        val url = "$API/files".toHttpUrl().newBuilder()
            .addQueryParameter("q", "mimeType='$FOLDER_MIME' and name='$FOLDER_NAME' and trashed=false")
            .addQueryParameter("fields", "files(id,name)")
            .build()
        val existing = MyNoteJson.decodeFromString(
            FileList.serializer(),
            send(Request.Builder().url(url).get()),
        )
        existing.files.firstOrNull()?.let {
            folderId = it.id
            return it.id
        }

        val created = MyNoteJson.decodeFromString(
            DriveFile.serializer(),
            send(
                Request.Builder()
                    .url("$API/files?fields=id")
                    .post(
                        MyNoteJson.encodeToString(
                            NewFile.serializer(),
                            NewFile(name = FOLDER_NAME, parents = null, mimeType = FOLDER_MIME),
                        ).toRequestBody(JSON)
                    )
            ),
        )
        folderId = created.id
        return created.id
    }

    private suspend fun id(name: String): String? {
        fileIds[name]?.let { return it }
        list()
        return fileIds[name]
    }

    // MARK: - Transport

    private suspend fun send(builder: Request.Builder): String =
        sendBytes(builder).decodeToString()

    private suspend fun sendBytes(builder: Request.Builder): ByteArray {
        val request = builder
            .header("Authorization", "Bearer ${auth.token()}")
            .build()

        val response = try {
            client.newCall(request).execute()
        } catch (e: IOException) {
            throw RemoteFolderException(RemoteFolderError.Offline)
        }

        response.use {
            val bytes = it.body?.bytes() ?: ByteArray(0)
            if (!it.isSuccessful) throw RemoteFolderException(error(it.code, bytes.decodeToString()))
            return bytes
        }
    }

    private fun error(status: Int, body: String): RemoteFolderError = when {
        status == 401 -> RemoteFolderError.NeedsReauthentication
        status == 403 && body.contains("insufficient", true) -> RemoteFolderError.NeedsReauthentication
        status == 403 && body.contains("quota", true) -> RemoteFolderError.StorageFull
        status == 404 -> RemoteFolderError.NotFound(body)
        // Rate limited or Drive is unwell; both are worth retrying later.
        status == 429 || status >= 500 -> RemoteFolderError.Offline
        else -> RemoteFolderError.Provider("Drive error ($status)")
    }

    // MARK: - Wire types

    @Serializable
    private data class FileList(
        val files: List<DriveFile> = emptyList(),
        val nextPageToken: String? = null,
    )

    @Serializable
    private data class DriveFile(
        val id: String,
        val name: String = "",
        val modifiedTime: String? = null,
        val size: String? = null,
        val version: String? = null,
    )

    @Serializable
    private data class NewFile(
        val name: String,
        val parents: List<String>? = null,
        val mimeType: String? = null,
    )

    private companion object {
        const val FOLDER_NAME = "MyNote"
        const val FOLDER_MIME = "application/vnd.google-apps.folder"
        const val API = "https://www.googleapis.com/drive/v3"
        const val UPLOAD = "https://www.googleapis.com/upload/drive/v3"
        val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
