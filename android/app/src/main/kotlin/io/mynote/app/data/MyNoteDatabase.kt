package io.mynote.app.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [NoteRow::class, BlockRow::class, ThemeRow::class, OutboxRow::class, SyncStateRow::class],
    version = 1,
    exportSchema = true,
)
abstract class MyNoteDatabase : RoomDatabase() {
    abstract fun notes(): NoteDao
    abstract fun blocks(): BlockDao
    abstract fun themes(): ThemeDao
    abstract fun outbox(): OutboxDao
    abstract fun syncState(): SyncStateDao

    companion object {
        @Volatile
        private var instance: MyNoteDatabase? = null

        fun get(context: Context): MyNoteDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext,
                    MyNoteDatabase::class.java,
                    "mynote.db",
                )
                    // No destructive fallback: a migration bug must fail loudly
                    // in testing rather than silently delete someone's notes.
                    .build()
                    .also { instance = it }
            }
    }
}
