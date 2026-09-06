import Foundation

public struct SnoopyWeatherSnapshot: Codable, Sendable, Equatable {
    public let conditions: [String]
    public let observedAt: Date
    public let expiresAt: Date
    public let sunrise: Date?
    public let sunset: Date?
    public let previousDayConditions: [String]
    public let source: String?
    public let locationName: String?

    public init(conditions: [String], observedAt: Date = .now,
                expiresAt: Date = .now.addingTimeInterval(3600), sunrise: Date? = nil,
                sunset: Date? = nil, previousDayConditions: [String] = [],
                source: String? = nil, locationName: String? = nil) {
        self.conditions = conditions
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.sunrise = sunrise
        self.sunset = sunset
        self.previousDayConditions = previousDayConditions
        self.source = source
        self.locationName = locationName
    }

    public var isUsable: Bool { expiresAt > .now.addingTimeInterval(-6 * 3600) }
    public var needsRefresh: Bool { expiresAt <= .now.addingTimeInterval(10 * 60) }
}

public struct SnoopyWeatherLocation: Codable, Sendable, Equatable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let timeZoneIdentifier: String?

    public init(name: String, latitude: Double, longitude: Double, timeZoneIdentifier: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// A non-secret preference suite shared by the configuration sheet, optional
/// future helper app, and saver bundle. Playback reads only the cached weather
/// snapshot; refreshes happen asynchronously and never delay media startup.
public enum SnoopyPreferences {
    public static let suiteName = "com.dingdangnao.snoopy.shared"
    public static let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    public static let assetIndexPathKey = "SnoopyAssetIndexPath"
    public static let cityNameKey = "SnoopyCityName"
    public static let weatherEnabledKey = "SnoopyWeatherEnabled"
    public static let weatherOverrideKey = "SnoopyWeatherOverride"
    public static let weatherSnapshotKey = "SnoopyWeatherSnapshot"
    public static let weatherLocationKey = "SnoopyWeatherLocation"
    public static let selectionMemoryKey = "SnoopySelectionMemory"

    // Host playback settings, shared by the wallpaper app and the saver.
    public static let playbackRateKey = "SnoopyPlaybackRate"
    public static let onBatteryModeKey = "SnoopyOnBatteryMode"
    public static let pauseWhenHiddenKey = "SnoopyPauseWhenHidden"
    public static let wallpaperEnabledKey = "SnoopyWallpaperEnabled"

    /// Playback speed multiplier (1 = authored speed) for one host. Applied to
    /// video rate and the HEIC frame clock by SnoopySceneView; scene budgets
    /// stay in wall time. The legacy shared key is the fallback for both hosts.
    public static func playbackRate(for host: SnoopyPlaybackHost) -> Double {
        let own = defaults.double(forKey: host.playbackRateKey)
        let chosen = own > 0 ? own : defaults.double(forKey: playbackRateKey)
        return chosen > 0 ? clampPlaybackRate(chosen) : 1.0
    }

    public static func setPlaybackRate(_ rate: Double, for host: SnoopyPlaybackHost) {
        defaults.set(clampPlaybackRate(rate), forKey: host.playbackRateKey)
    }

    public static func clampPlaybackRate(_ rate: Double) -> Double {
        min(max(rate, 0.25), 4.0)
    }

    /// The speeds offered by the menus and the Options sheet.
    public static let playbackRateChoices: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public static func playbackRateTitle(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    public static var onBatteryMode: SnoopyOnBatteryMode {
        get { SnoopyOnBatteryMode(rawValue: defaults.integer(forKey: onBatteryModeKey)) ?? .keepPlaying }
        set { defaults.set(newValue.rawValue, forKey: onBatteryModeKey) }
    }

    /// Pause the wallpaper while other windows cover most of the screen.
    public static var pauseWhenHidden: Bool {
        get { defaults.object(forKey: pauseWhenHiddenKey) == nil ? true : defaults.bool(forKey: pauseWhenHiddenKey) }
        set { defaults.set(newValue, forKey: pauseWhenHiddenKey) }
    }

    /// Whether the desktop wallpaper is shown (the menu-bar app's main toggle).
    public static var wallpaperEnabled: Bool {
        get { defaults.object(forKey: wallpaperEnabledKey) == nil ? true : defaults.bool(forKey: wallpaperEnabledKey) }
        set { defaults.set(newValue, forKey: wallpaperEnabledKey) }
    }

    public static var weatherEnabled: Bool {
        get {
            if defaults.object(forKey: weatherEnabledKey) != nil {
                return defaults.bool(forKey: weatherEnabledKey)
            }
            return !(defaults.string(forKey: cityNameKey) ?? "").isEmpty
        }
        set { defaults.set(newValue, forKey: weatherEnabledKey) }
    }

    public static func weatherSnapshot() -> SnoopyWeatherSnapshot? {
        guard let data = defaults.data(forKey: weatherSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(SnoopyWeatherSnapshot.self, from: data)
    }

    public static func save(weatherSnapshot: SnoopyWeatherSnapshot) {
        if let data = try? JSONEncoder().encode(weatherSnapshot) {
            defaults.set(data, forKey: weatherSnapshotKey)
        }
    }

    public static func weatherLocation() -> SnoopyWeatherLocation? {
        guard let data = defaults.data(forKey: weatherLocationKey) else { return nil }
        return try? JSONDecoder().decode(SnoopyWeatherLocation.self, from: data)
    }

    public static func save(weatherLocation: SnoopyWeatherLocation) {
        if let data = try? JSONEncoder().encode(weatherLocation) {
            defaults.set(data, forKey: weatherLocationKey)
        }
        defaults.set(weatherLocation.name, forKey: cityNameKey)
    }
}

/// The two hosts of SnoopySceneView; each keeps its own playback speed.
public enum SnoopyPlaybackHost: String, CaseIterable, Sendable {
    case wallpaper
    case screenSaver

    public var playbackRateKey: String { "SnoopyPlaybackRate.\(rawValue)" }

    public var title: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .screenSaver: return "Screen Saver"
        }
    }
}

/// What the wallpaper does when the Mac runs on battery (mirrors Aerial's
/// keepEnabled / alwaysDisabled / disableOnLow).
public enum SnoopyOnBatteryMode: Int, CaseIterable, Sendable {
    case keepPlaying = 0
    case pause = 1
    case pauseWhenLow = 2

    public var title: String {
        switch self {
        case .keepPlaying: return "Keep playing"
        case .pause: return "Pause"
        case .pauseWhenLow: return "Pause when battery is low"
        }
    }
}
