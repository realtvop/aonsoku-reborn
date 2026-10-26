import AonsokuKit
import Perception
import SwiftUI

/// Connects to a Subsonic server: the web login form, with the same
/// validation and protocol check.
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionStore.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    @State private var url = "https://"
    @State private var fallbackUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showsErrors = false
    @State private var isConnecting = false
    @State private var isAskingToForce = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case url
        case fallbackUrl
        case username
        case password
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                WithPerceptionTracking {
                    ThemedForm {
                        WithPerceptionTracking {
                            Section {
                                header
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())

                            Section {
                                LabeledContent(t("login.form.url")) {
                                    TextField(t("login.form.url"), text: $url, prompt: Text(verbatim: "https://"))
                                        .keyboardType(.URL)
                                        .textContentType(.URL)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .submitLabel(.next)
                                        .focused($focus, equals: .url)
                                        .onSubmit { focus = .fallbackUrl }
                                }
                            } footer: {
                                if showsErrors, let urlError {
                                    ValidationMessage(text: urlError)
                                } else {
                                    Text(t("login.form.urlDescription"))
                                }
                            }
                            .themedRow()

                            Section {
                                LabeledContent(t("settings.server.fallbackUrl.label")) {
                                    TextField(
                                        t("settings.server.fallbackUrl.label"),
                                        text: $fallbackUrl,
                                        prompt: Text(t("settings.server.fallbackUrl.placeholder"))
                                    )
                                    .keyboardType(.URL)
                                    .textContentType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .focused($focus, equals: .fallbackUrl)
                                    .onSubmit { focus = .username }
                                }
                            } footer: {
                                if showsErrors, let fallbackUrlError {
                                    ValidationMessage(text: fallbackUrlError)
                                } else {
                                    Text(t("settings.server.fallbackUrl.info"))
                                }
                            }
                            .themedRow()

                            Section {
                                LabeledContent(t("login.form.username")) {
                                    TextField(
                                        t("login.form.username"),
                                        text: $username,
                                        prompt: Text(t("login.form.usernamePlaceholder"))
                                    )
                                    .textContentType(.username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .focused($focus, equals: .username)
                                    .onSubmit { focus = .password }
                                }
                                LabeledContent(t("login.form.password")) {
                                    SecureField(t("login.form.password"), text: $password)
                                        .textContentType(.password)
                                        .submitLabel(.go)
                                        .focused($focus, equals: .password)
                                        .onSubmit { connect() }
                                }
                            } footer: {
                                if showsErrors, let credentialsError {
                                    ValidationMessage(text: credentialsError)
                                }
                            }
                            .themedRow()
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .disabled(isConnecting)
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) {
                        connectButton
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            WithPerceptionTracking {
                                LanguageMenu()
                            }
                        }
                    }
                    .alert(t("server.incompatible.title"), isPresented: $isAskingToForce) {
                        Button(t("server.incompatible.skip")) {
                            connect(force: true)
                        }
                        Button(t("generic.cancel"), role: .cancel) {}
                    } message: {
                        Text(t("server.incompatible.description"))
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            AonsokuMark()
                .frame(width: 88, height: 88)
                .padding(18)
                .appGlass(in: RoundedRectangle(cornerRadius: 30))
            VStack(spacing: 6) {
                Text(t("login.form.server"))
                    .displayFont(.largeTitle)
                Text(t("login.form.description"))
                    .font(.body)
                    .foregroundStyle(ThemeColor.mutedForeground)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .tint(.white)
                }
                Text(t(isConnecting ? "login.form.connecting" : "login.form.connect"))
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .appGlassButtonStyle(prominent: true)
        .controlSize(.large)
        .disabled(isConnecting)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
    }

    // MARK: Validation

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var urlError: String? {
        let value = trimmedURL
        guard let components = URLComponents(string: value),
              components.scheme != nil,
              let host = components.host, !host.isEmpty
        else {
            return t("login.form.validations.url")
        }
        guard value.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else {
            return t("login.form.validations.protocol")
        }
        return nil
    }

    private var fallbackUrlError: String? {
        let value = ServerAddress.normalize(fallbackUrl)
        guard !value.isEmpty else { return nil }
        return ServerAddress.isValid(value)
            ? nil
            : t("settings.server.validation.fallbackUrl")
    }

    private var credentialsError: String? {
        if username.isEmpty { return t("login.form.validations.username") }
        if username.count < 2 { return t("login.form.validations.usernameLength") }
        if password.isEmpty { return t("login.form.validations.password") }
        if password.count < 2 { return t("login.form.validations.passwordLength") }
        return nil
    }

    // MARK: Connecting

    private func connect(force: Bool = false) {
        guard !isConnecting else { return }
        showsErrors = true
        if urlError != nil {
            focus = .url
            return
        }
        if fallbackUrlError != nil {
            focus = .fallbackUrl
            return
        }
        if credentialsError != nil {
            focus = username.count < 2 ? .username : .password
            return
        }
        let serverUrl = ServerAddress.normalize(trimmedURL)
        let fallback = ServerAddress.normalize(fallbackUrl)
        focus = nil
        isConnecting = true
        Task {
            if !force {
                let primaryCompatibility = await session.compatibility(
                    serverUrl: serverUrl,
                    username: username,
                    password: password
                )
                var fallbackCompatibility: ServerCompatibility?
                if primaryCompatibility == .unknown, !fallback.isEmpty {
                    fallbackCompatibility = await session.compatibility(
                        serverUrl: fallback,
                        username: username,
                        password: password
                    )
                }
                if ServerCompatibility.requiresOverride(
                    primary: primaryCompatibility,
                    fallback: fallbackCompatibility
                ) {
                    isConnecting = false
                    isAskingToForce = true
                    return
                }
            }
            do {
                try await app.signIn(
                    serverUrl: serverUrl,
                    fallbackUrl: fallback.isEmpty ? nil : fallback,
                    username: username,
                    password: password
                )
                // A sign-in that waits on the account-switch alert reports
                // success once the user has decided.
                if !app.isAwaitingAccountDecision {
                    toasts.success("toast.server.success")
                }
            } catch {
                toasts.show(.key("toast.server.error"), style: .error)
            }
            isConnecting = false
        }
    }
}

private struct ValidationMessage: View {
    let text: String

    var body: some View {
        WithPerceptionTracking {
            Label(text, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// Picks the interface language; "System" follows the device.
struct LanguageMenu: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            Menu {
                Picker(t("menu.language"), selection: selection) {
                    ForEach(AppLanguage.all) { language in
                        WithPerceptionTracking {
                            Text(verbatim: "\(language.flagEmoji)  \(language.nativeName)")
                                .tag(language.code)
                        }
                    }
                }
            } label: {
                Label(t("menu.language"), systemImage: "globe")
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { t.language.code },
            set: { code in settings.update { $0.languageCode = code } }
        )
    }
}
