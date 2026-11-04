import AonsokuKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Songs dragged inside the app, declared in the Mac Info.plist.
    static let aonsokuSongs = UTType(exportedAs: "github.realtvop.aonsoku.songs")
}

/// Songs dragged from a list to a playlist in the sidebar or to the queue.
/// Other apps receive the titles as text.
struct MacSongTransfer: Codable, Transferable {
    var songIds: [String]
    var titles: [String]

    init(songs: [Song]) {
        songIds = songs.map(\.id)
        titles = songs.map { "\($0.title) — \($0.artistLine)" }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .aonsokuSongs)
        ProxyRepresentation(exporting: \.text)
    }

    private var text: String { titles.joined(separator: "\n") }
}
