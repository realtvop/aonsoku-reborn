import AonsokuKit
import SwiftUI

/// Creates a playlist, with the songs it was started from, or edits a
/// playlist's name, description and visibility.
struct PlaylistEditorView: View {
    enum Mode {
        case create(songs: [Song])
        case edit(Playlist)
    }

    let mode: Mode

    @State private var name: String
    @State private var comment: String
    @State private var isPublic: Bool
    @State private var isSaving = false
    /// Validation shows once the name was edited or saving was attempted.
    @State private var showsValidation = false
    @FocusState private var isNameFocused: Bool

    @Environment(PlaylistsStore.self) private var playlists
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.dismiss) private var dismiss

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case let .create(songs):
            _name = State(initialValue: Self.suggestedName(for: songs))
            _comment = State(initialValue: "")
            _isPublic = State(initialValue: false)
        case let .edit(playlist):
            _name = State(initialValue: playlist.name)
            _comment = State(initialValue: playlist.comment ?? "")
            _isPublic = State(initialValue: playlist.isPublic)
        }
    }

    var body: some View {
        NavigationStack {
            ThemedForm {
                Section {
                    TextField(t("playlist.form.labels.name"), text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text(t("playlist.form.labels.name"))
                } footer: {
                    if showsValidation, !isNameValid {
                        Text(t("playlist.form.validations.nameLength"))
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    TextField(t("playlist.form.labels.comment"), text: $comment, axis: .vertical)
                        .lineLimit(3 ... 8)
                } header: {
                    Text(t("playlist.form.labels.comment"))
                } footer: {
                    Text(t("playlist.form.labels.commentDescription"))
                }
                Section {
                    Toggle(t("playlist.form.labels.isPublic"), isOn: $isPublic)
                } footer: {
                    Text(t("playlist.form.labels.isPublicDescription"))
                }
            }
            .disabled(isSaving)
            .navigationTitle(t(isCreating ? "playlist.form.create.title" : "playlist.form.edit.title"))
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
                                t(isCreating ? "playlist.form.create.button" : "playlist.form.edit.button")
                            )
                            .disabled(showsValidation && !isNameValid)
                    }
                }
            }
            .onChange(of: name) {
                showsValidation = true
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            if isCreating {
                isNameFocused = true
            }
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At least two characters, as the web form requires.
    private var isNameValid: Bool {
        trimmedName.count >= 2
    }

    private func save() {
        guard !isSaving else { return }
        guard isNameValid else {
            showsValidation = true
            return
        }
        let name = trimmedName
        let comment = self.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task {
            defer { isSaving = false }
            switch mode {
            case let .create(songs):
                do {
                    try await playlists.create(
                        name: name,
                        comment: comment.isEmpty ? nil : comment,
                        isPublic: isPublic,
                        songIds: songs.map(\.id)
                    )
                    toasts.success("playlist.form.create.toast.success")
                    dismiss()
                } catch {
                    toasts.show(error: error, fallbackKey: "playlist.form.create.toast.error")
                }
            case let .edit(playlist):
                do {
                    try await playlists.update(playlist.id, name: name, comment: comment, isPublic: isPublic)
                    toasts.success("playlist.form.edit.toast.success")
                    dismiss()
                } catch {
                    toasts.show(error: error, fallbackKey: "playlist.form.edit.toast.error")
                }
            }
        }
    }

    /// The album's name when every song is from one album, else the first
    /// song's title, as the web New Playlist option names it.
    static func suggestedName(for songs: [Song]) -> String {
        guard let first = songs.first else { return "" }
        if songs.count > 1, !first.album.isEmpty, songs.allSatisfy({ $0.album == first.album }) {
            return first.album
        }
        return first.title
    }
}
