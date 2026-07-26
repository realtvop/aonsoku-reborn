import UIKit
import Capacitor
import WebKit
import AonsokuNativePlugin

class AonsokuViewController: CAPBridgeViewController {
    private let mediaSchemeHandler = MediaSchemeHandler()
    private let startupBackgroundColor = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 6 / 255, green: 14 / 255, blue: 35 / 255, alpha: 1)
        }
        return UIColor(red: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = startupBackgroundColor
        webView?.backgroundColor = startupBackgroundColor
        webView?.scrollView.backgroundColor = startupBackgroundColor
        webView?.allowsBackForwardNavigationGestures = true
    }

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let config = super.webViewConfiguration(for: instanceConfiguration)
        config.setURLSchemeHandler(mediaSchemeHandler, forURLScheme: "aonsoku-media")
        return config
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            presentDebugMenu()
        }
    }

    private func presentDebugMenu() {
        guard presentedViewController == nil else { return }
        let debugVC = DebugViewController(bridge: bridge)
        let nav = UINavigationController(rootViewController: debugVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}
