import SwiftUI
import UIKit

/// One persistent set of controls: only their geometry changes as the dock
/// collapses. In particular, Search never changes its system tab role.
struct CompactTabBar<Player: View>: View, Animatable {
    var collapse: CGFloat
    let selectedTab: AppTab
    let primaryTab: AppTab
    let homeTitle: String
    let libraryTitle: String
    let searchTitle: String
    let select: (AppTab) -> Void
    @ViewBuilder var player: (CGFloat) -> Player

    @ScaledMetric(relativeTo: .caption) private var tabHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var compactHeight: CGFloat = 52

    var animatableData: CGFloat {
        get { collapse }
        set { collapse = newValue }
    }

    private var progress: CGFloat { min(max(collapse, 0), 1) }

    var body: some View {
        dockLayout {
            tab(.home, title: homeTitle, symbol: "house.fill")
                .layoutValue(key: DockElementKey.self, value: .home)
            tab(.library, title: libraryTitle, symbol: "square.stack.fill")
                .layoutValue(key: DockElementKey.self, value: .library)
            tab(.search, title: searchTitle, symbol: "magnifyingglass")
                .layoutValue(key: DockElementKey.self, value: .search)
            player(progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutValue(key: DockElementKey.self, value: .player)
        }
        .background {
            GlassEffectContainer(spacing: 8) {
                dockLayout {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .layoutValue(key: DockElementKey.self, value: .navigation)
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .opacity(progress)
                        .layoutValue(key: DockElementKey.self, value: .search)
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                        .layoutValue(key: DockElementKey.self, value: .player)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var dockLayout: CompactTabBarLayout {
        CompactTabBarLayout(progress: progress, tabHeight: tabHeight, compactHeight: compactHeight)
    }

    private func tab(_ tab: AppTab, title: String, symbol: String) -> some View {
        let staysVisible = tab == .search || tab == primaryTab
        let isSelected = tab == selectedTab
        return Button {
            select(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 24 + 2 * progress, weight: .medium))
                    .frame(height: 28)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .opacity(1 - progress)
            }
            .offset(y: 7 * progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background {
                Capsule()
                    .fill(.primary.opacity(isSelected ? 0.08 : 0))
                    .padding(4)
                    .opacity(1 - progress)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(staysVisible ? 1 : max(0, 1 - progress * 3))
        .allowsHitTesting(staysVisible || progress < 0.5)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHidden(!staysVisible && progress >= 0.5)
    }
}

nonisolated private enum DockElement {
    case navigation, home, library, search, player
}

nonisolated private struct DockElementKey: LayoutValueKey {
    static let defaultValue = DockElement.navigation
}

/// The controls and glass retain their identities and interpolate in the same
/// coordinate space, including the player moving down into the tab row.
private struct CompactTabBarLayout: SwiftUI.Layout {
    let progress: CGFloat
    let tabHeight: CGFloat
    let compactHeight: CGFloat
    private let playerHeight: CGFloat = 48
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let width = bounds.width
        let column = width / 3
        // Open horizontal room before the player descends between the tabs.
        let horizontal = 1 - (1 - progress) * (1 - progress)
        let rowY = (playerHeight + spacing) * (1 - progress)
        let rowHeight = mix(tabHeight, compactHeight)
        let tabWidth = column + (compactHeight - column) * horizontal
        let searchX = column * 2 + (width - compactHeight - column * 2) * horizontal
        for subview in subviews {
            let frame: CGRect =
                switch subview[DockElementKey.self] {
                case .navigation:
                    CGRect(
                        x: 0, y: rowY, width: width + (compactHeight - width) * horizontal,
                        height: rowHeight)
                case .home:
                    CGRect(x: 0, y: rowY, width: tabWidth, height: rowHeight)
                case .library:
                    CGRect(
                        x: column * (1 - horizontal), y: rowY, width: tabWidth, height: rowHeight)
                case .search:
                    CGRect(x: searchX, y: rowY, width: tabWidth, height: rowHeight)
                case .player:
                    CGRect(
                        x: (compactHeight + spacing) * horizontal,
                        y: 0,
                        width: width - 2 * (compactHeight + spacing) * horizontal,
                        height: mix(playerHeight, compactHeight)
                    )
                }
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private var height: CGFloat { mix(playerHeight + spacing + tabHeight, compactHeight) }

    private func mix(_ expanded: CGFloat, _ compact: CGFloat) -> CGFloat {
        expanded + (compact - expanded) * progress
    }
}

extension EnvironmentValues {
    @Entry var compactTabBarMinimization: ((Bool) -> Void)?
}

extension View {
    /// Hide the system bar at the page and observe its vertical scroll view,
    /// leaving horizontal shelves and programmatic restoration out of minimization.
    func compactTabBarPage() -> some View {
        modifier(CompactTabBarScrollBehavior())
    }

    func hideCompactTabBarWithKeyboard() -> some View {
        modifier(CompactTabBarKeyboardVisibility())
    }
}

private struct CompactTabBarKeyboardVisibility: ViewModifier {
    @State private var isKeyboardVisible = false

    func body(content: Content) -> some View {
        content
            .frame(height: isKeyboardVisible ? 0 : nil, alignment: .bottom)
            .opacity(isKeyboardVisible ? 0 : 1)
            .clipped()
            .allowsHitTesting(!isKeyboardVisible)
            .accessibilityHidden(isKeyboardVisible)
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            ) {
                update(true, notification: $0)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            ) {
                update(false, notification: $0)
            }
    }

    private func update(_ visible: Bool, notification: Notification) {
        let duration =
            notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
            ?? 0.25
        withAnimation(.easeOut(duration: duration)) {
            isKeyboardVisible = visible
        }
    }
}

private struct CompactTabBarScrollBehavior: ViewModifier {
    @Environment(\.compactTabBarMinimization) private var minimize
    @State private var isUserScrolling = false
    @State private var travel: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .toolbar(minimize == nil ? .automatic : .hidden, for: .tabBar)
            .onAppear { minimize?(false) }
            .onScrollPhaseChange { old, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
                if phase == .interacting, old != .decelerating {
                    travel = 0
                }
            }
            .onScrollGeometryChange(for: VerticalScroll.self) { geometry in
                VerticalScroll(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    limit: max(
                        0,
                        geometry.contentSize.height + geometry.contentInsets.top
                            + geometry.contentInsets.bottom - geometry.containerSize.height)
                )
            } action: { old, value in
                guard let minimize else { return }
                let offset = min(max(value.offset, 0), value.limit)
                guard offset > 8, value.limit > 40 else {
                    travel = 0
                    minimize(false)
                    return
                }
                guard isUserScrolling else { return }
                // A changing bottom inset must not look like a reverse swipe
                // when the dock animates near the end of a page.
                let commonLimit = min(old.limit, value.limit)
                let delta = min(offset, commonLimit) - min(max(old.offset, 0), commonLimit)
                travel = delta * travel < 0 ? delta : travel + delta
                if travel >= 28 {
                    minimize(true)
                    travel = 0
                } else if travel <= -18 {
                    minimize(false)
                    travel = 0
                }
            }
    }

    private struct VerticalScroll: Equatable {
        let offset: CGFloat
        let limit: CGFloat
    }
}
