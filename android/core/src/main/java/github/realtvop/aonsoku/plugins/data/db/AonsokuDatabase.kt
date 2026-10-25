package github.realtvop.aonsoku.plugins.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import github.realtvop.aonsoku.plugins.data.db.dao.*
import github.realtvop.aonsoku.plugins.data.db.entity.*

@Database(entities = [ArtistEntity::class, AlbumEntity::class, SongEntity::class, PlaylistEntity::class, PlaylistDetailEntity::class, GenreEntity::class, LyricsEntity::class, CacheMetaEntity::class, SyncStateEntity::class], version = 1, exportSchema = false)
abstract class AonsokuDatabase : RoomDatabase() {
    abstract fun artistDao(): ArtistDao; abstract fun albumDao(): AlbumDao; abstract fun songDao(): SongDao
    abstract fun playlistDao(): PlaylistDao; abstract fun genreDao(): GenreDao; abstract fun lyricsDao(): LyricsDao
    abstract fun cacheMetaDao(): CacheMetaDao; abstract fun syncStateDao(): SyncStateDao
    companion object {
        @Volatile private var INSTANCE: AonsokuDatabase? = null
        fun getInstance(context: Context): AonsokuDatabase = INSTANCE ?: synchronized(this) {
            INSTANCE ?: Room.databaseBuilder(context.applicationContext, AonsokuDatabase::class.java, "aonsoku_library.db").fallbackToDestructiveMigration().build().also { INSTANCE = it }
        }
    }
}