package github.realtvop.aonsoku.plugins.data

import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteQuery

enum class AlbumSort {
    RecentlyAdded,
    RecentlyPlayed,
    MostPlayed,
    Name,
    Artist,
    Starred,
    YearNewest,
    YearOldest,
    Random,
}

/** Typed album listing used by native screens. Unlimited when [limit] is null. */
data class AlbumQuery(
    val sort: AlbumSort = AlbumSort.RecentlyAdded,
    val search: String? = null,
    val artistId: String? = null,
    val genre: String? = null,
    val starredOnly: Boolean = false,
    /** Keep only albums that were played at least once. */
    val playedOnly: Boolean = false,
    val limit: Int? = null,
    val offset: Int = 0,
)

enum class SongSort { LastAdded, Artist, Title, Album, Starred, AlbumOrder }

data class SongQuery(
    val sort: SongSort = SongSort.LastAdded,
    val ascending: Boolean = false,
    val search: String? = null,
    val artistId: String? = null,
    val albumId: String? = null,
    val starredOnly: Boolean = false,
    val limit: Int? = null,
    val offset: Int = 0,
)

data class ArtistQuery(
    val search: String? = null,
    val starredOnly: Boolean = false,
    val limit: Int? = null,
    val offset: Int = 0,
)

/**
 * Builds parameterized SQL for the typed library queries. Search terms are
 * split on whitespace and every term must match at least one column.
 */
internal object LibrarySql {
    private class Statement(table: String) {
        private val conditions = mutableListOf<String>()
        private val args = mutableListOf<Any>()
        private val from = table

        fun where(condition: String, vararg values: Any) {
            conditions += condition
            args.addAll(values)
        }

        fun search(text: String?, columns: List<String>) {
            for (token in tokenize(text)) {
                where(
                    columns.joinToString(" OR ", "(", ")") { "$it LIKE ? ESCAPE '\\'" },
                    *Array(columns.size) { "%${escapeLike(token)}%" },
                )
            }
        }

        fun select(orderBy: String?, limit: Int?, offset: Int): SupportSQLiteQuery {
            val sql = StringBuilder("SELECT * FROM $from")
            appendWhere(sql)
            if (orderBy != null) sql.append(" ORDER BY ").append(orderBy)
            val values = args.toMutableList()
            if (limit != null) {
                sql.append(" LIMIT ? OFFSET ?")
                values += limit.coerceAtLeast(0)
                values += offset.coerceAtLeast(0)
            }
            return SimpleSQLiteQuery(sql.toString(), values.toTypedArray())
        }

        fun count(): SupportSQLiteQuery {
            val sql = StringBuilder("SELECT COUNT(*) FROM $from")
            appendWhere(sql)
            return SimpleSQLiteQuery(sql.toString(), args.toTypedArray())
        }

        private fun appendWhere(sql: StringBuilder) {
            if (conditions.isNotEmpty()) {
                sql.append(" WHERE ").append(conditions.joinToString(" AND "))
            }
        }
    }

    fun tokenize(text: String?): List<String> =
        text.orEmpty().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }

    fun escapeLike(token: String): String =
        token.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    private fun albumStatement(query: AlbumQuery) = Statement("album").apply {
        search(query.search, listOf("name", "artist", "genre"))
        query.artistId?.let { where("artistId = ?", it) }
        query.genre?.let { where("genre = ?", it) }
        if (query.starredOnly || query.sort == AlbumSort.Starred) where("starredAt IS NOT NULL")
        if (query.playedOnly || query.sort == AlbumSort.RecentlyPlayed) {
            where("played IS NOT NULL AND played != ''")
        }
        if (query.sort == AlbumSort.MostPlayed) where("COALESCE(playCount, 0) > 0")
    }

    fun albums(query: AlbumQuery): SupportSQLiteQuery = albumStatement(query).select(
        orderBy = when (query.sort) {
            AlbumSort.RecentlyAdded -> "created DESC, name COLLATE NOCASE ASC"
            AlbumSort.RecentlyPlayed -> "played DESC, name COLLATE NOCASE ASC"
            AlbumSort.MostPlayed -> "COALESCE(playCount, 0) DESC, name COLLATE NOCASE ASC"
            AlbumSort.Name -> "name COLLATE NOCASE ASC"
            AlbumSort.Artist -> "artist COLLATE NOCASE ASC, name COLLATE NOCASE ASC"
            AlbumSort.Starred -> "starredAt DESC, name COLLATE NOCASE ASC"
            AlbumSort.YearNewest -> "COALESCE(year, 0) DESC, name COLLATE NOCASE ASC"
            AlbumSort.YearOldest -> "COALESCE(year, 0) ASC, name COLLATE NOCASE ASC"
            AlbumSort.Random -> "RANDOM()"
        },
        limit = query.limit,
        offset = query.offset,
    )

    fun albumCount(query: AlbumQuery): SupportSQLiteQuery = albumStatement(query).count()

    private fun songStatement(query: SongQuery) = Statement("song").apply {
        search(query.search, listOf("title", "artist", "album"))
        query.artistId?.let { where("artistId = ?", it) }
        query.albumId?.let { where("albumId = ?", it) }
        if (query.starredOnly || query.sort == SongSort.Starred) where("starredAt IS NOT NULL")
    }

    fun songs(query: SongQuery): SupportSQLiteQuery {
        val direction = if (query.ascending) "ASC" else "DESC"
        return songStatement(query).select(
            orderBy = when (query.sort) {
                SongSort.LastAdded -> "created $direction, title COLLATE NOCASE ASC"
                SongSort.Artist -> "artist COLLATE NOCASE $direction, title COLLATE NOCASE ASC"
                SongSort.Title -> "title COLLATE NOCASE $direction"
                SongSort.Album -> "album COLLATE NOCASE $direction, discNumber ASC, track ASC"
                SongSort.Starred -> "starredAt $direction, title COLLATE NOCASE ASC"
                SongSort.AlbumOrder -> "COALESCE(discNumber, 0) ASC, COALESCE(track, 0) ASC"
            },
            limit = query.limit,
            offset = query.offset,
        )
    }

    fun songCount(query: SongQuery): SupportSQLiteQuery = songStatement(query).count()

    private fun artistStatement(query: ArtistQuery) = Statement("artist").apply {
        search(query.search, listOf("name"))
        if (query.starredOnly) where("starredAt IS NOT NULL")
    }

    fun artists(query: ArtistQuery): SupportSQLiteQuery = artistStatement(query).select(
        orderBy = "name COLLATE NOCASE ASC",
        limit = query.limit,
        offset = query.offset,
    )

    fun artistCount(query: ArtistQuery): SupportSQLiteQuery = artistStatement(query).count()
}
