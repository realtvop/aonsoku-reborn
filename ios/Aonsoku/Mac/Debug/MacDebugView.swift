import AonsokuKit
import AppKit
import Perception
import SwiftUI

/// The native player debug window (Help ▸ Native Player Debug…), the Mac
/// counterpart of the iOS shake-to-debug panel and the Electron debug
/// window: Playback (what plays, transport, the queues), Info (the buffer,
/// the signed-in connection, memory) and Logs (the native log with level and
/// source filters, copy and clear), read from `DebugDataProvider` and
/// `NativeLogger` every two seconds.
struct MacDebugView: View {
    @Environment(Localizer.self) private var t

    @State private var tab = Tab.playback
    @State private var snapshot: AudioDebugSnapshot?
    @State private var connection: ConnectionDebugSnapshot?
    @State private var memoryMB: Double = 0
    @State private var entries: [NativeLogger.Entry] = []

    private let provider = DebugDataProvider()

    private enum Tab: Hashable {
        case playback, info, logs
    }

    var body: some View {
        WithPerceptionTracking {
            TabView(selection: $tab) {
                playback
                    .tabItem { Text(t("native.mac.debug.playback")) }
                    .tag(Tab.playback)
                info
                    .tabItem { Text(t("native.mac.debug.info")) }
                    .tag(Tab.info)
                MacDebugLogs(entries: entries) {
                    NativeLogger.shared.clear()
                    entries = []
                }
                .tabItem { Text(t("native.mac.debug.logs")) }
                .tag(Tab.logs)
            }
            .padding(12)
            .frame(minWidth: 640, minHeight: 460)
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func refresh() {
        snapshot = provider.audioSnapshot()
        connection = provider.connectionSnapshot()
        memoryMB = provider.memoryUsageMB()
        entries = NativeLogger.shared.getEntries()
    }

    // MARK: Playback

    private var playback: some View {
        Form {
            Section(t("native.mac.debug.nowPlaying")) {
                LabeledContent(t("native.mac.debug.track"), value: trackText)
                LabeledContent(t("native.mac.debug.time")) {
                    let buffered = t("native.mac.debug.buffered")
                    Text("\(time(snapshot?.currentTime)) / \(time(snapshot?.duration))  ·  \(buffered) \(time(snapshot?.bufferedTime))")
                        .monospacedDigit()
                }
                LabeledContent(t("native.mac.debug.mode")) {
                    let repeatTitle = t("shortcuts.playback.repeat")
                    let shuffleTitle = t("shortcuts.playback.shuffle")
                    let shuffle = snapshot?.shuffleEnabled == true ? "on" : "off"
                    Text("\(repeatTitle) \(snapshot?.repeatMode ?? "off") · \(shuffleTitle) \(shuffle)")
                }
                HStack {
                    Button(t("player.tooltips.previous"), systemImage: "backward.fill") {
                        provider.skipPrevious()
                        refreshSoon()
                    }
                    Button(
                        t(snapshot?.isPlaying == true ? "player.tooltips.pause" : "player.tooltips.play"),
                        systemImage: snapshot?.isPlaying == true ? "pause.fill" : "play.fill"
                    ) {
                        provider.playPause()
                        refreshSoon()
                    }
                    Button(t("player.tooltips.next"), systemImage: "forward.fill") {
                        provider.skipNext()
                        refreshSoon()
                    }
                }
                .disabled(snapshot?.title == nil)
            }
            queueSection(t("fullscreen.queue"), items: snapshot?.userQueue ?? [])
            queueSection(contextTitle, items: snapshot?.queue ?? [])
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func queueSection(_ title: String, items: [QueueItemInfo]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                            .opacity(item.isCurrent ? 1 : 0)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(time(item.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(item.isCurrent ? .isSelected : [])
                }
            }
        }
    }

    /// The context queue with the current position in it.
    private var contextTitle: String {
        let title = t("native.mac.debug.context")
        let position = (snapshot?.queueIndex ?? 0) + 1
        return "\(title) (\(position)/\(snapshot?.queueItemCount ?? 0))"
    }

    private var trackText: String {
        guard let snapshot, let title = snapshot.title else { return t("native.mac.debug.idle") }
        return [title, snapshot.artist, snapshot.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: Info

    private var info: some View {
        Form {
            Section(t("native.mac.debug.buffer")) {
                LabeledContent(t("native.mac.debug.status"), value: bufferStatus)
                LabeledContent(t("native.mac.debug.buffered"), value: time(snapshot?.bufferedTime))
                LabeledContent(t("native.mac.debug.recovery"), value: snapshot?.recoveryState ?? "idle")
            }
            Section(t("native.mac.debug.connection")) {
                if let connection {
                    LabeledContent(t("settings.options.server"), value: connection.serverUrl)
                    LabeledContent(t("native.mac.debug.user"), value: connection.username)
                    LabeledContent(t("native.mac.debug.auth"), value: "\(connection.authType) · \(connection.protocolVersion)")
                    LabeledContent(
                        t("native.mac.debug.serverType"),
                        value: connection.serverType + (connection.hasFallbackUrl ? " + fallback" : "")
                    )
                } else {
                    Text(t("native.mac.debug.noCredentials")).foregroundStyle(.secondary)
                }
            }
            Section(t("native.mac.debug.system")) {
                LabeledContent(t("native.mac.debug.memory"), value: String(format: "%.1f MB", memoryMB))
                LabeledContent(t("native.mac.debug.version"), value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
        }
        .formStyle(.grouped)
    }

    private var bufferStatus: String {
        guard let snapshot else { return "—" }
        if snapshot.bufferEmpty { return "EMPTY" }
        return snapshot.likelyToKeepUp ? "OK" : "LOW"
    }

    private func time(_ seconds: Double?) -> String {
        Formatters.clock(max(seconds ?? 0, 0))
    }

    /// Transport settles on the audio queue; look again shortly after.
    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
        }
    }
}

/// The native log: newest last, filtered by level, source and text, with
/// Copy (also ⌘C) for the selected or shown entries and Clear.
private struct MacDebugLogs: View {
    let entries: [NativeLogger.Entry]
    let clear: () -> Void

    @Environment(Localizer.self) private var t

    @State private var levels = Set(NativeLogger.Entry.Level.allCases)
    @State private var hiddenSources: Set<String> = []
    @State private var query = ""
    @State private var selection: Set<Int> = []

    private struct Row: Identifiable {
        let id: Int
        let entry: NativeLogger.Entry
    }

    var body: some View {
        WithPerceptionTracking {
            let rows = shownRows
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(NativeLogger.Entry.Level.allCases, id: \.self) { level in
                        Toggle(level.rawValue.uppercased(), isOn: Binding(
                            get: { levels.contains(level) },
                            set: { isOn in
                                if isOn { levels.insert(level) } else { levels.remove(level) }
                            }
                        ))
                        .toggleStyle(.button)
                    }
                    Menu(t("native.mac.debug.sources")) {
                        ForEach(sources, id: \.self) { source in
                            Toggle(source, isOn: Binding(
                                get: { !hiddenSources.contains(source) },
                                set: { isOn in
                                    if isOn { hiddenSources.remove(source) } else { hiddenSources.insert(source) }
                                }
                            ))
                        }
                    }
                    .fixedSize()
                    TextField(t("native.mac.debug.filter"), text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button(t("native.mac.debug.copy")) {
                        copy(rows)
                    }
                    .disabled(rows.isEmpty)
                    Button(t("generic.clear"), role: .destructive, action: clear)
                        .disabled(entries.isEmpty)
                }
                Table(rows, selection: $selection) {
                    TableColumn(t("native.mac.debug.time")) { row in
                        Text(row.entry.timestamp, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 80, max: 100)
                    TableColumn(t("native.mac.debug.level")) { row in
                        Text(row.entry.level.rawValue.uppercased())
                            .foregroundStyle(Self.color(of: row.entry.level))
                    }
                    .width(min: 50, ideal: 56, max: 70)
                    TableColumn(t("native.mac.debug.source")) { row in
                        Text(row.entry.source)
                    }
                    .width(min: 80, ideal: 120, max: 200)
                    TableColumn(t("native.mac.debug.message")) { row in
                        Text(row.entry.message)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .onCopyCommand {
                    [NSItemProvider(object: Self.text(of: rows.filter { selection.isEmpty || selection.contains($0.id) }) as NSString)]
                }
            }
        }
    }

    private var sources: [String] {
        Array(Set(entries.map(\.source))).sorted()
    }

    private var shownRows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.enumerated().compactMap { index, entry in
            guard levels.contains(entry.level), !hiddenSources.contains(entry.source) else { return nil }
            if !needle.isEmpty, !entry.message.lowercased().contains(needle), !entry.source.lowercased().contains(needle) {
                return nil
            }
            return Row(id: index, entry: entry)
        }
    }

    /// The selected rows, or every row shown when none is selected.
    private func copy(_ rows: [Row]) {
        let chosen = selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.text(of: chosen), forType: .string)
    }

    private static func text(of rows: [Row]) -> String {
        let formatter = ISO8601DateFormatter()
        return rows.map { row in
            "\(formatter.string(from: row.entry.timestamp)) [\(row.entry.level.rawValue.uppercased())] [\(row.entry.source)] \(row.entry.message)"
        }
        .joined(separator: "\n")
    }

    private static func color(of level: NativeLogger.Entry.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warn: .orange
        case .error: .red
        }
    }
}
