import SwiftUI
import UIKit

/// AMLL's width-constrained, content-height text layout. Measurement and drawing
/// use the same UILabel configuration, before any lyric emphasis transforms.
@MainActor
struct LyricsTextLayout {
    let text: String
    let font: UIFont
    let width: CGFloat
    var lineSpacing: CGFloat = 0

    func configure(_ label: UILabel) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontSizeToFitWidth = false
        label.textColor = .white
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph,
        ])
    }

    var height: CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }
        let label = UILabel()
        configure(label)
        return ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// An explicit content-sized leaf: neither a Button nor the animation canvas
/// may propose a smaller height and turn a long lyric into an ellipsis.
struct LyricsText: UIViewRepresentable {
    let layout: LyricsTextLayout

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.isUserInteractionEnabled = false
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        layout.configure(label)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        layout.configure(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        CGSize(width: layout.width, height: layout.height)
    }
}
