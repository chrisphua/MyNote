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

    @Query("SELECT COUNT(*) FROM notes WHERE deleted = 0")
    suspend fun count(): Int

    @Query("SELECT * FROM notes WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): NoteRow?

    @Query("SELECT * FROM notes WHERE id = :id LIMIT 1")
    fun observeById(id: String): Flow<NoteRow?>

    @Query("SELECT hlc FROM notes WHERE id = :id LIMIT 1")
    suspend fun hlc(id: String): String?

    @Query("SELECT * FROM notes WHERE authorNode = :node")
    suspend fun authoredBy(node: String): List<NoteRow>

    @Query("SELECT MAX(hlc) FROM notes")
    suspend fun maxHlc(): String?

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

    @Query("SELECT * FROM blocks WHERE authorNode = :node")
    suspend fun authoredBy(node: String): List<BlockRow>

    @Query("SELECT MAX(hlc) FROM blocks")
    suspend fun maxHlc(): String?

    @Upsert
    suspend fun upsert(row: BlockRow)
}

@Dao
interface ThemeDao {
    @Query("SELECT * FROM themes WHERE deleted = 0")
    suspend fun allActive(): List<ThemeRow>

    @Query("SELECT * FROM themes WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): ThemeRow?

    @Query("SELECT hlc FROM themes WHERE id = :id LIMIT 1")
    suspend fun hlc(id: String): String?

    @Query("SELECT * FROM themes WHERE authorNode = :node")
    suspend fun authoredBy(node: String): List<ThemeRow>

    @Query("SELECT MAX(hlc) FROM themes")
    suspend fun maxHlc(): String?

    @Upsert
    suspend fun upsert(row: ThemeRow)
}

@Dao
interface RemoteVersionDao {
    @Query("SELECT * FROM remote_versions")
    suspend fun all(): List<RemoteVersionRow>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun put(row: RemoteVersionRow)
}

@Dao
interface SyncMetaDao {
    @Query("SELECT * FROM sync_meta WHERE id = 1")
    suspend fun get(): SyncMetaRow?

    @Query("SELECT * FROM sync_meta WHERE id = 1")
    fun observe(): Flow<SyncMetaRow?>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun put(row: SyncMetaRow)
}
