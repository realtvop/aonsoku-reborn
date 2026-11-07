import AonsokuKit
import Perception
import SwiftUI

struct ArtworkSettingsView: View {
    @Environment(Localizer.self) private var t
    @State private var snapshot = ArtworkPreferences.options()
    @State private var videos: [[String: Any]] = []
    @State private var error: String?
    private let prefix = "settings.audio.lockScreenArtwork."

    private var options: [String: Any] { snapshot["options"] as? [String: Any] ?? [:] }
    private func bool(_ key: String, default value: Bool = false) -> Binding<Bool> {
        Binding(get: { options[key] as? Bool ?? value }, set: { update([key: $0]) })
    }
    private func number(_ key: String, default value: Double = 1) -> Binding<Double> {
        Binding(get: { options[key] as? Double ?? value }, set: { update([key: $0]) })
    }
    private func update(_ values: [String: Any]) {
        do { try ArtworkPreferences.configure(values); refresh() }
        catch { self.error = error.localizedDescription }
    }
    private func refresh() {
        snapshot = ArtworkPreferences.options()
        ArtworkPreferences.videos { items in DispatchQueue.main.async { videos = items } }
    }
    var body: some View {
        WithPerceptionTracking {
            ThemedForm {
                Section {
                    if snapshot["supported"] as? Bool == true {
                        Toggle(t(prefix + "immersive"), isOn: bool("immersiveEnabled", default: true))
                    } else { Text(t(prefix + "unsupported")).font(.footnote) }
                    Toggle(t(prefix + "dynamic"), isOn: bool("dynamicEnabled"))
                    Toggle(t(prefix + "wifiOnly"), isOn: bool("wifiOnly", default: true))
                    Toggle(t(prefix + "disableProtection"), isOn: Binding(
                        get: { !(options["resourceProtectionEnabled"] as? Bool ?? true) },
                        set: { update(["resourceProtectionEnabled": !$0]) }))
                } footer: { Text(t(prefix + "disableProtectionInfo")) }
                Section {
                    Picker(t(prefix + "quality"), selection: Binding(
                        get: { options["quality"] as? String ?? "auto" },
                        set: { update(["quality": $0]) })) {
                        Text(t(prefix + "automatic", ["tier": snapshot["recommendedTier"] as? String ?? "p6"])).tag("auto")
                        ForEach(["fp16", "p8", "p6"], id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    Text(t(prefix + "motionAmplitude"))
                    Slider(value: number("motionAmplitude"), in: 0.5...2, step: 0.05)
                    Picker(t(prefix + "motionSpeed"), selection: number("motionSpeed")) {
                        ForEach([0.5, 0.75, 1, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }
                } footer: { Text(t(prefix + "qualityInfo")) }
                Section {
                    ForEach(snapshot["models"] as? [[String: Any]] ?? [], id: \.tierID) { model in
                        let tier = model["tier"] as? String ?? "p6"
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tier.uppercased())
                            Text(t(prefix + "model." + (model["status"] as? String ?? "notDownloaded"))).font(.caption)
                            ProgressView(value: model["progress"] as? Double ?? 0)
                            HStack {
                                Button(t(prefix + "download")) { ArtworkPreferences.download(tier); refresh() }
                                Button(t(prefix + "cancel")) { ArtworkPreferences.cancel(tier); refresh() }
                                Button(t(prefix + "remove"), role: .destructive) { ArtworkPreferences.remove(tier); refresh() }
                            }.buttonStyle(.borderless)
                        }
                    }
                } footer: { Text(t(prefix + "modelsInfo")) }
                Section {
                    ForEach(videos, id: \.tierID) { video in
                        HStack {
                            Text(video["id"] as? String ?? "").font(.caption).lineLimit(1)
                            Spacer()
                            Button(t(prefix + "remove"), role: .destructive) {
                                ArtworkPreferences.deleteVideo(video["id"] as? String ?? "") { _ in refresh() }
                            }
                        }
                    }
                    Button(t("settings.storage.limits.clearAll"), role: .destructive) {
                        ArtworkPreferences.clearVideos { _, _ in refresh() }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(t(prefix + "group"))
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    var tierID: String { self["tier"] as? String ?? self["id"] as? String ?? "" }
}
