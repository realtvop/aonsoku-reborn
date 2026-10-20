import AonsokuKit
import SwiftUI

/// Everything the server knows about a song, like the web song details
/// dialog, as a grouped list. The album, artists and genres link to their
/// pages.
struct SongInfoView: View {
    @State private var song: Song
    @State private var recordLabels: [String] = []

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    init(song: Song) {
        _song = State(initialValue: song)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                Section {
                    general
                }
                Section {
                    file
                }
                if let gain = song.replayGain {
                    Section(t("settings.audio.replayGain.group")) {
                        replayGain(gain)
                    }
                }
            }
            .themedBackground(grouped: true)
            .navigationTitle(t("songInfo.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await refresh()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            SongArtwork(song: song, size: .medium, cornerRadius: 8)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(song.artistLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !song.album.isEmpty {
                    Text(song.album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            FavoriteToolbarButton(kind: .song, id: song.id)
                .font(.title3)
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var general: some View {
        row(t("table.columns.title"), song.title)
        if !song.album.isEmpty {
            if let albumId = song.albumId {
                link(t("table.columns.album"), song.album) {
                    router.navigate(to: .album(id: albumId, preview: nil))
                }
            } else {
                row(t("table.columns.album"), song.album)
            }
        }
        artists(t("table.columns.albumArtist"), song.albumArtists)
        artists(t("table.columns.artist"), song.creditedArtists)
        if song.contributors.count > 1 {
            LabeledContent(t("table.columns.contributors")) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(song.contributors.enumerated()), id: \.offset) { _, contributor in
                        Text(contributorLine(contributor))
                    }
                }
                .multilineTextAlignment(.trailing)
            }
        }
        if let year = song.year, year > 0 {
            row(t("table.columns.year"), String(year))
        }
        row(t("table.columns.discNumber"), String(song.discNumber ?? 1))
        if let track = song.track, track > 0 {
            row(t("table.columns.track"), String(track))
        }
        if !recordLabels.isEmpty {
            row(t("table.columns.recordLabel"), recordLabels.joined(separator: "\n"))
        }
        ForEach(genres, id: \.self) { genre in
            link(t("table.columns.genres"), genre) {
                router.navigate(to: .albums(.byGenre(genre)))
            }
        }
        row(t("table.columns.duration"), Formatters.clock(TimeInterval(song.duration)))
        row(t("table.columns.plays"), Formatters.number(song.playCount ?? 0, locale: locale))
        row(t("table.columns.lastPlayed"), song.played.map { Formatters.relative($0, locale: locale) } ?? "—")
    }

    @ViewBuilder
    private var file: some View {
        if let path = song.path, !path.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("table.columns.path"))
                Text(path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
        if let size = song.size, size > 0 {
            row(t("table.columns.size"), Formatters.bytes(size, locale: locale))
        }
        if let suffix = song.suffix, !suffix.isEmpty {
            row(t("table.columns.codec"), suffix.uppercased())
        }
        if let bitRate = song.bitRate, bitRate > 0 {
            row(t("table.columns.bitrate"), "\(bitRate) kbps")
        }
        if let rate = song.samplingRate, rate > 0 {
            row(t("table.columns.samplingRate"), "\(Formatters.kilohertz(rate)) kHz")
        }
        if let depth = song.bitDepth, depth > 0 {
            row(t("table.columns.bitDepth"), "\(depth)-bit")
        }
        if let channels = song.channelCount, channels > 0 {
            row(t("table.columns.channelCount"), String(channels))
        }
        if let bpm = song.bpm, bpm > 0 {
            row(t("table.columns.bpm"), String(bpm))
        }
    }

    @ViewBuilder
    private func replayGain(_ gain: ReplayGainInfo) -> some View {
        row(t("table.columns.trackGain"), Formatters.decibels(gain.trackGain ?? 0))
        row(t("table.columns.trackPeak"), peak(gain.trackPeak))
        row(t("table.columns.albumGain"), Formatters.decibels(gain.albumGain ?? 0))
        row(t("table.columns.albumPeak"), peak(gain.albumPeak))
    }

    // MARK: - Rows

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    /// A row whose value opens another page.
    private func link(_ label: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 4) {
                    Text(value)
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            } label: {
                Text(label)
                    .foregroundStyle(.primary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// One row per credited artist, linking to those the server knows.
    @ViewBuilder
    private func artists(_ label: String, _ credits: [ArtistCredit]) -> some View {
        ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
            if let id = credit.id, !id.isEmpty {
                link(label, credit.name) {
                    router.navigate(to: .artist(id: id, name: credit.name))
                }
            } else {
                row(label, credit.name)
            }
        }
    }

    // MARK: - Values

    /// The genre and the OpenSubsonic genres, without repeats.
    private var genres: [String] {
        var seen = Set<String>()
        return ([song.genre].compactMap { $0 } + song.genres)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "Composer: Name", with the sub-role when there is one.
    private func contributorLine(_ contributor: Contributor) -> String {
        var role = contributor.role.capitalized(with: locale)
        if let subRole = contributor.subRole, !subRole.isEmpty {
            role += " (\(subRole))"
        }
        return "\(role): \(contributor.artist.name)"
    }

    private func peak(_ value: Double?) -> String {
        (value ?? 1).formatted(.number.precision(.fractionLength(0 ... 6)).locale(locale))
    }

    // MARK: - Loading

    /// The full song from the server, for fields lists leave out, and the
    /// album's record labels.
    private func refresh() async {
        let repository = app.repository
        if let loaded = try? await repository.song(id: song.id) {
            song = loaded
        }
        guard let albumId = song.albumId else { return }
        var album = await repository.cachedAlbum(id: albumId)?.album
        if album?.recordLabels.isEmpty ?? true, let loaded = try? await repository.album(id: albumId) {
            album = loaded.album
        }
        var seen = Set<String>()
        recordLabels = (album?.recordLabels ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(3)
            .map { $0 }
    }
}
