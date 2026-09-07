import XCTest
import SnoopyTVCore

/// The V2 reaction poses (docs/REACTION_POSES.md): four closed style families,
/// enters from base poses and from additional-pose loops, trigger-tagged poses
/// and generic holds. The default style must behave exactly like the V1 graph.
final class ReactionPoseTests: XCTestCase {
    // MARK: - Fixtures

    private func basePose(_ id: String) -> AssetRecord {
        AssetRecord(id: id, metadataType: "characterBasePose")
    }

    private func additionalPose(_ id: String, from start: String, to end: String) -> AssetRecord {
        AssetRecord(id: id, metadataType: "characterAdditionalPose",
                    startCharacterBasePoseID: start, endCharacterBasePoseID: end)
    }

    private func enter(_ id: String, from poseID: String, style: String? = nil) -> AssetRecord {
        AssetRecord(id: id, metadataType: "characterReactionTransitionPose",
                    phase: TransitionPhaseRecord(kind: "enter", startCharacterPoseID: poseID),
                    reactionStyleID: style)
    }

    private func exit(_ id: String, to poseID: String, style: String? = nil) -> AssetRecord {
        AssetRecord(id: id, metadataType: "characterReactionTransitionPose",
                    phase: TransitionPhaseRecord(kind: "exit", endCharacterPoseID: poseID),
                    reactionStyleID: style)
    }

    private func triggerInfo(_ triggers: [String]) -> JSONValue {
        .object(["info": .array(triggers.map {
            .object(["reactionTrigger": .object(["reactionTrigger": .string($0)])])
        })])
    }

    private func reactionPose(_ id: String, style: String, triggers: [String]) -> AssetRecord {
        AssetRecord(id: id, metadataType: "characterReactionPose",
                    relevancyData: triggerInfo(triggers), reactionStyleID: style)
    }

    private let standard = ReactionStyle.standard
    private let alternate = ReactionStyle.alternate
    private let withCompanion = ReactionStyle.standardWithCompanion
    private let alternateWithCompanion = ReactionStyle.alternateWithCompanion

    /// The V1 records of the shipped index (no reactionStyleID anywhere).
    private var v1Records: [AssetRecord] {
        [
            basePose("101_BP001"), basePose("101_BP002"),
            additionalPose("101_AP001", from: "101_BP001", to: "101_BP001"),
            additionalPose("103_AP021", from: "101_BP002", to: "101_BP002"),
            enter("101_BP001_To_RPH", from: "101_BP001"), enter("101_BP002_To_RPH", from: "101_BP002"),
            exit("101_RPH_To_BP001", to: "101_BP001"), exit("101_RPH_To_BP002", to: "101_BP002"),
        ]
    }

    /// A representative slice of the 44 V2 records.
    private var v2Records: [AssetRecord] {
        [
            enter("101_BP001_To_RPD", from: "101_BP001", style: alternate),
            enter("101_BP002_To_RPD", from: "101_BP002", style: alternate),
            enter("103_AP001_To_RPH", from: "101_AP001", style: standard),
            enter("101_AP001_To_RPD", from: "101_AP001", style: alternate),
            enter("103_AP021_To_RWH", from: "103_AP021", style: withCompanion),
            enter("103_AP021_To_RWD", from: "103_AP021", style: alternateWithCompanion),
            exit("101_RPD_To_BP001", to: "101_BP001", style: alternate),
            exit("101_RPD_To_BP002", to: "101_BP002", style: alternate),
            exit("101_RWH_To_BP001", to: "101_BP001", style: withCompanion),
            exit("101_RWH_To_BP002", to: "101_BP002", style: withCompanion),
            exit("101_RWD_To_BP001", to: "101_BP001", style: alternateWithCompanion),
            exit("101_RWD_To_BP002", to: "101_BP002", style: alternateWithCompanion),
            reactionPose("101_RPH_Loop", style: standard, triggers: ["generic"]),
            reactionPose("101_RPD_Loop", style: alternate, triggers: ["generic"]),
            reactionPose("101_RPD001", style: alternate, triggers: ["doorbell"]),
            reactionPose("101_RWD001", style: alternateWithCompanion, triggers: ["doorbell"]),
            reactionPose("103_RPH002", style: standard, triggers: ["alarm"]),
            reactionPose("103_RWH002", style: withCompanion, triggers: ["alarm"]),
            reactionPose("104_RPH003", style: standard, triggers: ["music"]),
        ]
    }

    private var mixedGraph: PlaybackGraph { PlaybackGraph(assets: v1Records + v2Records) }

    // MARK: - Default style keeps the V1 behaviour

    func testDefaultStyleResolvesV1ClipsWithV2RecordsPresent() {
        let v1Only = PlaybackGraph(assets: v1Records)
        for graph in [v1Only, mixedGraph] {
            XCTAssertEqual(graph.reactionEnter(from: "101_BP001")?.id, "101_BP001_To_RPH")
            XCTAssertEqual(graph.reactionExit(to: "101_BP002")?.id, "101_RPH_To_BP002")
            XCTAssertEqual(graph.reactionQueue(from: "101_BP001", to: "101_BP002")?.map(\.id),
                           ["101_BP001_To_RPH", "101_RPH_To_BP002"])
            let exitSequence = graph.idleExitSequence(from: "101_BP001")
            XCTAssertEqual(exitSequence?.assets.map(\.id), ["101_BP001_To_RPH"])
            XCTAssertEqual(exitSequence?.startPoseID, "101_BP001")
            XCTAssertEqual(exitSequence?.endPoseID, "RPH")
            let entrySequence = graph.idleEntrySequence(to: "101_BP002")
            XCTAssertEqual(entrySequence?.assets.map(\.id), ["101_RPH_To_BP002", "101_BP002"])
            XCTAssertEqual(entrySequence?.startPoseID, "RPH")
            XCTAssertEqual(entrySequence?.endPoseID, "101_BP002")
            XCTAssertEqual(graph.reactionStyle(of: graph.assetsByID["101_BP001_To_RPH"]!), ReactionStyle.standard)
        }
        // A V1-only index has no styled families and no reaction poses.
        XCTAssertNil(v1Only.reactionEnter(from: "101_BP001", style: alternate))
        XCTAssertEqual(v1Only.supportedReactionStyles(from: "101_BP001"), [standard])
        XCTAssertTrue(v1Only.reactionPoses().isEmpty)
        XCTAssertNil(v1Only.reactionHold())
    }

    func testReactionLookupsDoNotDependOnRecordOrder() {
        // Two standard enters from the same pose: the id-sorted first wins,
        // whatever the input order of the records.
        let records = v1Records + v2Records + [enter("101_BP001_To_RPH_alt", from: "101_BP001")]
        var orders: [[AssetRecord]] = [records, records.reversed()]
        for shift in stride(from: 3, to: records.count, by: 5) {
            orders.append(Array(records[shift...] + records[..<shift]))
        }
        for order in orders {
            let graph = PlaybackGraph(assets: order)
            XCTAssertEqual(graph.reactionEnter(from: "101_BP001")?.id, "101_BP001_To_RPH")
            XCTAssertEqual(graph.reactionEnter(from: "101_BP001", style: alternate)?.id, "101_BP001_To_RPD")
            XCTAssertEqual(graph.reactionExit(to: "101_BP001")?.id, "101_RPH_To_BP001")
            XCTAssertEqual(graph.reactionExit(to: "101_BP001", style: withCompanion)?.id, "101_RWH_To_BP001")
            XCTAssertEqual(graph.reactionPoses(style: standard).map(\.id),
                           ["101_RPH_Loop", "103_RPH002", "104_RPH003"])
            XCTAssertEqual(graph.supportedReactionStyles(from: "101_AP001"), [alternate, standard])
        }
    }

    // MARK: - Styles and where they can be entered

    func testEnterFromAdditionalPoseUsesTheV2Shortcut() {
        let graph = mixedGraph
        XCTAssertEqual(graph.reactionEnter(from: "101_AP001")?.id, "103_AP001_To_RPH")
        XCTAssertEqual(graph.reactionEnter(from: "101_AP001", style: alternate)?.id, "101_AP001_To_RPD")
        XCTAssertEqual(graph.supportedReactionStyles(from: "101_AP001"), [alternate, standard])
        let exitSequence = graph.idleExitSequence(from: "101_AP001", style: alternate)
        XCTAssertEqual(exitSequence?.assets.map(\.id), ["101_AP001_To_RPD"])
        XCTAssertEqual(exitSequence?.endPoseID, "RPD")
        XCTAssertEqual(graph.idleEntrySequence(to: "101_BP001", style: alternate)?.startPoseID, "RPD")
        XCTAssertEqual(graph.reactionQueue(from: "101_AP001", to: "101_BP002", style: alternate)?.map(\.id),
                       ["101_AP001_To_RPD", "101_RPD_To_BP002"])
        // No shortcut was authored for this AP: it must finish its outro.
        XCTAssertNil(graph.reactionEnter(from: "101_AP004"))
        XCTAssertEqual(graph.supportedReactionStyles(from: "101_AP004"), [])
    }

    func testCompanionStylesAreReachableOnlyFromWoodstockPoses() {
        let graph = mixedGraph
        XCTAssertEqual(graph.supportedReactionStyles(from: "101_BP001"), [alternate, standard])
        XCTAssertNil(graph.reactionEnter(from: "101_BP001", style: withCompanion))
        XCTAssertNil(graph.reactionEnter(from: "101_BP001", style: alternateWithCompanion))
        XCTAssertNil(graph.idleExitSequence(from: "101_BP002", style: withCompanion))
        XCTAssertEqual(graph.supportedReactionStyles(from: "103_AP021"), [alternateWithCompanion, withCompanion])
        XCTAssertEqual(graph.reactionEnter(from: "103_AP021", style: withCompanion)?.id, "103_AP021_To_RWH")
        XCTAssertNil(graph.reactionEnter(from: "103_AP021"))
        // Every style exits to every base pose, and each in its own family.
        for style in ReactionStyle.all {
            XCTAssertEqual(graph.reactionExit(to: "101_BP001", style: style)?.id,
                           "101_\(ReactionStyle.nodeID(for: style))_To_BP001")
        }
    }

    // MARK: - Reaction sequences

    func testReactionSequenceIsEnterPoseExitAndBasePoseInOneStyle() throws {
        let graph = mixedGraph
        let doorbell = try XCTUnwrap(graph.assetsByID["101_RPD001"])
        let sequence = graph.reactionSequence(from: "101_BP001", pose: doorbell, to: "101_BP002")
        XCTAssertEqual(sequence?.assets.map(\.id), ["101_BP001_To_RPD", "101_RPD001", "101_RPD_To_BP002", "101_BP002"])
        XCTAssertEqual(sequence?.startPoseID, "101_BP001")
        XCTAssertEqual(sequence?.endPoseID, "101_BP002")

        let alarm = try XCTUnwrap(graph.assetsByID["103_RPH002"])
        XCTAssertEqual(graph.reactionSequence(from: "101_AP001", pose: alarm, to: "101_BP001")?.assets.map(\.id),
                       ["103_AP001_To_RPH", "103_RPH002", "101_RPH_To_BP001", "101_BP001"])

        let companionAlarm = try XCTUnwrap(graph.assetsByID["103_RWH002"])
        XCTAssertEqual(graph.reactionSequence(from: "103_AP021", pose: companionAlarm, to: "101_BP002")?.assets.map(\.id),
                       ["103_AP021_To_RWH", "103_RWH002", "101_RWH_To_BP002", "101_BP002"])
        // Woodstock cannot pop into existence: no companion enter from a BP.
        XCTAssertNil(graph.reactionSequence(from: "101_BP001", pose: companionAlarm, to: "101_BP002"))
        // The target must be a base pose with an exit in the pose's style.
        XCTAssertNil(graph.reactionSequence(from: "101_BP001", pose: doorbell, to: "101_AP001"))
        XCTAssertNil(graph.reactionSequence(from: "101_BP001", pose: doorbell, to: "101_BP009"))
        let basePoseOnly = PlaybackGraph(assets: v1Records + v2Records + [basePose("101_BP003")])
        XCTAssertNil(basePoseOnly.reactionSequence(from: "101_BP001", pose: doorbell, to: "101_BP003"))
        // Only a characterReactionPose can be the middle of the sequence.
        XCTAssertNil(graph.reactionSequence(from: "101_BP001", pose: graph.assetsByID["101_BP002"]!, to: "101_BP002"))
    }

    func testReactionPosesAndHoldsPerStyle() {
        let graph = mixedGraph
        XCTAssertEqual(graph.reactionPoses(style: standard).map(\.id), ["101_RPH_Loop", "103_RPH002", "104_RPH003"])
        XCTAssertEqual(graph.reactionPoses(style: alternate).map(\.id), ["101_RPD001", "101_RPD_Loop"])
        XCTAssertEqual(graph.reactionPoses(style: withCompanion).map(\.id), ["103_RWH002"])
        XCTAssertEqual(graph.reactionPoses(style: standard, trigger: "alarm").map(\.id), ["103_RPH002", "101_RPH_Loop"])
        XCTAssertEqual(graph.reactionPoses(style: standard, trigger: "doorbell").map(\.id), ["101_RPH_Loop"])
        XCTAssertEqual(graph.reactionPoses(style: alternate, trigger: "doorbell").map(\.id), ["101_RPD001", "101_RPD_Loop"])
        XCTAssertEqual(graph.reactionPoses(style: withCompanion, trigger: "doorbell").map(\.id), [])
        XCTAssertEqual(graph.reactionHold(style: standard)?.id, "101_RPH_Loop")
        XCTAssertEqual(graph.reactionHold(style: alternate)?.id, "101_RPD_Loop")
        XCTAssertNil(graph.reactionHold(style: withCompanion))
        XCTAssertTrue(graph.assetsByID["101_RPH_Loop"]!.isReactionHold)
        XCTAssertFalse(graph.assetsByID["101_RPD001"]!.isReactionHold)
        XCTAssertEqual(graph.assetsByID["101_RPD001"]!.reactionTriggers, ["doorbell"])
        XCTAssertEqual(graph.reactionStyle(of: graph.assetsByID["101_RWD001"]!), alternateWithCompanion)
    }

    // MARK: - Scorer

    func testScorerNeedsPendingTriggerAndRanksSpecificAboveGeneric() {
        let scorer = RelevancyScorer()
        let doorbell = reactionPose("101_RPD001", style: alternate, triggers: ["doorbell"])
        let alarm = reactionPose("103_RPH002", style: standard, triggers: ["alarm"])
        let hold = reactionPose("101_RPH_Loop", style: standard, triggers: ["generic"])
        let cloudy = AssetRecord(id: "palette", metadataType: "scenePalette",
                                 relevancyData: .object(["info": .array([
                                     .object(["weather": .object(["condition": .string("cloudy")])]),
                                 ])]))

        // No trigger pending: every tagged reaction pose is fully deboosted.
        let idle = SelectionContext(weatherConditions: ["cloudy"])
        XCTAssertNil(idle.reactionTrigger)
        XCTAssertNil(scorer.relevanceScore(doorbell, context: idle))
        XCTAssertNil(scorer.relevanceScore(alarm, context: idle))
        XCTAssertNil(scorer.relevanceScore(hold, context: idle))
        XCTAssertEqual(scorer.relevanceScore(cloudy, context: idle), 50)

        let ringing = SelectionContext(weatherConditions: ["cloudy"], reactionTrigger: ReactionTrigger.doorbell)
        XCTAssertEqual(scorer.relevanceScore(doorbell, context: ringing), 60)
        XCTAssertEqual(scorer.relevanceScore(hold, context: ringing), 20)
        XCTAssertNil(scorer.relevanceScore(alarm, context: ringing))
        // Other families are not touched by a pending trigger.
        XCTAssertEqual(scorer.relevanceScore(cloudy, context: ringing), 50)

        let alarming = SelectionContext(reactionTrigger: ReactionTrigger.alarm)
        XCTAssertNil(scorer.relevanceScore(doorbell, context: alarming))
        XCTAssertEqual(scorer.relevanceScore(alarm, context: alarming), 60)
        XCTAssertEqual(scorer.relevanceScore(hold, context: alarming), 20)

        let ranked = [hold, doorbell].compactMap { asset in
            scorer.relevanceScore(asset, context: ringing).map { (asset.id, $0) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
        XCTAssertEqual(ranked, ["101_RPD001", "101_RPH_Loop"])
    }

    // MARK: - Model

    func testReactionStyleIDRoundTripsAndDefaultsToNil() throws {
        let pose = reactionPose("101_RPD001", style: alternate, triggers: ["doorbell"])
        let data = try JSONEncoder().encode(pose)
        let decoded = try JSONDecoder().decode(AssetRecord.self, from: data)
        XCTAssertEqual(decoded.reactionStyleID, alternate)
        XCTAssertEqual(decoded.reactionTriggers, ["doorbell"])
        XCTAssertFalse(decoded.isReactionHold)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["reactionStyleID"] as? String, alternate)

        let v1 = try JSONDecoder().decode(AssetRecord.self, from: Data("""
        {"id": "101_BP001_To_RPH", "metadataType": "characterReactionTransitionPose",
         "sprites": [], "phase": {"kind": "enter", "startCharacterPoseID": "101_BP001"}}
        """.utf8))
        XCTAssertNil(v1.reactionStyleID)
        XCTAssertEqual(v1.reactionTriggers, [])
        XCTAssertFalse(v1.isReactionHold)
        XCTAssertEqual(PlaybackGraph(assets: [v1]).reactionStyle(of: v1), ReactionStyle.standard)

        let hold = try JSONDecoder().decode(AssetRecord.self, from: Data("""
        {"id": "101_RPH_Loop", "bundle": "idlechara_defaultV2_v1", "metadataType": "characterReactionPose",
         "sprites": [], "reactionStyleID": "standardReactionTransitionStyleID",
         "relevancyData": {"info": [{"reactionTrigger": {"reactionTrigger": "generic"}}],
                           "dependencies": [], "exclusions": []}}
        """.utf8))
        XCTAssertEqual(hold.reactionStyleID, ReactionStyle.standard)
        XCTAssertEqual(hold.reactionTriggers, ["generic"])
        XCTAssertTrue(hold.isReactionHold)
    }

    func testReactionStyleAndTriggerVocabulary() {
        XCTAssertEqual(ReactionStyle.defaultStyle, ReactionStyle.standard)
        XCTAssertEqual(ReactionStyle.all, [standard, alternate, withCompanion, alternateWithCompanion])
        XCTAssertEqual(Set(ReactionStyle.all).count, 4)
        XCTAssertEqual(ReactionStyle.nodeID(for: standard), "RPH")
        XCTAssertEqual(ReactionStyle.nodeID(for: alternate), "RPD")
        XCTAssertEqual(ReactionStyle.nodeID(for: withCompanion), "RWH")
        XCTAssertEqual(ReactionStyle.nodeID(for: alternateWithCompanion), "RWD")
        XCTAssertEqual(ReactionStyle.nodeID(for: "customStyleID"), "customStyleID")
        XCTAssertFalse(ReactionStyle.isCompanion(standard))
        XCTAssertFalse(ReactionStyle.isCompanion(alternate))
        XCTAssertTrue(ReactionStyle.isCompanion(withCompanion))
        XCTAssertTrue(ReactionStyle.isCompanion(alternateWithCompanion))
        XCTAssertEqual(ReactionTrigger.all, ["doorbell", "alarm", "music", "environment", "presence", "generic"])
        XCTAssertNil(SelectionContext().reactionTrigger)
        XCTAssertEqual(SelectionContext(reactionTrigger: "music").reactionTrigger, "music")
    }
}
