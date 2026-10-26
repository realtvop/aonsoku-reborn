import Perception
import SwiftUI

// MARK: - Cards

extension View {
    /// The web's bordered card: the theme's card color, faint enough for
    /// the page to show through, inside a hairline border.
    func cardSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.themeContext) private var theme

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(theme.palette.card.opacity(theme.palette.isDark ? 0.55 : 0.9), in: shape)
                .overlay {
                    WithPerceptionTracking {
                        shape.strokeBorder(theme.palette.border, lineWidth: 1)
                    }
                }
                .contentShape(shape)
        }
    }
}

/// A symbol on a rounded square in the theme's border color, like the
/// icons of the web's mobile library rows.
struct IconTile: View {
    let systemImage: String
    var size: CGFloat = 36

    var body: some View {
        WithPerceptionTracking {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(ThemeColor.border, in: .rect(cornerRadius: size * 0.24, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Metadata

/// One fact in a `MetadataLine`, linking to `route` when it has one.
struct MetadataItem {
    let text: String
    var route: AppRoute?
}

/// "2021 · Rock · 12 songs", the web's header badges: facts separated by
/// dots that wrap onto further lines, centered or leading.
struct MetadataLine: View {
    let items: [MetadataItem]
    var alignment: HorizontalAlignment = .center

    var body: some View {
        WithPerceptionTracking {
            FlowLayout(alignment: alignment, spacing: 0, lineSpacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    WithPerceptionTracking {
                        HStack(spacing: 0) {
                            if index > 0 {
                                Text(verbatim: " · ")
                            }
                            if let route = item.route {
                                NavigationLink(value: route) {
                                    Text(item.text)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(item.text)
                            }
                        }
                        .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Lays its children out in rows, wrapping when the width runs out.
struct FlowLayout: SwiftUI.Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = switch alignment {
            case .center: bounds.minX + (bounds.width - row.width) / 2
            case .trailing: bounds.maxX - row.width
            default: bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: LayoutSubviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty {
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Captions

/// A small uppercase caption over a group, like the web's search sections
/// and device overview, with an optional link at the trailing edge.
struct CaptionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(title)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(ThemeColor.mutedForeground)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.tint)
                    }
                }
                .labelStyle(CaptionLabelStyle(showsIcon: systemImage != nil))
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}

extension CaptionHeader where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) {
            EmptyView()
        }
    }
}

private struct CaptionLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                if showsIcon {
                    configuration.icon
                }
                configuration.title
            }
        }
    }
}
