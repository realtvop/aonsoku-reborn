import AonsokuKit
import Perception
import SwiftUI
import UIKit

// Keep availability decisions here so pages share one fallback on older systems.
extension View {
    @ViewBuilder
    func appGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func appGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    func appSymbolTransition() -> some View {
        if #available(iOS 17, *) { contentTransition(.symbolEffect(.replace)) }
        else { self }
    }

    @ViewBuilder
    func appNumericTransition() -> some View {
        if #available(iOS 17, *) { contentTransition(.numericText()) }
        else { self }
    }

    @ViewBuilder
    func appSymbolBounce<T: Equatable>(value: T) -> some View {
        if #available(iOS 17, *) { symbolEffect(.bounce, value: value) }
        else { self }
    }

    @ViewBuilder
    func appOnChange<T: Equatable>(
        of value: T, initial: Bool = false, _ action: @escaping (T, T) -> Void
    ) -> some View {
        if #available(iOS 17, *) { onChange(of: value, initial: initial, action) }
        else { modifier(AppChangeObserver(value: value, initial: initial, action: action)) }
    }

    func appOnChange<T: Equatable>(
        of value: T, initial: Bool = false, _ action: @escaping () -> Void
    ) -> some View {
        appOnChange(of: value, initial: initial) { _, _ in action() }
    }

    @ViewBuilder
    func appFeedback<T: Equatable>(
        trigger: T, _ feedback: @escaping (T, T) -> AppFeedback?
    ) -> some View {
        if #available(iOS 17, *) {
            sensoryFeedback(trigger: trigger) { old, new in feedback(old, new)?.sensory }
        } else {
            appOnChange(of: trigger) { old, new in feedback(old, new)?.play() }
        }
    }

    @ViewBuilder
    func appHideScrollEdgeEffects() -> some View {
        if #available(iOS 26, *) { scrollEdgeEffectHidden() }
        else { self }
    }

    @ViewBuilder
    func appAlwaysBounceVertically() -> some View {
        if #available(iOS 16.4, *) { scrollBounceBehavior(.always) }
        else { self } // QueueHeaderTrackingReader also sets UIKit's bounce flags.
    }

    @ViewBuilder
    func appListSectionSpacing(_ spacing: CGFloat) -> some View {
        if #available(iOS 17, *) { listSectionSpacing(spacing) }
        else { environment(\.defaultMinListHeaderHeight, spacing) }
    }

    @ViewBuilder
    func appScrollTargetLayout() -> some View {
        if #available(iOS 17, *) { scrollTargetLayout() }
        else { self }
    }

    @ViewBuilder
    func appViewAlignedScrolling() -> some View {
        if #available(iOS 17, *) { scrollTargetBehavior(.viewAligned) }
        else { self }
    }

    @ViewBuilder
    func appScrollClipDisabled() -> some View {
        if #available(iOS 17, *) { scrollClipDisabled() }
        else { background(LegacyScrollObserver(configure: { $0.clipsToBounds = false })) }
    }

    func appHorizontalScrollMargins(_ margin: CGFloat) -> some View {
        modifier(HorizontalScrollMargins(margin: margin))
    }

    func appContainerRelativeFrame(
        _ axes: Axis.Set, count: Int = 1, span: Int = 1, spacing: CGFloat = 0
    ) -> some View {
        modifier(HorizontalRelativeFrame(count: count, span: span, spacing: spacing))
    }
}

private struct AppChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var previous: Value
    @State private var appeared = false

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !appeared else { return }
                appeared = true
                previous = value
                if initial { action(value, value) }
            }
            .onChange(of: value) { next in
                let old = previous
                previous = next
                action(old, next)
            }
    }
}

enum AppFeedback {
    case selection, lightImpact, success, error

    @available(iOS 17, *)
    var sensory: SensoryFeedback {
        switch self {
        case .selection: .selection
        case .lightImpact: .impact(weight: .light)
        case .success: .success
        case .error: .error
        }
    }

    @MainActor func play() {
        switch self {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .lightImpact: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func appHideSharedBackground() -> some ToolbarContent {
        if #available(iOS 26, *) { sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

struct AppUnavailableView<Label: View, Description: View, Actions: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var description: Description
    @ViewBuilder var actions: Actions

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 17, *) {
                ContentUnavailableView { label } description: { description } actions: { actions }
            } else {
                VStack(spacing: 16) {
                    label.labelStyle(UnavailableLabelStyle())
                    description
                        .font(.subheadline)
                        .foregroundStyle(ThemeColor.mutedForeground)
                    actions
                }
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct UnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 16) {
            configuration.icon.font(.system(size: 44)).foregroundStyle(ThemeColor.mutedForeground)
            configuration.title.font(.headline)
        }
    }
}

private struct ScrollWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    var legacyScrollWidth: CGFloat? {
        get { self[ScrollWidthKey.self] }
        set { self[ScrollWidthKey.self] = newValue }
    }
}

private struct HorizontalScrollMargins: ViewModifier {
    let margin: CGFloat
    @State private var width: CGFloat = 0

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.contentMargins(.horizontal, margin, for: .scrollContent)
        } else {
            content
                .environment(\.legacyScrollWidth, max(0, width - margin * 2))
                .padding(.horizontal, margin)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        }
    }
}

private struct HorizontalRelativeFrame: ViewModifier {
    let count: Int
    let span: Int
    let spacing: CGFloat
    @Environment(\.legacyScrollWidth) private var width

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.containerRelativeFrame(.horizontal, count: count, span: span, spacing: spacing)
        } else {
            let available = width ?? 0
            let unit = max(0, (available - CGFloat(count - 1) * spacing) / CGFloat(count))
            content.frame(width: unit * CGFloat(span) + CGFloat(span - 1) * spacing)
        }
    }
}

extension View {
    func appInteractiveGlass<S: Shape>(in shape: S) -> some View {
        appGlass(in: shape, interactive: true)
    }

    @ViewBuilder
    func appZeroVerticalScrollMargins() -> some View {
        if #available(iOS 17, *) { contentMargins(.vertical, 0, for: .scrollContent) }
        else { self }
    }
}

struct AppCloseButton: View {
    let action: () -> Void
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 26, *) {
                Button(role: .close, action: action)
            } else {
                Button(action: action) { Image(systemName: "xmark") }
                    .accessibilityLabel(t("fullscreen.close"))
            }
        }
    }
}

struct AppCancelButton: View {
    let action: () -> Void
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 26, *) { Button(role: .cancel, action: action) }
            else { Button(t("generic.cancel"), role: .cancel, action: action) }
        }
    }
}

struct AppSaveButton: View {
    let action: () -> Void
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 26, *) { Button(role: .confirm, action: action) }
            else { Button(t("settings.crossDevice.device.save"), action: action).fontWeight(.semibold) }
        }
    }
}

extension View {
    @ViewBuilder
    func appCircularButtonBorder() -> some View {
        if #available(iOS 17, *) { buttonBorderShape(.circle) }
        else { buttonBorderShape(.capsule) }
    }
}
