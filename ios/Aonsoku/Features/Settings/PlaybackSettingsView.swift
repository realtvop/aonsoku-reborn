import AonsokuKit
import Perception
import SwiftUI

/// Haptics, ReplayGain and the play history size, like the web player and
/// audio settings.
struct PlaybackSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let replayGain = settings.settings.replayGain
            ThemedForm {
                WithPerceptionTracking {
                    Section {
                        SettingsToggle(
                            title: t("native.settings.estimateContentLength.label"),
                            info: t("native.settings.estimateContentLength.info"),
                            isOn: settings.binding(\.playback.estimateContentLength)
                        )
                    }

                    Section {
                        SettingsToggle(
                            title: t("settings.audio.hapticFeedback.enabled.label"),
                            info: t("settings.audio.hapticFeedback.enabled.info"),
                            isOn: settings.binding(\.playback.hapticFeedback)
                        )
                    } header: {
                        Text(t("settings.audio.hapticFeedback.group"))
                    } footer: {
                        Text(t("settings.audio.hapticFeedback.description"))
                    }

                    Section {
                        Toggle(t("settings.audio.replayGain.enabled"), isOn: settings.binding(\.replayGain.enabled))
                        if replayGain.enabled {
                            Picker(t("settings.audio.replayGain.mode.label"), selection: settings.binding(\.replayGain.mode)) {
                                Text(t("settings.audio.replayGain.mode.track"))
                                    .tag(ReplayGainMode.track)
                                Text(t("settings.audio.replayGain.mode.album"))
                                    .tag(ReplayGainMode.album)
                            }
                            DecibelStepper(
                                title: t("settings.audio.replayGain.preAmp"),
                                value: settings.binding(\.replayGain.preAmp),
                                range: ReplayGainSettings.preAmpRange
                            )
                            DecibelStepper(
                                title: t("settings.audio.replayGain.defaultGain.label"),
                                value: settings.binding(\.replayGain.defaultGain),
                                range: ReplayGainSettings.defaultGainRange
                            )
                        }
                    } header: {
                        Text(t("settings.audio.replayGain.group"))
                    } footer: {
                        Text(t(replayGain.enabled ? "settings.audio.replayGain.defaultGain.info" : "settings.audio.replayGain.description"))
                    }

                    Section {
                        Stepper(value: settings.binding(\.history.maxSize), in: HistorySettings.range, step: HistorySettings.step) {
                            LabeledContent(t("settings.audio.history.maxSize.label")) {
                                Text(Formatters.number(settings.settings.history.maxSize, locale: t.locale))
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        Text(t("settings.audio.history.group"))
                    } footer: {
                        Text(t("settings.audio.history.maxSize.info"))
                    }
                }
            }
            .navigationTitle(t("settings.options.audio"))
            .animation(.smooth, value: replayGain.enabled)
        }
    }
}

/// A gain in decibels, changed in steps of one, as the web number field.
private struct DecibelStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        WithPerceptionTracking {
            Stepper(value: $value, in: range, step: 1) {
                LabeledContent(title) {
                    Text(Formatters.decibels(value))
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Lyrics sources, their order, and the custom lyrics server, like the web
/// lyrics settings.
struct LyricsPreferencesView: View {
    @State private var serverUrl = ""
    @State private var serverPassword = ""
    @State private var didPrefill = false

    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let lyrics = settings.settings.lyrics
            ThemedForm {
                WithPerceptionTracking {
                    Section {
                        SettingsToggle(
                            title: t("settings.audio.lyrics.preferSynced.label"),
                            info: t("settings.audio.lyrics.preferSynced.info"),
                            isOn: settings.binding(\.lyrics.preferSyncedLyrics)
                        )
                        SettingsToggle(
                            title: t("settings.audio.lyrics.showTranslation.label"),
                            info: t("settings.audio.lyrics.showTranslation.info"),
                            isOn: settings.binding(\.lyrics.showTranslation)
                        )
                    } footer: {
                        Text(t("settings.audio.lyrics.description"))
                    }

                    Section {
                        NavigationLink {
                            LyricsSourceOrderView()
                        } label: {
                            LabeledContent(t("settings.audio.lyrics.source.label")) {
                                Text(lyrics.sourcePriority.map { t("settings.audio.lyrics.source.\($0.rawValue)") }
                                    .joined(separator: ", "))
                            }
                        }
                    } footer: {
                        Text(t("settings.audio.lyrics.source.info"))
                    }

                    Section {
                        SettingsToggle(
                            title: t("settings.audio.lyrics.customServer.enabled.label"),
                            info: t("settings.audio.lyrics.customServer.enabled.info"),
                            isOn: settings.binding(\.lyrics.customServerEnabled)
                        )
                        if lyrics.customServerEnabled {
                            URLField(
                                title: t("settings.audio.lyrics.customServer.url.label"),
                                text: $serverUrl,
                                prompt: t("settings.audio.lyrics.customServer.url.placeholder")
                            )
                            SecureField(
                                t("settings.audio.lyrics.customServer.password.label"),
                                text: $serverPassword,
                                prompt: Text(t("settings.audio.lyrics.customServer.password.placeholder"))
                            )
                            .textContentType(.password)
                            Button(t("settings.audio.lyrics.customServer.save"), action: saveServer)
                                .disabled(!hasServerChanges)
                        }
                    } footer: {
                        if lyrics.customServerEnabled {
                            Text("\(t("settings.audio.lyrics.customServer.url.info")) \(t("settings.audio.lyrics.customServer.password.info"))")
                        }
                    }
                }
            }
            .navigationTitle(t("settings.audio.lyrics.group"))
            .animation(.smooth, value: lyrics.customServerEnabled)
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                serverUrl = lyrics.customServerUrl
                serverPassword = lyrics.customServerPassword
            }
        }
    }

    private var hasServerChanges: Bool {
        let lyrics = settings.settings.lyrics
        return serverUrl.trimmingCharacters(in: .whitespaces) != lyrics.customServerUrl
            || serverPassword != lyrics.customServerPassword
    }

    private func saveServer() {
        let url = serverUrl.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty, !ServerAddress.isValid(url) {
            toasts.show(.key("settings.audio.lyrics.customServer.url.invalid"), style: .error)
            return
        }
        settings.update {
            $0.lyrics.customServerUrl = url
            $0.lyrics.customServerPassword = serverPassword
        }
        serverUrl = url
        toasts.success("settings.audio.lyrics.customServer.saved")
    }
}

/// The order lyrics sources are tried in, rearranged by dragging.
private struct LyricsSourceOrderView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            ThemedList {
                WithPerceptionTracking {
                    Section {
                        ForEach(Array(settings.settings.lyrics.sourcePriority.enumerated()), id: \.element) { index, source in
                            WithPerceptionTracking {
                                let name = t("settings.audio.lyrics.source.\(source.rawValue)")
                                HStack(spacing: 12) {
                                    Text(verbatim: "\(index + 1)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(name)
                                }
                                .accessibilityLabel(t(
                                    "settings.audio.lyrics.source.priority",
                                    ["priority": String(index + 1), "source": name]
                                ))
                                .accessibilityHint(t("settings.audio.lyrics.source.dragHandle", ["source": name]))
                            }
                        }
                        .onMove { offsets, destination in
                            settings.update { $0.lyrics.sourcePriority.move(fromOffsets: offsets, toOffset: destination) }
                        }
                    } footer: {
                        Text("\(t("settings.audio.lyrics.source.info")) \(t("settings.audio.lyrics.source.dragInstruction"))")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(t("settings.audio.lyrics.source.label"))
        }
    }
}

/// Which Library sections show, like the web sidebar settings.
struct ContentSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            ThemedForm {
                WithPerceptionTracking {
                    Section {
                        Toggle(t("settings.content.sidebar.radios.section"), isOn: settings.binding(\.content.hideRadiosSection))
                    } header: {
                        Text(t("settings.content.sidebar.group"))
                    } footer: {
                        Text(t("settings.content.sidebar.description"))
                    }
                }
            }
            .navigationTitle(t("settings.options.content"))
        }
    }
}

/// The outside services Aonsoku may use, like the web privacy settings.
struct PrivacySettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            ThemedForm {
                WithPerceptionTracking {
                    Section {
                        SettingsToggle(
                            title: t("settings.privacy.services.lrclib.label"),
                            info: t("settings.privacy.services.lrclib.info"),
                            isOn: settings.binding(\.privacy.lrcLibEnabled)
                        )
                    } header: {
                        Text(t("settings.privacy.services.group"))
                    } footer: {
                        Text(t("settings.privacy.services.description"))
                    }
                }
            }
            .navigationTitle(t("settings.options.privacy"))
        }
    }
}
