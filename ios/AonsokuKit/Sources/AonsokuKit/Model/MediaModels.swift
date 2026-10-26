import Foundation

// Library value types shown by the native app. They mirror the Subsonic and
// OpenSubsonic shapes the web client uses (`src/types/responses/*`), with
// dates parsed and optional fields normalized. Decoding, encoding back to the
// web JSON shape and bridging from `Library*` records live in
// `MediaModels+Coding.swift`.

// MARK: - Shared

/// One credited artist. OpenSubsonic servers send ids; legacy servers only
/// send the display string.
public struct ArtistCredit: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

/// An OpenSubsonic contributor such as a composer or producer.
public struct Contributor: Hashable, Sendable {
    public var role: String
    public var subRole: String?
    public var artist: ArtistCredit

    public init(role: String, subRole: String? = nil, artist: ArtistCredit) {
        self.role = role
        self.subRole = subRole
        self.artist = artist
    }
}

/// ReplayGain tags in dB (gains) and linear sample peaks.
public struct ReplayGainInfo: Hashable, Sendable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?
    public var baseGain: Double?
    public var fallbackGain: Double?

    public init(
        trackGain: Double? = nil,
        trackPeak: Double? = nil,
        albumGain: Double? = nil,
        albumPeak: Double? = nil,
        baseGain: Double? = nil,
        fallbackGain: Double? = nil
    ) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
        self.baseGain = baseGain
        self.fallbackGain = fallbackGain
    }
}

public enum ExplicitStatus: String, Codable, Hashable, Sendable {
    case explicit
    case clean
}

public struct DiscTitle: Codable, Hashable, Sendable {
    public var disc: Int
    public var title: String

    public init(disc: Int, title: String) {
        self.disc = disc
        self.title = title
    }
}

/// A partial date as OpenSubsonic reports release dates.
public struct ItemDate: Codable, Hashable, Sendable {
    public var year: Int?
    public var month: Int?
    public var day: Int?

    public init(year: Int? = nil, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }
}

// MARK: - Song

public struct Song: Identifiable, Hashable, Sendable {
    public var id: String
    public var parent: String?
    public var title: String
    public var album: String
    public var albumId: String?
    public var artist: String
    public var artistId: String?
    public var artists: [ArtistCredit]
    public var displayArtist: String?
    public var albumArtists: [ArtistCredit]
    public var displayAlbumArtist: String?
    public var displayComposer: String?
    public var contributors: [Contributor]
    public var track: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var genres: [String]
    public var coverArt: String?
    /// Whole seconds, as Subsonic reports them.
    public var duration: Int
    public var bitRate: Int?
    public var bitDepth: Int?
    public var samplingRate: Int?
    public var channelCount: Int?
    public var size: Int64?
    public var suffix: String?
    public var contentType: String?
    public var path: String?
    public var playCount: Int?
    public var played: Date?
    public var created: Date?
    public var starred: Date?
    public var userRating: Int?
    public var bpm: Int?
    public var comment: String?
    public var musicBrainzId: String?
    public var replayGain: ReplayGainInfo?
    public var explicitStatus: ExplicitStatus?
    public var mediaType: String?
    public var sortName: String?

    public init(
        id: String,
        parent: String? = nil,
        title: String,
        album: String = "",
        albumId: String? = nil,
        artist: String = "",
        artistId: String? = nil,
        artists: [ArtistCredit] = [],
        displayArtist: String? = nil,
        albumArtists: [ArtistCredit] = [],
        displayAlbumArtist: String? = nil,
        displayComposer: String? = nil,
        contributors: [Contributor] = [],
        track: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        genres: [String] = [],
        coverArt: String? = nil,
        duration: Int = 0,
        bitRate: Int? = nil,
        bitDepth: Int? = nil,
        samplingRate: Int? = nil,
        channelCount: Int? = nil,
        size: Int64? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        path: String? = nil,
        playCount: Int? = nil,
        played: Date? = nil,
        created: Date? = nil,
        starred: Date? = nil,
        userRating: Int? = nil,
        bpm: Int? = nil,
        comment: String? = nil,
        musicBrainzId: String? = nil,
        replayGain: ReplayGainInfo? = nil,
        explicitStatus: ExplicitStatus? = nil,
        mediaType: String? = nil,
        sortName: String? = nil
    ) {
        self.id = id
        self.parent = parent
        self.title = title
        self.album = album
        self.albumId = albumId
        self.artist = artist
        self.artistId = artistId
        self.artists = artists
        self.displayArtist = displayArtist
        self.albumArtists = albumArtists
        self.displayAlbumArtist = displayAlbumArtist
        self.displayComposer = displayComposer
        self.contributors = contributors
        self.track = track
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.genres = genres
        self.coverArt = coverArt
        self.duration = duration
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.channelCount = channelCount
        self.size = size
        self.suffix = suffix
        self.contentType = contentType
        self.path = path
        self.playCount = playCount
        self.played = played
        self.created = created
        self.starred = starred
        self.userRating = userRating
        self.bpm = bpm
        self.comment = comment
        self.musicBrainzId = musicBrainzId
        self.replayGain = replayGain
        self.explicitStatus = explicitStatus
        self.mediaType = mediaType
        self.sortName = sortName
    }

    /// The artist line to display: OpenSubsonic `displayArtist`, else the
    /// legacy `artist` string.
    public var artistLine: String {
        if let displayArtist, !displayArtist.isEmpty { return displayArtist }
        return artist
    }

    /// Every credited artist, falling back to the legacy single artist.
    public var creditedArtists: [ArtistCredit] {
        if !artists.isEmpty { return artists }
        guard !artist.isEmpty else { return [] }
        return [ArtistCredit(id: artistId, name: artist)]
    }
}

// MARK: - Album

public struct Album: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var artist: String
    public var artistId: String?
    public var artists: [ArtistCredit]
    public var displayArtist: String?
    public var coverArt: String?
    public var songCount: Int
    /// Whole seconds.
    public var duration: Int
    public var playCount: Int?
    public var created: Date?
    public var played: Date?
    public var starred: Date?
    public var year: Int?
    public var genre: String?
    public var genres: [String]
    public var userRating: Int?
    public var musicBrainzId: String?
    public var isCompilation: Bool
    public var sortName: String?
    public var discTitles: [DiscTitle]
    public var originalReleaseDate: ItemDate?
    public var releaseDate: ItemDate?
    public var releaseTypes: [String]
    public var recordLabels: [String]
    public var moods: [String]
    public var explicitStatus: ExplicitStatus?
    public var version: String?

    public init(
        id: String,
        name: String,
        artist: String = "",
        artistId: String? = nil,
        artists: [ArtistCredit] = [],
        displayArtist: String? = nil,
        coverArt: String? = nil,
        songCount: Int = 0,
        duration: Int = 0,
        playCount: Int? = nil,
        created: Date? = nil,
        played: Date? = nil,
        starred: Date? = nil,
        year: Int? = nil,
        genre: String? = nil,
        genres: [String] = [],
        userRating: Int? = nil,
        musicBrainzId: String? = nil,
        isCompilation: Bool = false,
        sortName: String? = nil,
        discTitles: [DiscTitle] = [],
        originalReleaseDate: ItemDate? = nil,
        releaseDate: ItemDate? = nil,
        releaseTypes: [String] = [],
        recordLabels: [String] = [],
        moods: [String] = [],
        explicitStatus: ExplicitStatus? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.artists = artists
        self.displayArtist = displayArtist
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.playCount = playCount
        self.created = created
        self.played = played
        self.starred = starred
        self.year = year
        self.genre = genre
        self.genres = genres
        self.userRating = userRating
        self.musicBrainzId = musicBrainzId
        self.isCompilation = isCompilation
        self.sortName = sortName
        self.discTitles = discTitles
        self.originalReleaseDate = originalReleaseDate
        self.releaseDate = releaseDate
        self.releaseTypes = releaseTypes
        self.recordLabels = recordLabels
        self.moods = moods
        self.explicitStatus = explicitStatus
        self.version = version
    }

    public var artistLine: String {
        if let displayArtist, !displayArtist.isEmpty { return displayArtist }
        return artist
    }

    public var creditedArtists: [ArtistCredit] {
        if !artists.isEmpty { return artists }
        guard !artist.isEmpty else { return [] }
        return [ArtistCredit(id: artistId, name: artist)]
    }
}

public struct AlbumDetail: Hashable, Sendable {
    public var album: Album
    /// Tracks in server order (disc, then track).
    public var songs: [Song]

    public init(album: Album, songs: [Song]) {
        self.album = album
        self.songs = songs
    }
}

public struct AlbumInfo: Hashable, Sendable {
    /// Notes as the server sends them; may contain HTML and a Last.fm link.
    public var notes: String?
    public var musicBrainzId: String?
    public var lastFmUrl: String?
    public var smallImageUrl: String?
    public var mediumImageUrl: String?
    public var largeImageUrl: String?

    public init(
        notes: String? = nil,
        musicBrainzId: String? = nil,
        lastFmUrl: String? = nil,
        smallImageUrl: String? = nil,
        mediumImageUrl: String? = nil,
        largeImageUrl: String? = nil
    ) {
        self.notes = notes
        self.musicBrainzId = musicBrainzId
        self.lastFmUrl = lastFmUrl
        self.smallImageUrl = smallImageUrl
        self.mediumImageUrl = mediumImageUrl
        self.largeImageUrl = largeImageUrl
    }
}

// MARK: - Artist

public struct Artist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var coverArt: String?
    public var artistImageUrl: String?
    public var albumCount: Int
    public var starred: Date?
    public var musicBrainzId: String?
    public var sortName: String?
    public var roles: [String]

    public init(
        id: String,
        name: String,
        coverArt: String? = nil,
        artistImageUrl: String? = nil,
        albumCount: Int = 0,
        starred: Date? = nil,
        musicBrainzId: String? = nil,
        sortName: String? = nil,
        roles: [String] = []
    ) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
        self.artistImageUrl = artistImageUrl
        self.albumCount = albumCount
        self.starred = starred
        self.musicBrainzId = musicBrainzId
        self.sortName = sortName
        self.roles = roles
    }
}

public struct ArtistDetail: Hashable, Sendable {
    public var artist: Artist
    public var albums: [Album]

    public init(artist: Artist, albums: [Album]) {
        self.artist = artist
        self.albums = albums
    }
}

public struct ArtistInfo: Hashable, Sendable {
    /// Biography as the server sends it; may contain HTML and a Last.fm link.
    public var biography: String?
    public var musicBrainzId: String?
    public var lastFmUrl: String?
    public var smallImageUrl: String?
    public var mediumImageUrl: String?
    public var largeImageUrl: String?
    public var similarArtists: [Artist]

    public init(
        biography: String? = nil,
        musicBrainzId: String? = nil,
        lastFmUrl: String? = nil,
        smallImageUrl: String? = nil,
        mediumImageUrl: String? = nil,
        largeImageUrl: String? = nil,
        similarArtists: [Artist] = []
    ) {
        self.biography = biography
        self.musicBrainzId = musicBrainzId
        self.lastFmUrl = lastFmUrl
        self.smallImageUrl = smallImageUrl
        self.mediumImageUrl = mediumImageUrl
        self.largeImageUrl = largeImageUrl
        self.similarArtists = similarArtists
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var comment: String?
    public var owner: String?
    public var isPublic: Bool
    public var songCount: Int
    /// Whole seconds.
    public var duration: Int
    public var created: Date?
    public var changed: Date?
    public var coverArt: String?
    public var starred: Date?

    public init(
        id: String,
        name: String,
        comment: String? = nil,
        owner: String? = nil,
        isPublic: Bool = false,
        songCount: Int = 0,
        duration: Int = 0,
        created: Date? = nil,
        changed: Date? = nil,
        coverArt: String? = nil,
        starred: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.owner = owner
        self.isPublic = isPublic
        self.songCount = songCount
        self.duration = duration
        self.created = created
        self.changed = changed
        self.coverArt = coverArt
        self.starred = starred
    }
}

public struct PlaylistDetail: Hashable, Sendable {
    public var playlist: Playlist
    /// Entries in playlist order. The same song may appear more than once.
    public var songs: [Song]

    public init(playlist: Playlist, songs: [Song]) {
        self.playlist = playlist
        self.songs = songs
    }
}

// MARK: - Other

public struct Genre: Identifiable, Hashable, Sendable {
    public var name: String
    public var songCount: Int
    public var albumCount: Int

    public var id: String { name }

    public init(name: String, songCount: Int = 0, albumCount: Int = 0) {
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
    }
}

public struct RadioStation: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var streamUrl: String
    public var homePageUrl: String?

    public init(id: String, name: String, streamUrl: String, homePageUrl: String? = nil) {
        self.id = id
        self.name = name
        self.streamUrl = streamUrl
        self.homePageUrl = homePageUrl
    }
}

public struct SearchResults: Hashable, Sendable {
    public var artists: [Artist]
    public var albums: [Album]
    public var songs: [Song]

    public init(artists: [Artist] = [], albums: [Album] = [], songs: [Song] = []) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

public struct SubsonicUser: Hashable, Sendable {
    public var username: String
    public var email: String?
    public var scrobblingEnabled: Bool
    public var adminRole: Bool
    public var settingsRole: Bool
    public var downloadRole: Bool
    public var uploadRole: Bool
    public var playlistRole: Bool
    public var coverArtRole: Bool
    public var commentRole: Bool
    public var podcastRole: Bool
    public var streamRole: Bool
    public var jukeboxRole: Bool
    public var shareRole: Bool

    public init(
        username: String,
        email: String? = nil,
        scrobblingEnabled: Bool = false,
        adminRole: Bool = false,
        settingsRole: Bool = false,
        downloadRole: Bool = false,
        uploadRole: Bool = false,
        playlistRole: Bool = false,
        coverArtRole: Bool = false,
        commentRole: Bool = false,
        podcastRole: Bool = false,
        streamRole: Bool = false,
        jukeboxRole: Bool = false,
        shareRole: Bool = false
    ) {
        self.username = username
        self.email = email
        self.scrobblingEnabled = scrobblingEnabled
        self.adminRole = adminRole
        self.settingsRole = settingsRole
        self.downloadRole = downloadRole
        self.uploadRole = uploadRole
        self.playlistRole = playlistRole
        self.coverArtRole = coverArtRole
        self.commentRole = commentRole
        self.podcastRole = podcastRole
        self.streamRole = streamRole
        self.jukeboxRole = jukeboxRole
        self.shareRole = shareRole
    }
}

/// What the server reports about itself (web About dialog).
public struct ServerInfo: Hashable, Sendable {
    /// `navidrome`, `lms`, `subsonic`, ...
    public var type: String
    /// The server software's own version, such as `0.53.3`.
    public var serverVersion: String?
    /// The Subsonic API version, such as `1.16.1`.
    public var protocolVersion: String
    public var isOpenSubsonic: Bool

    public init(
        type: String,
        serverVersion: String? = nil,
        protocolVersion: String,
        isOpenSubsonic: Bool = false
    ) {
        self.type = type
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.isOpenSubsonic = isOpenSubsonic
    }
}

public struct ScanStatus: Hashable, Sendable {
    public var scanning: Bool
    /// Songs in the library.
    public var count: Int?
    public var folderCount: Int?
    public var lastScan: Date?

    public init(scanning: Bool, count: Int? = nil, folderCount: Int? = nil, lastScan: Date? = nil) {
        self.scanning = scanning
        self.count = count
        self.folderCount = folderCount
        self.lastScan = lastScan
    }
}

/// `getAlbumList2` list types.
public enum AlbumListType: String, Sendable, CaseIterable {
    case random
    case newest
    case frequent
    case recent
    case starred
    case alphabeticalByName
    case alphabeticalByArtist
    case byYear
    case byGenre
}

// MARK: - Library queries

/// Album lists the app shows. Mirrors the web album filters
/// (`src/utils/albumsFilter.ts`) and the album list routes.
public enum AlbumListFilter: Hashable, Sendable {
    case alphabeticalByName
    case alphabeticalByArtist
    case recentlyAdded
    case recentlyPlayed
    case mostPlayed
    case random
    case favorites
    /// Release year order; `newestFirst` false lists oldest first.
    case byYear(newestFirst: Bool)
    case byGenre(String)
    case discography(artistId: String)
    case search(String)
}

/// Song list order. Matches the web songs list (`SongsOrderByOptions`).
public enum SongSort: String, Hashable, Sendable, CaseIterable {
    case recentlyAdded
    case title
    case artist
    case album

    public var labelKey: String {
        switch self {
        case .recentlyAdded: "songs.sort.lastAdded"
        case .title: "songs.sort.title"
        case .artist: "songs.sort.artist"
        case .album: "songs.sort.album"
        }
    }
}

/// A song list request: which songs, an optional search, and the order.
public struct SongListQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case all
        case favorites
        case artist(id: String, name: String)
        case album(id: String)
        case genre(String)
    }

    public var scope: Scope
    /// Words that must all match the title, artist or album; empty for none.
    public var search: String
    public var sort: SongSort
    public var ascending: Bool

    public init(
        scope: Scope = .all,
        search: String = "",
        sort: SongSort = .recentlyAdded,
        ascending: Bool = false
    ) {
        self.scope = scope
        self.search = search
        self.sort = sort
        self.ascending = ascending
    }
}
