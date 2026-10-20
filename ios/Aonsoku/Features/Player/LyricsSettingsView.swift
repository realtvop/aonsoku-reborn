import AonsokuKit
import SwiftUI

/// Lyrics for the playing song, like the web lyrics settings: hide them,
/// shift their timing, and pick lyrics from the custom lyrics server.
struct LyricsSettingsView: View {
    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var candidates: [CustomLyricsCandidate] = []
    @State private var searchPhase = LoadPhase.idle
    @State private var choosing: String?

    @Environment(PlayerStore.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let song = player.currentSong {
                    Section {
                        header(song)
                        Toggle(t("lyrics.customSelect.disableLyrics"), isOn: isDisabled)
                    }
                    offset
                    currentSelection(song)
                    if isCustomServerReady {
                        search
                        results
                    } else {
                        Section {
                        } footer: {
                            Text(t("lyrics.customSelect.serverDisabled"))
                        }
                    }
                } else {
                    ContentUnavailableView(t("lyrics.customSelect.noSong"), systemImage: "quote.bubble")
                }
            }
            .themedBackground(grouped: true)
            .navigationTitle(t("lyrics.customSelect.title"))
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
        .task(id: player.currentSong?.id) {
            guard let song = player.currentSong else { return }
            searchTitle = song.title
            searchArtist = song.artist
            await runSearch()
        }
    }

    private var isCustomServerReady: Bool {
        let lyricsSettings = settings.settings.lyrics
        return lyricsSettings.customServerEnabled
            && !lyricsSettings.customServerUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func header(_ song: Song) -> some View {
        HStack(spacing: 12) {
            SongArtwork(song: song, size: .small, cornerRadius: 6)
                .frame(width: 48, height: 48)
            Text(t("lyrics.customSelect.subtitle", ["title": song.title, "artist": song.artistLine]))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var isDisabled: Binding<Bool> {
        Binding(
            get: { lyrics.selection.disabled },
            set: { disabled in
                Task { await lyrics.setDisabled(disabled) }
            }
        )
    }

    // MARK: - Offset

    private var offset: some View {
        let value = lyrics.selection.offset
        return Section {
            HStack {
                Text(Self.formatOffset(value))
                    .font(.body.monospacedDigit().weight(.semibold))
                Spacer()
                Button(t("lyrics.customSelect.offsetReset")) {
                    lyrics.setOffset(0)
                }
                .disabled(value == 0 || lyrics.selection.disabled)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { lyrics.setOffset(($0 * 10).rounded() / 10) }
                ),
                in: CustomLyricsSelection.offsetRange,
                step: CustomLyricsSelection.offsetStep
            ) {
                Text(t("lyrics.customSelect.offsetLabel"))
            } minimumValueLabel: {
                Text(Self.formatOffset(CustomLyricsSelection.offsetRange.lowerBound))
            } maximumValueLabel: {
                Text(Self.formatOffset(CustomLyricsSelection.offsetRange.upperBound))
            }
            .font(.caption)
            .disabled(lyrics.selection.disabled)
        } header: {
            Text(t("lyrics.customSelect.offsetLabel"))
        } footer: {
            Text(t("lyrics.customSelect.offsetHint"))
        }
    }

    /// "+0.3s", as the web shows offsets.
    static func formatOffset(_ offset: Double) -> String {
        let rounded = (offset * 10).rounded() / 10
        return String(format: rounded > 0 ? "+%.1fs" : "%.1fs", rounded)
    }

    // MARK: - Selection

    @ViewBuilder
    private func currentSelection(_ song: Song) -> some View {
        let selection = lyrics.selection
        if selection.key != nil, !selection.disabled {
            Section {
                HStack {
                    Text(t(
                        "lyrics.customSelect.currentSelection",
                        ["title": selection.title ?? song.title, "artist": selection.artist ?? song.artist]
                    ))
                    .font(.subheadline)
                    Spacer()
                    Button(t("lyrics.customSelect.offsetReset")) {
                        Task { await lyrics.resetSelection() }
                    }
                }
            }
        }
    }

    // MARK: - Search

    private var search: some View {
        Section {
            TextField(t("lyrics.customSelect.searchTitle"), text: $searchTitle)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            TextField(t("lyrics.customSelect.searchArtist"), text: $searchArtist)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            Button {
                Task { await runSearch() }
            } label: {
                HStack {
                    Label(t("lyrics.customSelect.search"), systemImage: "magnifyingglass")
                    if searchPhase == .loading {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!canSearch || searchPhase == .loading)
        }
    }

    @ViewBuilder
    private var results: some View {
        switch searchPhase {
        case .idle, .loading:
            EmptyView()
        case let .failed(message):
            Section {
                Text(message.isEmpty ? t("toast.server.error") : message)
                    .foregroundStyle(.secondary)
            }
        case .loaded:
            if candidates.isEmpty {
                Section {
                    Text(t("lyrics.customSelect.empty"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(candidates) { candidate in
                        Button {
                            choose(candidate)
                        } label: {
                            CandidateRow(
                                candidate: candidate,
                                isSelected: candidate.id == lyrics.selection.key,
                                isChoosing: choosing == candidate.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(choosing != nil)
                    }
                }
            }
        }
    }

    private var canSearch: Bool {
        !searchTitle.trimmingCharacters(in: .whitespaces).isEmpty
            || !searchArtist.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runSearch() async {
        guard isCustomServerReady, canSearch else { return }
        searchPhase = .loading
        do {
            candidates = try await lyrics.searchCandidates(
                title: searchTitle.trimmingCharacters(in: .whitespaces),
                artist: searchArtist.trimmingCharacters(in: .whitespaces)
            )
            searchPhase = .loaded
        } catch {
            guard !(error is CancellationError) else { return }
            searchPhase = .failed(error.localizedDescription)
        }
    }

    private func choose(_ candidate: CustomLyricsCandidate) {
        guard !candidate.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toasts.show(.key("lyrics.customSelect.saveError"), style: .error)
            return
        }
        choosing = candidate.id
        Task {
            await lyrics.select(candidate)
            choosing = nil
            dismiss()
        }
    }
}

/// One result: title, artist, whether it has romanization, the server id
/// and the first lines.
private struct CandidateRow: View {
    let candidate: CustomLyricsCandidate
    let isSelected: Bool
    let isChoosing: Bool

    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.headline)
                        .lineLimit(1)
                    if candidate.romaji?.isEmpty == false {
                        Text(t("lyrics.customSelect.hasRomaji"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                Text([candidate.artist, candidate.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let serverId = candidate.serverId, !serverId.isEmpty {
                    Text(t("lyrics.customSelect.lyricsId", ["id": serverId]))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(preview.isEmpty ? t("lyrics.customSelect.noPreview") : preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if isChoosing {
                ProgressView()
            } else {
                Text(t(isSelected ? "lyrics.customSelect.selected" : "lyrics.customSelect.select"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// The first lines without LRC timestamps.
    private var preview: String {
        candidate.lyrics
            .split(whereSeparator: \.isNewline)
            .map { $0.replacing(#/\[[0-9:.]+\]/#, with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "\n")
    }
}
