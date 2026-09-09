import Foundation

public enum IndexStoreError: Error, LocalizedError {
    case invalidSchema(Int)
    case missingIndex(URL)
    case invalidAssetPath(String)
    case noPlayableAssets

    public var errorDescription: String? {
        switch self {
        case .invalidSchema(let version): return "Unsupported Snoopy asset-index schema: \(version)"
        case .missingIndex(let url): return "Snoopy asset-index.json not found at \(url.path)"
        case .invalidAssetPath(let path): return "Invalid asset path in index: \(path)"
        case .noPlayableAssets: return "No playable Snoopy assets were found"
        }
    }
}

public struct AssetStore: Sendable {
    public let indexURL: URL
    public let assetsRoot: URL
    public let index: AssetIndex

    public init(indexURL: URL, assetsRootOverride: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { throw IndexStoreError.missingIndex(indexURL) }
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode(AssetIndex.self, from: data)
        guard decoded.schemaVersion == 1 else { throw IndexStoreError.invalidSchema(decoded.schemaVersion) }
        self.indexURL = indexURL
        let bundledAssets = indexURL.deletingLastPathComponent().appendingPathComponent("SnoopyAssets", isDirectory: true)
        if let override = assetsRootOverride {
            self.assetsRoot = override.standardizedFileURL
        } else if Self.isPopulatedDirectory(bundledAssets) {
            // A self-contained .saver keeps the index and all tvOS assets in
            // Contents/Resources. Prefer that portable copy over an absolute
            // source path recorded when the index was generated.
            self.assetsRoot = bundledAssets.standardizedFileURL
        } else if FileManager.default.fileExists(atPath: Self.sharedMediaDirectory.path) {
            // A small host (the wallpaper app) ships without media and reads it
            // from a shared folder the user fills once; see sharedMediaDirectory.
            self.assetsRoot = Self.sharedMediaDirectory
        } else if let relative = decoded.assetRoot, relative != "." {
            if relative.hasPrefix("/") {
                self.assetsRoot = URL(fileURLWithPath: relative).standardizedFileURL
            } else {
                self.assetsRoot = URL(fileURLWithPath: relative, relativeTo: indexURL.deletingLastPathComponent()).standardizedFileURL
            }
        } else if let absolute = decoded.assetsRoot, absolute.hasPrefix("/") {
            self.assetsRoot = URL(fileURLWithPath: absolute)
        } else {
            self.assetsRoot = indexURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        }
        self.index = decoded
    }

    /// The shared media folder a small host (the wallpaper app) reads its
    /// clips from when it ships without them: `~/Library/Application Support/
    /// Snoopy Wallpaper/SnoopyAssets`. A self-contained `.saver` never reaches
    /// here because its bundled `SnoopyAssets` folder wins first.
    public static var sharedMediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Snoopy Wallpaper/SnoopyAssets", isDirectory: true).standardizedFileURL
    }

    /// A directory that exists and holds at least one visible asset bundle.
    public static func isPopulatedDirectory(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return entries.contains { !$0.hasPrefix(".") }
    }

    /// Whether the shared media folder looks like it holds the tvOS asset
    /// bundles (the wallpaper app's first-run check).
    public static var sharedMediaIsPopulated: Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sharedMediaDirectory.path) else { return false }
        return entries.contains { $0.hasPrefix("idlechara_") }
    }

    public func url(for asset: AssetRecord) throws -> URL {
        let relative = asset.assetPath
        guard !relative.contains(".."), !relative.hasPrefix("/") else { throw IndexStoreError.invalidAssetPath(relative) }
        return assetsRoot.appendingPathComponent(relative, isDirectory: true)
    }

    public func playableAssets() -> [AssetRecord] {
        index.assets.filter { asset in
            guard asset.integrity?.valid != false else { return false }
            if let media = asset.media, !media.isEmpty { return true }
            return asset.sprites.contains { sprite in
                if let media = sprite.media, !media.isEmpty { return true }
                return !(sprite.mediaFiles ?? []).isEmpty
            }
        }
    }

    public func activeScenes() -> [AssetRecord] {
        playableAssets().filter { $0.kind == "activeScene" }
    }

    public func eligible(_ assets: [AssetRecord], on date: Date, calendar: Calendar = .current) -> [AssetRecord] {
        let byName = Dictionary(uniqueKeysWithValues: (index.bundles ?? []).map { ($0.name, $0) })
        return assets.filter { asset in
            guard let name = asset.bundle, let bundle = byName[name], let range = bundle.activeDateRange else { return true }
            return Self.contains(date, range: range, calendar: calendar)
        }
    }

    private static func contains(_ date: Date, range: DateRange, calendar: Calendar) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startText = range.startDate, let endText = range.endDate,
              let start = formatter.date(from: startText), let end = formatter.date(from: endText) else { return true }

        // Apple refreshes dated bundles each year. For an offline historical
        // index, repeat the same month/day window so seasonal scenes remain
        // useful instead of expiring permanently.
        let now = calendar.dateComponents([.month, .day], from: date)
        let startMD = calendar.dateComponents([.month, .day], from: start)
        let endMD = calendar.dateComponents([.month, .day], from: end)
        let value = (now.month ?? 1) * 100 + (now.day ?? 1)
        let lower = (startMD.month ?? 1) * 100 + (startMD.day ?? 1)
        let upper = (endMD.month ?? 1) * 100 + (endMD.day ?? 1)
        return lower < upper ? (value >= lower && value < upper) : (value >= lower || value < upper)
    }
}
