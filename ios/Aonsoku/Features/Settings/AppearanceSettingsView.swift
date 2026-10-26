import AonsokuKit
import Perception
import SwiftUI

/// Light, dark or system appearance, the theme for each, and how artwork
/// and Now Playing look, like the web appearance settings.
struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let mode = settings.settings.appearance.themeMode
            ThemedForm {
                WithPerceptionTracking {
                    Section {
                        Picker(t("theme.modeLabel"), selection: settings.binding(\.appearance.themeMode)) {
                            ForEach(ThemeMode.allCases, id: \.self) { mode in
                                WithPerceptionTracking {
                                    Text(t(mode.labelKey))
                                        .tag(mode)
                                }
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text(t("theme.label"))
                    }
                    if mode != .dark {
                        Section(t("theme.light")) {
                            ThemeGrid(themes: AppTheme.lightThemes, selection: settings.binding(\.appearance.lightTheme))
                        }
                    }
                    if mode != .light {
                        Section(t("theme.dark")) {
                            ThemeGrid(themes: AppTheme.darkThemes, selection: settings.binding(\.appearance.darkTheme))
                        }
                    }
                    Section {
                        SettingsToggle(
                            title: t("native.settings.autoOpenNowPlaying.label"),
                            info: t("native.settings.autoOpenNowPlaying.info"),
                            isOn: settings.binding(\.playback.autoOpenNowPlaying)
                        )
                        SettingsToggle(
                            title: t("settings.appearance.general.albumCoverForSongs.label"),
                            info: t("settings.appearance.general.albumCoverForSongs.info"),
                            isOn: settings.binding(\.playback.useAlbumCoverForSongs)
                        )
                    } header: {
                        Text(t("settings.appearance.general.group"))
                    }
                    Section {
                        let intensity = settings.binding(\.appearance.nowPlayingColorIntensity)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(t("settings.appearance.colors.queue.intensity"))
                                Spacer()
                                Text(intensity.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: intensity, in: AppearanceSettings.colorIntensityRange, step: 0.05)
                                .accessibilityLabel(t("settings.appearance.colors.queue.intensity"))
                        }
                    } header: {
                        Text(t("settings.appearance.queue.group"))
                    } footer: {
                        Text(t("settings.appearance.queue.description"))
                    }
                }
            }
            .navigationTitle(t("settings.options.appearance"))
            .animation(.smooth, value: mode)
        }
    }
}

/// Themes as small previews of their colors.
private struct ThemeGrid: View {
    let themes: [AppTheme]
    @Binding var selection: AppTheme

    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                ForEach(themes) { theme in
                    WithPerceptionTracking {
                        let isSelected = selection == theme
                        Button {
                            selection = theme
                        } label: {
                            VStack(spacing: 6) {
                                ThemePreview(palette: theme.palette)
                                    .overlay {
                                        WithPerceptionTracking {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(
                                                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.12)),
                                                    lineWidth: isSelected ? 2.5 : 1
                                                )
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        WithPerceptionTracking {
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .symbolRenderingMode(.multicolor)
                                                    .font(.body)
                                                    .foregroundStyle(.tint)
                                                    .padding(6)
                                            }
                                        }
                                    }
                                // Long names such as "Catppuccin Mocha" shrink to
                                // fit the card rather than lose their ending.
                                Text(t(theme.labelKey))
                                    .font(.caption)
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t(theme.labelKey))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// A miniature page in a theme's colors.
private struct ThemePreview: View {
    let palette: ThemePalette

    var body: some View {
        WithPerceptionTracking {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.background)
                .frame(height: 64)
                .overlay(alignment: .topLeading) {
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule()
                                .fill(palette.foreground.opacity(0.85))
                                .frame(width: 34, height: 5)
                            Capsule()
                                .fill(palette.mutedForeground.opacity(0.7))
                                .frame(width: 48, height: 4)
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                Capsule()
                                    .fill(palette.primary)
                                    .frame(width: 26, height: 10)
                                Capsule()
                                    .fill(palette.secondary)
                                    .frame(width: 18, height: 10)
                            }
                        }
                        .padding(10)
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

/// The interface language, or the device's.
struct LanguageSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let selected = settings.settings.languageCode
            ThemedList {
                WithPerceptionTracking {
                    Section {
                        languageRow(title: t("theme.modeSystem"), subtitle: nil, code: nil, isSelected: selected == nil)
                    }
                    Section {
                        // Like the system's list: each language in its own words,
                        // then in the current one. Languages aren't countries, so
                        // no flags.
                        ForEach(AppLanguage.all) { language in
                            WithPerceptionTracking {
                                languageRow(
                                    title: language.nativeName,
                                    subtitle: t.locale.localizedString(forIdentifier: language.code),
                                    code: language.code,
                                    isSelected: selected == language.code
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle(t("settings.options.language"))
        }
    }

    private func languageRow(title: String, subtitle: String?, code: String?, isSelected: Bool) -> some View {
        Button {
            settings.update { $0.languageCode = code }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .foregroundStyle(.primary)
                    if let subtitle, subtitle != title {
                        Text(verbatim: subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
