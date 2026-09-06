import XCTest
import SnoopyTVCore

final class PreferencesTests: XCTestCase {
    private let keys = [
        SnoopyPreferences.playbackRateKey,
        SnoopyPlaybackHost.wallpaper.playbackRateKey,
        SnoopyPlaybackHost.screenSaver.playbackRateKey,
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { SnoopyPreferences.defaults.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { SnoopyPreferences.defaults.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testPlaybackRateDefaultsToAuthoredSpeedAndIsPerHost() {
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .wallpaper), 1.0)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .screenSaver), 1.0)
        SnoopyPreferences.setPlaybackRate(1.5, for: .wallpaper)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .wallpaper), 1.5)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .screenSaver), 1.0)
    }

    func testLegacySharedRateIsTheFallbackAndValuesAreClamped() {
        SnoopyPreferences.defaults.set(0.75, forKey: SnoopyPreferences.playbackRateKey)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .screenSaver), 0.75)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .wallpaper), 0.75)
        SnoopyPreferences.setPlaybackRate(10, for: .screenSaver)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .screenSaver), 4.0)
        XCTAssertEqual(SnoopyPreferences.playbackRate(for: .wallpaper), 0.75)
    }

    func testRateTitles() {
        XCTAssertEqual(SnoopyPreferences.playbackRateTitle(1.0), "1×")
        XCTAssertEqual(SnoopyPreferences.playbackRateTitle(0.75), "0.75×")
    }
}
