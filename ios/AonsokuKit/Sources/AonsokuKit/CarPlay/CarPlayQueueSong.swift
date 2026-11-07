import Foundation

extension SongRecord {
    func toQueueSong(useAlbumCoverForSongs: Bool = false) -> QueueSong {
        let tags = replayGainJson.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(AudioReplayGain.self, from: $0) }
        return QueueSong(
            id: id, title: title, artist: artist ?? "", artistId: artistId,
            album: album ?? "", albumId: albumId, duration: Double(duration),
            coverArtId: useAlbumCoverForSongs ? (albumId ?? coverArt) : (coverArt ?? albumId),
            streamUrl: LibraryMediaReference(songID: id).urlString, replayGain: tags)
    }
}
