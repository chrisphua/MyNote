package io.mynote.app.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import io.mynote.core.Hlc

/**
 * Room mirrors of the core models.
 *
 * Storage types, not domain types: `:core` owns the domain so the sync engine
 * stays testable on the JVM. Each row keeps the `hlc` it was last written with —
 * that is what makes local merge decisions possible — and the `authorNode` from
 * inside that clock, so "everything this device owns" is an indexed query rather
 * than a scan.
 */

private fun nodeOf(hlc: String) = Hlc.decode(hlc)?.node.orEmpty()

@Entity(tableName = "notes", indices = [Index("parentId", "orderKey"), Index("authorNode")])
data class NoteRow(
    @PrimaryKey val id: String,
    val title: String = "",
    val icon: String? = null,
    val parentId: String? = null,
    val orderKey: String,
    val hlc: String,
    /** Device that wrote the current version; decoded from [hlc] on write. */
    val authorNode: String = nodeOf(hlc),
    val deleted: Boolean = false,
    val updatedAt: Long = System.currentTimeMillis(),
)

@Entity(tableName = "blocks", indices = [Index("noteId", "orderKey"), Index("authorNode")])
data class BlockRow(
    @PrimaryKey val id: String,
    val noteId: String,
    val parentId: String? = null,
    val orderKey: String,
    val type: String,
    /** JSON, matching the `content` field on the wire. */
    val content: String,
    val hlc: String,
    val authorNode: String = nodeOf(hlc),
    val deleted: Boolean = false,
    val updatedAt: Long = System.currentTimeMillis(),
)

@Entity(tableName = "themes", indices = [Index("authorNode")])
data class ThemeRow(
    @PrimaryKey val id: String,
    val name: String,
    val spec: String,
    val hlc: String,
    val authorNode: String = nodeOf(hlc),
    val deleted: Boolean = false,
)

/**
 * Which version of each other device's file we have already merged.
 *
 * Lets a sync skip a file that has not changed, instead of re-downloading every
 * device's whole backup on every pass.
 */
@Entity(tableName = "remote_versions")
data class RemoteVersionRow(
    @PrimaryKey val fileName: String,
    val version: String,
)

/** Sync bookkeeping. One row. */
@Entity(tableName = "sync_meta")
data class SyncMetaRow(
    @PrimaryKey val id: Int = 1,
    /** Newest clock we had when our own file was last uploaded successfully. */
    val lastUploadedHlc: String? = null,
    val lastSyncedAt: Long? = null,
    /** Which storage provider the notes currently belong to. */
    val connectedProvider: String? = null,
)
