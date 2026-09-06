import XCTest
import SnoopyTVCore

/// Apple's `info` lists combine condition families with AND and the members of
/// one family with OR: `ScenePalette_Cloudy_Day` = cloudy ∧ (morning ∨ afternoon),
/// the full-moon visitor = (evening ∨ lateNight) ∧ moonFull.
final class RelevancySemanticsTests: XCTestCase {
    private func clause(_ family: String, _ field: String, _ value: String) -> JSONValue {
        .object([family: .object([field: .string(value)])])
    }

    private func asset(_ id: String, info: [JSONValue]) -> AssetRecord {
        AssetRecord(id: id, metadataType: "idleSceneVisitor", relevancyData: .object(["info": .array(info)]))
    }

    private func score(_ asset: AssetRecord, _ context: SelectionContext) -> Int? {
        RelevancyScorer().relevanceScore(asset, context: context)
    }

    func testMoonVisitorNeedsNightAndPhase() {
        let fullMoon = asset("101_VI004", info: [
            clause("timeOfDay", "timeOfDay", "evening"), clause("timeOfDay", "timeOfDay", "lateNight"),
            clause("weather", "condition", "moonFull"),
        ])
        XCTAssertNil(score(fullMoon, SelectionContext(timeOfDay: "afternoon", moonPhases: ["moonFull"])))
        XCTAssertNil(score(fullMoon, SelectionContext(timeOfDay: "evening", moonPhases: ["moonNew"])))
        XCTAssertNotNil(score(fullMoon, SelectionContext(timeOfDay: "evening", moonPhases: ["moonFull"])))
        XCTAssertNotNil(score(fullMoon, SelectionContext(timeOfDay: "lateNight", moonPhases: ["moonFull"])))
    }

    func testPaletteNeedsWeatherAndDaytime() {
        let cloudyDay = asset("ScenePalette_Cloudy_Day", info: [
            clause("weather", "condition", "cloudy"),
            clause("timeOfDay", "timeOfDay", "morning"), clause("timeOfDay", "timeOfDay", "afternoon"),
        ])
        XCTAssertNotNil(score(cloudyDay, SelectionContext(timeOfDay: "morning", weatherConditions: ["cloudy"])))
        XCTAssertNotNil(score(cloudyDay, SelectionContext(timeOfDay: "afternoon", weatherConditions: ["cloudy"])))
        XCTAssertNil(score(cloudyDay, SelectionContext(timeOfDay: "morning", weatherConditions: ["clear"])))
        XCTAssertNil(score(cloudyDay, SelectionContext(timeOfDay: "evening", weatherConditions: ["cloudy"])))
    }

    func testSingleFamilyListStaysOr() {
        let rain = asset("103_AS045", info: [
            clause("weather", "condition", "rainy"), clause("weather", "condition", "stormy"),
        ])
        XCTAssertNotNil(score(rain, SelectionContext(weatherConditions: ["stormy"])))
        XCTAssertNotNil(score(rain, SelectionContext(weatherConditions: ["rainy"])))
        XCTAssertNil(score(rain, SelectionContext(weatherConditions: ["sunny"])))
    }

    func testFamilySpecificitiesAddUp() {
        let cloudyDay = asset("palette", info: [
            clause("weather", "condition", "cloudy"), clause("timeOfDay", "timeOfDay", "morning"),
        ])
        let cloudy = asset("cloudy", info: [clause("weather", "condition", "cloudy")])
        let context = SelectionContext(timeOfDay: "morning", weatherConditions: ["cloudy"])
        XCTAssertEqual(score(cloudyDay, context), 80) // weather 50 + timeOfDay 30
        XCTAssertEqual(score(cloudy, context), 50)
    }
}
