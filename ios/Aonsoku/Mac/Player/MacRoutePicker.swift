import AVKit
import SwiftUI

/// The system AirPlay and output picker, as a borderless toolbar-sized button.
struct MacRoutePicker: NSViewRepresentable {
    /// What VoiceOver reads for the picker and its button.
    let label: String

    func makeNSView(context: Context) -> LabeledRoutePickerView {
        let view = LabeledRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.label = label
        return view
    }

    func updateNSView(_ view: LabeledRoutePickerView, context: Context) {
        view.label = label
    }
}

/// An `AVRoutePickerView` whose button reads the app's localized label
/// rather than the system's English one. The picker answers for its own
/// label, and its button is created lazily, so that one is labeled again on
/// layout.
final class LabeledRoutePickerView: AVRoutePickerView {
    var label = "" {
        didSet { labelDescendants(of: self) }
    }

    override func accessibilityLabel() -> String? { label }

    /// The picker is itself the button VoiceOver presses; its inner button
    /// would be a second, unlabeled one.
    override func accessibilityChildren() -> [Any]? { [] }

    override func layout() {
        super.layout()
        labelDescendants(of: self)
    }

    private func labelDescendants(of view: NSView) {
        for subview in view.subviews {
            if subview is NSControl || subview.isAccessibilityElement() {
                subview.setAccessibilityLabel(label)
            }
            labelDescendants(of: subview)
        }
    }
}
