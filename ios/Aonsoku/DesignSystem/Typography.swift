import CoreText
import Perception
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Poppins, the web app's typeface, carries Aonsoku's headings: navigation
/// titles, page titles and section titles. Body text, rows and controls keep
/// the system font. Characters Poppins lacks, such as CJK, fall back to the
/// system's fonts for the preferred languages at the same weight, as the web
/// falls back to the platform sans-serif.
enum BrandFont {
    #if canImport(UIKit)
    typealias NativeFont = UIFont
    typealias NativeFontDescriptor = UIFontDescriptor
    #else
    typealias NativeFont = NSFont
    typealias NativeFontDescriptor = NSFontDescriptor
    #endif

    enum Weight: Hashable {
        case medium
        case semibold
        case bold

        fileprivate var postScriptName: String {
            switch self {
            case .medium: "Poppins-Medium"
            case .semibold: "Poppins-SemiBold"
            case .bold: "Poppins-Bold"
            }
        }

        fileprivate var systemWeight: NativeFont.Weight {
            switch self {
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    /// Poppins at exactly `size`.
    static func nativeFont(size: CGFloat, weight: Weight) -> NativeFont {
        let system = NativeFont.systemFont(ofSize: size, weight: weight.systemWeight)
        guard let poppins = NativeFont(name: weight.postScriptName, size: size) else {
            return system
        }
        let languages = Locale.preferredLanguages as CFArray
        let fallbacks = CTFontCopyDefaultCascadeListForLanguages(system as CTFont, languages)
            as? [NativeFontDescriptor] ?? []
        let descriptor = poppins.fontDescriptor.addingAttributes([
            .cascadeList: [system.fontDescriptor] + fallbacks,
        ])
        #if canImport(UIKit)
        return UIFont(descriptor: descriptor, size: size)
        #else
        return NSFont(descriptor: descriptor, size: size) ?? poppins
        #endif
    }

    #if os(macOS)
    /// Registers the bundled Poppins files with the process. iOS reads them
    /// from the Info.plist's font list; a Mac app registers them itself, and
    /// must do so before the first heading asks for one.
    static func registerBundledFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
    #endif

    #if canImport(UIKit)
    /// Poppins at `size` for the default text size, scaled for `category`
    /// the way `textStyle` scales.
    static func uiFont(
        size: CGFloat,
        weight: Weight,
        relativeTo textStyle: UIFont.TextStyle,
        category: UIContentSizeCategory
    ) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let scaled = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size, compatibleWith: traits)
        return nativeFont(size: scaled, weight: weight)
    }

    /// Navigation bar titles in Poppins. Call once at launch, before the
    /// first bar appears.
    static func applyToNavigationBars() {
        let category = UIApplication.shared.preferredContentSizeCategory
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [
            .font: uiFont(size: DisplayStyle.largeTitle.size, weight: .bold, relativeTo: .largeTitle, category: category),
        ]
        bar.titleTextAttributes = [
            .font: uiFont(size: 17, weight: .semibold, relativeTo: .headline, category: category),
        ]
    }
    #endif
}

/// The heading styles, each scaled with Dynamic Type like the system style
/// it stands in for. A Mac has no Dynamic Type, so they keep their size there.
enum DisplayStyle: Hashable {
    /// Large navigation titles.
    case largeTitle
    /// The name on an album, playlist or artist page.
    case title
    /// Shelf and section titles.
    case section
    /// Titles on featured cards.
    case card
    /// The song title in the full-screen player.
    case player
    /// Inline titles, matching the navigation bar's.
    case inline

    var size: CGFloat {
        switch self {
        case .largeTitle: 30
        case .title: 22
        case .section: 19
        case .card: 18
        case .player: 20
        case .inline: 17
        }
    }

    var weight: BrandFont.Weight {
        switch self {
        case .largeTitle, .title, .card, .player: .bold
        case .section, .inline: .semibold
        }
    }

    #if canImport(UIKit)
    var textStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title2
        case .section, .card, .player: .title3
        case .inline: .headline
        }
    }
    #endif
}

extension View {
    /// Sets a Poppins heading font.
    func displayFont(_ style: DisplayStyle) -> some View {
        modifier(DisplayFontModifier(style: style))
    }
}

private struct DisplayFontModifier: ViewModifier {
    let style: DisplayStyle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content.font(DisplayFontCache.font(style, dynamicTypeSize))
        }
    }
}

/// Builds each style once per text size; cascade lists are not free.
private enum DisplayFontCache {
    private struct Key: Hashable {
        let style: DisplayStyle
        let size: DynamicTypeSize
    }

    private static var fonts: [Key: Font] = [:]

    static func font(_ style: DisplayStyle, _ size: DynamicTypeSize) -> Font {
        let key = Key(style: style, size: size)
        if let font = fonts[key] {
            return font
        }
        #if canImport(UIKit)
        let native = BrandFont.uiFont(
            size: style.size,
            weight: style.weight,
            relativeTo: style.textStyle,
            category: UIContentSizeCategory(size)
        )
        #else
        let native = BrandFont.nativeFont(size: style.size, weight: style.weight)
        #endif
        let font = Font(native)
        fonts[key] = font
        return font
    }
}
