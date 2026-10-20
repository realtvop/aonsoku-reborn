import AonsokuKit
import SwiftUI

/// Cross-device playback, like the web device panel: this device, devices
/// playing now to control or continue here, and recent playback from
/// devices that went offline.
struct DevicesView: View {
    @State private var pendingHandoff: DevicePlaybackSummary?
    @State private var isRetrying = false

    @Environment(CoordinationStore.self) private var coordination
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let status = HandoffStatusText(coordination.handoffStatus, t) {
                    Section {
                        Label {
                            Text(status.text)
                        } icon: {
                            if status.isFailure {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
                Section {
                    ThisDeviceRow()
                } header: {
                    Text(t("settings.crossDevice.playback.thisDevice"))
                } footer: {
                    if coordination.state.isConnected {
                        Text(t("settings.crossDevice.statusInfo"))
                    }
                }
                connectionSections
            }
            .themedBackground(grouped: true)
            .navigationTitle(t("settings.crossDevice.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("settings.label"), systemImage: "gearshape") {
                        router.openSettings(.crossDevice)
                    }
                }
            }
            .refreshable {
                try? await coordination.refreshDevices()
            }
            .task {
                // Opening the panel reconnects, as the web panel does.
                if coordination.isRegistered, !coordination.state.isConnected {
                    await coordination.reconnect()
                }
                try? await coordination.refreshDevices()
            }
            .alert(
                t("settings.crossDevice.playback.continueConfirmTitle"),
                isPresented: isConfirmingHandoff,
                presenting: pendingHandoff
            ) { summary in
                Button(t("settings.crossDevice.playback.relay")) {
                    continueHere(summary)
                }
                Button(t("generic.cancel"), role: .cancel) {}
            } message: { _ in
                Text(t("settings.crossDevice.playback.continueConfirmDesc"))
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var connectionSections: some View {
        if !coordination.isRegistered {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(t("settings.crossDevice.error.unconfiguredTitle"), systemImage: "link")
                        .font(.headline)
                    Text(t("settings.crossDevice.error.unconfiguredDescription"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Button(t("settings.crossDevice.connect")) {
                    router.openSettings(.crossDevice)
                }
            }
        } else if !coordination.state.isConnected {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(t("settings.crossDevice.error.connectFailed"), systemImage: "wifi.slash")
                        .font(.headline)
                    Text(t("settings.crossDevice.error.disconnectedDescription"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Button {
                    retry()
                } label: {
                    HStack {
                        Text(t("settings.crossDevice.retry"))
                        if isRetrying || isConnecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRetrying || isConnecting)
            }
        } else {
            let groups = coordination.groups
            if !groups.live.isEmpty {
                Section(t("settings.crossDevice.playback.liveDevices")) {
                    ForEach(groups.live) { summary in
                        DevicePlaybackRow(summary: summary)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                liveActions(summary)
                            }
                            .contextMenu {
                                liveActions(summary)
                            }
                    }
                }
            }
            if !groups.offlineSnapshots.isEmpty {
                Section(t("settings.crossDevice.playback.offlineSnapshots")) {
                    ForEach(groups.offlineSnapshots) { summary in
                        DevicePlaybackRow(summary: summary)
                            .contextMenu {
                                if summary.canContinueHere {
                                    continueButton(summary, title: t("settings.crossDevice.playback.continue"))
                                }
                            }
                    }
                }
            }
        }
    }

    /// Control or stop controlling, and continue here.
    @ViewBuilder
    private func liveActions(_ summary: DevicePlaybackSummary) -> some View {
        if coordination.controlledDeviceId == summary.id {
            Button {
                coordination.stopControlling()
            } label: {
                Label(t("settings.crossDevice.playback.exitControl"), systemImage: "xmark.circle")
            }
            .tint(.gray)
        } else if summary.canBeControlled {
            Button {
                coordination.control(deviceId: summary.id)
                dismiss()
            } label: {
                Label(t("settings.crossDevice.playback.remoteControl"), systemImage: "hand.tap")
            }
            .tint(.indigo)
        }
        if summary.canContinueHere {
            continueButton(summary, title: t("settings.crossDevice.playback.relay"))
        }
    }

    private func continueButton(_ summary: DevicePlaybackSummary, title: String) -> some View {
        Button {
            requestHandoff(summary)
        } label: {
            Label(title, systemImage: "arrow.down.right.and.arrow.up.left")
        }
        .tint(.accentColor)
    }

    private var isConnecting: Bool {
        switch coordination.state.connectionState {
        case .connecting, .authenticating, .reconnecting: true
        default: false
        }
    }

    private var isConfirmingHandoff: Binding<Bool> {
        Binding(
            get: { pendingHandoff != nil },
            set: { if !$0 { pendingHandoff = nil } }
        )
    }

    private func retry() {
        isRetrying = true
        Task {
            await coordination.reconnect()
            isRetrying = false
        }
    }

    /// Asks first when this device is playing, since the handoff replaces
    /// its playback.
    private func requestHandoff(_ summary: DevicePlaybackSummary) {
        if player.localSong != nil || player.radio != nil {
            pendingHandoff = summary
        } else {
            continueHere(summary)
        }
    }

    private func continueHere(_ summary: DevicePlaybackSummary) {
        pendingHandoff = nil
        Task {
            await coordination.continueHere(from: summary.id)
            if coordination.handoffStatus == .idle {
                dismiss()
            }
        }
    }
}

// MARK: - Rows

/// This device and what it plays; while controlling another device, a way
/// back.
private struct ThisDeviceRow: View {
    @Environment(CoordinationStore.self) private var coordination
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        let device = coordination.groups.thisDevice?.device
        HStack(spacing: 12) {
            DeviceArtwork(song: player.localSong, isRadio: player.radio != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(localTitle)
                    .lineLimit(1)
                Label(device?.name ?? UIDevice.current.name, systemImage: DeviceSymbol.name(for: "ios"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if player.target.isRemote {
                Button(t("settings.crossDevice.playback.exitControl")) {
                    coordination.stopControlling()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } else if player.localSong != nil || player.radio != nil {
                NowPlayingIndicator(isPlaying: player.localIsPlaying)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var localTitle: String {
        if let song = player.localSong {
            return song.title
        }
        if let station = player.radio?.current {
            return station.name
        }
        return t("player.noSongPlaying")
    }
}

/// Another device and its playback.
struct DevicePlaybackRow: View {
    let summary: DevicePlaybackSummary

    @Environment(CoordinationStore.self) private var coordination
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            DeviceArtwork(song: summary.song, isRadio: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Label(summary.device.name, systemImage: DeviceSymbol.name(for: summary.device.platform))
                        .lineLimit(1)
                    Text(verbatim: "·")
                    Text(status)
                        .foregroundStyle(summary.isOnline ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if coordination.controlledDeviceId == summary.id {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(t("settings.crossDevice.playback.controllingDevice", ["name": summary.device.name]))
            } else if summary.snapshot?.snapshot.isPlaying == true, summary.isOnline {
                NowPlayingIndicator(isPlaying: true)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    private var title: String {
        if let song = summary.song {
            return song.title
        }
        if summary.snapshot != nil {
            return t("settings.crossDevice.playback.fetchingSong")
        }
        return t("settings.crossDevice.playback.unknownTrack")
    }

    /// Online, or when it was last seen.
    private var status: String {
        if summary.isOnline {
            return t("settings.crossDevice.connectionState.connected")
        }
        if let date = summary.snapshot?.lastConfirmedDate ?? summary.device.lastOnlineDate {
            return t("settings.crossDevice.device.lastOnline", ["time": Formatters.relative(date, locale: locale)])
        }
        return t("settings.crossDevice.never")
    }
}

/// The cover of what a device plays.
private struct DeviceArtwork: View {
    let song: Song?
    let isRadio: Bool

    var body: some View {
        Group {
            if let song {
                SongArtwork(song: song, size: .small, cornerRadius: 6)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: isRadio ? "dot.radiowaves.left.and.right" : "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// A symbol for a device's platform, like the web device icons.
enum DeviceSymbol {
    static func name(for platform: String) -> String {
        let platform = platform.lowercased()
        if ["ios", "android", "phone", "mobile"].contains(where: platform.contains) {
            return "iphone"
        }
        if ["electron", "desktop", "mac", "windows", "linux"].contains(where: platform.contains) {
            return "laptopcomputer"
        }
        if platform.contains("tv") {
            return "tv"
        }
        return "hifispeaker"
    }
}

/// The handoff's progress or why it failed, for the devices sheet.
struct HandoffStatusText {
    let text: String
    let isFailure: Bool

    init?(_ status: HandoffStatus, _ t: Localizer) {
        switch status {
        case .idle:
            return nil
        case let .inProgress(deviceName):
            text = "\(t("settings.crossDevice.toast.preparingRelay")) \(deviceName)"
            isFailure = false
        case let .failed(code):
            text = Self.message(for: code, t)
            isFailure = true
        }
    }

    /// The web `handoffErrorMessage`: a sentence for known codes, the code
    /// otherwise.
    static func message(for code: String, _ t: Localizer) -> String {
        switch code {
        case CoordinationErrorCode.targetOffline:
            t("settings.crossDevice.handoffError.targetOffline")
        case CoordinationErrorCode.snapshotExpired:
            t("settings.crossDevice.handoffError.snapshotExpired")
        case CoordinationErrorCode.handoffConflict:
            t("settings.crossDevice.handoffError.handoffConflict")
        case CoordinationErrorCode.sourceChanged:
            t("settings.crossDevice.handoffError.sourceChanged")
        case CoordinationErrorCode.sourcePauseTimeout:
            t("settings.crossDevice.handoffError.sourcePauseTimeout")
        case CoordinationErrorCode.unsupportedMedia:
            t("settings.crossDevice.handoffError.unsupportedMedia")
        case CoordinationErrorCode.deviceRevoked:
            t("settings.crossDevice.handoffError.deviceRevoked")
        case CoordinationErrorCode.protocolIncompatible, "capability_disabled":
            t("settings.crossDevice.handoffError.protocolIncompatible")
        case CoordinationErrorCode.forbidden:
            t("settings.crossDevice.handoffError.forbidden")
        default:
            t("settings.crossDevice.handoffError.fallback", ["reason": code])
        }
    }
}
