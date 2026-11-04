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

// MARK: - Selectable lists

extension EnvironmentValues {
    /// True inside a list whose rows a Mac user selects. Its rows then leave
    /// clicks, menus and the primary action to the list.
    @Entry var appRowsSelectable = false
}

/// A `List` whose rows a Mac user selects with clicks, Shift and Command, and
/// the arrow keys. iOS selects only while editing, so there it is a plain
/// list whose rows act on a tap.
struct AppList<Selection: Hashable, Content: View>: View {
    @Binding var selection: Set<Selection>
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        List(selection: $selection) {
            content
        }
        .environment(\.appRowsSelectable, true)
        #else
        List {
            content
        }
        #endif
    }
}

extension View {
    /// The menu for the selected rows, or the right-clicked one, and what a
    /// double-click or Return does with them (macOS).
    func appSelectionMenu<Selection: Hashable, Menu: View>(
        forSelectionType type: Selection.Type,
        @ViewBuilder menu: @escaping (Set<Selection>) -> Menu,
        primaryAction: @escaping (Set<Selection>) -> Void
    ) -> some View {
        #if os(macOS)
        contextMenu(forSelectionType: type, menu: menu, primaryAction: primaryAction)
        #else
        self
        #endif
    }

    /// What Delete does with a Mac list's selection; nil when it does nothing.
    func appDeleteCommand(perform action: (() -> Void)?) -> some View {
        #if os(macOS)
        onDeleteCommand(perform: action)
        #else
        self
        #endif
    }

    /// Lets a row be dragged onto a playlist or the queue (macOS).
    func appDraggableSongs(_ songs: @escaping () -> [Song]) -> some View {
        #if os(macOS)
        draggable(MacSongTransfer(songs: songs()))
        #else
        self
        #endif
    }
}

// MARK: - Metrics

/// Sizes that follow the pointing device: touch targets on iOS, the denser
/// rows and buttons of a Mac list.
enum AppMetrics {
    static var rowHeight: CGFloat {
        #if os(macOS)
        32
        #else
        44
        #endif
    }

    static var rowArtwork: CGFloat {
        #if os(macOS)
        34
        #else
        44
        #endif
    }

    static var iconButton: CGFloat {
        #if os(macOS)
        26
        #else
        44
        #endif
    }

    /// Synced lyric lines: the full-screen player on iOS, the narrower
    /// inspector on a Mac.
    static var lyricLine: CGFloat {
        #if os(macOS)
        24
        #else
        30
        #endif
    }
}

// MARK: - Pointer

extension View {
    /// A play button over a cover while the pointer rests on it (macOS).
    func appHoverPlayButton(label: String, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        modifier(HoverPlayButton(label: label, action: action))
        #else
        self
        #endif
    }

    /// Buttons at the ends of a horizontal shelf that scroll it by a page
    /// while the pointer is over it: a mouse wheel scrolls only vertically
    /// (macOS).
    func appShelfPaging() -> some View {
        #if os(macOS)
        modifier(ShelfPaging())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct HoverPlayButton: ViewModifier {
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if isHovered {
                    Button(action: action) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.tint, in: .circle)
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help(label)
                    .accessibilityLabel(label)
                    .transition(.opacity)
                }
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
            }
    }
}

private struct ShelfPaging: ViewModifier {
    @State private var position = ScrollPosition(edge: .leading)
    @State private var metrics = Metrics()
    @State private var isHovered = false

    private struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0
    }

    @Environment(Localizer.self) private var t

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(
                    offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                    content: geometry.contentSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing,
                    viewport: geometry.containerSize.width
                )
            } action: { _, new in
                metrics = new
            }
            .overlay(alignment: .leading) {
                if isHovered, metrics.offset > 1 {
                    pageButton(-1, systemImage: "chevron.backward", label: t("navigation.back"))
                }
            }
            .overlay(alignment: .trailing) {
                if isHovered, metrics.offset < metrics.content - metrics.viewport - 1 {
                    pageButton(1, systemImage: "chevron.forward", label: t("native.mac.navigation.forward"))
                }
            }
            .onHover { isHovered = $0 }
    }

    private func pageButton(_ direction: CGFloat, systemImage: String, label: String) -> some View {
        Button {
            let maximum = max(metrics.content - metrics.viewport, 0)
            let target = min(max(metrics.offset + direction * metrics.viewport * 0.85, 0), maximum)
            withAnimation(.smooth(duration: 0.4)) {
                position.scrollTo(x: target)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: .circle)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .help(label)
        .accessibilityLabel(label)
    }
}
#endif
