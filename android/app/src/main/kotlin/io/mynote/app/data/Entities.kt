package io.mynote.app.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Room mirrors of the core models.
 *
 * Storage types, not domain types: `:core` owns the domain so the sync engine
 * stays testable on the JVM. Each row keeps the `hlc` it was last written with,
 * which is what makes local merge decisions possible.
 */

@Entity(tableName = "notes", indices = [Index("parentId", "orderKey")])
data class NoteRow(
    @PrimaryKey val id: String,
    val title: String = "",
    val icon: String? = null,
    val parentId: String? = null,
    val orderKey: String,
    val hlc: String,
    val deleted: Boolean = false,
    val updatedAt: Long = System.currentTimeMillis(),
)

@Entity(tableName = "blocks", indices = [Index("noteId", "orderKey")])
data class BlockRow(
    @PrimaryKey val id: String,
    val noteId: String,
    val parentId: String? = null,
    val orderKey: String,
    val type: String,
    /** JSON, matching `blocks.content` on the server. */
    val content: String,
    val hlc: String,
    val deleted: Boolean = false,
    val updatedAt: Long = System.currentTimeMillis(),
)

@Entity(tableName = "themes")
data class ThemeRow(
    @PrimaryKey val id: String,
    val name: String,
    val spec: String,
    val hlc: String,
    val deleted: Boolean = false,
)

/**
 * A local edit waiting to reach the server.
 *
 * Persisting the outbox is what makes the app genuinely offline-first: edits made
 * in airplane mode survive a force-stop and a reboot.
 */
@Entity(tableName = "outbox")
data class OutboxRow(
    @PrimaryKey val key: String,     // "<entity>:<id>"
    val entity: String,
    val recordId: String,
    val hlc: String,
    val deleted: Boolean,
    val fieldsJson: String,
    val queuedAt: Long = System.currentTimeMillis(),
)

@Entity(tableName = "sync_state")
data class SyncStateRow(
    @PrimaryKey val id: Int = 1,
    val cursor: Int = 0,
    val lastSyncedAt: Long? = null,
)
