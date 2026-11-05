import SwiftUI
import UIKit

// Simulator regression harness using the production text leaf inside the same
// Button / VStack / constrained ZStack structure as the animated lyrics.
struct Fixture: View {
    let width: CGFloat
    let scale: CGFloat
    let active: Bool
    let translation: Bool
    static let original = "夜空の光とどちらが多いのだろう？ 長い歌詞も省略せず最後の文字まで表示します。終わり"
    static let roman = "yo zo ra no hi ka ri to do chi ra ga o o i no da ro u? nagai kashi mo saigo made subete hyouji shimasu. owari"
    static let translated = "和夜空光芒比起来哪个多呢？无论歌词有多长，都应完整显示最后一个字，不能隐藏或省略。结束"

    func layout(_ text: String, main: Bool = false) -> LyricsTextLayout {
        LyricsTextLayout(text: text, font: .systemFont(ofSize: (main ? 36 : 16) * scale,
                         weight: main ? .semibold : .regular), width: width - 40)
    }
    func leaf(_ text: String, main: Bool = false) -> some View {
        let value = layout(text, main: main)
        return LyricsText(layout: value)
            .frame(width: value.width, height: value.height)
    }
    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                Button {} label: {
                    VStack(alignment: .leading, spacing: 0) {
                        leaf(Self.roman).opacity(0.3)
                        leaf(Self.original, main: true)
                            .scaleEffect(active ? 1 : 0.862069, anchor: .leading)
                            .opacity(active ? 0.85 : 0.2)
                        if translation { leaf(Self.translated).opacity(0.3) }
                    }
                    .padding(20)
                    .fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain)
            }.frame(width: width, height: 1600, alignment: .topLeading)
        }.frame(width: width, height: 650).background(Color(white: 0.23))
    }
}

@main
class LayoutApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Tests", sessionRole: session.role)
        configuration.delegateClass = LayoutScene.self
        return configuration
    }
}

class LayoutScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var checks = 0
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.rootViewController = UIHostingController(rootView: Text("Running lyric layout checks"))
        window?.makeKeyAndVisible()
        Task { @MainActor in await run() }
    }
    func labels(_ view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels)
    }
    func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for width: CGFloat in [240, 320, 390, 620] {
            for scale: CGFloat in [1, 1.8] {
                for translation in [true, false] {
                    var baseline: [CGFloat] = []
                    for active in [false, true, false] {
                        let fixture = Fixture(width: width, scale: scale, active: active, translation: translation)
                        let host = UIHostingController(rootView: fixture)
                        window?.rootViewController = host
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        host.view.layoutIfNeeded()
                        let found = labels(host.view)
                        check(found.count == (translation ? 3 : 2), "Missing lyric layers: \(width)/\(scale)")
                        let heights = found.map { $0.bounds.height }
                        if baseline.isEmpty { baseline = heights }
                        check(heights == baseline, "Focus changed layout height: \(width)/\(scale)")
                        for label in found {
                            let required = ceil(label.sizeThatFits(CGSize(width: width - 40, height: CGFloat.greatestFiniteMagnitude)).height)
                            check(label.bounds.height >= required, "Clipped text: \(width)/\(scale): \(label.bounds.height) < \(required)")
                            check(abs(label.bounds.width - (width - 40)) < 0.5, "Wrong text width")
                            check(label.numberOfLines == 0 && label.lineBreakMode == .byWordWrapping, "Truncation enabled")
                            check(!label.adjustsFontSizeToFitWidth, "Text shrinks")
                        }
                        if width == 390 && scale == 1 && active && translation {
                            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                            }
                            try? image.pngData()?.write(to: directory.appendingPathComponent("lyrics.png"))
                        }
                    }
                }
            }
        }
        // Explicit 1/2/3/4+ line cases, newlines, long unbroken words and emoji.
        for value in ["短句", "第一行\n第二行", "一\n二\n三", "一\n二\n三\n四\n五", String(repeating: "longword", count: 30), "👨‍👩‍👧‍👦 音楽 🎵\n最后一行"] {
            let layout = LyricsTextLayout(text: value, font: .systemFont(ofSize: 36), width: 200)
            let label = UILabel()
            layout.configure(label)
            check(label.text == value, "Text content changed")
            check(layout.height >= label.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)).height, "Incorrect natural height")
        }
        let result: [String: Any] = ["checks": checks, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: directory.appendingPathComponent("results.json"))
    }
}
