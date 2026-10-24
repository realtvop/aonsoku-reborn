import AonsokuKit
import SwiftUI

/// Adds a radio station, or edits one, with the web form's checks.
struct RadioEditorView: View {
    let station: RadioStation?

    @State private var name: String
    @State private var streamUrl: String
    @State private var homePageUrl: String
    @State private var isSaving = false
    /// Fields whose problems show: those edited, or all after a save attempt.
    @State private var checked: Set<Field> = []

    @Environment(RadioStore.self) private var radios
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.dismiss) private var dismiss

    private enum Field: CaseIterable {
        case name
        case stream
        case homepage
    }

    init(station: RadioStation?) {
        self.station = station
        _name = State(initialValue: station?.name ?? "")
        _streamUrl = State(initialValue: station?.streamUrl ?? "")
        _homePageUrl = State(initialValue: station?.homePageUrl ?? "")
    }

    var body: some View {
        NavigationStack {
            ThemedForm {
                Section {
                    TextField(t("radios.table.name"), text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text(t("radios.table.name"))
                } footer: {
                    problem(.name)
                }
                Section {
                    urlField(t("radios.table.stream"), text: $streamUrl)
                } header: {
                    Text(t("radios.table.stream"))
                } footer: {
                    problem(.stream)
                }
                Section {
                    urlField(t("radios.table.homepage"), text: $homePageUrl)
                } header: {
                    Text(t("radios.table.homepage"))
                } footer: {
                    problem(.homepage)
                }
            }
            .disabled(isSaving)
            .navigationTitle(t(station == nil ? "radios.form.create.title" : "radios.form.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(role: .confirm, action: save)
                            .accessibilityLabel(
                                t(station == nil ? "radios.form.create.button" : "radios.form.edit.button")
                            )
                            .disabled(!checked.isEmpty && !isValid)
                    }
                }
            }
            .onChange(of: name) { checked.insert(.name) }
            .onChange(of: streamUrl) { checked.insert(.stream) }
            .onChange(of: homePageUrl) { checked.insert(.homepage) }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(verbatim: "https://"))
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    @ViewBuilder
    private func problem(_ field: Field) -> some View {
        if checked.contains(field), let message = message(for: field) {
            Text(message)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Validation

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        Field.allCases.allSatisfy { message(for: $0) == nil }
    }

    private func message(for field: Field) -> String? {
        switch field {
        case .name:
            trimmed(name).count >= 3 ? nil : t("radios.form.validations.name")
        case .stream:
            urlProblem(trimmed(streamUrl), tooShort: t("radios.form.validations.streamUrlLength"))
        case .homepage:
            trimmed(homePageUrl).isEmpty
                ? nil
                : urlProblem(trimmed(homePageUrl), tooShort: t("radios.form.validations.homepageUrlLength"))
        }
    }

    /// A web address of at least ten characters, as the web form requires.
    private func urlProblem(_ value: String, tooShort: String) -> String? {
        guard let url = URL(string: value), url.scheme != nil, url.host() != nil else {
            return t("radios.form.validations.url")
        }
        guard value.count >= 10 else { return tooShort }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return t("login.form.validations.protocol")
        }
        return nil
    }

    // MARK: - Saving

    private func save() {
        guard !isSaving else { return }
        guard isValid else {
            checked = Set(Field.allCases)
            return
        }
        let name = trimmed(self.name)
        let streamUrl = trimmed(self.streamUrl)
        let homePageUrl = trimmed(self.homePageUrl)
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                if let station {
                    try await radios.update(RadioStation(
                        id: station.id,
                        name: name,
                        streamUrl: streamUrl,
                        homePageUrl: homePageUrl.isEmpty ? nil : homePageUrl
                    ))
                    toasts.success("radios.form.edit.toast.success")
                } else {
                    try await radios.create(
                        name: name,
                        streamUrl: streamUrl,
                        homePageUrl: homePageUrl.isEmpty ? nil : homePageUrl
                    )
                    toasts.success("radios.form.create.toast.success")
                }
                dismiss()
            } catch {
                toasts.show(
                    error: error,
                    fallbackKey: station == nil ? "radios.form.create.toast.error" : "radios.form.edit.toast.error"
                )
            }
        }
    }
}
