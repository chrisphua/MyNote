package io.mynote.app.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface NoteDao {
    @Query("SELECT * FROM notes WHERE deleted = 0 ORDER BY orderKey")
    fun observeAll(): Flow<List<NoteRow>>

    @Query("SELECT * FROM notes WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): NoteRow?

    @Query("SELECT * FROM notes WHERE id = :id LIMIT 1")
    fun observeById(id: String): Flow<NoteRow?>

    @Query("SELECT hlc FROM notes WHERE id = :id LIMIT 1")
    suspend fun hlc(id: String): String?

    @Upsert
    suspend fun upsert(row: NoteRow)
}

@Dao
interface BlockDao {
    @Query("SELECT * FROM blocks WHERE noteId = :noteId AND deleted = 0 ORDER BY orderKey")
    fun observeForNote(noteId: String): Flow<List<BlockRow>>

    @Query("SELECT id FROM blocks WHERE noteId = :noteId AND deleted = 0")
    suspend fun idsForNote(noteId: String): List<String>

    @Query("SELECT * FROM blocks WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): BlockRow?

    @Query("SELECT hlc FROM blocks WHERE id = :id LIMIT 1")
    suspend fun hlc(id: String): String?

    @Upsert
    suspend fun upsert(row: BlockRow)
}

@Dao
interface ThemeDao {
    @Query("SELECT * FROM themes WHERE deleted = 0")
    fun observeAll(): Flow<List<ThemeRow>>

    @Query("SELECT * FROM themes WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): ThemeRow?

    @Query("SELECT hlc FROM themes WHERE id = :id LIMIT 1")
    suspend fun hlc(id: String): String?

    @Upsert
    suspend fun upsert(row: ThemeRow)
}

@Dao
interface OutboxDao {
    @Query("SELECT * FROM outbox ORDER BY queuedAt LIMIT :limit")
    suspend fun oldest(limit: Int): List<OutboxRow>

    @Query("SELECT COUNT(*) FROM outbox")
    fun observeCount(): Flow<Int>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(row: OutboxRow)

    @Query("DELETE FROM outbox WHERE `key` IN (:keys)")
    suspend fun deleteKeys(keys: List<String>)
}

@Dao
interface SyncStateDao {
    @Query("SELECT * FROM sync_state WHERE id = 1")
    suspend fun get(): SyncStateRow?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun put(row: SyncStateRow)
}
