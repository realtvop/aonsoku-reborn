import AonsokuKit
import SwiftUI

extension SettingsStore {
    /// A binding to one setting that saves on change.
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }
}

/// The icon before a settings row: a symbol on a tile in the theme's
/// border color, the same tiles as the library rows, rather than the
/// Settings app's colored squares.
struct SettingsIcon: View {
    let systemImage: String

    var body: some View {
        IconTile(systemImage: systemImage, size: 30)
    }
}

/// A toggle with the web setting's explanation under its title.
struct SettingsToggle: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let info {
                Text(info)
            }
        }
    }
}

/// A web address field: no capitalization or correction, URL keyboard.
struct URLField: View {
    let title: String
    @Binding var text: String
    var prompt: String = "https://"

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

/// Server address checks shared by sign-in and server settings, like the
/// web `serverUrl` helpers.
enum ServerAddress {
    /// Trimmed and without trailing slashes.
    static func normalize(_ value: String) -> String {
        var url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }

    /// An http or https address with a host.
    static func isValid(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }
}
