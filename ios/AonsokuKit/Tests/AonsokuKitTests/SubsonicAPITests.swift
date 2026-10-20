import XCTest
@testable import AonsokuKit

final class SubsonicAPITests: XCTestCase {
  private var fakeTransport: FakeSubsonicTransport!
  private var api: LiveSubsonicAPI!

  override func setUp() {
    super.setUp()
    fakeTransport = FakeSubsonicTransport()
    api = LiveSubsonicAPI(transport: fakeTransport)
  }

  // MARK: - Ping

  func testPingReturnsServerInfo() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "version": "1.16.1",
          "type": "navidrome",
          "serverVersion": "0.53.3",
          "openSubsonic": true
        }
      }
      """.utf8)

    let info = try await api.ping()

    XCTAssertEqual(info.type, "navidrome")
    XCTAssertEqual(info.serverVersion, "0.53.3")
    XCTAssertEqual(info.protocolVersion, "1.16.1")
    XCTAssertTrue(info.isOpenSubsonic)
    XCTAssertEqual(fakeTransport.lastRequest?.path, "ping.view")
  }

  func testPingDefaultsType() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "version": "1.16.0"
        }
      }
      """.utf8)

    let info = try await api.ping()

    XCTAssertEqual(info.type, "subsonic")
    XCTAssertFalse(info.isOpenSubsonic)
  }

  // MARK: - User

  func testUserReturnsSubsonicUser() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "user": {
            "username": "alice",
            "email": "alice@example.com",
            "scrobblingEnabled": true,
            "adminRole": true,
            "streamRole": true
          }
        }
      }
      """.utf8)

    let user = try await api.user(username: "alice")

    XCTAssertEqual(user.username, "alice")
    XCTAssertEqual(user.email, "alice@example.com")
    XCTAssertTrue(user.scrobblingEnabled)
    XCTAssertTrue(user.adminRole)
    XCTAssertTrue(user.streamRole)
    XCTAssertEqual(fakeTransport.lastRequest?.query.first?.name, "username")
  }

  // MARK: - Scan Status

  func testScanStatusReturnsStatus() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "scanStatus": {
            "scanning": true,
            "count": 1500,
            "folderCount": 50,
            "lastScan": "2024-01-15T10:30:00Z"
          }
        }
      }
      """.utf8)

    let status = try await api.scanStatus()

    XCTAssertTrue(status.scanning)
    XCTAssertEqual(status.count, 1500)
    XCTAssertEqual(status.folderCount, 50)
    XCTAssertNotNil(status.lastScan)
  }

  func testStartScanReturnsStatus() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "scanStatus": {
            "scanning": false,
            "count": 1500
          }
        }
      }
      """.utf8)

    let status = try await api.startScan()

    XCTAssertFalse(status.scanning)
    XCTAssertEqual(fakeTransport.lastRequest?.path, "startScan.view")
  }

  // MARK: - Album List

  func testAlbumListWithTypeAndPaging() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "albumList2": {
            "album": [
              {
                "id": "al1",
                "name": "Album 1",
                "artist": "Artist 1",
                "songCount": 10,
                "duration": 2400
              }
            ]
          }
        }
      }
      """.utf8)

    let albums = try await api.albumList(.newest, size: 20, offset: 0, fromYear: nil, toYear: nil, genre: nil)

    XCTAssertEqual(albums.count, 1)
    XCTAssertEqual(albums[0].id, "al1")
    XCTAssertEqual(albums[0].name, "Album 1")

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "type" && $0.value == "newest" })
    XCTAssertTrue(query.contains { $0.name == "size" && $0.value == "20" })
  }

  func testAlbumListByYearIncludesYearRange() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "albumList2": { "album": [] }
        }
      }
      """.utf8)

    _ = try await api.albumList(.byYear, size: 10, offset: 0, fromYear: 2000, toYear: 2020, genre: nil)

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "fromYear" && $0.value == "2000" })
    XCTAssertTrue(query.contains { $0.name == "toYear" && $0.value == "2020" })
  }

  func testAlbumListByGenreIncludesGenre() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "albumList2": { "album": [] }
        }
      }
      """.utf8)

    _ = try await api.albumList(.byGenre, size: 10, offset: 0, fromYear: nil, toYear: nil, genre: "Rock")

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "genre" && $0.value == "Rock" })
  }

  // MARK: - Album Detail

  func testAlbumReturnsAlbumWithSongs() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "album": {
            "id": "al1",
            "name": "Album",
            "artist": "Artist",
            "songCount": 2,
            "duration": 480,
            "song": [
              {
                "id": "s1",
                "title": "Song 1",
                "album": "Album",
                "artist": "Artist",
                "duration": 240
              },
              {
                "id": "s2",
                "title": "Song 2",
                "album": "Album",
                "artist": "Artist",
                "duration": 240
              }
            ]
          }
        }
      }
      """.utf8)

    let detail = try await api.album(id: "al1")

    XCTAssertEqual(detail.album.id, "al1")
    XCTAssertEqual(detail.songs.count, 2)
    XCTAssertEqual(detail.songs[0].id, "s1")
  }

  func testAlbumHandlesSingleSongAsObject() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "album": {
            "id": "al1",
            "name": "Album",
            "artist": "Artist",
            "songCount": 1,
            "duration": 240,
            "song": {
              "id": "s1",
              "title": "Song",
              "album": "Album",
              "artist": "Artist",
              "duration": 240
            }
          }
        }
      }
      """.utf8)

    let detail = try await api.album(id: "al1")

    XCTAssertEqual(detail.songs.count, 1)
    XCTAssertEqual(detail.songs[0].id, "s1")
  }

  // MARK: - Album Info

  func testAlbumInfoReturnsMetadata() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "albumInfo": {
            "notes": "Great album",
            "musicBrainzId": "mb123",
            "lastFmUrl": "https://last.fm/album",
            "largeImageUrl": "https://example.com/large.jpg"
          }
        }
      }
      """.utf8)

    let info = try await api.albumInfo(id: "al1")

    XCTAssertEqual(info.notes, "Great album")
    XCTAssertEqual(info.musicBrainzId, "mb123")
    XCTAssertEqual(info.largeImageUrl, "https://example.com/large.jpg")
  }

  // MARK: - Artists

  func testArtistsFlattensIndexes() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "artists": {
            "index": [
              {
                "name": "A",
                "artist": [
                  {
                    "id": "ar1",
                    "name": "Alice",
                    "albumCount": 5
                  }
                ]
              },
              {
                "name": "B",
                "artist": [
                  {
                    "id": "ar2",
                    "name": "Bob",
                    "albumCount": 3
                  }
                ]
              }
            ]
          }
        }
      }
      """.utf8)

    let artists = try await api.artists()

    XCTAssertEqual(artists.count, 2)
    XCTAssertEqual(artists[0].id, "ar1")
    XCTAssertEqual(artists[1].id, "ar2")
  }

  // MARK: - Artist Detail

  func testArtistReturnsArtistWithAlbums() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "artist": {
            "id": "ar1",
            "name": "Artist",
            "albumCount": 2,
            "album": [
              {
                "id": "al1",
                "name": "Album 1",
                "artist": "Artist",
                "songCount": 10,
                "duration": 2400
              }
            ]
          }
        }
      }
      """.utf8)

    let detail = try await api.artist(id: "ar1")

    XCTAssertEqual(detail.artist.id, "ar1")
    XCTAssertEqual(detail.albums.count, 1)
  }

  // MARK: - Artist Info

  func testArtistInfoReturnsBiographyAndSimilar() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "artistInfo2": {
            "biography": "Bio text",
            "musicBrainzId": "mb123",
            "similarArtist": [
              {
                "id": "ar2",
                "name": "Similar",
                "albumCount": 2
              }
            ]
          }
        }
      }
      """.utf8)

    let info = try await api.artistInfo(id: "ar1")

    XCTAssertEqual(info.biography, "Bio text")
    XCTAssertEqual(info.similarArtists.count, 1)
    XCTAssertEqual(info.similarArtists[0].name, "Similar")
  }

  func testArtistInfoAcceptsArtistInfo1Fallback() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "artistInfo": {
            "biography": "Old bio"
          }
        }
      }
      """.utf8)

    let info = try await api.artistInfo(id: "ar1")

    XCTAssertEqual(info.biography, "Old bio")
  }

  // MARK: - Top Songs

  func testTopSongsReturnsList() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "topSongs": {
            "song": [
              {
                "id": "s1",
                "title": "Popular Song",
                "album": "Album",
                "artist": "Artist",
                "duration": 240
              }
            ]
          }
        }
      }
      """.utf8)

    let songs = try await api.topSongs(artistName: "Artist", count: 10)

    XCTAssertEqual(songs.count, 1)
    XCTAssertEqual(songs[0].title, "Popular Song")

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "artist" && $0.value == "Artist" })
    XCTAssertTrue(query.contains { $0.name == "count" && $0.value == "10" })
  }

  // MARK: - Song

  func testSongReturnsSingleSong() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "song": {
            "id": "s1",
            "title": "Track",
            "album": "Album",
            "artist": "Artist",
            "duration": 240,
            "track": 1,
            "year": 2020
          }
        }
      }
      """.utf8)

    let song = try await api.song(id: "s1")

    XCTAssertEqual(song.id, "s1")
    XCTAssertEqual(song.title, "Track")
    XCTAssertEqual(song.track, 1)
  }

  // MARK: - Random Songs

  func testRandomSongsWithFilters() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "randomSongs": {
            "song": []
          }
        }
      }
      """.utf8)

    _ = try await api.randomSongs(size: 20, genre: "Rock", fromYear: 2000, toYear: 2020)

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "size" && $0.value == "20" })
    XCTAssertTrue(query.contains { $0.name == "genre" && $0.value == "Rock" })
    XCTAssertTrue(query.contains { $0.name == "fromYear" && $0.value == "2000" })
  }

  // MARK: - Genres

  func testGenresReturnsGenresList() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "genres": {
            "genre": [
              {
                "value": "Rock",
                "songCount": 100,
                "albumCount": 20
              },
              {
                "value": "Pop",
                "songCount": 80
              }
            ]
          }
        }
      }
      """.utf8)

    let genres = try await api.genres()

    XCTAssertEqual(genres.count, 2)
    XCTAssertEqual(genres[0].name, "Rock")
    XCTAssertEqual(genres[0].songCount, 100)
    XCTAssertEqual(genres[1].name, "Pop")
    XCTAssertEqual(genres[1].albumCount, 0)
  }

  // MARK: - Starred

  func testStarredReturnsArtistsAlbumsAndSongs() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "starred2": {
            "artist": [
              {
                "id": "ar1",
                "name": "Fav Artist",
                "albumCount": 3
              }
            ],
            "album": [
              {
                "id": "al1",
                "name": "Fav Album",
                "artist": "Artist",
                "songCount": 12,
                "duration": 2400
              }
            ],
            "song": [
              {
                "id": "s1",
                "title": "Fav Song",
                "album": "Album",
                "artist": "Artist",
                "duration": 240
              }
            ]
          }
        }
      }
      """.utf8)

    let results = try await api.starred()

    XCTAssertEqual(results.artists.count, 1)
    XCTAssertEqual(results.albums.count, 1)
    XCTAssertEqual(results.songs.count, 1)
    XCTAssertEqual(results.artists[0].name, "Fav Artist")
  }

  // MARK: - Search

  func testSearchReturnsResultsWithPaging() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "searchResult3": {
            "artist": [],
            "album": [
              {
                "id": "al1",
                "name": "Search Result",
                "artist": "Artist",
                "songCount": 10,
                "duration": 2400
              }
            ],
            "song": []
          }
        }
      }
      """.utf8)

    let page = SearchPage.albums(count: 10, offset: 0)
    let results = try await api.search("query", page: page)

    XCTAssertEqual(results.albums.count, 1)

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "query" && $0.value == "query" })
    XCTAssertTrue(query.contains { $0.name == "albumCount" && $0.value == "10" })
  }

  // MARK: - Playlists

  func testPlaylistsReturnsPlaylistList() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "playlists": {
            "playlist": [
              {
                "id": "pl1",
                "name": "My Playlist",
                "owner": "alice",
                "public": false,
                "songCount": 5,
                "duration": 1200
              }
            ]
          }
        }
      }
      """.utf8)

    let playlists = try await api.playlists()

    XCTAssertEqual(playlists.count, 1)
    XCTAssertEqual(playlists[0].name, "My Playlist")
    XCTAssertFalse(playlists[0].isPublic)
  }

  // MARK: - Playlist Detail

  func testPlaylistReturnsPlaylistWithSongs() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "playlist": {
            "id": "pl1",
            "name": "Playlist",
            "owner": "alice",
            "songCount": 1,
            "duration": 240,
            "entry": [
              {
                "id": "s1",
                "title": "Song",
                "album": "Album",
                "artist": "Artist",
                "duration": 240
              }
            ]
          }
        }
      }
      """.utf8)

    let detail = try await api.playlist(id: "pl1")

    XCTAssertEqual(detail.playlist.id, "pl1")
    XCTAssertEqual(detail.songs.count, 1)
  }

  // MARK: - Create Playlist

  func testCreatePlaylistWithSongs() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "playlist": {
            "id": "pl1",
            "name": "New",
            "owner": "alice",
            "songCount": 2,
            "duration": 480,
            "entry": [
              {
                "id": "s1",
                "title": "Song 1",
                "album": "Album",
                "artist": "Artist",
                "duration": 240
              }
            ]
          }
        }
      }
      """.utf8)

    let detail = try await api.createPlaylist(name: "New", songIds: ["s1", "s2"])

    XCTAssertNotNil(detail)
    XCTAssertEqual(detail?.playlist.name, "New")

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "name" && $0.value == "New" })
    let songIds = query.filter { $0.name == "songId" }
    XCTAssertEqual(songIds.count, 2)
  }

  func testCreatePlaylistWithoutResponseReturnsNil() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    let detail = try await api.createPlaylist(name: "New", songIds: ["s1"])

    XCTAssertNil(detail)
  }

  // MARK: - Update Playlist

  func testUpdatePlaylistSendsChanges() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    let changes = PlaylistChanges(
      name: "Updated",
      comment: "New comment",
      isPublic: true,
      songIdsToAdd: ["s3"],
      songIndexesToRemove: [0]
    )
    try await api.updatePlaylist(id: "pl1", changes: changes)

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "playlistId" && $0.value == "pl1" })
    XCTAssertTrue(query.contains { $0.name == "name" && $0.value == "Updated" })
    XCTAssertTrue(query.contains { $0.name == "public" && $0.value == "true" })
  }

  func testUpdatePlaylistWithEmptyChangesDoesNotSend() async throws {
    let changes = PlaylistChanges()
    try await api.updatePlaylist(id: "pl1", changes: changes)

    XCTAssertNil(fakeTransport.lastRequest)
  }

  // MARK: - Delete Playlist

  func testDeletePlaylistSendsRequest() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    try await api.deletePlaylist(id: "pl1")

    XCTAssertEqual(fakeTransport.lastRequest?.path, "deletePlaylist.view")
  }

  // MARK: - Star / Unstar

  func testStarSends() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    let target = StarTarget(songIds: ["s1"], albumIds: ["al1"], artistIds: ["ar1"])
    try await api.star(target)

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertEqual(query.filter { $0.name == "id" }.count, 1)
    XCTAssertEqual(query.filter { $0.name == "albumId" }.count, 1)
    XCTAssertEqual(query.filter { $0.name == "artistId" }.count, 1)
  }

  func testStarWithEmptyTargetDoesNotSend() async throws {
    let target = StarTarget()
    try await api.star(target)

    XCTAssertNil(fakeTransport.lastRequest)
  }

  func testUnstarSends() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    try await api.unstar(.song("s1"))

    XCTAssertEqual(fakeTransport.lastRequest?.path, "unstar.view")
  }

  // MARK: - Scrobble

  func testScrobbleSendsWithTime() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    let time = Date(timeIntervalSince1970: 1000)
    try await api.scrobble(songId: "s1", submission: true, time: time)

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "submission" && $0.value == "true" })
    XCTAssertTrue(query.contains { $0.name == "time" && $0.value == "1000000" })
  }

  // MARK: - Radio Stations

  func testRadioStationsReturnsStations() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "internetRadioStations": {
            "internetRadioStation": [
              {
                "id": "r1",
                "name": "Station",
                "streamUrl": "https://stream.example.com",
                "homePageUrl": "https://example.com"
              }
            ]
          }
        }
      }
      """.utf8)

    let stations = try await api.radioStations()

    XCTAssertEqual(stations.count, 1)
    XCTAssertEqual(stations[0].name, "Station")
    XCTAssertEqual(stations[0].homePageUrl, "https://example.com")
  }

  func testRadioStationFallbackHomepageUrl() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "internetRadioStations": {
            "internetRadioStation": [
              {
                "id": "r1",
                "name": "Station",
                "streamUrl": "https://stream.example.com",
                "homepageUrl": "https://example.com"
              }
            ]
          }
        }
      }
      """.utf8)

    let stations = try await api.radioStations()

    XCTAssertEqual(stations[0].homePageUrl, "https://example.com")
  }

  // MARK: - Create Radio Station

  func testCreateRadioStationWithOptionalUrl() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    try await api.createRadioStation(
      name: "New Station",
      streamUrl: "https://stream.example.com",
      homePageUrl: "https://example.com"
    )

    let query = fakeTransport.lastRequest?.query ?? []
    XCTAssertTrue(query.contains { $0.name == "streamUrl" && $0.value == "https://stream.example.com" })
    XCTAssertTrue(query.contains { $0.name == "homepageUrl" && $0.value == "https://example.com" })
    XCTAssertEqual(fakeTransport.lastRequest?.method, .post)
  }

  // MARK: - Lyrics

  func testLyricsReturnsPlainLyrics() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "lyrics": {
            "artist": "Artist",
            "title": "Song",
            "value": "Line 1\\nLine 2"
          }
        }
      }
      """.utf8)

    let lyrics = try await api.lyrics(artist: "Artist", title: "Song")

    XCTAssertNotNil(lyrics)
    XCTAssertEqual(lyrics?.artist, "Artist")
    XCTAssertEqual(lyrics?.title, "Song")
  }

  func testLyricsReturnsNilWhenMissing() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok"
        }
      }
      """.utf8)

    let lyrics = try await api.lyrics(artist: "Artist", title: "Song")

    XCTAssertNil(lyrics)
  }

  func testLyricsReturnsNilWhenValueEmpty() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "lyrics": {
            "artist": "Artist",
            "title": "Song",
            "value": ""
          }
        }
      }
      """.utf8)

    let lyrics = try await api.lyrics(artist: "Artist", title: "Song")

    XCTAssertNil(lyrics)
  }

  // MARK: - Structured Lyrics

  func testLyricsBySongIdReturnsStructured() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "lyricsList": {
            "structuredLyrics": [
              {
                "lang": "en",
                "synced": true,
                "offset": 0,
                "displayTitle": "Song",
                "line": [
                  {
                    "start": 1000,
                    "value": "First line"
                  },
                  {
                    "start": 3000,
                    "value": "Second line"
                  }
                ]
              }
            ]
          }
        }
      }
      """.utf8)

    let lyrics = try await api.lyricsBySongId("s1")

    XCTAssertEqual(lyrics.count, 1)
    XCTAssertEqual(lyrics[0].lang, "en")
    XCTAssertTrue(lyrics[0].synced)
    XCTAssertEqual(lyrics[0].lines.count, 2)
    XCTAssertEqual(lyrics[0].lines[0].start, 1000)
  }

  // MARK: - Error Handling

  func testAuthenticationFailedError() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "failed",
          "error": {
            "code": 40,
            "message": "Wrong username or password"
          }
        }
      }
      """.utf8)

    do {
      _ = try await api.ping()
      XCTFail("Expected authentication error")
    } catch SubsonicAPIError.authenticationFailed(let message) {
      XCTAssertEqual(message, "Wrong username or password")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNotAuthorizedError() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "failed",
          "error": {
            "code": 50,
            "message": "No stream role"
          }
        }
      }
      """.utf8)

    do {
      _ = try await api.ping()
      XCTFail("Expected authorization error")
    } catch SubsonicAPIError.notAuthorized(let message) {
      XCTAssertEqual(message, "No stream role")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNotFoundError() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "failed",
          "error": {
            "code": 70,
            "message": "Album not found"
          }
        }
      }
      """.utf8)

    do {
      _ = try await api.album(id: "missing")
      XCTFail("Expected not found error")
    } catch SubsonicAPIError.notFound(let message) {
      XCTAssertEqual(message, "Album not found")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testUnsupportedErrorForUnknownMethod() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "failed",
          "error": {
            "code": 0,
            "message": "Unknown method"
          }
        }
      }
      """.utf8)

    do {
      _ = try await api.ping()
      XCTFail("Expected unsupported error")
    } catch SubsonicAPIError.unsupported {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testServerErrorForOtherCodes() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "failed",
          "error": {
            "code": 99,
            "message": "Some error"
          }
        }
      }
      """.utf8)

    do {
      _ = try await api.ping()
      XCTFail("Expected server error")
    } catch SubsonicAPIError.server(let code, let message) {
      XCTAssertEqual(code, 99)
      XCTAssertEqual(message, "Some error")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testInvalidResponseForMissingEnvelope() async throws {
    fakeTransport.returnData = Data("""
      {"invalid": "response"}
      """.utf8)

    do {
      _ = try await api.ping()
      XCTFail("Expected invalid response error")
    } catch SubsonicAPIError.invalidResponse {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSongFieldConversionsHandleNumbersAsStrings() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "song": {
            "id": "s1",
            "title": "Song",
            "album": "Album",
            "artist": "Artist",
            "duration": "240",
            "track": "5",
            "year": "2020",
            "size": "5000000"
          }
        }
      }
      """.utf8)

    let song = try await api.song(id: "s1")

    XCTAssertEqual(song.duration, 240)
    XCTAssertEqual(song.track, 5)
    XCTAssertEqual(song.year, 2020)
    XCTAssertEqual(song.size, 5000000)
  }

  func testAlbumFieldHandlesOpenSubsonicExtensions() async throws {
    fakeTransport.returnData = Data("""
      {
        "subsonic-response": {
          "status": "ok",
          "album": {
            "id": "al1",
            "name": "Album",
            "artist": "Artist",
            "songCount": 10,
            "duration": 2400,
            "artists": [
              {
                "id": "ar1",
                "name": "Alice"
              }
            ],
            "displayArtist": "Alice & Bob",
            "genres": [
              {
                "name": "Rock"
              }
            ],
            "releaseDate": {
              "year": 2020,
              "month": 6,
              "day": 15
            },
            "explicitStatus": "explicit",
            "isCompilation": true
          }
        }
      }
      """.utf8)

    let detail = try await api.album(id: "al1")

    XCTAssertEqual(detail.album.artists.count, 1)
    XCTAssertEqual(detail.album.displayArtist, "Alice & Bob")
    XCTAssertEqual(detail.album.genres.count, 1)
    XCTAssertNotNil(detail.album.releaseDate)
    XCTAssertEqual(detail.album.releaseDate?.year, 2020)
    XCTAssertEqual(detail.album.explicitStatus, .explicit)
    XCTAssertTrue(detail.album.isCompilation)
  }
}

// MARK: - Fake Transport

private nonisolated(unsafe) let _fakeTransportLock = NSLock()

private final class FakeSubsonicTransport: SubsonicTransport {
  private var _returnData = Data()
  private var _lastRequest: SubsonicRequest?
  private var _shouldThrow: SubsonicAPIError?

  var returnData: Data {
    get {
      _fakeTransportLock.withLock { _returnData }
    }
    set {
      _fakeTransportLock.withLock { _returnData = newValue }
    }
  }

  var lastRequest: SubsonicRequest? {
    get {
      _fakeTransportLock.withLock { _lastRequest }
    }
    set {
      _fakeTransportLock.withLock { _lastRequest = newValue }
    }
  }

  var shouldThrow: SubsonicAPIError? {
    get {
      _fakeTransportLock.withLock { _shouldThrow }
    }
    set {
      _fakeTransportLock.withLock { _shouldThrow = newValue }
    }
  }

  func send(_ request: SubsonicRequest) async throws -> Data {
    _fakeTransportLock.withLock { _lastRequest = request }
    if let error = _fakeTransportLock.withLock({ _shouldThrow }) {
      throw error
    }
    return _fakeTransportLock.withLock { _returnData }
  }
}
