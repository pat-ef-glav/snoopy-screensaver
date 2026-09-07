import Foundation

public struct AssetIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let assetRoot: String?
    public let assetsRoot: String?
    public let assets: [AssetRecord]
    public let bundles: [BundleRecord]?

    public init(schemaVersion: Int, assetRoot: String?, assetsRoot: String?, assets: [AssetRecord], bundles: [BundleRecord]? = nil) {
        self.schemaVersion = schemaVersion
        self.assetRoot = assetRoot
        self.assetsRoot = assetsRoot
        self.assets = assets
        self.bundles = bundles
    }
}

public struct BundleRecord: Codable, Sendable {
    public let name: String
    public let preferredOrder: Int?
    public let activeDateRange: DateRange?
    public let version: String?

    public init(name: String, preferredOrder: Int? = nil, activeDateRange: DateRange? = nil, version: String? = nil) {
        self.name = name
        self.preferredOrder = preferredOrder
        self.activeDateRange = activeDateRange
        self.version = version
    }
}

public struct DateRange: Codable, Sendable {
    public let startDate: String?
    public let endDate: String?

    public init(startDate: String? = nil, endDate: String? = nil) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct AssetRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let bundle: String?
    public let relativePath: String?
    public let path: String?
    public let metadataType: String?
    public let type: String?
    public let status: JSONValue?
    public let relevancyData: JSONValue?
    public let sprites: [SpriteRecord]
    public let media: [MediaRecord]?
    public let integrity: IntegrityRecord?
    public let startCharacterBasePoseID: String?
    public let endCharacterBasePoseID: String?
    public let phase: TransitionPhaseRecord?
    public let transitionPhase: String?
    public let transitionCategoryIDs: [String]?
    public let transitionPair: TransitionPairRecord?
    public let transitionCategory: TransitionCategoryRecord?
    public let scenePalette: ScenePaletteRecord?
    public let parentIdleSceneIDs: [String]?
    public let idleScene: IdleSceneRecord?
    public let visitor: VisitorRecord?
    /// `reactionStyleID` of the V2 `characterReactionPose` and
    /// `characterReactionTransitionPose` records (see `ReactionStyle`). V1
    /// reaction transitions carry none and belong to the standard style.
    public let reactionStyleID: String?

    public init(id: String, bundle: String? = nil, relativePath: String? = nil, path: String? = nil,
                metadataType: String? = nil, type: String? = nil, status: JSONValue? = nil,
                relevancyData: JSONValue? = nil, sprites: [SpriteRecord] = [], media: [MediaRecord]? = nil,
                integrity: IntegrityRecord? = nil, startCharacterBasePoseID: String? = nil,
                endCharacterBasePoseID: String? = nil, phase: TransitionPhaseRecord? = nil,
                transitionPhase: String? = nil, transitionCategoryIDs: [String]? = nil,
                transitionPair: TransitionPairRecord? = nil, transitionCategory: TransitionCategoryRecord? = nil,
                scenePalette: ScenePaletteRecord? = nil, parentIdleSceneIDs: [String]? = nil,
                idleScene: IdleSceneRecord? = nil, visitor: VisitorRecord? = nil,
                reactionStyleID: String? = nil) {
        self.id = id
        self.bundle = bundle
        self.relativePath = relativePath
        self.path = path
        self.metadataType = metadataType
        self.type = type
        self.status = status
        self.relevancyData = relevancyData
        self.sprites = sprites
        self.media = media
        self.integrity = integrity
        self.startCharacterBasePoseID = startCharacterBasePoseID
        self.endCharacterBasePoseID = endCharacterBasePoseID
        self.phase = phase
        self.transitionPhase = transitionPhase
        self.transitionCategoryIDs = transitionCategoryIDs
        self.transitionPair = transitionPair
        self.transitionCategory = transitionCategory
        self.scenePalette = scenePalette
        self.parentIdleSceneIDs = parentIdleSceneIDs
        self.idleScene = idleScene
        self.visitor = visitor
        self.reactionStyleID = reactionStyleID
    }

    public var assetPath: String { relativePath ?? path ?? id }
    public var kind: String { metadataType ?? type ?? "unknown" }
    public var hasConditions: Bool {
        guard let info = relevancyData?.objectValue?["info"] else { return false }
        if case .array(let values) = info { return !values.isEmpty }
        return false
    }

    /// The trigger tokens authored on a `characterReactionPose`
    /// (`relevancyData.info[].reactionTrigger.reactionTrigger`), in authored order.
    public var reactionTriggers: [String] {
        guard let info = relevancyData?.objectValue?["info"], case .array(let entries) = info else { return [] }
        return entries.flatMap { entry -> [String] in
            guard let clause = entry.objectValue?["reactionTrigger"] else { return [] }
            return Self.triggerTokens(in: clause.objectValue?["reactionTrigger"] ?? clause)
        }
    }

    /// The generic `_Loop` hold of a style: a short stay in the reaction pose
    /// that "may generically apply" to any trigger.
    public var isReactionHold: Bool {
        kind == "characterReactionPose" && reactionTriggers == [ReactionTrigger.generic]
    }

    private static func triggerTokens(in value: JSONValue) -> [String] {
        switch value {
        case .string(let token): return [token]
        case .array(let values): return values.flatMap(triggerTokens(in:))
        case .object(let object): return object.keys.sorted()
        default: return []
        }
    }
}

/// The four `reactionStyleID` values of the V2 reaction clips. A style is a
/// closed family: the enter, the reaction pose and the exit all carry the same
/// id. V1 records carry no id and belong to the standard style
/// (`CharacterReactionPoseDefaultStyleID` in IdleCharacterCore).
public enum ReactionStyle {
    /// RPH: Snoopy seated, facing the viewer (the V1 reaction pose).
    public static let standard = "standardReactionTransitionStyleID"
    /// RPD: Snoopy seated in profile, facing right.
    public static let alternate = "alternateReactionTransitionStyleID"
    /// RWH: as RPH, with Woodstock present during the reaction.
    public static let standardWithCompanion = "standardWithCompanionReactionTransitionStyleID"
    /// RWD: as RPD, with Woodstock present during the reaction.
    public static let alternateWithCompanion = "alternateWithCompanionReactionTransitionStyleID"

    public static let defaultStyle = standard
    public static let all: [String] = [standard, alternate, standardWithCompanion, alternateWithCompanion]

    public static func isCompanion(_ style: String) -> Bool {
        style == standardWithCompanion || style == alternateWithCompanion
    }

    /// The filename code of a style, used as the graph node between an enter
    /// and an exit (`101_BP001_To_RPH` -> `RPH` -> `101_RPH_To_BP002`).
    public static func nodeID(for style: String) -> String {
        switch style {
        case standard: return "RPH"
        case alternate: return "RPD"
        case standardWithCompanion: return "RWH"
        case alternateWithCompanion: return "RWD"
        default: return style
        }
    }
}

/// The `reactionTrigger` tokens of `characterReactionPose.relevancyData.info`.
public enum ReactionTrigger {
    public static let doorbell = "doorbell"
    public static let alarm = "alarm"
    public static let music = "music"
    public static let environment = "environment"
    public static let presence = "presence"
    /// A pose that "may generically apply" to any trigger (the `_Loop` holds).
    public static let generic = "generic"

    public static let all: [String] = [doorbell, alarm, music, environment, presence, generic]
}

public struct SpriteRecord: Codable, Sendable {
    public let metadataPath: String?
    public let contentPath: String?
    public let spriteType: String?
    public let assetBaseName: String?
    public let assetSize: [Int]?
    public let frameIndexDigitCount: Int?
    public let mediaFiles: [String]?
    public let media: [MediaRecord]?
    public let endBehavior: String?
    public let customTiming: JSONValue?
    public let placement: JSONValue?
    public let plane: String?
    public let phase: String?

    public init(metadataPath: String? = nil, contentPath: String? = nil, spriteType: String? = nil, assetBaseName: String? = nil,
                assetSize: [Int]? = nil, frameIndexDigitCount: Int? = nil, mediaFiles: [String]? = nil, media: [MediaRecord]? = nil,
                endBehavior: String? = nil, customTiming: JSONValue? = nil, placement: JSONValue? = nil, plane: String? = nil,
                phase: String? = nil) {
        self.metadataPath = metadataPath
        self.contentPath = contentPath
        self.spriteType = spriteType
        self.assetBaseName = assetBaseName
        self.assetSize = assetSize
        self.frameIndexDigitCount = frameIndexDigitCount
        self.mediaFiles = mediaFiles
        self.media = media
        self.endBehavior = endBehavior
        self.customTiming = customTiming
        self.placement = placement
        self.plane = plane
        self.phase = phase
    }
}

public struct TransitionPhaseRecord: Codable, Sendable, Equatable {
    public let kind: String?
    public let startCharacterPoseID: String?
    public let endCharacterPoseID: String?

    public init(kind: String? = nil, startCharacterPoseID: String? = nil, endCharacterPoseID: String? = nil) {
        self.kind = kind
        self.startCharacterPoseID = startCharacterPoseID
        self.endCharacterPoseID = endCharacterPoseID
    }
}

public struct TransitionPairRecord: Codable, Sendable, Equatable {
    public let hideParametersID: String?
    public let revealParametersID: String?

    public init(hideParametersID: String? = nil, revealParametersID: String? = nil) {
        self.hideParametersID = hideParametersID
        self.revealParametersID = revealParametersID
    }
}

public struct TransitionCategoryRecord: Codable, Sendable, Equatable {
    public let hideCharacterPoseIDs: [String]
    public let revealCharacterPoseIDs: [String]
    public let sceneTransitionPairIDs: [String]
    public let preventsIdleSceneChange: Bool

    public init(hideCharacterPoseIDs: [String] = [], revealCharacterPoseIDs: [String] = [],
                sceneTransitionPairIDs: [String] = [], preventsIdleSceneChange: Bool = false) {
        self.hideCharacterPoseIDs = hideCharacterPoseIDs
        self.revealCharacterPoseIDs = revealCharacterPoseIDs
        self.sceneTransitionPairIDs = sceneTransitionPairIDs
        self.preventsIdleSceneChange = preventsIdleSceneChange
    }
}

public struct ColorRecord: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct ScenePaletteRecord: Codable, Sendable, Equatable {
    public let backgroundColor: ColorRecord?
    public let overlayColor: ColorRecord?
    public let parentIdleSceneIDs: [String]?

    public init(backgroundColor: ColorRecord? = nil, overlayColor: ColorRecord? = nil,
                parentIdleSceneIDs: [String]? = nil) {
        self.backgroundColor = backgroundColor
        self.overlayColor = overlayColor
        self.parentIdleSceneIDs = parentIdleSceneIDs
    }
}

public struct PointRecord: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct IdleSceneExclusionsRecord: Codable, Sendable, Equatable {
    public let excludedCharacterAdditionalPoses: [String]
    public let excludedCharacterMoments: [String]
    public let excludedPalettes: [String]
    public let excludedVisitors: [String]

    public init(excludedCharacterAdditionalPoses: [String] = [], excludedCharacterMoments: [String] = [],
                excludedPalettes: [String] = [], excludedVisitors: [String] = []) {
        self.excludedCharacterAdditionalPoses = excludedCharacterAdditionalPoses
        self.excludedCharacterMoments = excludedCharacterMoments
        self.excludedPalettes = excludedPalettes
        self.excludedVisitors = excludedVisitors
    }
}

public struct IdleSceneRecord: Codable, Sendable, Equatable {
    public let sceneOffset: PointRecord?
    public let exclusions: IdleSceneExclusionsRecord?

    public init(sceneOffset: PointRecord? = nil, exclusions: IdleSceneExclusionsRecord? = nil) {
        self.sceneOffset = sceneOffset
        self.exclusions = exclusions
    }
}

public struct VisitorRecord: Codable, Sendable, Equatable {
    public let ignoresSceneOffset: Bool
    public let isFullscreenEffect: Bool

    public init(ignoresSceneOffset: Bool = false, isFullscreenEffect: Bool = false) {
        self.ignoresSceneOffset = ignoresSceneOffset
        self.isFullscreenEffect = isFullscreenEffect
    }
}

public struct MediaRecord: Codable, Sendable {
    public let name: String?
    public let relativePath: String?
    public let suffix: String?
    public let bytes: Int?
    /// Encoded container duration and the last visually-changing timestamp.
    /// Fetcher-generated indexes may omit these for non-video media.
    public let durationSeconds: Double?
    public let effectiveEndSeconds: Double?

    public init(name: String? = nil, relativePath: String? = nil, suffix: String? = nil, bytes: Int? = nil,
                durationSeconds: Double? = nil, effectiveEndSeconds: Double? = nil) {
        self.name = name
        self.relativePath = relativePath
        self.suffix = suffix
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.effectiveEndSeconds = effectiveEndSeconds
    }
}

public struct IntegrityRecord: Codable, Sendable {
    public let valid: Bool?
    public let metadata: JSONValue?
    public let version: JSONValue?
    public let status: JSONValue?
    public let missingMedia: [String]?
    public let missingSpriteMedia: [String]?

    public init(valid: Bool? = nil, metadata: JSONValue? = nil, version: JSONValue? = nil, status: JSONValue? = nil,
                missingMedia: [String]? = nil, missingSpriteMedia: [String]? = nil) {
        self.valid = valid
        self.metadata = metadata
        self.version = version
        self.status = status
        self.missingMedia = missingMedia
        self.missingSpriteMedia = missingSpriteMedia
    }
}

public struct SelectionContext: Sendable, Equatable {
    public var date: Date
    public var calendarIdentifier: Calendar.Identifier
    public var timeOfDay: String?
    public var routine: String?
    /// Extra routine states that may overlap the ordinary day-part routine.
    /// For example, `morning` remains active while school/work commute states
    /// are added as occasional-insert conditions in their authored windows.
    public var routineConditions: Set<String>
    public var weatherConditions: Set<String>
    public var calendarEvents: Set<String>
    public var hourlyEvents: Set<String>
    public var moonPhases: Set<String>
    public var fulfilledDependencies: Set<String>
    public var excludedValues: Set<String>
    /// Runtime categories currently installed by another selected asset.
    /// IdleCharacter uses this to couple weather/full-screen visitors with
    /// character actions whose relevancy metadata depends on, or excludes,
    /// `sceneFullscreenEffectVisitor`.
    public var activeCategories: Set<String>
    /// The pending reaction trigger (`ReactionTrigger`), if one is fresh.
    /// tvOS keeps a `reactionTriggerEvent` that expires; while it is nil
    /// every tagged `characterReactionPose` is ineligible.
    public var reactionTrigger: String?

    public init(date: Date = .now, calendarIdentifier: Calendar.Identifier = .gregorian, timeOfDay: String? = nil,
                routine: String? = nil, routineConditions: Set<String> = [],
                weatherConditions: Set<String> = [], calendarEvents: Set<String> = [],
                hourlyEvents: Set<String> = [], moonPhases: Set<String> = [], fulfilledDependencies: Set<String> = [],
                excludedValues: Set<String> = [], activeCategories: Set<String> = [],
                reactionTrigger: String? = nil) {
        self.date = date
        self.calendarIdentifier = calendarIdentifier
        self.timeOfDay = timeOfDay
        self.routine = routine
        self.routineConditions = routineConditions
        self.weatherConditions = weatherConditions
        self.calendarEvents = calendarEvents
        self.hourlyEvents = hourlyEvents
        self.moonPhases = moonPhases
        self.fulfilledDependencies = fulfilledDependencies
        self.excludedValues = excludedValues
        self.activeCategories = activeCategories
        self.reactionTrigger = reactionTrigger
    }
}

public struct SelectionMemory: Codable, Sendable {
    public var lastSelectedID: String?
    public var recentIDs: [String]
    public var playCounts: [String: Int]
    public var lastSelectedIDByPool: [String: String]
    public var recentIDsByPool: [String: [String]]
    public var playCountsByPool: [String: [String: Int]]

    public init(
        lastSelectedID: String? = nil,
        recentIDs: [String] = [],
        playCounts: [String: Int] = [:],
        lastSelectedIDByPool: [String: String] = [:],
        recentIDsByPool: [String: [String]] = [:],
        playCountsByPool: [String: [String: Int]] = [:]
    ) {
        self.lastSelectedID = lastSelectedID
        self.recentIDs = recentIDs
        self.playCounts = playCounts
        self.lastSelectedIDByPool = lastSelectedIDByPool
        self.recentIDsByPool = recentIDsByPool
        self.playCountsByPool = playCountsByPool
    }

    public func recentIDs(in pool: String, limit: Int = 5) -> [String] {
        Array(recentIDsByPool[pool, default: []].prefix(max(0, limit)))
    }

    public func lastSelectedID(in pool: String) -> String? {
        lastSelectedIDByPool[pool]
    }

    public func playCount(for id: String, in pool: String) -> Int {
        playCountsByPool[pool]?[id] ?? 0
    }

    public mutating func record(_ id: String, in pool: String, recentLimit: Int = 5) {
        lastSelectedID = id
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        recentIDs = Array(recentIDs.prefix(20))
        playCounts[id, default: 0] += 1

        lastSelectedIDByPool[pool] = id
        var poolRecent = recentIDsByPool[pool, default: []]
        poolRecent.removeAll { $0 == id }
        poolRecent.insert(id, at: 0)
        recentIDsByPool[pool] = Array(poolRecent.prefix(max(1, recentLimit)))
        playCountsByPool[pool, default: [:]][id, default: 0] += 1
    }

    private enum CodingKeys: String, CodingKey {
        case lastSelectedID, recentIDs, playCounts
        case lastSelectedIDByPool, recentIDsByPool, playCountsByPool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSelectedID = try container.decodeIfPresent(String.self, forKey: .lastSelectedID)
        recentIDs = try container.decodeIfPresent([String].self, forKey: .recentIDs) ?? []
        playCounts = try container.decodeIfPresent([String: Int].self, forKey: .playCounts) ?? [:]
        lastSelectedIDByPool = try container.decodeIfPresent(
            [String: String].self, forKey: .lastSelectedIDByPool
        ) ?? [:]
        recentIDsByPool = try container.decodeIfPresent(
            [String: [String]].self, forKey: .recentIDsByPool
        ) ?? [:]
        playCountsByPool = try container.decodeIfPresent(
            [String: [String: Int]].self, forKey: .playCountsByPool
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastSelectedID, forKey: .lastSelectedID)
        try container.encode(recentIDs, forKey: .recentIDs)
        try container.encode(playCounts, forKey: .playCounts)
        try container.encode(lastSelectedIDByPool, forKey: .lastSelectedIDByPool)
        try container.encode(recentIDsByPool, forKey: .recentIDsByPool)
        try container.encode(playCountsByPool, forKey: .playCountsByPool)
    }
}
