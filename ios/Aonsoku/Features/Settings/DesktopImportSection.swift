import AonsokuKit
import Perception
import SwiftUI

/// Settings → Storage → "Import downloads from Aonsoku Desktop…".
///
/// Copies the songs the Electron desktop app downloaded into this app's own
/// cache, so they play offline here too. The desktop app's folder is only
/// read, and the section does not exist on platforms without a desktop app
/// (`DownloadsStore.supportsDesktopImport`).
struct DesktopImportSection: View {
    @Environment(DownloadsStore.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    @State private var isCancelling = false

    var body: some View {
        WithPerceptionTracking {
            if downloads.desktopImport != .unavailable {
                Section {
                    row(downloads.desktopImport)
                } footer: {
                    Text(t("native.mac.desktopImport.footer"))
                }
            }
        }
    }

    private func row(_ state: DesktopImportState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("native.mac.desktopImport.title"))
                .font(.body.weight(.medium))
            details(state)
        }
        .padding(.vertical, 4)
        .task {
            if downloads.desktopImport == .idle {
                await downloads.refreshDesktopDownloads()
            }
        }
        .appOnChange(of: downloads.desktopImport) { _, state in
            if !state.isImporting { isCancelling = false }
            if case let .finished(result) = state { announce(result) }
        }
    }

    // MARK: - States

    @ViewBuilder
    private func details(_ state: DesktopImportState) -> some View {
        switch state {
        case .unavailable:
            EmptyView()
        case .idle, .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                note(t("native.mac.desktopImport.scanning"))
            }
        case let .ready(summary):
            ready(summary)
        case .unreadable:
            needsFolder(t("native.mac.desktopImport.unreadable"))
        case .empty:
            needsFolder(t("native.mac.desktopImport.empty"))
        case let .importing(progress):
            importing(progress)
        case let .finished(result):
            finished(result)
        case let .failed(error):
            failed(error)
        }
    }

    private func ready(_ summary: DesktopDownloadsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t(
                "native.mac.desktopImport.found",
                count: summary.songCount,
                ["size": Formatters.cacheSize(summary.totalBytes, locale: locale)]
            ))
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            if summary.isUpToDate {
                note(t("native.mac.desktopImport.upToDate"))
            } else if summary.importableCount < summary.songCount {
                note(t("native.mac.desktopImport.newCount", count: summary.importableCount))
            }
            if summary.skipped > 0 {
                note(t("native.mac.desktopImport.skipped", count: summary.skipped))
            }
            HStack {
                if !summary.isUpToDate {
                    Button(t("native.mac.desktopImport.import")) {
                        Task { await downloads.importDesktopDownloads() }
                    }
                    .buttonStyle(.bordered)
                }
                chooseButton
            }
        }
    }

    private func needsFolder(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            note(message)
            chooseButton
        }
    }

    private func importing(_ progress: DesktopImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.total > 0 {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(alignment: .firstTextBaseline) {
                note(progress.total > 0
                    ? t("native.mac.desktopImport.progress", [
                        "completed": Formatters.number(progress.completed, locale: locale),
                        "total": Formatters.number(progress.total, locale: locale),
                        "size": Formatters.cacheSize(progress.bytesCopied, locale: locale),
                    ])
                    : t("native.mac.desktopImport.preparing"))
                    .monospacedDigit()
                Spacer()
                Button(t("generic.cancel")) {
                    isCancelling = true
                    downloads.cancelDesktopImport()
                }
                .buttonStyle(.borderless)
                .disabled(isCancelling)
            }
        }
    }

    private func finished(_ result: DesktopImportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            note(resultText(result))
            HStack {
                Button(t("native.mac.desktopImport.checkAgain")) {
                    Task { await downloads.rescanDesktopDownloads() }
                }
                .buttonStyle(.bordered)
                chooseButton
            }
        }
    }

    private func failed(_ error: DesktopImportError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            note(failureText(error))
            HStack {
                Button(t("native.mac.desktopImport.tryAgain")) {
                    Task { await downloads.rescanDesktopDownloads() }
                }
                .buttonStyle(.bordered)
                chooseButton
            }
        }
    }

    // MARK: - Pieces

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chooseButton: some View {
        Button(t("native.mac.desktopImport.choose")) {
            Task { await chooseFolder() }
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func chooseFolder() async {
        let url = await AppFolderPicker.chooseFolder(
            message: t("native.mac.desktopImport.chooseMessage"),
            prompt: t("native.mac.desktopImport.choosePrompt"),
            startingAt: DesktopDataLocator.applicationSupportDirectory
        )
        guard let url else { return }
        await downloads.chooseDesktopDownloads(at: url)
    }

    private func announce(_ result: DesktopImportResult) {
        let style: Toast.Style
        if result.imported == 0 && !result.failures.isEmpty {
            style = .error
        } else if result.failures.isEmpty && !result.wasCancelled && !result.ranOutOfSpace {
            style = .success
        } else {
            style = .info
        }
        toasts.show(.text(resultText(result)), style: style)
    }

    // MARK: - Text

    /// What an import did, in a sentence per outcome. Plurals are resolved
    /// here because a toast message cannot carry a count.
    private func resultText(_ result: DesktopImportResult) -> String {
        var parts: [String] = []
        if result.imported > 0 {
            parts.append(t("native.mac.desktopImport.result.imported", count: result.imported))
        }
        if result.alreadyPresent > 0 {
            parts.append(t("native.mac.desktopImport.result.alreadyHere", count: result.alreadyPresent))
        }
        if !result.failures.isEmpty {
            parts.append(t("native.mac.desktopImport.result.failed", count: result.failures.count))
        }
        if result.ranOutOfSpace {
            parts.append(t("native.mac.desktopImport.result.diskFull"))
        }
        if result.wasCancelled {
            parts.append(t("native.mac.desktopImport.result.cancelled"))
        }
        if parts.isEmpty {
            parts.append(t("native.mac.desktopImport.result.nothing"))
        }
        return parts.joined(separator: " ")
    }

    private func failureText(_ error: DesktopImportError) -> String {
        switch error {
        case .unavailable:
            t("native.mac.desktopImport.error.unavailable")
        case .sourceUnreadable:
            t("native.mac.desktopImport.unreadable")
        case .sourceIsDestination:
            t("native.mac.desktopImport.error.sameFolder")
        case let .insufficientSpace(required, available):
            t("native.mac.desktopImport.error.space", [
                "needed": Formatters.cacheSize(required, locale: locale),
                "available": Formatters.cacheSize(available, locale: locale),
            ])
        case .storageUnavailable:
            t("native.mac.desktopImport.error.storage")
        }
    }
}

private extension DesktopImportState {
    var isImporting: Bool {
        if case .importing = self { return true }
        return false
    }
}
