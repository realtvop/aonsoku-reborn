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
