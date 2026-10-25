import AonsokuKit
import SwiftUI

/// Internet radio stations saved on the server. A tap tunes in, or pauses
/// the station already playing; swipe to edit or delete.
struct RadiosView: View {
    @State private var pendingDeletion: RadioStation?

    @Environment(Router.self) private var router
    @Environment(RadioStore.self) private var radios
    @Environment(PlayerStore.self) private var player
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        List {
            ForEach(Array(radios.stations.enumerated()), id: \.element.id) { index, station in
                RadioRow(station: station, isCurrent: isCurrent(station), isPlaying: player.isPlaying) {
                    tune(index)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Not a destructive role: the row stays until the
                    // deletion is confirmed.
                    Button {
                        pendingDeletion = station
                    } label: {
                        Label(t("radios.table.actions.delete"), systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        router.present(.radioEditor(station))
                    } label: {
                        Label(t("radios.table.actions.edit"), systemImage: "pencil")
                    }
                }
                .contextMenu {
                    Button(t("radios.table.actions.edit"), systemImage: "pencil") {
                        router.present(.radioEditor(station))
                    }
                    if let homepage = station.homepage {
                        Link(destination: homepage) {
                            Label(homepage.host() ?? homepage.absoluteString, systemImage: "safari")
                        }
                    }
                    Divider()
                    Button(t("radios.table.actions.delete"), systemImage: "trash", role: .destructive) {
                        pendingDeletion = station
                    }
                }
                .themedRow(plain: true)
            }
        }
        .listStyle(.plain)
        .loadStates(radios.phase, isEmpty: radios.stations.isEmpty) {
            Task { await radios.load() }
        } empty: {
            EmptyStateView(title: t("radios.empty.title"), systemImage: "dot.radiowaves.left.and.right") {
                Button(t("radios.addRadio")) {
                    router.present(.radioEditor(nil))
                }
                .buttonStyle(.glassProminent)
            }
        }
        .offlineBanner()
        .themedBackground()
        .navigationTitle(t("sidebar.radios"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(t("radios.addRadio"), systemImage: "plus") {
                    router.present(.radioEditor(nil))
                }
            }
        }
        .refreshable { await radios.load() }
        .task {
            guard radios.phase == .idle else { return }
            await radios.load()
        }
        .alert(
            t("radios.form.delete.title"),
            isPresented: isConfirmingDeletion,
            presenting: pendingDeletion
        ) { station in
            Button(t("radios.table.actions.delete"), role: .destructive) {
                delete(station)
            }
            Button(t("generic.cancel"), role: .cancel) {}
        } message: { _ in
            Text(t("radios.form.delete.description"))
        }
    }

    private func isCurrent(_ station: RadioStation) -> Bool {
        player.isRadio && player.radio?.current?.id == station.id
    }

    private func tune(_ index: Int) {
        let station = radios.stations[index]
        if isCurrent(station) {
            player.togglePlayPause()
        } else {
            player.playRadio(radios.stations, index: index)
        }
    }

    private func delete(_ station: RadioStation) {
        pendingDeletion = nil
        Task {
            do {
                try await radios.delete(station.id)
                toasts.success("radios.form.delete.toast.success")
            } catch {
                toasts.show(error: error, fallbackKey: "radios.form.delete.toast.error")
            }
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
}

/// A station in the list: a colored badge, which shows the playing bars
/// while it is on air, its name and its homepage.
private struct RadioRow: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    @Environment(Localizer.self) private var t

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RadioBadge(name: station.name)
                    .clipShape(.rect(cornerRadius: Layout.rowArtworkRadius, style: .continuous))
                    .frame(width: 48, height: 48)
                    .overlay {
                        if isCurrent {
                            NowPlayingIndicator(isPlaying: isPlaying, size: 20)
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                        .lineLimit(1)
                    Text(station.homepage?.host() ?? station.streamUrl)
                        .font(.footnote)
                        .foregroundStyle(ThemeColor.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .compactRowInsets()
        .accessibilityLabel(station.name)
        .accessibilityHint(
            isCurrent && isPlaying
                ? t("radios.table.pauseTooltip", ["name": station.name])
                : t("radios.table.playTooltip", ["name": station.name])
        )
    }
}

/// A station's square, colored from its name like a genre card.
struct RadioBadge: View {
    let name: String

    var body: some View {
        let hue = GenreTile.hue(for: name)
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.78),
                        Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.48),
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            )
    }
}

extension RadioStation {
    /// The homepage when it is a web address.
    var homepage: URL? {
        guard let homePageUrl, let url = URL(string: homePageUrl),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}
