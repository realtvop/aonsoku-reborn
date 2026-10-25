import XCTest

@testable import AonsokuKit

final class RGBColorTests: XCTestCase {
    func testContrastRatioMatchesWCAGReferenceValues() {
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let gray = RGBColor(red: 0.5, green: 0.5, blue: 0.5)

        XCTAssertEqual(white.contrastRatio(with: black), 21, accuracy: 0.001)
        XCTAssertEqual(black.contrastRatio(with: white), 21, accuracy: 0.001)
        XCTAssertEqual(gray.contrastRatio(with: gray), 1, accuracy: 0.001)
        // sRGB 0.5 has a relative luminance of about 0.214.
        XCTAssertEqual(white.contrastRatio(with: gray), 3.98, accuracy: 0.01)
    }
}
