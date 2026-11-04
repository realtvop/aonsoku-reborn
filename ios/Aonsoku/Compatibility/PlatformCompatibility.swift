import AonsokuKit
import Perception
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Where iOS and macOS disagree on a SwiftUI API, the screens call the
// `app`-prefixed spelling here, so no screen branches on the platform itself.
// `ViewCompatibility` does the same for older systems.

// MARK: - Observation

#if os(macOS)
/// SwiftUI's `Bindable`. `Perception.Bindable` is obsolete from macOS 14, and
/// `@Perceptible` types are `Observable` there.
typealias AppBindable = SwiftUI.Bindable
#else
typealias AppBindable = Perception.Bindable
#endif

// MARK: - Names

#if os(macOS)
/// ApplicationServices ships QuickDraw's `RGBColor`, which AppKit and SwiftUI
/// bring into scope on macOS next to `AonsokuKit.RGBColor`. A declaration in
/// this module wins over both, so the app's bare `RGBColor` keeps meaning the
/// cover color.
typealias RGBColor = AonsokuKit.RGBColor
#endif

// MARK: - Images

extension Image {
    /// A bitmap from the image cache, whichever toolkit made it.
    init(platformImage image: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

// MARK: - Device

enum AppDevice {
    /// The name the user gave this device, such as "Ada's iPhone".
    @MainActor static var name: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    /// The SF Symbol family `DeviceSymbol` knows this platform by.
    static var platform: String {
        #if canImport(UIKit)
        "ios"
        #else
        "macos"
        #endif
    }
}

// MARK: - Navigation and toolbars

enum AppTitleDisplayMode {
    case inline
    case large
}

extension ToolbarItemPlacement {
    /// The trailing end of the navigation bar, or a Mac toolbar's actions.
    static var appTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .navigationBarTrailing
        #endif
    }

    /// The leading end of the navigation bar, or a Mac toolbar's navigation area.
    static var appLeading: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .navigationBarLeading
        #endif
    }
}

extension View {
    /// Inline or large navigation title. A Mac window has one title style.
    func appTitleDisplayMode(_ mode: AppTitleDisplayMode) -> some View {
        #if os(macOS)
        toolbarTitleDisplayMode(mode == .inline ? .inline : .automatic)
        #else
        navigationBarTitleDisplayMode(mode == .inline ? .inline : .large)
        #endif
    }

    /// The color scheme of the navigation bar, or of a Mac window's toolbar.
    func appToolbarColorScheme(_ scheme: ColorScheme?) -> some View {
        #if os(macOS)
        toolbarColorScheme(scheme, for: .windowToolbar)
        #else
        toolbarColorScheme(scheme, for: .navigationBar)
        #endif
    }

    /// A search field below the navigation title that is always shown, or the
    /// Mac toolbar's search field.
    func appSearchableDrawer(text: Binding<String>, prompt: Text) -> some View {
        #if os(macOS)
        searchable(text: text, prompt: prompt)
        #else
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #endif
    }
}

// MARK: - Text input

enum AppAutocapitalization {
    case never
    case words
}

extension View {
    /// Capitalization of typed text. Macs do not capitalize while typing.
    func appAutocapitalization(_ mode: AppAutocapitalization) -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(mode == .never ? .never : .words)
        #endif
    }

    /// A web address: the URL keyboard and content type, and no capitalization.
    func appURLField() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
        #endif
    }

    /// The URL keyboard alone, for fields that set the rest themselves.
    func appURLKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.URL)
        #endif
    }
}

// MARK: - Lists and paging

extension View {
    /// Pages the content horizontally without an index. Only iOS 16 uses it;
    /// a Mac has the aligned-scrolling carousel.
    func appPageTabViewStyle() -> some View {
        #if os(macOS)
        self
        #else
        tabViewStyle(.page(indexDisplayMode: .never))
        #endif
    }

    /// Shows a list's reordering handles at all times. A Mac list reorders by
    /// dragging its rows.
    func appAlwaysEditing() -> some View {
        #if os(macOS)
        self
        #else
        environment(\.editMode, .constant(.active))
        #endif
    }
}

// MARK: - Search and filter fields

extension View {
    /// The Search page's field. A Mac window's toolbar has one search field
    /// for every section, which writes the same text, so the page adds none.
    func appSearchField(text: Binding<String>, prompt: Text, onSubmit: @escaping () -> Void) -> some View {
        #if os(macOS)
        self
        #else
        searchable(text: text, prompt: prompt)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search, onSubmit)
        #endif
    }

    /// A field that narrows what the page lists: the navigation bar's search
    /// field on iOS. On a Mac, whose toolbar field searches the whole
    /// library, a filter field over the top of the page.
    @ViewBuilder
    func appFilterField(_ isEnabled: Bool = true, text: Binding<String>, prompt: String) -> some View {
        if isEnabled {
            #if os(macOS)
            safeAreaInset(edge: .top, spacing: 0) {
                AppFilterBar(text: text, prompt: prompt)
            }
            #else
            searchable(text: text, prompt: Text(prompt))
            #endif
        } else {
            self
        }
    }
}

#if os(macOS)
/// A Mac filter field at the trailing end of a bar over the page.
private struct AppFilterBar: View {
    @Binding var text: String
    let prompt: String

    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .accessibilityLabel(prompt)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("generic.clear"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 240)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .themeBackground(.page, in: Rectangle())
    }
}
#endif

// MARK: - Navigation chrome

extension View {
    /// Hides a pushed page's own Back button where the window's toolbar
    /// has Back and Forward for every page (macOS).
    func appHidesSystemBackButton() -> some View {
        #if os(macOS)
        navigationBarBackButtonHidden(true)
        #else
        self
        #endif
    }

    /// The large leading title and the account avatar that Home and Library
    /// show in the iOS navigation bar. A Mac window shows the title in its
    /// title bar and keeps the account menu in its own toolbar.
    @ViewBuilder
    func appRootPageHeader<Title: View, Account: View>(
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder account: @escaping () -> Account
    ) -> some View {
        #if os(macOS)
        self
        #else
        appTitleDisplayMode(.inline)
            .appHideNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .appLeading) {
                    WithPerceptionTracking { title() }
                }
                .appHideSharedBackground()
                ToolbarItem(placement: .appTrailing) {
                    WithPerceptionTracking { account() }
                }
                .appHideSharedBackground()
            }
        #endif
    }

    /// Grouped rows like the iOS default, which a Mac form draws as System
    /// Settings does. A Mac text field shows its own title beside it, so a
    /// field inside a labeled row hides it there.
    func appGroupedFormStyle() -> some View {
        #if os(macOS)
        formStyle(.grouped)
            .labeledContentStyle(AppFormRowStyle())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct AppFormRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .labelsHidden()
        }
    }
}
#endif
