import AVFoundation
import Cocoa
import CoreVideo
import ImageIO
#if canImport(SnoopyTVCore)
import SnoopyTVCore // Swift package build; the Xcode target compiles the core sources directly
#endif

/// Offline Apple TV-style Snoopy playback engine. Full-screen active-scene
/// videos and metadata-driven HEIC composites share one randomized playback
/// queue. This view is the compositor, hostable by any window: the `.saver`
/// shell (ScreenSaver/SnoopySaverView.swift) drives it with
/// `start()`/`tick()`/`stop()` from the ScreenSaver lifecycle; the desktop
/// wallpaper app (Sources/SnoopyWallpaper) embeds it in a desktop-level window
/// and lets it run its own clock via `startClock()`.
public final class SnoopySceneView: NSView {
    /// Repository root when running from a source checkout (this file lives at
    /// Sources/SnoopySceneKit/), so a bare `swift run` can find Resources/.
    private static let sourceTreeRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SnoopySceneView.swift
        .deletingLastPathComponent() // SnoopySceneKit
        .deletingLastPathComponent() // Sources

    private enum PlaybackKind { case video, composite }
    private enum TransitionStage: String { case hide, reveal }
    private enum PendingSceneStage {
        case activeScene(AssetRecord)
        case activeSceneWithReveal(AssetRecord, SceneTransitionSelection)
        case transition(TransitionStage, SceneTransitionSelection)
    }

    private var store: AssetStore?
    private var derivedMediaStore: DerivedMediaStore?
    private var playbackGraph: PlaybackGraph?
    private var sessionState = PlaybackSessionState()
    private var pendingBasePoseID: String?
    private var pendingCharacterAssetIDs: [String] = []
    private var pendingIdleEntrySequence: CharacterPlaybackSequence?
    private var pendingSceneStages: [PendingSceneStage] = []
    private var currentPaletteAssetID: String?
    private var currentSceneOffset: PointRecord?
    private var lastRevealTransitionPoseID: String?
    private var consecutiveTransitionsPreventingIdleSceneChange = 0
    private var idleSceneStartedAt: TimeInterval?
    private var idleSceneTargetDuration: TimeInterval = 240
    private var idleSceneAnimationCount = 0
    private var idleSceneTargetAnimationCount = Int.max
    private var visitorScheduleTimes: [TimeInterval] = []
    private var nextVisitorScheduleIndex = 0
    private var idleSceneChangeRequested = false
    private var hasPlayedInitialActiveScene = false
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerReadyObservation: NSKeyValueObservation?
    private var activeVideoPlaceholderLayer: CALayer?
    private var activeVideoAssetID: String?
    private var compositeVideoLayer: AVPlayerLayer?
    private var compositeVideoHostView: NSView?
    private var retiringCompositePlayer: AVPlayer?
    private var retiringCompositeHostView: NSView?
    private var retiringFrameView: NSImageView?
    private var compositeVideoPlaceholderLayer: CALayer?
    private var compositeVideoReadyObservation: NSKeyValueObservation?
    private var compositeItemStatusObservation: NSKeyValueObservation?
    private var compositePrerollTimeout: DispatchWorkItem?
    private var compositePlaybackGeneration: UInt64 = 0
    private var compositeDrawablePoll: (() -> Void)?
    private var visitorPlayer: AVQueuePlayer?
    private var visitorLayer: AVPlayerLayer?
    private var visitorPlaceholderLayer: CALayer?
    private var visitorReadyObservation: NSKeyValueObservation?
    private var visitorHostView: NSView?
    private var visitorSprite: SpriteRecord?
    private var visitorIgnoresSceneOffset = false
    private var visitorIsFullscreenEffect = false
    private var visitorEndObserver: NSObjectProtocol?
    private var transitionPlayers: [AVPlayer] = []
    private var transitionLayers: [CALayer] = []
    private var transitionEndObserver: NSObjectProtocol?
    private var transitionHostView: NSView?
    private var retiringTransitionPlayers: [AVPlayer] = []
    private var retiringTransitionHostView: NSView?
    private var holdingCompletedIdleEntrySurface = false
    private var transitionPrerollTimeout: DispatchWorkItem?
    private var transitionPlaybackGeneration: UInt64 = 0
    private var transitionItemStatusObservations: [NSKeyValueObservation] = []
    private var transitionDrawablePoll: (() -> Void)?
    private var idleExitTransitionInProgress = false
    private var idleEntryRequestedWhileExiting = false
    private var holdingActiveFrameForIdleEntry = false
    private var playerEndObserver: NSObjectProtocol?
    private var playerFailureObserver: NSObjectProtocol?
    private var playerStallObserver: NSObjectProtocol?
    private var playerBoundaryObserver: Any?
    private var watchdogWorkItem: DispatchWorkItem?
    private var advanceWorkItem: DispatchWorkItem?
    private var frameDisplayLink: CVDisplayLink?
    private var frameSequenceURLs: [URL] = []
    private var frameSequenceIndex = 0
    private var frameSequenceGeneration: UInt64 = 0
    private var frameSequenceLastHostTime: UInt64 = 0
    private var frameSequenceMaxPixelSize = 0
    private var frameSequenceVisitorControlsCompletion = false
    private var frameSequenceDecodeMisses = 0
    private var frameDrawablePoll: (() -> Void)?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var backgroundColorView: NSView?
    private var halftoneView: NSImageView?
    private var backgroundImageView: NSImageView?
    private var backgroundVideoHostView: NSView?
    private var backgroundVideoLayer: AVPlayerLayer?
    private var backgroundVideoPlayer: AVQueuePlayer?
    private var backgroundVideoLooper: AVPlayerLooper?
    private var backgroundVideoReadyObservation: NSKeyValueObservation?
    private var backgroundVideoPlaceholderLayer: CALayer?
    private var overlayView: NSView?
    private var frameView: NSImageView?
    private var backgroundSprite: SpriteRecord?
    private var foregroundSprite: SpriteRecord?
    private var frameGeneration: UInt64 = 0
    private let frameDecodeLock = NSLock()
    private var pendingFrameKeys = Set<String>()
    private let decodedFrameCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 8
        return cache
    }()
    private let frameDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.dingdangnao.snoopy.frame-decode"
        queue.qualityOfService = .userInitiated
        // One decoder is fast enough to stay ahead of 24 fps and avoids the
        // large CPU spikes caused by two HEIC decoders racing at startup.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var memory = SelectionMemory()
    private var seed = UInt64.random(in: UInt64.min...UInt64.max)
    private var isPlaying = false
    private var isStopping = true
    private var currentAssetID: String?
    private var startupFadeView: NSView?
    private var startupFadeHasBegun = false
    private var weatherRefreshTask: Task<Void, Never>?

    // MARK: - Reactions (docs/REACTION_POSES.md §5)

    /// A fired reaction trigger, like tvOS's `reactionTriggerEvent`. Equality
    /// includes `firedAt`, so firing the same token twice makes two events
    /// (a doorbell can ring twice) while one event is never replayed.
    private struct ReactionTriggerEvent: Equatable {
        let trigger: String
        var firedAt: TimeInterval
        /// "host" | "env" | "interval" (log only).
        let source: String
    }
    private var pendingReactionTrigger: ReactionTriggerEvent?
    private var lastHandledReactionTrigger: ReactionTriggerEvent?
    /// tvOS `defaultReactionTriggerTimeout`.
    private static let reactionTriggerTimeout: TimeInterval = 30
    /// `SNOOPY_REACTION_TRIGGER`: fired once, at the first character boundary
    /// of an idle scene after one animation has played there.
    private var startupReactionTrigger: String?
    /// `SNOOPY_REACTION_INTERVAL_SECONDS`.
    private var reactionIntervalTimer: Timer?

    /// The character holds in a reaction pose (RPH) instead of resting in a
    /// base pose: the scene transition that consumes it starts from that node
    /// and skips `idleExitSequence`.
    private struct ParkedCharacter {
        let style: String
        /// The BP an exit returns to when no scene transition consumes the park.
        let returnPoseID: String
        /// Parked because the idle scene is due to rotate.
        let forRotation: Bool
    }
    private var parkedCharacter: ParkedCharacter?
    /// Set by the hold-boundary observer right before `finishCurrentPlayback`
    /// and consumed by `cleanCurrentPlayback`: the composite player is moved
    /// to `retiringCompositePlayer` without `pause()`, so the hold keeps
    /// animating while the next stage prerolls.
    private var retiringSurfaceKeepsPlaying = false
    /// Hold repeats cover the transition preroll timeout (4 s) plus one retry.
    private static let reactionHoldSeconds: TimeInterval = 8.5

    public override init(frame: NSRect) {
        super.init(frame: frame)
        configureView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    deinit {
        // A host that releases the view without stop() must not leave a
        // repeating timer on the main run loop for the life of the process.
        reactionIntervalTimer?.invalidate()
        hostClock?.invalidate()
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        installMemoryPressureHandler()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        loadSelectionMemory()
        loadStore()
    }

    private func installStartupFade() {
        startupFadeView?.removeFromSuperview()
        startupFadeHasBegun = false
        let fade = NSView(frame: bounds)
        fade.autoresizingMask = [.width, .height]
        fade.wantsLayer = true
        fade.layer?.backgroundColor = NSColor.black.cgColor
        fade.layer?.zPosition = 10_000
        fade.alphaValue = 1
        addSubview(fade, positioned: .above, relativeTo: nil)
        startupFadeView = fade
    }

    private func revealStartupFadeIfNeeded() {
        guard !startupFadeHasBegun, let fade = startupFadeView else { return }
        startupFadeHasBegun = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.animator().alphaValue = 0
        } completionHandler: { [weak self, weak fade] in
            DispatchQueue.main.async {
                guard let self, let fade, self.startupFadeView === fade else { return }
                fade.removeFromSuperview()
                self.startupFadeView = nil
            }
        }
    }

    public func start() {
        isStopping = false
        resetPauseState()
        previousIdleSceneID = nil
        forcedNextIdleSceneID = nil
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        stallRecoveryAttempted = false
        seed = UInt64.random(in: UInt64.min...UInt64.max)
        sessionState = PlaybackSessionState()
        pendingBasePoseID = nil
        pendingCharacterAssetIDs.removeAll()
        pendingIdleEntrySequence = nil
        pendingSceneStages.removeAll()
        currentPaletteAssetID = nil
        currentSceneOffset = nil
        lastRevealTransitionPoseID = nil
        consecutiveTransitionsPreventingIdleSceneChange = 0
        idleSceneStartedAt = nil
        idleSceneAnimationCount = 0
        visitorScheduleTimes.removeAll()
        nextVisitorScheduleIndex = 0
        idleSceneChangeRequested = false
        hasPlayedInitialActiveScene = false
        pendingReactionTrigger = nil
        lastHandledReactionTrigger = nil
        parkedCharacter = nil
        retiringSurfaceKeepsPlaying = false
        installStartupFade()
        configureReactionEnvironment()
        // Start identically in Preview and full-screen mode. The first media
        // tree installs synchronously and its decoded first-frame placeholder
        // remains visible during AVPlayer preroll; no poster/cover interstitial.
        refreshWeatherIfNeeded()
        playNext()
    }

    public func stop() {
        isStopping = true
        resetPauseState()
        startupFadeView?.removeFromSuperview()
        startupFadeView = nil
        startupFadeHasBegun = false
        weatherRefreshTask?.cancel()
        weatherRefreshTask = nil
        reactionIntervalTimer?.invalidate()
        reactionIntervalTimer = nil
        // Nothing may report a stale trigger or park to a host after stop().
        startupReactionTrigger = nil
        pendingReactionTrigger = nil
        lastHandledReactionTrigger = nil
        parkedCharacter = nil
        cancelPendingAdvance()
        cleanCurrentPlayback()
        NSLog("SnoopyTVScreenSaver: stopped")
    }

    public override func draw(_ rect: NSRect) {
        (layer?.backgroundColor.map(NSColor.init(cgColor:)) ?? NSColor.black)?.setFill()
        rect.fill()
    }

    public func tick() {
        if !isStopping, !isPaused, !isPlaying, advanceWorkItem == nil {
            scheduleNext(after: 0.05)
        }
        recoverFromStallIfNeeded()
    }

    /// Progress is a displayed HEIC frame, a player that is actually playing,
    /// or a scheduled advance/watchdog/preroll timeout. Without any of those
    /// the clip can never end on its own: first re-create the display link (it
    /// can go silent after a display sleeps), then move on to the next clip.
    private func recoverFromStallIfNeeded() {
        guard isPlaying, !isPaused, !isStopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if allPlayers.contains(where: { $0.timeControlStatus == .playing }) {
            lastProgressAt = now
            stallRecoveryAttempted = false
            return
        }
        let stalledFor = now - lastProgressAt
        if frameDisplayLink != nil, stalledFor > 3, !stallRecoveryAttempted {
            stallRecoveryAttempted = true
            lastProgressAt = now
            NSLog("SnoopyTVScreenSaver: no HEIC frame for %.1fs; recreating the display link", stalledFor)
            recreateFrameDisplayLink()
            return
        }
        guard advanceWorkItem == nil, watchdogWorkItem == nil,
              transitionPrerollTimeout == nil, compositePrerollTimeout == nil,
              stalledFor > 10 else { return }
        NSLog("SnoopyTVScreenSaver: no playback progress for %.1fs; advancing", stalledFor)
        stallRecoveryAttempted = false
        finishCurrentPlayback("stalled")
    }

    private func loadStore() {
        let defaults = SnoopyPreferences.defaults
        let configuredPath = defaults.string(forKey: SnoopyPreferences.assetIndexPathKey)
        // The published saver is self-contained and no longer has a settings
        // UI. Prefer its bundled index so a stale path saved by an older build
        // cannot leave the screen black after the source tree is moved.
        let compatibleConfiguredPath = configuredPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? $0 : nil
        }
        let path = defaultIndexURL()?.path ?? compatibleConfiguredPath
        guard let path else {
            NSLog("SnoopyTVScreenSaver: asset-index.json not found")
            return
        }
        do {
            store = try AssetStore(indexURL: URL(fileURLWithPath: path))
            playbackGraph = store.map { PlaybackGraph(assets: $0.index.assets) }
            let bundledDerived = Bundle(for: Self.self).resourceURL?.appendingPathComponent("DerivedMedia", isDirectory: true)
            let sourceDerived = Self.sourceTreeRoot
                .appendingPathComponent(".derived-media", isDirectory: true)
            if ProcessInfo.processInfo.environment["SNOOPY_DISABLE_DERIVED_MEDIA"] == "1" {
                derivedMediaStore = nil
            } else {
                derivedMediaStore = [bundledDerived, sourceDerived].compactMap { $0 }
                    .lazy.compactMap(DerivedMediaStore.init(root:)).first
            }
            NSLog("SnoopyTVScreenSaver: derived proxies=%ld", derivedMediaStore?.index.proxies.count ?? 0)
            if configuredPath != nil, compatibleConfiguredPath == nil {
                defaults.removeObject(forKey: SnoopyPreferences.assetIndexPathKey)
            }
        } catch {
            NSLog("SnoopyTVScreenSaver: %@", error.localizedDescription)
        }
    }

    private func defaultIndexURL() -> URL? {
        // Development only: play from another index (for example the V1-only
        // index at HEAD) without swapping the bundled file. Media resolves as
        // usual, from a `SnoopyAssets` folder next to that index.
        if let override = ProcessInfo.processInfo.environment["SNOOPY_ASSET_INDEX_PATH"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundleIndex = Bundle(for: Self.self).url(forResource: "asset-index", withExtension: "json")
        let sourceIndex = Self.sourceTreeRoot
            .appendingPathComponent("Resources/asset-index.json")
        return [bundleIndex, sourceIndex].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func halftoneImageURL() -> URL? {
        let bundled = Bundle(for: Self.self).url(forResource: "halftone_pattern", withExtension: "png")
        let source = Self.sourceTreeRoot
            .appendingPathComponent("Resources/halftone_pattern.png")
        return [bundled, source].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func scheduleNext(after delay: TimeInterval) {
        guard !isStopping else { return }
        advanceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.advanceWorkItem = nil
            if self.isPaused {
                // Advance as soon as the host resumes instead of while frozen.
                self.deferredWhilePaused.append { [weak self] in self?.scheduleNext(after: 0) }
                return
            }
            self.playNext()
        }
        advanceWorkItem = work
        advanceDeadline = ProcessInfo.processInfo.systemUptime + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingAdvance() {
        advanceWorkItem?.cancel()
        advanceWorkItem = nil
    }

    private func finishCurrentPlayback(_ reason: String) {
        guard isPlaying, !isStopping else { return }
        NSLog("SnoopyTVScreenSaver: finish %@ (%@)", currentAssetID ?? "unknown", reason)
        if let pendingBasePoseID { sessionState.currentBasePoseID = pendingBasePoseID }
        pendingBasePoseID = nil
        let shouldHoldActiveFrame: Bool
        if playerLayer != nil, let next = pendingSceneStages.first,
           case .transition(.hide, _) = next {
            shouldHoldActiveFrame = true
        } else {
            shouldHoldActiveFrame = false
        }
        holdingActiveFrameForIdleEntry = shouldHoldActiveFrame
        // Keep the outgoing layer tree alive until playNext installs the
        // incoming tree in the same Core Animation transaction. The previous
        // 120 ms remove-then-wait sequence exposed the root black layer.
        isPlaying = false
        scheduleNext(after: 0)
    }

    private func cleanCurrentPlayback(
        preservingActiveVideo: Bool = false,
        preservingIdleComposite: Bool = false
    ) {
        isPlaying = false
        currentAssetID = nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        stopFrameDisplayLink()
        frameDrawablePoll = nil
        frameGeneration &+= 1
        frameDecodeQueue.cancelAllOperations()
        frameDecodeLock.lock()
        pendingFrameKeys.removeAll()
        frameDecodeLock.unlock()
        if let observer = playerEndObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = playerFailureObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = playerStallObserver { NotificationCenter.default.removeObserver(observer) }
        if !preservingIdleComposite, let observer = visitorEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = transitionEndObserver { NotificationCenter.default.removeObserver(observer) }
        playerEndObserver = nil
        playerFailureObserver = nil
        playerStallObserver = nil
        if !preservingIdleComposite { visitorEndObserver = nil }
        transitionEndObserver = nil
        transitionPrerollTimeout?.cancel()
        transitionPrerollTimeout = nil
        transitionItemStatusObservations.removeAll()
        transitionDrawablePoll = nil
        transitionPlaybackGeneration &+= 1
        idleExitTransitionInProgress = false
        idleEntryRequestedWhileExiting = false
        if holdingCompletedIdleEntrySurface, transitionHostView != nil {
            retirePreviousTransitionSurface()
            transitionPlayers.forEach { $0.pause() }
            retiringTransitionPlayers = transitionPlayers
            retiringTransitionHostView = transitionHostView
            transitionPlayers.removeAll()
            transitionLayers.removeAll()
            transitionHostView = nil
            holdingCompletedIdleEntrySurface = false
        } else {
            teardownPlayerLayers(in: transitionHostView?.layer)
            transitionPlayers.forEach { teardownPlayer($0) }
            transitionPlayers.removeAll()
            transitionLayers.forEach {
                teardownPlayerLayers(in: $0)
                $0.mask = nil
                $0.removeFromSuperlayer()
            }
            transitionLayers.removeAll()
            transitionHostView?.removeFromSuperview()
            transitionHostView = nil
        }
        // A reaction hold that reached its logical end keeps animating on the
        // retiring surface until the reveal tree replaces it (see the
        // hold-boundary observer in startVideoComposition).
        if !(preservingIdleComposite && retiringSurfaceKeepsPlaying) { player?.pause() }
        if let observer = playerBoundaryObserver { player?.removeTimeObserver(observer) }
        playerBoundaryObserver = nil
        if !preservingActiveVideo {
            playerReadyObservation = nil
            activeVideoPlaceholderLayer?.removeFromSuperlayer()
            activeVideoPlaceholderLayer = nil
            if !preservingIdleComposite {
                teardownPlayer(player)
                player = nil
            }
            teardownPlayerLayer(playerLayer)
            playerLayer = nil
            activeVideoAssetID = nil
            holdingActiveFrameForIdleEntry = false
        }
        if preservingIdleComposite {
            retiringSurfaceKeepsPlaying = false
            // A failed incoming candidate may already have been discarded.
            // In that case the retiring surface is the only visible foreground
            // and must survive the retry instead of being collected here.
            let hasCurrentComposite = player != nil || compositeVideoHostView != nil || frameView != nil
            if hasCurrentComposite {
                retirePreviousCompositeSurface()
                retiringCompositePlayer = player
                retiringCompositeHostView = compositeVideoHostView
                retiringFrameView = frameView
            }
            player = nil
            compositeVideoLayer = nil
            compositeVideoHostView = nil
            frameView = nil
        } else {
            retiringSurfaceKeepsPlaying = false
            // No idle composite surface survives this branch (the retiring
            // one included), so a character parked on it goes with it: a
            // reveal abandoned by the watchdog or an item failure must not
            // leave the park forcing another rotation before the idle entry.
            parkedCharacter = nil
            retirePreviousCompositeSurface()
            teardownPlayerLayer(compositeVideoLayer)
            compositeVideoLayer = nil
            teardownPlayerLayers(in: compositeVideoHostView?.layer)
            compositeVideoHostView?.removeFromSuperview()
            compositeVideoHostView = nil
            frameView?.removeFromSuperview()
            frameView = nil
        }
        compositeVideoReadyObservation = nil
        compositeItemStatusObservation = nil
        compositePrerollTimeout?.cancel()
        compositePrerollTimeout = nil
        compositeDrawablePoll = nil
        compositePlaybackGeneration &+= 1
        compositeVideoPlaceholderLayer?.removeFromSuperlayer()
        compositeVideoPlaceholderLayer = nil
        if !preservingIdleComposite {
            removeVisitorPlayback()
            backgroundColorView?.removeFromSuperview()
            backgroundColorView = nil
            halftoneView?.removeFromSuperview()
            halftoneView = nil
            backgroundImageView?.removeFromSuperview()
            backgroundImageView = nil
            backgroundVideoReadyObservation = nil
            backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
            backgroundVideoPlaceholderLayer = nil
            backgroundVideoLooper = nil
            teardownPlayerLayer(backgroundVideoLayer)
            teardownPlayer(backgroundVideoPlayer)
            backgroundVideoPlayer = nil
            backgroundVideoLayer = nil
            teardownPlayerLayers(in: backgroundVideoHostView?.layer)
            backgroundVideoHostView?.removeFromSuperview()
            backgroundVideoHostView = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
            backgroundSprite = nil
        }
        foregroundSprite = nil
        if isStopping {
            retirePreviousTransitionSurface()
        }
    }

    private func installMemoryPressureHandler() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameDecodeQueue.cancelAllOperations()
            self.frameDecodeLock.lock()
            self.pendingFrameKeys.removeAll()
            self.frameDecodeLock.unlock()
            self.decodedFrameCache.removeAllObjects()
            NSLog("SnoopyTVScreenSaver: cleared HEIC prefetch cache after memory pressure")
        }
        source.resume()
        memoryPressureSource = source
    }

    private func stopFrameDisplayLink() {
        if let frameDisplayLink { CVDisplayLinkStop(frameDisplayLink) }
        frameDisplayLink = nil
        frameDrawablePoll = nil
        frameSequenceURLs.removeAll(keepingCapacity: false)
        frameSequenceIndex = 0
        frameSequenceLastHostTime = 0
        frameSequenceMaxPixelSize = 0
        frameSequenceVisitorControlsCompletion = false
        frameSequenceDecodeMisses = 0
    }

    /// AVPlayer keeps its VideoToolbox session and decoded IOSurfaces alive
    /// after pause(). Explicitly sever the item/queue before releasing the last
    /// owner so a cached legacyScreenSaver host does not retain decoder memory.
    private func teardownPlayer(_ player: AVPlayer?) {
        guard let player else { return }
        player.pause()
        player.cancelPendingPrerolls()
        if let queue = player as? AVQueuePlayer {
            queue.removeAllItems()
        } else {
            player.replaceCurrentItem(with: nil)
        }
    }

    /// Transition hosts can contain several nested AVPlayerLayers, including a
    /// reparented ActiveScene layer. Walk the complete tree so no layer remains
    /// an implicit owner of a player after that host is retired.
    private func teardownPlayerLayers(in root: CALayer?) {
        guard let root else { return }
        if let mask = root.mask {
            root.mask = nil
            teardownPlayerLayers(in: mask)
        }
        root.sublayers?.forEach { teardownPlayerLayers(in: $0) }
        if let playerLayer = root as? AVPlayerLayer {
            teardownPlayer(playerLayer.player)
            playerLayer.player = nil
        }
    }

    private func teardownPlayerLayer(_ layer: AVPlayerLayer?) {
        guard let layer else { return }
        teardownPlayerLayers(in: layer)
        layer.removeFromSuperlayer()
    }

    private func retirePreviousCompositeSurface() {
        teardownPlayerLayers(in: retiringCompositeHostView?.layer)
        teardownPlayer(retiringCompositePlayer)
        retiringCompositePlayer = nil
        retiringCompositeHostView?.removeFromSuperview()
        retiringCompositeHostView = nil
        retiringFrameView?.removeFromSuperview()
        retiringFrameView = nil
    }

    private func retirePreviousTransitionSurface() {
        teardownPlayerLayers(in: retiringTransitionHostView?.layer)
        retiringTransitionPlayers.forEach { teardownPlayer($0) }
        retiringTransitionPlayers.removeAll()
        retiringTransitionHostView?.removeFromSuperview()
        retiringTransitionHostView = nil
    }

    private func retirePreviousPlaybackSurfaces() {
        retirePreviousCompositeSurface()
        retirePreviousTransitionSurface()
    }

    /// Once the duplicate transition scene is drawable it becomes the sole
    /// owner of the outgoing IdleScene. Leaving the normal character/backdrop
    /// mounted underneath defeats the reveal mask: it exposes that second
    /// IdleScene instead of the ActiveScene and can briefly show two Snoopys.
    private func retireOutgoingIdleSurfaceForTransition() {
        retirePreviousCompositeSurface()
        teardownPlayerLayer(compositeVideoLayer)
        compositeVideoLayer = nil
        teardownPlayerLayers(in: compositeVideoHostView?.layer)
        compositeVideoHostView?.removeFromSuperview()
        compositeVideoHostView = nil
        frameView?.removeFromSuperview()
        frameView = nil
        removeVisitorPlayback()
        backgroundColorView?.removeFromSuperview()
        backgroundColorView = nil
        halftoneView?.removeFromSuperview()
        halftoneView = nil
        backgroundImageView?.removeFromSuperview()
        backgroundImageView = nil
        backgroundVideoReadyObservation = nil
        backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
        backgroundVideoPlaceholderLayer = nil
        backgroundVideoLooper = nil
        teardownPlayerLayer(backgroundVideoLayer)
        teardownPlayer(backgroundVideoPlayer)
        backgroundVideoPlayer = nil
        backgroundVideoLayer = nil
        teardownPlayerLayers(in: backgroundVideoHostView?.layer)
        backgroundVideoHostView?.removeFromSuperview()
        backgroundVideoHostView = nil
        overlayView?.removeFromSuperview()
        overlayView = nil
        backgroundSprite = nil
        foregroundSprite = nil
    }

    private var hasRetiringPlaybackSurface: Bool {
        retiringCompositeHostView != nil || retiringFrameView != nil || retiringTransitionHostView != nil
    }

    private var hasMountedNormalIdleSurface: Bool {
        retiringCompositeHostView != nil || retiringFrameView != nil
            || compositeVideoHostView != nil || frameView != nil
            || backgroundColorView != nil || halftoneView != nil
            || backgroundImageView != nil || backgroundVideoHostView != nil
            || overlayView != nil
    }

    private func keepRetiringPlaybackSurfaceAbove(_ incomingView: NSView) {
        if let host = retiringCompositeHostView, host.superview === self {
            addSubview(host, positioned: .above, relativeTo: incomingView)
        }
        if let view = retiringFrameView, view.superview === self {
            addSubview(view, positioned: .above, relativeTo: incomingView)
        }
        if let host = retiringTransitionHostView, host.superview === self {
            addSubview(host, positioned: .above, relativeTo: incomingView)
        }
    }

    private func cleanTransitionOverlay() {
        if let observer = transitionEndObserver { NotificationCenter.default.removeObserver(observer) }
        transitionEndObserver = nil
        transitionPrerollTimeout?.cancel()
        transitionPrerollTimeout = nil
        transitionItemStatusObservations.removeAll()
        transitionDrawablePoll = nil
        transitionPlaybackGeneration &+= 1
        teardownPlayerLayers(in: transitionHostView?.layer)
        transitionPlayers.forEach { teardownPlayer($0) }
        transitionPlayers.removeAll()
        transitionLayers.forEach {
            teardownPlayerLayers(in: $0)
            $0.mask = nil
            $0.removeFromSuperlayer()
        }
        transitionLayers.removeAll()
        transitionHostView?.removeFromSuperview()
        transitionHostView = nil
    }

    private func installWatchdog(defaultSeconds: TimeInterval) {
        watchdogWorkItem?.cancel()
        let testSeconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_SEGMENT_SECONDS"].flatMap(Double.init)
        let seconds = max(0.5, testSeconds ?? defaultSeconds)
        let installedAt = ProcessInfo.processInfo.systemUptime
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isPaused {
                // Re-arm after resume with the time that was left when we paused.
                let remaining = max(0.5, seconds - (self.pauseStartedAt - installedAt))
                self.deferredWhilePaused.append { [weak self] in self?.installWatchdog(defaultSeconds: remaining) }
                return
            }
            self.finishCurrentPlayback("watchdog")
        }
        watchdogWorkItem = work
        watchdogDeadline = installedAt + seconds
        watchdogRearm = { [weak self] remaining in self?.installWatchdog(defaultSeconds: remaining) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func installTransitionWatchdog(
        defaultSeconds: TimeInterval, generation: UInt64,
        stage: TransitionStage, selection: SceneTransitionSelection
    ) {
        watchdogWorkItem?.cancel()
        let testSeconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_SEGMENT_SECONDS"].flatMap(Double.init)
        let seconds = max(0.5, testSeconds ?? defaultSeconds)
        let installedAt = ProcessInfo.processInfo.systemUptime
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionPlaybackGeneration == generation else { return }
            if self.isPaused {
                let remaining = max(0.5, seconds - (self.pauseStartedAt - installedAt))
                self.deferredWhilePaused.append { [weak self] in
                    self?.installTransitionWatchdog(defaultSeconds: remaining, generation: generation,
                                                    stage: stage, selection: selection)
                }
                return
            }
            self.completeSceneTransitionStage(stage, selection: selection, reason: "watchdog")
        }
        watchdogWorkItem = work
        watchdogDeadline = installedAt + seconds
        watchdogRearm = { [weak self] remaining in
            self?.installTransitionWatchdog(defaultSeconds: remaining, generation: generation,
                                            stage: stage, selection: selection)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func currentContext() -> SelectionContext {
        let now = Date()
        let override = SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.weatherOverrideKey)
            .flatMap { $0.isEmpty ? nil : $0 }
        let snapshot = SnoopyPreferences.weatherEnabled
            ? SnoopyPreferences.weatherSnapshot().flatMap { $0.isUsable ? $0 : nil }
            : nil
        let weather = override.map { Set([$0]) } ?? Set(snapshot?.conditions ?? [])
        return SelectionContext(
            date: now,
            timeOfDay: currentTimeOfDay(),
            routine: SnoopyCalendarResolver.routine(for: now),
            routineConditions: SnoopyCalendarResolver.routineConditions(for: now),
            weatherConditions: weather,
            calendarEvents: SnoopyCalendarResolver.events(for: now),
            hourlyEvents: SnoopyCalendarResolver.hourlyEvents(
                for: now, sunrise: snapshot?.sunrise, sunset: snapshot?.sunset
            ),
            moonPhases: [SnoopyCalendarResolver.moonCondition(for: now)]
        )
    }

    private func refreshWeatherIfNeeded() {
        guard SnoopyPreferences.weatherEnabled else { return }
        if let snapshot = SnoopyPreferences.weatherSnapshot(), !snapshot.needsRefresh { return }
        let city = SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.cityNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard SnoopyPreferences.weatherLocation() != nil || city.count >= 2 else { return }
        weatherRefreshTask?.cancel()
        weatherRefreshTask = Task {
            do {
                let client = SnoopyWeatherClient()
                let location: SnoopyWeatherLocation
                if let saved = SnoopyPreferences.weatherLocation() {
                    location = saved
                } else {
                    location = try await client.resolve(city: city)
                    guard !Task.isCancelled else { return }
                    SnoopyPreferences.save(weatherLocation: location)
                }
                let snapshot = try await client.fetch(location: location)
                guard !Task.isCancelled else { return }
                SnoopyPreferences.save(weatherSnapshot: snapshot)
                NSLog("SnoopyTVScreenSaver: weather refreshed location=%@ source=%@ conditions=%@",
                      location.name, snapshot.source ?? "unknown", snapshot.conditions.joined(separator: ","))
            } catch {
                if !Task.isCancelled {
                    NSLog("SnoopyTVScreenSaver: weather refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }

    private func playNext() {
        guard !isStopping, let store else {
            return
        }
        // AppKit commits the outgoing removal and incoming installation as a
        // single frame. AVPlayer playback remains time-driven; only implicit
        // layer property animations are disabled for this swap.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        let nextStagePreservesIdle: Bool
        if let first = pendingSceneStages.first,
           case .activeSceneWithReveal = first {
            nextStagePreservesIdle = true
        } else {
            nextStagePreservesIdle = false
        }
        let continuingIdleComposite = sessionState.currentIdleSceneID != nil
            && playerLayer == nil
            && (pendingSceneStages.isEmpty || nextStagePreservesIdle)
        // Keep the authored outgoing Idle surface for both character-to-
        // character swaps and Idle -> Hide -> ActiveScene. Previously the
        // rotation path cleared it before Hide was drawable, then exposed its
        // separately-retained last frame again when the Hide host was removed.
        cleanCurrentPlayback(
            preservingActiveVideo: holdingActiveFrameForIdleEntry,
            preservingIdleComposite: continuingIdleComposite
        )
        let context = currentContext()
        NSLog("SnoopyTVScreenSaver: context time=%@ routine=%@ weather=%@ calendar=%@ hourly=%@",
              context.timeOfDay ?? "none", context.routine ?? "none",
              context.weatherConditions.sorted().joined(separator: ","),
              context.calendarEvents.sorted().joined(separator: ","),
              context.hourlyEvents.sorted().joined(separator: ","))
        let kind: PlaybackKind
        let started: Bool
        if !pendingSceneStages.isEmpty {
            let stage = pendingSceneStages.removeFirst()
            switch stage {
            case .activeScene(let asset):
                kind = .video
                started = startActiveVideo(asset, from: store, context: context)
            case .activeSceneWithReveal(let asset, let selection):
                kind = .video
                started = startActiveSceneWithReveal(asset, selection: selection, from: store, context: context)
            case .transition(let phase, let selection):
                kind = .composite
                started = playSceneTransitionStage(phase, selection: selection, from: store, context: context)
            }
        } else {
            // CharacterAnimationManager in tvOS drains pendingAnimationQueue
            // before asking the display coordinator for a different scene type.
            kind = pendingCharacterAssetIDs.isEmpty ? nextPlaybackKind() : .composite
            switch kind {
            case .video:
                started = playRandomVideo(from: store, context: context)
            case .composite:
                started = playRandomComposite(from: store, context: context)
            }
        }
        if !started {
            NSLog("SnoopyTVScreenSaver: unable to start requested %@; will retry same media class", String(describing: kind))
            scheduleNext(after: 0.5)
        } else {
            let visibleSurfaceCount = subviews.filter { !$0.isHidden && $0.alphaValue > 0 }.count
                + (layer?.sublayers?.filter { !$0.isHidden && $0.opacity > 0 }.count ?? 0)
            if visibleSurfaceCount == 0 {
                NSLog("SnoopyTVScreenSaver: ERROR committed playback with no visible surface")
            }
            saveSelectionMemory()
        }
    }

    /// ActiveScene + Reveal over the outgoing idle surface: that RPH/Idle
    /// surface remains above the movie while Reveal is prepared, and both
    /// start on the same host clock only after every transition renderer is
    /// drawable.
    private func startActiveSceneWithReveal(
        _ asset: AssetRecord, selection: SceneTransitionSelection,
        from store: AssetStore, context: SelectionContext
    ) -> Bool {
        guard startActiveVideo(asset, from: store, context: context) else { return false }
        player?.pause()
        return playSceneTransitionStage(.reveal, selection: selection, from: store, context: context)
    }

    private func nextPlaybackKind() -> PlaybackKind {
        if ProcessInfo.processInfo.environment["SNOOPY_TEST_START_WITH_COMPOSITE"] == "1",
           sessionState.currentIdleSceneID == nil, !hasPlayedInitialActiveScene {
            return .composite
        }
        if ProcessInfo.processInfo.environment["SNOOPY_TEST_NATIVE_SEQUENCE"] == "1" {
            if sessionState.currentIdleSceneID != nil {
                return shouldRotateIdleScene ? .video : .composite
            }
            return hasPlayedInitialActiveScene ? .composite : .video
        }
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_PLAYBACK_KIND"] == "video" { return .video }
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_PLAYBACK_KIND"] == "composite" { return .composite }
        if sessionState.currentIdleSceneID != nil {
            // A character parked at RPH for the rotation (D) forces the
            // transition even when the build-time prediction was early.
            let parkedForRotation = parkedCharacter?.forRotation == true
            if shouldRotateIdleScene || parkedForRotation {
                idleSceneChangeRequested = true
                if parkedForRotation, !shouldRotateIdleScene {
                    NSLog("SnoopyTVScreenSaver: reaction parked: forcing active scene transition")
                }
                NSLog("SnoopyTVScreenSaver: idle scene reached Apple 240s target; requesting active scene transition")
                return .video
            }
            return .composite
        }
        // IdleCharacterPoster starts with an ActiveScene, then enters a long
        // IdleScene residency. It does not use a 1:4 shuffled media bag.
        return hasPlayedInitialActiveScene ? .composite : .video
    }

    private var shouldRotateIdleScene: Bool {
        guard sessionState.currentIdleSceneID != nil,
              let startedAt = idleSceneStartedAt else { return false }
        return idleSceneAnimationCount >= idleSceneTargetAnimationCount
            || ProcessInfo.processInfo.systemUptime - startedAt >= idleSceneTargetDuration
    }

    private func beginIdleScene(_ id: String) {
        sessionState.currentIdleSceneID = id
        idleSceneStartedAt = ProcessInfo.processInfo.systemUptime
        idleSceneAnimationCount = 0
        idleSceneTargetAnimationCount = ProcessInfo.processInfo.environment["SNOOPY_TEST_IDLE_ROTATION_COUNT"]
            .flatMap(Int.init) ?? .max
        idleSceneTargetDuration = ProcessInfo.processInfo.environment["SNOOPY_TEST_IDLE_ROTATION_SECONDS"]
            .flatMap(Double.init) ?? 240
        sessionState.resetCharacterMix()
        visitorScheduleTimes = PlaybackSessionState.visitorSchedule(
            targetDuration: idleSceneTargetDuration, seed: seed
        )
        nextVisitorScheduleIndex = 0
        idleSceneChangeRequested = false
        NSLog("SnoopyTVScreenSaver: begin idle scene %@ targetDuration=%.0f visitorSchedule=%@",
              id, idleSceneTargetDuration,
              visitorScheduleTimes.map { String(format: "%.1f", $0) }.joined(separator: ","))
    }

    private func clearIdleSceneState() {
        if let current = sessionState.currentIdleSceneID { previousIdleSceneID = current }
        sessionState.currentIdleSceneID = nil
        sessionState.currentBasePoseID = nil
        idleSceneStartedAt = nil
        idleSceneAnimationCount = 0
        visitorScheduleTimes.removeAll()
        nextVisitorScheduleIndex = 0
        currentPaletteAssetID = nil
        currentSceneOffset = nil
        pendingCharacterAssetIDs.removeAll()
        parkedCharacter = nil
    }

    private func sessionChoice(from assets: [AssetRecord], pool: String, context: SelectionContext) -> AssetRecord? {
        let policy = SelectionPolicy()
        var weighted = policy.weightedAssets(
            from: assets, context: context, memory: memory, pool: pool
        )
        let recentLimit = policy.recentLimit(for: pool, candidateCount: weighted.count)
        let persistedRecent = Set(memory.recentIDs(in: pool, limit: recentLimit))
        let fresh = weighted.filter { !persistedRecent.contains($0.asset.id) }
        if !fresh.isEmpty {
            weighted = fresh
        } else if let lastID = memory.lastSelectedID(in: pool), weighted.count > 1 {
            weighted.removeAll { $0.asset.id == lastID }
        }
        defer { seed &+= 1 }
        let selected = sessionState.chooseWeighted(from: weighted, pool: pool, seed: seed)
        if let selected {
            memory.record(selected.id, in: pool, recentLimit: recentLimit)
        }
        return selected
    }

    private func playRandomVideo(from store: AssetStore, context: SelectionContext) -> Bool {
        var candidates = store.eligible(store.activeScenes(), on: context.date).filter { asset in
            guard let directory = try? store.url(for: asset) else { return false }
            return asset.sprites.contains { sprite in
                guard sprite.spriteType == "video", let base = sprite.assetBaseName else { return false }
                let name = asset.media?.first(where: { $0.name == base + ".mov" })?.name ?? base + ".mov"
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
        }
        let hasOutgoingIdle = sessionState.currentIdleSceneID != nil
        // `preventsIdleSceneChange` only means that an already-mounted room
        // must be retained. It does not forbid that transition from creating
        // the first IdleScene. For later 240s rotations, let authored dream /
        // story transitions retain the room at most twice, then force one of
        // the scene-changing RealWorld transitions so houses still rotate.
        let requiresNewIdle = hasOutgoingIdle && idleSceneChangeRequested
            && consecutiveTransitionsPreventingIdleSceneChange >= 2
        if requiresNewIdle, let graph = playbackGraph {
            candidates = candidates.filter { active in
                graph.transitionCandidates(for: active).contains {
                    !$0.preventsIdleSceneChange && sceneTransitionIsPlayable($0, from: store)
                }
            }
        }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_ASSET_ID"] {
            candidates = candidates.filter { $0.id == forcedID }
        }
        guard let selected = sessionChoice(from: candidates, pool: "activeVideos", context: context) else { return false }
        if let selection = chooseSceneTransition(
            for: selected, context: context, from: store, requiresSceneChange: requiresNewIdle
        ) {
            let basePoses = store.eligible(store.playableAssets(), on: context.date).filter {
                $0.kind == "characterBasePose"
            }
            guard let targetPose = sessionChoice(from: basePoses, pool: "basePoses", context: context),
                  let entrySequence = playbackGraph?.idleEntrySequence(to: targetPose.id) else {
                return false
            }
            pendingIdleEntrySequence = entrySequence
            sessionState.recordTransitionPair(selection.pairID)
            if selection.preventsIdleSceneChange {
                consecutiveTransitionsPreventingIdleSceneChange += 1
            } else {
                consecutiveTransitionsPreventingIdleSceneChange = 0
            }
            // ActiveScene is the upper maskHost in tvOS. Hide makes it
            // transparent to enter the IdleScene below; Reveal makes it
            // opaque again to exit IdleScene. Keep one moving player through
            // the complete Hide -> Active -> Reveal cycle.
            if hasOutgoingIdle {
                if let parked = parkedCharacter, parked.style == ReactionStyle.standard {
                    // The character already holds at RPH (an AP left through
                    // its V2 shortcut, or a hold armed the park): no BP_To_RPH
                    // exit; ActiveScene + Reveal start over the hold. When the
                    // movie itself fails to start the park survives (the retry
                    // keeps the hold and picks another ActiveScene); when the
                    // reveal fails after the movie mounted, the retry's
                    // non-preserving cleanup drops both the hold and the park.
                    NSLog("SnoopyTVScreenSaver: reaction parked at %@; skipping idleExitSequence and starting %@ + reveal",
                          ReactionStyle.nodeID(for: parked.style), selected.id)
                    pendingSceneStages = [.transition(.hide, selection)]
                    guard startActiveSceneWithReveal(selected, selection: selection, from: store, context: context) else {
                        pendingSceneStages.removeAll()
                        pendingIdleEntrySequence = nil
                        return false
                    }
                    return true
                }
                guard let currentPoseID = sessionState.currentBasePoseID,
                      let exitSequence = playbackGraph?.idleExitSequence(from: currentPoseID) else {
                    pendingIdleEntrySequence = nil
                    return false
                }
                // First drain BP_To_RPH over the intact IdleScene. The next
                // stage starts ActiveScene+Reveal together; Hide later returns
                // through the already-selected RPH_To_BP target.
                pendingCharacterAssetIDs = exitSequence.assets.map(\.id)
                pendingSceneStages = [
                    .activeSceneWithReveal(selected, selection),
                    .transition(.hide, selection),
                ]
                return playIdleCharacterComposite(from: store, context: context)
            }
            pendingSceneStages = [.transition(.hide, selection)]
            guard startActiveVideo(selected, from: store, context: context) else {
                pendingSceneStages.removeAll()
                pendingIdleEntrySequence = nil
                return false
            }
            return true
        }
        if idleSceneChangeRequested {
            // A hard cut mounts the opaque movie above the retiring surface:
            // a reaction hold has nothing left to animate for underneath it.
            if parkedCharacter != nil { retiringCompositePlayer?.pause() }
            clearIdleSceneState()
            idleSceneChangeRequested = false
        }
        return startActiveVideo(selected, from: store, context: context)
    }

    private func startActiveVideo(
        _ selected: AssetRecord, from store: AssetStore, context: SelectionContext
    ) -> Bool {
        guard let sprite = selected.sprites.first(where: { $0.spriteType == "video" }),
           let base = sprite.assetBaseName,
           let directory = try? store.url(for: selected) else { return false }
        let media = selected.media?.first(where: { $0.name == base + ".mov" })
        let name = media?.name ?? base + ".mov"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = Float(playbackRate)
        player.actionAtItemEnd = .pause
        // Standalone ActiveScene movies retain their authored 16:9 canvas.
        // They always fill the display height: narrow screens crop the sides,
        // while ultrawide screens expose black sidebars. Palette and halftone
        // belong only to layered composites.
        layer?.backgroundColor = NSColor.black.cgColor
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspect
        videoLayer.frame = activeVideoViewportFrame()
        layer?.masksToBounds = true
        layer?.addSublayer(videoLayer)
        if let image = videoPlaceholderImage(at: url) {
            let placeholder = CALayer()
            placeholder.frame = videoLayer.frame
            placeholder.contents = image
            placeholder.contentsGravity = .resizeAspect
            placeholder.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(placeholder)
            activeVideoPlaceholderLayer = placeholder
        }
        playerReadyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self, weak videoLayer] _, _ in
            guard videoLayer?.isReadyForDisplay == true else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.activeVideoPlaceholderLayer?.removeFromSuperlayer()
                self.activeVideoPlaceholderLayer = nil
                CATransaction.commit()
                self.playerReadyObservation = nil
                self.revealStartupFadeIfNeeded()
            }
        }
        self.player = player
        self.playerLayer = videoLayer
        activeVideoAssetID = selected.id
        foregroundSprite = sprite
        currentAssetID = selected.id
        isPlaying = true
        hasPlayedInitialActiveScene = true

        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.hasPendingIdleEntryTransition {
                    self.beginPendingIdleEntryTransition()
                } else {
                    self.finishCurrentPlayback("video ended")
                }
            }
        }
        playerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            NSLog("SnoopyTVScreenSaver: video failure %@", String(describing: notification.userInfo))
            self?.finishCurrentPlayback("video failed")
        }
        playerStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            self?.installWatchdog(defaultSeconds: 5)
        }
        let visualEnd = ProcessInfo.processInfo.environment["SNOOPY_TEST_ACTIVE_END_SECONDS"].flatMap(Double.init)
            ?? media?.effectiveEndSeconds ?? media?.durationSeconds
            ?? AVURLAsset(url: url).duration.seconds
        if visualEnd.isFinite, visualEnd > 0.5 {
            let entryOverlap = pendingIdleEntryTransitionDuration(from: store)
            let triggerTime = entryOverlap.map { max(0.25, visualEnd - $0) } ?? visualEnd
            let boundary = CMTime(seconds: triggerTime, preferredTimescale: 600)
            playerBoundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.hasPendingIdleEntryTransition {
                        self.beginPendingIdleEntryTransition()
                    } else {
                        self.finishCurrentPlayback("visual content ended")
                    }
                }
            }
            if let entryOverlap {
                NSLog("SnoopyTVScreenSaver: active/idle-entry overlap asset=%@ start=%.3f overlap=%.3f end=%.3f",
                      selected.id, triggerTime, entryOverlap, visualEnd)
            }
        }
        let watchdogSeconds = (media?.durationSeconds ?? 117) + 3
        installWatchdog(defaultSeconds: watchdogSeconds)
        let effectiveDescription = media?.effectiveEndSeconds.map { String(format: "%.3f", $0) } ?? "container-end"
        let durationDescription = media?.durationSeconds.map { String(format: "%.3f", $0) } ?? "unknown"
        NSLog("SnoopyTVScreenSaver: video %@ effectiveEnd=%@ duration=%@ fillFrame=%@ bounds=%@",
              selected.id, effectiveDescription, durationDescription,
              NSStringFromRect(videoLayer.frame), NSStringFromRect(bounds))
        player.play()
        return true
    }

    private var hasPendingIdleEntryTransition: Bool {
        guard let first = pendingSceneStages.first,
              case .transition(.hide, _) = first else { return false }
        return true
    }

    private func pendingIdleEntryTransitionDuration(from store: AssetStore) -> TimeInterval? {
        guard let first = pendingSceneStages.first,
              case .transition(.hide, let selection) = first else { return nil }
        return transitionDuration(.hide, selection: selection, from: store)
    }

    private func transitionDuration(
        _ stage: TransitionStage, selection: SceneTransitionSelection, from store: AssetStore
    ) -> TimeInterval? {
        guard let graph = playbackGraph,
              let parameterID = stage == .hide ? selection.hideParametersID : selection.revealParametersID,
              let parameter = graph.assetsByID[parameterID],
              let mask = parameter.sprites.first(where: { $0.plane == "mask" }),
              let url = videoURL(for: parameter, sprite: mask, store: store) else { return nil }
        let seconds = AVURLAsset(url: url).duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func beginPendingIdleEntryTransition() {
        guard isPlaying, let store, let first = pendingSceneStages.first,
              case .transition(.hide, let selection) = first else { return }
        if idleExitTransitionInProgress {
            idleEntryRequestedWhileExiting = true
            NSLog("SnoopyTVScreenSaver: idle entry requested while idle exit is active; deferring pair=%@",
                  selection.pairID)
            return
        }
        pendingSceneStages.removeFirst()
        if let observer = playerEndObserver { NotificationCenter.default.removeObserver(observer) }
        playerEndObserver = nil
        if let observer = playerBoundaryObserver, let player {
            player.removeTimeObserver(observer)
        }
        playerBoundaryObserver = nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        holdingActiveFrameForIdleEntry = true
        // Freeze on the first frame of the authored overlap window. The
        // ActiveScene resumes on the same host clock as mask/outline/ST, so a
        // slow preroll can never run the movie into its invalid tail.
        player?.pause()
        let movingTime = player?.currentTime().seconds ?? 0
        NSLog("SnoopyTVScreenSaver: begin moving idle entry pair=%@ activeTime=%.3f rate=%.2f",
              selection.pairID, movingTime, player?.rate ?? 0)
        if !playSceneTransitionStage(.hide, selection: selection, from: store, context: currentContext()) {
            finishCurrentPlayback("unable to start moving idle entry transition")
        }
    }

    private func completeIdleExitTransitionAndContinueActiveVideo(selection: SceneTransitionSelection) {
        let id = activeVideoAssetID ?? "active video"
        idleExitTransitionInProgress = false
        // The moving ActiveScene (or its decoded placeholder) is already
        // underneath both surfaces. Move it out of the Reveal mask host and
        // remove the outgoing Idle surface in one display transaction.
        // in one display transaction so the old character/room cannot flash
        // back for a frame between them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let activeLayer = playerLayer {
            activeLayer.mask = nil
            layer?.addSublayer(activeLayer)
        }
        cleanTransitionOverlay()
        retirePreviousCompositeSurface()
        CATransaction.commit()
        // The hold surface (if any) was torn down at the reveal commit; the
        // character is off screen and no longer parked.
        parkedCharacter = nil
        currentAssetID = id
        isPlaying = true
        let duration = player?.currentItem?.duration.seconds ?? 0
        let current = player?.currentTime().seconds ?? 0
        let remaining = duration.isFinite ? max(1, duration - current) : 120
        installWatchdog(defaultSeconds: remaining + 3)
        if !selection.preventsIdleSceneChange {
            clearIdleSceneState()
            idleSceneChangeRequested = false
        }
        NSLog("SnoopyTVScreenSaver: idle exit completed over moving video %@ time=%.3f rate=%.2f",
              id, current, player?.rate ?? 0)
        if idleEntryRequestedWhileExiting {
            idleEntryRequestedWhileExiting = false
            DispatchQueue.main.async { [weak self] in self?.beginPendingIdleEntryTransition() }
        }
    }

    private func completeSceneTransitionStage(
        _ stage: TransitionStage, selection: SceneTransitionSelection, reason: String
    ) {
        guard isPlaying else { return }
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        if stage == .reveal, playerLayer != nil {
            completeIdleExitTransitionAndContinueActiveVideo(selection: selection)
        } else {
            if stage == .hide {
                holdingCompletedIdleEntrySurface = true
                if selection.preventsIdleSceneChange, idleSceneChangeRequested,
                   let currentIdleSceneID = sessionState.currentIdleSceneID {
                    // A dream/story transition intentionally returns to the
                    // same authored room. That return begins a fresh 240s
                    // residency; leaving the old timer expired would launch
                    // another ActiveScene immediately after one character
                    // action and make these families look like interstitials.
                    beginIdleScene(currentIdleSceneID)
                }
            }
            finishCurrentPlayback("\(stage.rawValue) scene transition \(reason)")
        }
    }

    private func chooseSceneTransition(
        for activeScene: AssetRecord, context: SelectionContext, from store: AssetStore,
        requiresSceneChange: Bool
    ) -> SceneTransitionSelection? {
        guard let graph = playbackGraph else { return nil }
        let scorer = RelevancyScorer()
        var allCandidates = graph.transitionCandidates(for: activeScene).filter {
            sceneTransitionIsPlayable($0, from: store)
        }
        if let forcedPairID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_TRANSITION_PAIR_ID"] {
            allCandidates = allCandidates.filter { $0.pairID == forcedPairID }
        }
        guard !allCandidates.isEmpty else { return nil }
        if requiresSceneChange {
            allCandidates = allCandidates.filter { !$0.preventsIdleSceneChange }
            guard !allCandidates.isEmpty else { return nil }
        }
        if consecutiveTransitionsPreventingIdleSceneChange >= 2 {
            let sceneChanging = allCandidates.filter { !$0.preventsIdleSceneChange }
            if !sceneChanging.isEmpty { allCandidates = sceneChanging }
        }
        if let lastRevealTransitionPoseID {
            let freshPose = allCandidates.filter { !$0.revealCharacterPoseIDs.contains(lastRevealTransitionPoseID) }
            if !freshPose.isEmpty { allCandidates = freshPose }
        }
        var candidates = allCandidates.filter { candidate in
            guard let pair = graph.assetsByID[candidate.pairID] else { return false }
            return scorer.relevanceScore(pair, context: context) != nil
        }
        guard !candidates.isEmpty else { return nil }

        // Pick the real TM artwork family first. The manifest has many pair
        // references, but weather/time variants often point at the same mask
        // files; pair-only recency therefore kept showing Clock/Horizontal.
        let families = Dictionary(grouping: candidates, by: \SceneTransitionSelection.parameterFamilyID)
        let recentFamilies = Set(memory.recentIDs(in: "sceneTransitionParameterFamilies"))
        let freshFamilyIDs = families.keys.filter { !recentFamilies.contains($0) }
        var familyIDs = freshFamilyIDs.isEmpty ? Array(families.keys) : freshFamilyIDs
        if freshFamilyIDs.isEmpty,
           let lastFamilyID = memory.lastSelectedID(in: "sceneTransitionParameterFamilies"),
           familyIDs.count > 1 {
            familyIDs.removeAll { $0 == lastFamilyID }
        }
        familyIDs.sort()
        guard !familyIDs.isEmpty else { return nil }

        func relevanceWeight(for candidate: SceneTransitionSelection) -> Int {
            guard let pair = graph.assetsByID[candidate.pairID],
                  let relevance = scorer.relevanceScore(pair, context: context) else { return 0 }
            switch relevance {
            case 65...: return 8
            case 25...: return 4
            case 1...: return 2
            default: return 1
            }
        }

        let familyWeights = familyIDs.map { familyID in
            families[familyID, default: []].map(relevanceWeight).max() ?? 1
        }
        let totalFamilyWeight = familyWeights.reduce(0, +)
        var familyTicket = Int(PlaybackSessionState.mixedIndex(
            seed: seed, count: max(1, totalFamilyWeight)
        ))
        var selectedFamilyID = familyIDs[0]
        for (familyID, weight) in zip(familyIDs, familyWeights) {
            if familyTicket < weight {
                selectedFamilyID = familyID
                break
            }
            familyTicket -= weight
        }

        candidates = families[selectedFamilyID, default: []]
        let recentRevealPoseIDs = Set(memory.recentIDs(in: "sceneTransitionPoses.reveal"))
        let recentTransitionCategoryIDs = Set(memory.recentIDs(in: "sceneTransitionCategories"))
        let recentPairIDs = Set(memory.recentIDs(in: "sceneTransitionPairs"))
            .union(sessionState.recentTransitionPairIDs)
        let freshCandidates = candidates.filter { candidate in
            !recentPairIDs.contains(candidate.pairID)
                && !recentTransitionCategoryIDs.contains(candidate.categoryID)
                && candidate.revealCharacterPoseIDs.allSatisfy { !recentRevealPoseIDs.contains($0) }
        }
        if !freshCandidates.isEmpty { candidates = freshCandidates }
        if let lastPairID = memory.lastSelectedID(in: "sceneTransitionPairs"), candidates.count > 1 {
            let withoutLast = candidates.filter { $0.pairID != lastPairID }
            if !withoutLast.isEmpty { candidates = withoutLast }
        }
        candidates.sort { ($0.categoryID, $0.pairID) < ($1.categoryID, $1.pairID) }
        seed &+= 1
        let totalCandidateWeight = candidates.map(relevanceWeight).reduce(0, +)
        var candidateTicket = Int(PlaybackSessionState.mixedIndex(
            seed: seed, count: max(1, totalCandidateWeight)
        ))
        var selected = candidates[0]
        for candidate in candidates {
            let weight = relevanceWeight(for: candidate)
            if candidateTicket < weight {
                selected = candidate
                break
            }
            candidateTicket -= weight
        }
        seed &+= 1
        memory.record(selected.pairID, in: "sceneTransitionPairs")
        memory.record(selected.categoryID, in: "sceneTransitionCategories")
        memory.record(selected.parameterFamilyID, in: "sceneTransitionParameterFamilies")
        NSLog("SnoopyTVScreenSaver: selected transition family=%@ pair=%@ category=%@ availableFamilies=%d",
              selected.parameterFamilyID, selected.pairID, selected.categoryID, families.count)
        return selected
    }

    private func sceneTransitionIsPlayable(
        _ selection: SceneTransitionSelection, from store: AssetStore
    ) -> Bool {
        guard let graph = playbackGraph else { return false }
        for parameterID in [selection.hideParametersID, selection.revealParametersID] {
            guard let parameterID, let parameter = graph.assetsByID[parameterID],
                  let mask = parameter.sprites.first(where: { $0.plane == "mask" }),
                  let outline = parameter.sprites.first(where: { $0.plane == "foregroundEffect" }),
                  videoURL(for: parameter, sprite: mask, store: store) != nil,
                  videoURL(for: parameter, sprite: outline, store: store) != nil else { return false }
        }
        for (phase, ids) in [("hide", selection.hideCharacterPoseIDs),
                             ("reveal", selection.revealCharacterPoseIDs)] where !ids.isEmpty {
            let hasPlayablePose = ids.compactMap { graph.assetsByID[$0] }.contains { asset in
                asset.transitionPhase == phase
                    && asset.sprites.contains { videoURL(for: asset, sprite: $0, store: store) != nil }
            }
            if !hasPlayablePose { return false }
        }
        return true
    }

    private func playSceneTransitionStage(
        _ stage: TransitionStage, selection: SceneTransitionSelection,
        from store: AssetStore, context: SelectionContext
    ) -> Bool {
        guard let graph = playbackGraph else { return false }
        // Do not clear the outgoing IdleScene at reveal start. Its final
        // Reveal pose remains underneath the ActiveScene mask until the upper
        // scene is fully opaque, then the coordinator unloads it.
        let eligible = store.eligible(store.playableAssets(), on: context.date)
        let idleAssets = eligible.filter { $0.kind == "idleScene" }
        let idle: AssetRecord
        if let id = sessionState.currentIdleSceneID,
           let current = idleAssets.first(where: { $0.id == id }) {
            idle = current
        } else {
            guard let selected = chooseIdleScene(from: idleAssets, context: context) else { return false }
            idle = selected
            beginIdleScene(selected.id)
        }
        guard let directory = try? store.url(for: idle) else { return false }
        currentSceneOffset = idle.idleScene?.sceneOffset
        let backgroundSprite = idle.sprites.first
        let backgroundImage = firstHEICName(in: idle).map { directory.appendingPathComponent($0) }
        let backgroundVideo = idle.sprites.first(where: { $0.spriteType == "video" })
            .flatMap { videoURL(for: idle, sprite: $0, store: store) }
        guard backgroundImage != nil || backgroundVideo != nil else { return false }
        let palette = paletteColors(from: store, context: context, idleScene: idle)

        let parameterID = stage == .hide ? selection.hideParametersID : selection.revealParametersID
        let poseIDs = stage == .hide ? selection.hideCharacterPoseIDs : selection.revealCharacterPoseIDs
        guard let parameterID, let parameterAsset = graph.assetsByID[parameterID],
              let maskSprite = parameterAsset.sprites.first(where: { $0.plane == "mask" }),
              let outlineSprite = parameterAsset.sprites.first(where: { $0.plane == "foregroundEffect" }),
              let maskURL = videoURL(for: parameterAsset, sprite: maskSprite, store: store),
              let outlineURL = videoURL(for: parameterAsset, sprite: outlineSprite, store: store),
              let activeSurfaceLayer = playerLayer else { return false }

        let host = NSView(frame: bounds)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(host)
        transitionHostView = host
        guard let hostLayer = host.layer else { return false }
        // AVPlayer.preroll() may finish before an AVPlayerLayer renderer has a
        // drawable. Keep the complete transition tree barely visible so every
        // renderer participates in composition, then expose it only after all
        // layers report readyForDisplay.
        hostLayer.opacity = 0.001

        transitionPlayers = []
        transitionLayers = []
        var synchronizedVideoLayers: [AVPlayerLayer] = []
        var firstFrameLayers: [CALayer] = []

        func firstFrameLayer(for url: URL, frame: CGRect) -> CALayer? {
            guard let image = videoPlaceholderImage(at: url) else { return nil }
            let layer = CALayer()
            layer.frame = frame
            layer.contents = image
            layer.contentsGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            firstFrameLayers.append(layer)
            transitionLayers.append(layer)
            return layer
        }

        // tvOS keeps IdleScene at the bottom of the stack and uses the upper
        // ActiveScene as maskHostView. This port mirrors that ownership with
        // the already-mounted ActiveScene player and one transition tree.

        let sceneLayer = CALayer()
        sceneLayer.frame = bounds
        sceneLayer.backgroundColor = palette.background.cgColor
        sceneLayer.masksToBounds = true

        // Palette overlay belongs to the palette base. Putting an opaque
        // late-night overlay above the idle scene erases the house/tent and
        // halftone completely, leaving only the subsequently-added MOV pose.
        if let overlay = palette.overlay {
            let overlayLayer = CALayer()
            overlayLayer.frame = bounds
            overlayLayer.backgroundColor = overlay.cgColor
            sceneLayer.addSublayer(overlayLayer)
            transitionLayers.append(overlayLayer)
        }

        if let halftoneURL = halftoneImageURL(),
           let source = CGImageSourceCreateWithURL(halftoneURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let halftone = CALayer()
            halftone.frame = bounds
            halftone.contents = image
            halftone.contentsGravity = .resize
            halftone.opacity = 0.1
            sceneLayer.addSublayer(halftone)
            transitionLayers.append(halftone)
        }

        let eligiblePoses = poseIDs.compactMap { graph.assetsByID[$0] }.filter {
            $0.transitionPhase == stage.rawValue
        }
        let selectedPose = sessionChoice(
            from: eligiblePoses, pool: "sceneTransitionPoses.\(stage.rawValue)", context: context
        )
        if stage == .reveal {
            lastRevealTransitionPoseID = selectedPose?.id
        }
        var poseLayer: AVPlayerLayer?
        var poseFirstFrameLayer: CALayer?
        var poseItem: AVPlayerItem?
        if let poseAsset = selectedPose,
           let poseSprite = poseAsset.sprites.first,
           let poseURL = videoURL(for: poseAsset, sprite: poseSprite, store: store) {
            let item = AVPlayerItem(url: poseURL)
            let posePlayer = AVPlayer(playerItem: item)
            posePlayer.defaultRate = Float(playbackRate)
            let layer = AVPlayerLayer(player: posePlayer)
            layer.frame = compositeFrame(for: poseSprite)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            layer.opacity = 1
            poseLayer = layer
            poseItem = item
            poseFirstFrameLayer = firstFrameLayer(for: poseURL, frame: layer.frame)
            transitionPlayers.append(posePlayer)
            transitionLayers.append(layer)
            synchronizedVideoLayers.append(layer)
            // Install the transition character only after the IdleScene
            // background below. Adding it here let the subsequently-added
            // opaque house/tent layer cover Snoopy for the whole transition.
        }

        if let backgroundImage,
           let image = decodedCGImage(at: backgroundImage, maxPixelSize: maximumPixelSize(for: backgroundSprite)) {
            let backgroundLayer = CALayer()
            backgroundLayer.frame = compositeFrame(for: backgroundSprite)
            backgroundLayer.contents = image
            backgroundLayer.contentsGravity = .resize
            sceneLayer.addSublayer(backgroundLayer)
            transitionLayers.append(backgroundLayer)
        } else if let backgroundVideo, let backgroundSprite {
            let idlePlayer = AVPlayer(url: backgroundVideo)
            idlePlayer.defaultRate = Float(playbackRate)
            let idleLayer = AVPlayerLayer(player: idlePlayer)
            idleLayer.frame = compositeFrame(for: backgroundSprite)
            idleLayer.videoGravity = .resizeAspect
            idleLayer.opacity = 1
            sceneLayer.addSublayer(idleLayer)
            if let firstFrame = firstFrameLayer(for: backgroundVideo, frame: idleLayer.frame) {
                sceneLayer.addSublayer(firstFrame)
            }
            transitionPlayers.append(idlePlayer)
            transitionLayers.append(idleLayer)
            synchronizedVideoLayers.append(idleLayer)
        }
        if let poseLayer {
            sceneLayer.addSublayer(poseLayer)
            if let poseFirstFrameLayer { sceneLayer.addSublayer(poseFirstFrameLayer) }
        }

        // Transition masks describe the authored 16:9 ActiveScene canvas, not
        // an idle sprite. Match the movie's height-filled viewport so narrow
        // screens crop the wipe and movie by the same amount.
        let viewport = activeVideoViewportFrame()
        let maskItem = AVPlayerItem(url: maskURL)
        let maskPlayer = AVPlayer(playerItem: maskItem)
        maskPlayer.defaultRate = Float(playbackRate)
        let maskLayer = AVPlayerLayer(player: maskPlayer)
        // The tvOS maskHost is the upper ActiveScene, not the IdleScene.
        // Its local bounds remain 16:9 on every display, so the matte stays
        // aligned with the moving movie without a second scaling pass.
        maskLayer.frame = activeSurfaceLayer.bounds
        maskLayer.videoGravity = .resizeAspect
        hostLayer.addSublayer(sceneLayer)
        // A mask does not reliably receive a drawable while detached, but
        // assigning it to the live ActiveScene during preparation changes the
        // visible movie before the transition is ready. Warm it inside the
        // nearly-invisible host, then atomically reparent it as the mask.
        maskLayer.opacity = 0.001
        hostLayer.addSublayer(maskLayer)

        let outlinePlayer = AVPlayer(url: outlineURL)
        outlinePlayer.defaultRate = Float(playbackRate)
        let outlineLayer = AVPlayerLayer(player: outlinePlayer)
        outlineLayer.frame = viewport
        outlineLayer.videoGravity = .resizeAspect
        outlineLayer.backgroundColor = NSColor.clear.cgColor
        outlineLayer.opacity = 1
        hostLayer.addSublayer(outlineLayer)
        if let firstOutline = firstFrameLayer(for: outlineURL, frame: viewport) {
            hostLayer.addSublayer(firstOutline)
        }
        transitionPlayers.append(contentsOf: [maskPlayer, outlinePlayer])
        transitionLayers.append(contentsOf: [sceneLayer, maskLayer, outlineLayer])
        synchronizedVideoLayers.append(contentsOf: [maskLayer, outlineLayer])

        let maskDuration = AVURLAsset(url: maskURL).duration.seconds
        let poseDuration = poseItem?.asset.duration.seconds ?? 0
        // Hide enters IdleScene. Apple lets the initial SceneTransitionPose
        // finish after the short ActiveScene wipe; ending on the mask item
        // stopped many 4-8 second poses before Snoopy became visible.
        let completionItem = stage == .hide && poseDuration > maskDuration
            ? (poseItem ?? maskItem) : maskItem
        let completionDuration = max(maskDuration, poseDuration)
        let revealMaskLead = stage == .reveal ? max(0, poseDuration - maskDuration) : 0
        transitionEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: completionItem, queue: .main
        ) { [weak self] _ in
            self?.completeSceneTransitionStage(stage, selection: selection, reason: "ended")
        }
        let duration = completionDuration
        if stage == .reveal { idleExitTransitionInProgress = true }
        currentAssetID = "\(selection.pairID).\(stage.rawValue)"
        isPlaying = true

        transitionPlaybackGeneration &+= 1
        let generation = transitionPlaybackGeneration
        let prerollStartedAt = ProcessInfo.processInfo.systemUptime
        let resultLock = NSLock()
        var allPrerollsSucceeded = true
        var didStart = false
        var didBeginPreroll = false
        var didScheduleRetry = false
        let retryPreparation: (String) -> Void = { [weak self] reason in
            guard let self, !didStart, !didScheduleRetry,
                  self.transitionPlaybackGeneration == generation else { return }
            didScheduleRetry = true
            NSLog("SnoopyTVScreenSaver: retaining outgoing surface and retrying %@ transition (%@)",
                  stage.rawValue, reason)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            activeSurfaceLayer.mask = nil
            if activeSurfaceLayer.superlayer == nil { self.layer?.addSublayer(activeSurfaceLayer) }
            self.cleanTransitionOverlay()
            CATransaction.commit()
            self.idleExitTransitionInProgress = false
            self.currentAssetID = self.activeVideoAssetID
            self.isPlaying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.isPlaying, !self.isStopping else { return }
                _ = self.playSceneTransitionStage(stage, selection: selection,
                                                  from: store, context: context)
            }
        }
        let startSynchronizedPlayback: () -> Void = { [weak self] in
            guard let self, !didStart, self.isPlaying,
                  self.transitionPlaybackGeneration == generation else { return }
            resultLock.lock()
            let succeeded = allPrerollsSucceeded
            resultLock.unlock()
            guard succeeded else {
                retryPreparation("preroll failed")
                return
            }
            didStart = true
            self.transitionDrawablePoll = nil
            self.transitionPrerollTimeout?.cancel()
            self.transitionPrerollTimeout = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostLayer.opacity = 1
            firstFrameLayers.forEach { $0.removeFromSuperlayer() }
            if self.hasMountedNormalIdleSurface {
                // The transition tree is now the sole maskHost-equivalent
                // owner. Remove any normal or retiring Idle tree in this same
                // display transaction. This also makes Reveal resilient to a
                // stale surface left by a failed prior stage.
                self.retireOutgoingIdleSurfaceForTransition()
            }
            // Reparent the same moving ActiveScene layer into the transition
            // host. It sits above the unmasked IdleScene and below the authored
            // outline; Hide/Reveal now affect only this upper scene.
            if activeSurfaceLayer.superlayer !== hostLayer {
                activeSurfaceLayer.removeFromSuperlayer()
                hostLayer.insertSublayer(activeSurfaceLayer, above: sceneLayer)
            }
            maskLayer.removeFromSuperlayer()
            maskLayer.opacity = 1
            activeSurfaceLayer.mask = maskLayer
            CATransaction.commit()
            self.revealStartupFadeIfNeeded()
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: 0.06, preferredTimescale: 600)
            if let activePlayer = self.player {
                activePlayer.automaticallyWaitsToMinimizeStalling = false
                activePlayer.setRate(1, time: activePlayer.currentTime(), atHostTime: hostTime)
            }
            self.transitionPlayers.forEach { transitionPlayer in
                // Host-time synchronized playback is rejected by AVFoundation
                // while the player's automatic stall waiting is enabled.
                // Every transition surface has already been prerolled, so let
                // the shared clock (rather than per-player buffering) govern
                // when mask, outline, pose and idle motion become visible.
                transitionPlayer.automaticallyWaitsToMinimizeStalling = false
                let isWipePlayer = transitionPlayer === maskPlayer || transitionPlayer === outlinePlayer
                let startTime = hostTime + CMTime(
                    seconds: isWipePlayer ? revealMaskLead : 0,
                    preferredTimescale: 600
                )
                transitionPlayer.setRate(1, time: .zero, atHostTime: startTime)
            }
            self.installTransitionWatchdog(
                defaultSeconds: (duration.isFinite ? duration : 2) + 1,
                generation: generation, stage: stage, selection: selection
            )
            NSLog("SnoopyTVScreenSaver: transition synchronized stage=%@ preroll=%.3f players=%ld wipeLead=%.3f",
                  stage.rawValue, ProcessInfo.processInfo.systemUptime - prerollStartedAt,
                  self.transitionPlayers.count, revealMaskLead)
        }
        let beginPreroll: () -> Void = { [weak self] in
            guard let self, !didBeginPreroll, self.isPlaying,
                  self.transitionPlaybackGeneration == generation else { return }
            didBeginPreroll = true
            self.transitionItemStatusObservations.removeAll()
            let group = DispatchGroup()
            for player in self.transitionPlayers {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                group.enter()
                player.preroll(atRate: 1) { succeeded in
                    if !succeeded {
                        resultLock.lock()
                        allPrerollsSucceeded = false
                        resultLock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self, self.isPlaying,
                      self.transitionPlaybackGeneration == generation,
                      !didStart else { return }
                self.transitionDrawablePoll = { [weak self] in
                    guard let self else { return }
                    guard self.isPlaying,
                          self.transitionPlaybackGeneration == generation,
                          !didStart else {
                        if self.transitionPlaybackGeneration == generation {
                            self.transitionDrawablePoll = nil
                        }
                        return
                    }
                    if synchronizedVideoLayers.allSatisfy(\.isReadyForDisplay) {
                        self.transitionDrawablePoll = nil
                        startSynchronizedPlayback()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                            guard let self, self.transitionPlaybackGeneration == generation else { return }
                            self.transitionDrawablePoll?()
                        }
                    }
                }
                self.transitionDrawablePoll?()
            }
        }
        var readyItems = Set<ObjectIdentifier>()
        let expectedReadyItems = transitionPlayers.compactMap(\.currentItem).count
        transitionItemStatusObservations = transitionPlayers.compactMap { player in
            guard let item = player.currentItem else { return nil }
            return item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.isPlaying,
                          self.transitionPlaybackGeneration == generation,
                          !didBeginPreroll else { return }
                    switch item.status {
                    case .readyToPlay:
                        readyItems.insert(ObjectIdentifier(item))
                        if readyItems.count == expectedReadyItems { beginPreroll() }
                    case .failed:
                        resultLock.lock()
                        allPrerollsSucceeded = false
                        resultLock.unlock()
                        retryPreparation("item failed to become ready")
                    default:
                        break
                    }
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !didStart, self.isPlaying,
                  self.transitionPlaybackGeneration == generation else { return }
            if self.isPaused {
                self.deferredWhilePaused.append { [weak self] in self?.transitionPrerollTimeout?.perform() }
                return
            }
            NSLog("SnoopyTVScreenSaver: transition preroll timeout stage=%@", stage.rawValue)
            retryPreparation("drawable/preroll timeout")
        }
        transitionPrerollTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: timeout)
        NSLog("SnoopyTVScreenSaver: transition prepared stage=%@ category=%@ pair=%@ parameters=%@ retainIdle=%d matteFrame=%@ sceneBounds=%@ heldActive=%d",
              stage.rawValue, selection.categoryID, selection.pairID, parameterID,
              selection.preventsIdleSceneChange ? 1 : 0,
              NSStringFromRect(viewport), NSStringFromRect(sceneLayer.frame),
              holdingActiveFrameForIdleEntry ? 1 : 0)
        return true
    }

    private func playRandomComposite(from store: AssetStore, context: SelectionContext) -> Bool {
        // SS/switcher assets are intentionally excluded from runtime playback.
        return playIdleCharacterComposite(from: store, context: context)
    }

    private struct PhasedVideoPlan {
        let urls: [URL]
        let sprite: SpriteRecord
        let loopCount: Int
        /// Trailing URLs that are the asset's Outro phase (0 for combined
        /// plans), so an AP loop can be cut at a loop boundary for a V2
        /// `AP_To_R**` shortcut without drawing a second loop count.
        var outroCount: Int = 0
        var urlsWithoutOutro: [URL] { Array(urls.dropLast(outroCount)) }
    }

    private struct VisitorPlaybackPlan {
        let assetID: String
        let media: PhasedVideoPlan
        let ignoresSceneOffset: Bool
        let isFullscreenEffect: Bool
        let isBackgroundPlane: Bool
    }

    private func phaseRank(_ sprite: SpriteRecord) -> Int {
        let phase = sprite.phase ?? sprite.contentPath ?? sprite.metadataPath ?? ""
        if phase.localizedCaseInsensitiveContains("intro") { return 0 }
        if phase.localizedCaseInsensitiveContains("loop") { return 1 }
        if phase.localizedCaseInsensitiveContains("outro") { return 2 }
        return 1
    }

    private func videoURL(for asset: AssetRecord, sprite: SpriteRecord, store: AssetStore) -> URL? {
        guard let base = sprite.assetBaseName else { return nil }
        if let directory = try? store.url(for: asset) {
            let name = asset.media?.first(where: { $0.name == base + ".mov" })?.name ?? base + ".mov"
            let original = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: original.path) { return original }
        }
        return derivedMediaStore?.url(assetID: asset.id, baseName: base)
    }

    private func phasedVideoPlan(
        for asset: AssetRecord, store: AssetStore,
        repeatOneShot: Bool = false, visitorLoop: Bool = false
    ) -> PhasedVideoPlan? {
        let sprites = asset.sprites.sorted { phaseRank($0) < phaseRank($1) }
        guard !sprites.isEmpty else { return nil }
        var intro: [URL] = []
        var loop: [URL] = []
        var outro: [URL] = []
        var representative: SpriteRecord?
        for sprite in sprites {
            guard let url = videoURL(for: asset, sprite: sprite, store: store) else { continue }
            representative = representative ?? sprite
            switch phaseRank(sprite) {
            case 0: intro.append(url)
            case 2: outro.append(url)
            default: loop.append(url)
            }
        }
        guard let representative, !(intro.isEmpty && loop.isEmpty && outro.isEmpty) else { return nil }
        let hasExplicitPhases = sprites.contains { sprite in
            let value = sprite.phase ?? sprite.contentPath ?? ""
            return value.localizedCaseInsensitiveContains("intro")
                || value.localizedCaseInsensitiveContains("loop")
                || value.localizedCaseInsensitiveContains("outro")
        }
        let isFrameSequenceProxy = sprites.contains { $0.spriteType == "frameSequence" }
        let loops: Int
        if let testLoops = ProcessInfo.processInfo.environment["SNOOPY_TEST_COMPOSITE_LOOPS"].flatMap(Int.init) {
            loops = max(1, testLoops)
        } else if asset.kind == "characterBasePose" {
            loops = sessionState.basePoseLoopCount(seed: seed)
        } else if asset.kind == "characterAdditionalPose" {
            // The HEVC-alpha proxy preserves the authored Intro/Loop/Outro
            // split. Apple repeats AP Loop to meet its duration pool; treating
            // every converted HEIC phase as a one-shot produced 1–2s scenes.
            loops = asset.id.hasPrefix("101_AP00")
                ? sessionState.sustainedAdditionalPoseLoopCount(seed: seed)
                : sessionState.additionalPoseLoopCount(seed: seed)
        } else if isFrameSequenceProxy {
            // HEIC sequences remain authored one-shots even when their
            // metadata happens to contain named phase folders. The HEVC-alpha
            // proxy is only a lower-CPU transport for that exact frame list.
            loops = 1
        } else if hasExplicitPhases, visitorLoop {
            loops = sessionState.visitorLoopCount(seed: seed)
        } else if hasExplicitPhases {
            // Native MOV animations repeat only their Loop phase; Intro and
            // Outro remain one-shot.
            loops = sessionState.loopCount(seed: seed)
        } else if repeatOneShot {
            loops = sessionState.restingLoopCount(seed: seed)
        } else {
            loops = 1
        }
        seed &+= 1
        var urls = intro
        var outroCount = 0
        if !hasExplicitPhases && !repeatOneShot {
            urls.append(contentsOf: loop)
            urls.append(contentsOf: outro)
        } else if loop.isEmpty {
            urls.append(contentsOf: outro)
            outroCount = outro.count
        } else {
            for _ in 0..<loops { urls.append(contentsOf: loop) }
            urls.append(contentsOf: outro)
            outroCount = outro.count
        }
        return PhasedVideoPlan(urls: urls, sprite: representative, loopCount: loops, outroCount: outroCount)
    }

    private func startVideoComposition(
        assetID: String,
        backgroundImage: URL?,
        backgroundVideo: URL? = nil,
        backgroundSprite: SpriteRecord?,
        plan: PhasedVideoPlan,
        palette: (background: NSColor, overlay: NSColor?),
        pendingPoseID: String?,
        visitor: VisitorPlaybackPlan? = nil,
        characterAnimationKind: CharacterAnimationKind? = nil,
        holdBoundaryAfterSegment: Int? = nil
    ) -> Bool {
        guard !plan.urls.isEmpty else { return false }
        let estimatedSeconds = estimatedDuration(of: plan.urls)
        let visitorSeconds = visitor.map { estimatedDuration(of: $0.media.urls) } ?? 0
        var visitorInstalled = false
        installCompositeBackdrop(backgroundImage: backgroundImage, backgroundVideo: backgroundVideo,
                                 backgroundSprite: backgroundSprite, palette: palette)
        if let visitor, visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        self.foregroundSprite = plan.sprite
        let frame = compositeFrame(for: plan.sprite)
        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let isReplacingRetainedSurface = hasRetiringPlaybackSurface
        // An opacity of zero can keep AVPlayerLayer out of the render tree and
        // prevent readyForDisplay from ever becoming true. Keep the incoming
        // tree participating in composition without making it perceptible.
        host.layer?.opacity = isReplacingRetainedSurface ? 0.001 : 1
        addSubview(host)
        compositeVideoHostView = host

        guard let composition = seamlessComposition(for: plan.urls) else { return false }
        let seamlessItem = composition.item
        // The logical end of a reaction hold item: the enter's last frame.
        // Playback "finishes" there while the hold repeats keep the retiring
        // surface animating until the reveal tree replaces it.
        let holdBoundaryTime: CMTime? = holdBoundaryAfterSegment.flatMap { index in
            index >= 0 && index < composition.segmentEnds.count ? composition.segmentEnds[index] : nil
        }
        let compositionEndSeconds = composition.segmentEnds.last?.seconds ?? 0
        // A multi-item AVQueuePlayer briefly exposes the transparent backdrop
        // while VideoToolbox switches decoders between Intro/Loop/Outro or an
        // action and its returning BasePose. A single composition item lets
        // AVFoundation pre-roll the complete authored timeline without an
        // item-boundary drawable gap. Do not put that sole item back into an
        // advancing AVQueuePlayer: advancing the final item clears currentItem
        // before the end notification can retain its last drawable.
        let items = [seamlessItem]
        let queue = AVPlayer(playerItem: seamlessItem)
        queue.defaultRate = Float(playbackRate)
        queue.actionAtItemEnd = .pause
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.frame = host.bounds
        videoLayer.videoGravity = .resize
        videoLayer.backgroundColor = NSColor.clear.cgColor
        host.layer?.addSublayer(videoLayer)
        // AVAssetImageGenerator does not reproduce every HEVC-alpha first
        // frame exactly. It is safe for a cold start, but must never replace a
        // retained authored surface during an internal composite handoff.
        if !isReplacingRetainedSurface, let image = videoPlaceholderImage(at: plan.urls[0]) {
            let placeholder = CALayer()
            placeholder.frame = host.bounds
            placeholder.contents = image
            placeholder.contentsGravity = .resize
            placeholder.backgroundColor = NSColor.clear.cgColor
            host.layer?.addSublayer(placeholder)
            compositeVideoPlaceholderLayer = placeholder
        }
        keepRetiringPlaybackSurfaceAbove(host)
        if let visitor, !visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        let visitorControlsCompletion = visitorInstalled && visitorSeconds > estimatedSeconds
        // Foreground visitors are installed after the incoming character host.
        // Re-establish the retained character/reveal directly above the
        // incoming host while leaving foreground visitors above both.
        keepRetiringPlaybackSurfaceAbove(host)
        player = queue
        compositeVideoLayer = videoLayer
        currentAssetID = assetID
        self.pendingBasePoseID = pendingPoseID
        isPlaying = true
        NSLog("SnoopyTVScreenSaver: hardware composition %@ items=%ld loops=%d visitorDuration=%.3f frame=%@",
              assetID, plan.urls.count, plan.loopCount, visitorSeconds, NSStringFromRect(frame))

        // Short BP_To_BP and reaction clips can finish almost completely
        // before an unprimed AVPlayerLayer presents its first drawable. Require
        // both a successful preroll and an actual layer drawable before the
        // old authored surface is atomically exchanged for the new one.
        compositePlaybackGeneration &+= 1
        let generation = compositePlaybackGeneration
        var didBeginPreroll = false
        var didFinishPreroll = false
        var didStart = false
        var abandonIncoming: ((String) -> Void)!

        abandonIncoming = { [weak self, weak queue, weak host] reason in
            guard let self, let queue, let host, !didStart,
                  self.compositePlaybackGeneration == generation,
                  self.player === queue else { return }
            didStart = true
            self.compositePrerollTimeout?.cancel()
            self.compositePrerollTimeout = nil
            self.compositeDrawablePoll = nil
            self.compositeVideoReadyObservation = nil
            self.compositeItemStatusObservation = nil
            if let observer = self.playerEndObserver { NotificationCenter.default.removeObserver(observer) }
            if let observer = self.playerFailureObserver { NotificationCenter.default.removeObserver(observer) }
            self.playerEndObserver = nil
            self.playerFailureObserver = nil
            self.compositeVideoPlaceholderLayer?.removeFromSuperlayer()
            self.compositeVideoPlaceholderLayer = nil
            self.teardownPlayerLayer(videoLayer)
            self.teardownPlayer(queue)
            self.teardownPlayerLayers(in: host.layer)
            host.removeFromSuperview()
            self.player = nil
            self.compositeVideoLayer = nil
            self.compositeVideoHostView = nil
            self.currentAssetID = nil
            self.pendingBasePoseID = nil
            self.isPlaying = false
            self.compositePlaybackGeneration &+= 1
            NSLog("SnoopyTVScreenSaver: discarded unready composite %@ (%@); retaining outgoing surface",
                  assetID, reason)
            self.scheduleNext(after: 0.1)
        }

        compositeDrawablePoll = { [weak self, weak queue, weak videoLayer, weak host] in
            guard let self else { return }
            guard let queue, let videoLayer, let host else {
                if self.compositePlaybackGeneration == generation {
                    self.compositeDrawablePoll = nil
                }
                return
            }
            guard !didStart, self.isPlaying,
                  self.compositePlaybackGeneration == generation,
                  self.player === queue else {
                if self.compositePlaybackGeneration == generation {
                    self.compositeDrawablePoll = nil
                }
                return
            }
            guard didFinishPreroll, videoLayer.isReadyForDisplay else { return }
            if let backgroundLayer = self.backgroundVideoLayer,
               !backgroundLayer.isReadyForDisplay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                    guard let self, self.compositePlaybackGeneration == generation else { return }
                    self.compositeDrawablePoll?()
                }
                return
            }
            didStart = true
            self.compositeDrawablePoll = nil
            self.compositePrerollTimeout?.cancel()
            self.compositePrerollTimeout = nil
            self.compositeVideoReadyObservation = nil
            self.compositeItemStatusObservation = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.layer?.opacity = 1
            self.backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
            self.backgroundVideoPlaceholderLayer = nil
            self.backgroundVideoReadyObservation = nil
            self.compositeVideoPlaceholderLayer?.removeFromSuperlayer()
            self.compositeVideoPlaceholderLayer = nil
            self.retirePreviousPlaybackSurfaces()
            CATransaction.commit()
            self.revealStartupFadeIfNeeded()
            if let characterAnimationKind {
                self.sessionState.recordCharacterAnimation(characterAnimationKind, duration: estimatedSeconds)
            }
            self.installWatchdog(defaultSeconds: max(estimatedSeconds, visitorSeconds) + 3)
            queue.play()
            if let boundary = holdBoundaryTime {
                self.playerBoundaryObserver = queue.addBoundaryTimeObserver(
                    forTimes: [NSValue(time: boundary)], queue: .main
                ) { [weak self, weak queue] in
                    DispatchQueue.main.async {
                        guard let self, let queue, self.player === queue, self.isPlaying,
                              self.compositePlaybackGeneration == generation else { return }
                        // No visitor may outlive this item: its end observer
                        // survives the preserving cleanup and would abort the
                        // reveal stage from inside its preroll.
                        self.removeVisitorPlayback()
                        self.retiringSurfaceKeepsPlaying = true
                        NSLog("SnoopyTVScreenSaver: reaction hold %@ reached logical end at %.3f (item end %.3f); keeps playing while the next stage prerolls",
                              assetID, boundary.seconds, compositionEndSeconds)
                        self.finishCurrentPlayback("reaction hold boundary")
                    }
                }
            }
            NSLog("SnoopyTVScreenSaver: composite surface committed %@ time=%.3f",
                  assetID, queue.currentTime().seconds)
        }

        compositeVideoReadyObservation = videoLayer.observe(
            \.isReadyForDisplay, options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.compositePlaybackGeneration == generation else { return }
                self.compositeDrawablePoll?()
            }
        }
        compositeItemStatusObservation = queue.observe(
            \.status, options: [.initial, .new]
        ) { [weak self, weak queue] player, _ in
            DispatchQueue.main.async {
                guard let self, let queue, !didBeginPreroll, !didStart,
                      self.isPlaying, self.compositePlaybackGeneration == generation,
                      self.player === queue else { return }
                switch player.status {
                case .readyToPlay:
                    didBeginPreroll = true
                    queue.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    queue.preroll(atRate: 1) { succeeded in
                        DispatchQueue.main.async {
                            if succeeded {
                                didFinishPreroll = true
                                guard self.compositePlaybackGeneration == generation else { return }
                                self.compositeDrawablePoll?()
                            } else {
                                abandonIncoming("preroll failed")
                            }
                        }
                    }
                case .failed:
                    abandonIncoming("player failed to become ready")
                default:
                    break
                }
            }
        }
        if let last = items.last {
            playerEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: last, queue: .main
            ) { [weak self, weak queue] _ in
                // Keep currentItem and its final decoded frame attached until
                // the next MOV/HEIC surface has committed in one transaction.
                queue?.pause()
                NSLog("SnoopyTVScreenSaver: composite MOV ended currentItemRetained=%d",
                      queue?.currentItem === last ? 1 : 0)
                if !visitorControlsCompletion {
                    self?.finishCurrentPlayback("phased video ended")
                }
            }
        }
        playerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let failedItem = note.object as? AVPlayerItem,
                  items.contains(where: { $0 === failedItem }) else { return }
            NSLog("SnoopyTVScreenSaver: phased video failed %@", String(describing: note.userInfo))
            if didStart {
                self?.finishCurrentPlayback("phased video failed")
            } else {
                abandonIncoming("video failed before first drawable")
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !didStart, self.isPlaying,
                  self.compositePlaybackGeneration == generation else { return }
            if self.isPaused {
                self.deferredWhilePaused.append { [weak self] in self?.compositePrerollTimeout?.perform() }
                return
            }
            NSLog("SnoopyTVScreenSaver: composite preroll timeout %@", assetID)
            abandonIncoming("drawable/preroll timeout")
        }
        compositePrerollTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)
        return true
    }

    private func estimatedDuration(of urls: [URL]) -> TimeInterval {
        urls.reduce(0.0) { partial, url in
            let seconds = AVURLAsset(url: url).duration.seconds
            return partial + (seconds.isFinite && seconds > 0 ? seconds : 2)
        }
    }

    private func seamlessVideoItem(for urls: [URL]) -> AVPlayerItem? {
        seamlessComposition(for: urls)?.item
    }

    /// One composition item for `urls` plus the composition time at which each
    /// segment ends (after per-segment proxy trims), for boundary observers.
    private func seamlessComposition(for urls: [URL]) -> (item: AVPlayerItem, segmentEnds: [CMTime])? {
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        var cursor = CMTime.zero
        var segmentEnds: [CMTime] = []
        var copiedTransform = false
        var assetCache: [URL: AVURLAsset] = [:]
        do {
            for url in urls {
                let asset: AVURLAsset
                if let cached = assetCache[url] {
                    asset = cached
                } else {
                    let created = AVURLAsset(url: url)
                    assetCache[url] = created
                    asset = created
                }
                guard let source = asset.tracks(withMediaType: .video).first else { return nil }
                let duration = asset.duration
                guard duration.isValid, CMTimeCompare(duration, .zero) > 0 else { return nil }
                if !copiedTransform {
                    destination.preferredTransform = source.preferredTransform
                    copiedTransform = true
                }
                let trimSeconds = derivedMediaStore?.proxy(for: url)?.leadingDecodeTrim ?? 0
                let sourceStart = CMTime(seconds: trimSeconds, preferredTimescale: 600)
                let sourceDuration = CMTimeSubtract(duration, sourceStart)
                guard sourceDuration.isValid, CMTimeCompare(sourceDuration, .zero) > 0 else { return nil }
                try destination.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: sourceDuration), of: source, at: cursor
                )
                cursor = CMTimeAdd(cursor, sourceDuration)
                segmentEnds.append(cursor)
            }
        } catch {
            NSLog("SnoopyTVScreenSaver: unable to assemble seamless composite item %@",
                  String(describing: error))
            return nil
        }
        guard CMTimeCompare(cursor, .zero) > 0 else { return nil }
        return (AVPlayerItem(asset: composition), segmentEnds)
    }

    @discardableResult
    private func installVisitor(_ visitor: VisitorPlaybackPlan, finishesPlayback: Bool) -> Bool {
        guard visitorPlayer == nil else { return false }
        let items = visitor.media.urls.map(AVPlayerItem.init(url:))
        guard !items.isEmpty else { return false }
        let queue = AVQueuePlayer(items: items)
        queue.defaultRate = Float(playbackRate)
        queue.actionAtItemEnd = .advance
        queue.isMuted = true
        let frame = visitor.isFullscreenEffect
            ? playbackViewportFrame()
            : compositeFrame(for: visitor.media.sprite, ignoresSceneOffset: visitor.ignoresSceneOffset)
        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.frame = host.bounds
        videoLayer.videoGravity = .resize
        videoLayer.backgroundColor = NSColor.clear.cgColor
        host.layer?.addSublayer(videoLayer)
        if let image = videoPlaceholderImage(at: visitor.media.urls[0]) {
            let placeholder = CALayer()
            placeholder.frame = host.bounds
            placeholder.contents = image
            placeholder.contentsGravity = .resize
            placeholder.backgroundColor = NSColor.clear.cgColor
            host.layer?.addSublayer(placeholder)
            visitorPlaceholderLayer = placeholder
            visitorReadyObservation = videoLayer.observe(
                \.isReadyForDisplay, options: [.initial, .new]
            ) { [weak self, weak videoLayer] _, _ in
                guard videoLayer?.isReadyForDisplay == true else { return }
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self?.visitorPlaceholderLayer?.removeFromSuperlayer()
                    self?.visitorPlaceholderLayer = nil
                    self?.visitorReadyObservation = nil
                    CATransaction.commit()
                }
            }
        }
        addSubview(host)
        visitorPlayer = queue
        visitorLayer = videoLayer
        visitorHostView = host
        visitorSprite = visitor.media.sprite
        visitorIgnoresSceneOffset = visitor.ignoresSceneOffset || visitor.isFullscreenEffect
        visitorIsFullscreenEffect = visitor.isFullscreenEffect
        if let last = items.last {
            visitorEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: last, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if finishesPlayback {
                    self.finishCurrentPlayback("visitor duration completed")
                } else {
                    self.removeVisitorPlayback()
                }
            }
        }
        queue.play()
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_VISITOR_ID"] == nil,
           nextVisitorScheduleIndex < visitorScheduleTimes.count {
            let elapsed = idleSceneStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            NSLog("SnoopyTVScreenSaver: visitor schedule fired index=%d target=%.1f actual=%.1f",
                  nextVisitorScheduleIndex, visitorScheduleTimes[nextVisitorScheduleIndex], elapsed)
            nextVisitorScheduleIndex += 1
        }
        let planeName = visitor.media.sprite.plane ?? "unknown"
        NSLog("SnoopyTVScreenSaver: visitor %@ items=%ld fullscreen=%d plane=%@",
              visitor.assetID, items.count, visitor.isFullscreenEffect ? 1 : 0, planeName)
        return true
    }

    private func removeVisitorPlayback() {
        if let observer = visitorEndObserver { NotificationCenter.default.removeObserver(observer) }
        visitorEndObserver = nil
        teardownPlayerLayer(visitorLayer)
        teardownPlayer(visitorPlayer)
        visitorPlayer = nil
        visitorReadyObservation = nil
        visitorPlaceholderLayer?.removeFromSuperlayer()
        visitorPlaceholderLayer = nil
        visitorLayer = nil
        teardownPlayerLayers(in: visitorHostView?.layer)
        visitorHostView?.removeFromSuperview()
        visitorHostView = nil
        visitorSprite = nil
        visitorIgnoresSceneOffset = false
        visitorIsFullscreenEffect = false
    }

    private func installCompositeBackdrop(
        backgroundImage: URL?, backgroundVideo: URL? = nil, backgroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?)
    ) {
        layer?.backgroundColor = palette.background.cgColor
        // CharacterAnimationManager keeps one IdleScene alive while BP/AP/CM
        // foreground animations change. Reuse that exact background tree so
        // a decoder/preroll boundary cannot expose the root black layer.
        if backgroundColorView != nil {
            backgroundColorView?.layer?.backgroundColor = palette.background.cgColor
            return
        }
        let colorView = NSView(frame: bounds)
        colorView.autoresizingMask = [.width, .height]
        colorView.wantsLayer = true
        colorView.layer?.backgroundColor = palette.background.cgColor
        addSubview(colorView)
        backgroundColorView = colorView
        if let overlay = palette.overlay {
            let view = NSView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            view.layer?.backgroundColor = overlay.cgColor
            addSubview(view)
            overlayView = view
        }
        if let url = halftoneImageURL(), let image = NSImage(contentsOf: url) {
            let view = NSImageView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.alphaValue = 0.1
            addSubview(view)
            halftoneView = view
        }
        self.backgroundSprite = backgroundSprite
        if let backgroundVideo {
            let frame = compositeFrame(for: backgroundSprite)
            let host = NSView(frame: frame)
            host.wantsLayer = true
            let queue = AVQueuePlayer()
            queue.defaultRate = Float(playbackRate)
            queue.isMuted = true
            let item = AVPlayerItem(url: backgroundVideo)
            let looper = AVPlayerLooper(player: queue, templateItem: item)
            let videoLayer = AVPlayerLayer(player: queue)
            videoLayer.frame = host.bounds
            videoLayer.videoGravity = .resize
            videoLayer.backgroundColor = NSColor.clear.cgColor
            host.layer?.addSublayer(videoLayer)
            if let image = videoPlaceholderImage(at: backgroundVideo) {
                let placeholder = CALayer()
                placeholder.frame = host.bounds
                placeholder.contents = image
                placeholder.contentsGravity = .resize
                placeholder.backgroundColor = NSColor.clear.cgColor
                host.layer?.addSublayer(placeholder)
                backgroundVideoPlaceholderLayer = placeholder
                backgroundVideoReadyObservation = videoLayer.observe(
                    \.isReadyForDisplay, options: [.initial, .new]
                ) { [weak self, weak videoLayer] _, _ in
                    guard videoLayer?.isReadyForDisplay == true else { return }
                    DispatchQueue.main.async {
                        self?.backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
                        self?.backgroundVideoPlaceholderLayer = nil
                        self?.backgroundVideoReadyObservation = nil
                    }
                }
            }
            addSubview(host)
            backgroundVideoHostView = host
            backgroundVideoLayer = videoLayer
            backgroundVideoPlayer = queue
            backgroundVideoLooper = looper
            queue.play()
        }
        if let backgroundImage,
           let cgImage = decodedCGImage(at: backgroundImage, maxPixelSize: maximumPixelSize(for: backgroundSprite)) {
            let view = NSImageView(frame: compositeFrame(for: backgroundSprite))
            view.image = NSImage(cgImage: cgImage, size: view.frame.size)
            view.imageScaling = .scaleAxesIndependently
            addSubview(view)
            backgroundImageView = view
        }
        NSLog("SnoopyTVScreenSaver: composite backdrop image=%d video=%d halftone=%d overlay=%d frame=%@",
              backgroundImage != nil ? 1 : 0, backgroundVideo != nil ? 1 : 0,
              halftoneView != nil ? 1 : 0, palette.overlay != nil ? 1 : 0,
              NSStringFromRect(compositeFrame(for: backgroundSprite)))
    }

    private func playIdleCharacterComposite(from store: AssetStore, context: SelectionContext) -> Bool {
        let eligible = store.eligible(store.playableAssets(), on: context.date)
        var idleAssets = eligible.filter { $0.kind == "idleScene" }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_IDLE_ID"] {
            idleAssets = idleAssets.filter { $0.id == forcedID }
        }
        let idle: AssetRecord
        if let currentID = sessionState.currentIdleSceneID,
           let current = idleAssets.first(where: { $0.id == currentID }) {
            idle = current
        } else {
            guard let selected = chooseIdleScene(from: idleAssets, context: context) else { return false }
            idle = selected
            beginIdleScene(selected.id)
            currentPaletteAssetID = nil
        }
        guard let idleDirectory = try? store.url(for: idle) else { return false }
        currentSceneOffset = idle.idleScene?.sceneOffset
        let backgroundSprite = idle.sprites.first
        let backgroundImageURL = firstHEICName(in: idle).map { idleDirectory.appendingPathComponent($0) }
        let backgroundVideoURL = idle.sprites.first(where: { $0.spriteType == "video" })
            .flatMap { videoURL(for: idle, sprite: $0, store: store) }
        guard backgroundImageURL != nil || backgroundVideoURL != nil else { return false }
        idleSceneAnimationCount += 1
        let palette = paletteColors(from: store, context: context, idleScene: idle)
        if pendingCharacterAssetIDs.isEmpty, pendingSceneStages.isEmpty,
           let entrySequence = pendingIdleEntrySequence {
            pendingIdleEntrySequence = nil
            // The hide's ST clip brought the character back at RPH and this
            // entry returns it to a BP: no park can be outstanding here.
            parkedCharacter = nil
            sessionState.currentBasePoseID = entrySequence.endPoseID
            return playCharacterSequence(
                entrySequence, idle: idle,
                backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
                backgroundSprite: backgroundSprite, palette: palette, store: store, visitor: nil
            )
        }
        // The numeric prefix is an authoring wave, not a character family.
        // All four base poses are 101 assets while later 102/103/104 idle
        // scenes and actions deliberately reference those same 101_BP states.
        // Prefix-scoping here caused pose teleports on every later scene.
        var posePool = eligible.filter { $0.kind == "characterBasePose" }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_POSE_ID"] {
            posePool = posePool.filter { $0.id == forcedID }
        }
        let pose: AssetRecord
        if let currentID = sessionState.currentBasePoseID,
           let current = posePool.first(where: { $0.id == currentID }) {
            pose = current
        } else {
            guard let selected = sessionChoice(from: posePool, pool: "basePoses", context: context) else { return false }
            pose = selected
            sessionState.currentBasePoseID = selected.id
        }
        let stage = IdleSceneStage(
            idle: idle, backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
            backgroundSprite: backgroundSprite, palette: palette
        )
        if pendingCharacterAssetIDs.isEmpty, pendingSceneStages.isEmpty,
           let parked = parkedCharacter, let graph = playbackGraph {
            // Safety net: a park that no scene transition consumed (an env
            // override chose a composite, or the idle scene was cleared)
            // returns to its BP through the style's exit, as the hide entry does.
            parkedCharacter = nil
            let target = posePool.contains { $0.id == parked.returnPoseID } ? parked.returnPoseID : pose.id
            if let entry = graph.idleEntrySequence(to: target, style: parked.style) {
                NSLog("SnoopyTVScreenSaver: reaction unparked: %@ -> %@ (no scene transition consumed the park)",
                      ReactionStyle.nodeID(for: parked.style), target)
                sessionState.currentBasePoseID = target
                return playCharacterSequence(
                    entry, idle: idle,
                    backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
                    backgroundSprite: backgroundSprite, palette: palette, store: store, visitor: nil
                )
            }
            NSLog("SnoopyTVScreenSaver: ERROR reaction unpark impossible for style %@; continuing from %@",
                  parked.style, pose.id)
        }
        // A queued BP transition/reaction/action must finish against the same
        // idle scene and palette. This mirrors CharacterAnimationManager's
        // pendingAnimationQueue instead of re-randomizing every segment.
        if !pendingCharacterAssetIDs.isEmpty {
            let nextID = pendingCharacterAssetIDs.removeFirst()
            guard let segment = playbackGraph?.assetsByID[nextID] else { return false }
            return playCharacterSegment(segment, idle: idle, currentPose: pose.id,
                                        backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
                                        backgroundSprite: backgroundSprite,
                                        palette: palette, store: store, visitor: nil)
        }
        let elapsedInIdleScene = idleSceneStartedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        let forcedVisitor = ProcessInfo.processInfo.environment["SNOOPY_FORCE_VISITOR_ID"] != nil
        let visitorIsDue = nextVisitorScheduleIndex < visitorScheduleTimes.count
            && elapsedInIdleScene >= visitorScheduleTimes[nextVisitorScheduleIndex]
        let visitor = (forcedVisitor || visitorIsDue)
            ? visitorPlaybackPlan(for: idle, among: eligible, context: context, store: store)
            : nil
        var coupledContext = context
        if visitor?.isFullscreenEffect == true {
            coupledContext.activeCategories.insert("sceneFullscreenEffectVisitor")
        }
        // This is "the next character boundary" of tvOS's reactionTriggerEvent:
        // the character rests in a BP, the room and palette are resolved and
        // nothing is queued. A fresh trigger is consumed here, whatever the
        // mix asked for; the reaction replaces that animation (A/B below).
        var reactionEvent: ReactionTriggerEvent?
        if pendingSceneStages.isEmpty, parkedCharacter == nil {
            if let armed = startupReactionTrigger, idleSceneAnimationCount >= 2 {
                startupReactionTrigger = nil
                fireReactionTrigger(armed, source: "env")
            }
            reactionEvent = consumeFreshReactionTrigger()
        }

        let forcedCharacterKind = ProcessInfo.processInfo.environment["SNOOPY_FORCE_CHARACTER_KIND"]
        let additionalActions = playbackGraph?.characterActions(
            ofKind: "characterAdditionalPose", for: idle, among: eligible
        ) ?? []
        let moments = playbackGraph?.characterActions(
            ofKind: "characterMoment", for: idle, among: eligible
        ) ?? []
        let requestedActionKind: String?
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_BASE_POSE_ONLY"] == "1"
            || forcedCharacterKind == "base" {
            requestedActionKind = nil
        } else if forcedCharacterKind == "additional" {
            requestedActionKind = "characterAdditionalPose"
        } else if forcedCharacterKind == "moment" {
            requestedActionKind = "characterMoment"
        } else {
            var available: Set<CharacterAnimationKind> = [.basePose]
            if additionalActions.contains(where: {
                playbackGraph?.animationQueue(currentPoseID: pose.id, target: $0) != nil
            }) {
                available.insert(.additionalPose)
            }
            if moments.contains(where: {
                playbackGraph?.animationQueue(currentPoseID: pose.id, target: $0) != nil
            }) {
                available.insert(.moment)
            }
            switch sessionState.nextCharacterAnimationKind(available: available, seed: seed) {
            case .additionalPose: requestedActionKind = "characterAdditionalPose"
            case .moment: requestedActionKind = "characterMoment"
            default: requestedActionKind = nil
            }
            NSLog("SnoopyTVScreenSaver: character ratios base=%.3f additional=%.3f moment=%.3f next=%@",
                  sessionState.characterRatio(for: .basePose),
                  sessionState.characterRatio(for: .additionalPose),
                  sessionState.characterRatio(for: .moment),
                  requestedActionKind ?? "basePose")
        }
        var allActions: [AssetRecord]
        switch requestedActionKind {
        case "characterAdditionalPose": allActions = additionalActions
        case "characterMoment": allActions = moments
        default: allActions = []
        }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_CHARACTER_ASSET_ID"] {
            allActions = allActions.filter { $0.id == forcedID }
        }
        if let reactionEvent {
            // "A reactionPose was queued for %s, skipping standard idle
            // animation." From an AP the loop is cut short and the outro
            // skipped (AP_To_R**); otherwise the reaction starts from the BP.
            // Neither path could build a complete, playable sequence: the
            // standard idle animation plays instead.
            if requestedActionKind == "characterAdditionalPose",
               let started = playReactionFromAdditionalPose(
                   reactionEvent, from: pose, actions: allActions, in: stage, store: store,
                   visitor: visitor, context: coupledContext
               ) {
                return started
            }
            if let started = playReaction(
                reactionEvent, from: pose, in: stage, store: store, visitor: visitor, context: coupledContext
            ) {
                return started
            }
        }
        let sequence = characterAnimationSequence(
            startingAt: pose.id, actions: allActions, context: coupledContext
        )
        if let sequence {
            if let started = playRotationParkedSequence(
                sequence, from: pose, in: stage, store: store, visitor: visitor
            ) {
                return started
            }
            return playCharacterSequence(
                sequence, idle: idle,
                backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
                backgroundSprite: backgroundSprite, palette: palette, store: store, visitor: visitor
            )
        }
        if let plan = phasedVideoPlan(for: pose, store: store, repeatOneShot: true) {
            return startVideoComposition(
                assetID: "\(idle.id)+\(pose.id)", backgroundImage: backgroundImageURL,
                backgroundVideo: backgroundVideoURL,
                backgroundSprite: backgroundSprite, plan: plan, palette: palette,
                pendingPoseID: pose.id, visitor: visitor, characterAnimationKind: .basePose
            )
        }
        let frames = phasedFrameURLs(for: pose, store: store, minimumDuration: 0)
        guard !frames.isEmpty else { return false }
        return startFrameComposition(
            assetID: "\(idle.id)+\(pose.id)",
            backgroundImage: backgroundImageURL,
            backgroundVideo: backgroundVideoURL,
            backgroundSprite: backgroundSprite,
            frameURLs: frames,
            foregroundSprite: pose.sprites.first(where: { $0.spriteType == "frameSequence" }),
            palette: palette,
            pendingPoseID: pose.id, visitor: visitor, characterAnimationKind: .basePose
        )
    }

    /// Apple's CharacterAnimationManager chooses a relevant AP/Moment first,
    /// then resolves the current BP to that asset's authored From_BP through
    /// pendingAnimationQueue. Restricting selection to actions that already
    /// started at the current pose made every A node favor the same outgoing
    /// edge and left BP_A_To_BP_B/C assets unused.
    private func characterAnimationSequence(
        startingAt startPoseID: String, actions: [AssetRecord], context: SelectionContext
    ) -> CharacterPlaybackSequence? {
        guard let graph = playbackGraph else { return nil }
        let reachable = actions.filter {
            graph.actionSequence(currentPoseID: startPoseID, target: $0) != nil
        }
        guard let target = sessionChoice(
            from: reachable, pool: "characterActions", context: context
        ), let sequence = graph.actionSequence(currentPoseID: startPoseID, target: target) else {
            return nil
        }
        NSLog("SnoopyTVScreenSaver: character queue %@",
              sequence.assets.map { "\($0.id)[\($0.startCharacterBasePoseID ?? "?")->\($0.endCharacterBasePoseID ?? "?")]" }
                .joined(separator: " -> "))
        return sequence
    }

    /// The resolved room a character item is composed against.
    private struct IdleSceneStage {
        let idle: AssetRecord
        let backgroundImageURL: URL?
        let backgroundVideoURL: URL?
        let backgroundSprite: SpriteRecord?
        let palette: (background: NSColor, overlay: NSColor?)
    }

    private func playCharacterSequence(
        _ sequence: CharacterPlaybackSequence, idle: AssetRecord,
        backgroundImageURL: URL?, backgroundVideoURL: URL?, backgroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?), store: AssetStore,
        visitor: VisitorPlaybackPlan?
    ) -> Bool {
        let stage = IdleSceneStage(
            idle: idle, backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
            backgroundSprite: backgroundSprite, palette: palette
        )
        guard let plans = characterPlans(for: sequence, store: store) else {
            return playCharacterSequenceFallback(sequence, in: stage, store: store, visitor: visitor)
        }
        return playCharacterPlans(
            plans, assetIDs: sequence.assets.map(\.id), endPoseID: sequence.endPoseID,
            in: stage, visitor: visitor
        )
    }

    /// The seamless plan of every asset in `sequence`, built in order. Stops
    /// at the first asset without one and returns nil there, so the seed
    /// advances exactly as it always has on the HEIC-fallback path.
    private func characterPlans(for sequence: CharacterPlaybackSequence, store: AssetStore) -> [PhasedVideoPlan]? {
        var plans: [PhasedVideoPlan] = []
        for asset in sequence.assets {
            let repeatBase = asset.kind == "characterBasePose"
            guard let plan = phasedVideoPlan(for: asset, store: store, repeatOneShot: repeatBase) else { return nil }
            plans.append(plan)
        }
        return plans
    }

    /// Keep the graph intact on the HEIC fallback path. The legacy segment
    /// player still retains the previous surface between each node, and
    /// action/RPH nodes append their target BP.
    private func playCharacterSequenceFallback(
        _ sequence: CharacterPlaybackSequence, in stage: IdleSceneStage, store: AssetStore,
        visitor: VisitorPlaybackPlan?
    ) -> Bool {
        var fallback = sequence.assets
        if fallback.last?.kind == "characterBasePose" { fallback.removeLast() }
        guard let first = fallback.first else { return false }
        pendingCharacterAssetIDs = Array(fallback.dropFirst()).map(\.id)
        return playCharacterSegment(
            first, idle: stage.idle, currentPose: sequence.startPoseID,
            backgroundImageURL: stage.backgroundImageURL, backgroundVideoURL: stage.backgroundVideoURL,
            backgroundSprite: stage.backgroundSprite, palette: stage.palette, store: store, visitor: visitor
        )
    }

    /// One seamless item for an already-planned character sequence.
    private func playCharacterPlans(
        _ plans: [PhasedVideoPlan], assetIDs: [String], endPoseID: String,
        in stage: IdleSceneStage, visitor: VisitorPlaybackPlan?,
        holdBoundaryAfterSegment: Int? = nil
    ) -> Bool {
        guard let firstPlan = plans.first else { return false }
        let combined = PhasedVideoPlan(
            urls: plans.flatMap(\.urls), sprite: firstPlan.sprite,
            loopCount: plans.reduce(0) { $0 + $1.loopCount }
        )
        return startVideoComposition(
            assetID: "\(stage.idle.id)+" + assetIDs.joined(separator: "+"),
            backgroundImage: stage.backgroundImageURL, backgroundVideo: stage.backgroundVideoURL,
            backgroundSprite: stage.backgroundSprite, plan: combined, palette: stage.palette,
            pendingPoseID: endPoseID, visitor: visitor,
            holdBoundaryAfterSegment: holdBoundaryAfterSegment
        )
    }

    private func playCharacterSegment(
        _ asset: AssetRecord, idle: AssetRecord, currentPose: String,
        backgroundImageURL: URL?, backgroundVideoURL: URL?, backgroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?), store: AssetStore,
        visitor: VisitorPlaybackPlan?
    ) -> Bool {
        let endPose: String
        if asset.kind == "characterReactionTransitionPose", asset.phase?.kind == "exit" {
            endPose = asset.phase?.endCharacterPoseID ?? currentPose
        } else {
            endPose = normalizedEndPoseID(for: asset) ?? currentPose
        }
        let animationKind: CharacterAnimationKind?
        switch asset.kind {
        case "characterAdditionalPose": animationKind = .additionalPose
        case "characterMoment": animationKind = .moment
        case "characterBasePose": animationKind = .basePose
        default: animationKind = nil
        }
        let isIdleExitEnter = asset.kind == "characterReactionTransitionPose"
            && asset.phase?.kind == "enter" && nextStageIsActiveSceneWithReveal
        if let plan = phasedVideoPlan(for: asset, store: store) {
            if isIdleExitEnter, let graph = playbackGraph,
               let tail = reactionHoldTail(style: graph.reactionStyle(of: asset), store: store) {
                // Instead of freezing on the enter's last frame while the
                // ActiveScene + Reveal preroll, the character keeps breathing
                // in the generic hold. The boundary at the enter's end
                // finishes this segment; the hold repeats keep playing on the
                // retiring surface until the reveal commit tears it down.
                let combined = PhasedVideoPlan(
                    urls: plan.urls + tail.plan.urls, sprite: plan.sprite,
                    loopCount: plan.loopCount + tail.repeats
                )
                NSLog("SnoopyTVScreenSaver: reaction hold: %@ then %@ x%d (%.1fs) while the scene transition prerolls",
                      asset.id, tail.hold.id, tail.repeats, estimatedDuration(of: plan.urls) + tail.seconds)
                let started = startVideoComposition(
                    assetID: "\(idle.id)+\(asset.id)+\(tail.hold.id)x\(tail.repeats)",
                    backgroundImage: backgroundImageURL,
                    backgroundVideo: backgroundVideoURL,
                    backgroundSprite: backgroundSprite, plan: combined,
                    palette: palette, pendingPoseID: endPose, visitor: nil,
                    holdBoundaryAfterSegment: plan.urls.count - 1
                )
                // Park only once the hold item is really under way: a failed
                // composition leaves no RPH surface for the transition to use.
                if started {
                    parkedCharacter = ParkedCharacter(
                        style: graph.reactionStyle(of: asset), returnPoseID: currentPose, forRotation: true
                    )
                }
                return started
            }
            if asset.kind == "characterReactionTransitionPose",
               asset.phase?.kind == "exit",
               let basePose = playbackGraph?.assetsByID[endPose],
               basePose.kind == "characterBasePose",
               let basePlan = phasedVideoPlan(for: basePose, store: store, repeatOneShot: true) {
                // tvOS exits the Reveal reaction hold into the selected BP
                // loop. Keep RPH_To_BP and that loop in one AVPlayerItem so
                // the sequence is Reveal -> transition -> Loop, never
                // transition -> a separately-mounted Intro/first-frame host.
                let combined = PhasedVideoPlan(
                    urls: plan.urls + basePlan.urls,
                    sprite: plan.sprite,
                    loopCount: plan.loopCount + basePlan.loopCount
                )
                let started = startVideoComposition(
                    assetID: "\(idle.id)+\(asset.id)+\(basePose.id)",
                    backgroundImage: backgroundImageURL,
                    backgroundVideo: backgroundVideoURL,
                    backgroundSprite: backgroundSprite, plan: combined,
                    palette: palette, pendingPoseID: endPose, visitor: visitor
                )
                if started {
                    sessionState.recordCharacterAnimation(
                        .basePose, duration: estimatedDuration(of: basePlan.urls)
                    )
                }
                return started
            }
            if let animationKind, animationKind != .basePose,
               let basePose = playbackGraph?.assetsByID[endPose],
               basePose.kind == "characterBasePose",
               let basePlan = phasedVideoPlan(for: basePose, store: store, repeatOneShot: true) {
                // Apple queues a BP immediately after every AP/Moment. Keep
                // both in one seamless player timeline so a short action never
                // becomes a standalone 1–2 second "scene" or teardown gap.
                let combined = PhasedVideoPlan(
                    urls: plan.urls + basePlan.urls,
                    sprite: plan.sprite,
                    loopCount: plan.loopCount + basePlan.loopCount
                )
                let started = startVideoComposition(
                    assetID: "\(idle.id)+\(asset.id)+\(basePose.id)",
                    backgroundImage: backgroundImageURL,
                    backgroundVideo: backgroundVideoURL,
                    backgroundSprite: backgroundSprite, plan: combined,
                    palette: palette, pendingPoseID: endPose, visitor: visitor
                )
                if started {
                    sessionState.recordCharacterAnimation(
                        animationKind, duration: estimatedDuration(of: plan.urls)
                    )
                    sessionState.recordCharacterAnimation(
                        .basePose, duration: estimatedDuration(of: basePlan.urls)
                    )
                }
                return started
            }
            return startVideoComposition(
                assetID: "\(idle.id)+\(asset.id)", backgroundImage: backgroundImageURL,
                backgroundVideo: backgroundVideoURL,
                backgroundSprite: backgroundSprite, plan: plan, palette: palette,
                pendingPoseID: endPose, visitor: visitor,
                characterAnimationKind: animationKind
            )
        }
        if isIdleExitEnter, let graph = playbackGraph,
           ProcessInfo.processInfo.environment["SNOOPY_DISABLE_REACTION_HOLD"] != "1",
           graph.reactionHold(style: graph.reactionStyle(of: asset)) != nil {
            // A HEIC frame sequence cannot be concatenated with the hold's MOV.
            NSLog("SnoopyTVScreenSaver: reaction hold skipped: no proxy for %@", asset.id)
        }
        var fallbackFrames = phasedFrameURLs(for: asset, store: store, minimumDuration: 0)
        guard !fallbackFrames.isEmpty else { return false }
        var appendedBaseFrameCount = 0
        if let animationKind, animationKind != .basePose,
           let basePose = playbackGraph?.assetsByID[endPose] {
            let baseFrames = phasedFrameURLs(for: basePose, store: store, minimumDuration: 0)
            if !baseFrames.isEmpty {
                let repeats = max(1, Int(ceil(8.0 / (Double(baseFrames.count) / 24.0))))
                for _ in 0..<repeats { fallbackFrames.append(contentsOf: baseFrames) }
                appendedBaseFrameCount = baseFrames.count * repeats
            }
        }
        NSLog("SnoopyTVScreenSaver: proxy missing for %@; falling back to HEIC (%ld frames)",
              asset.id, fallbackFrames.count)
        let started = startFrameComposition(
            assetID: "\(idle.id)+\(asset.id)", backgroundImage: backgroundImageURL,
            backgroundVideo: backgroundVideoURL, backgroundSprite: backgroundSprite,
            frameURLs: fallbackFrames,
            foregroundSprite: asset.sprites.first(where: { $0.spriteType == "frameSequence" }),
            palette: palette, pendingPoseID: endPose,
            visitor: visitor,
            characterAnimationKind: appendedBaseFrameCount == 0 ? animationKind : nil
        )
        if started, let animationKind, appendedBaseFrameCount > 0 {
            sessionState.recordCharacterAnimation(
                animationKind,
                duration: Double(fallbackFrames.count - appendedBaseFrameCount) / 24.0
            )
            sessionState.recordCharacterAnimation(
                .basePose, duration: Double(appendedBaseFrameCount) / 24.0
            )
        }
        return started
    }

    // MARK: - Reaction poses (docs/REACTION_POSES.md §5)

    private var nextStageIsActiveSceneWithReveal: Bool {
        guard let first = pendingSceneStages.first, case .activeSceneWithReveal = first else { return false }
        return true
    }

    /// `SNOOPY_REACTION_TRIGGER` and `SNOOPY_REACTION_INTERVAL_SECONDS`, read
    /// once per `start()`.
    private func configureReactionEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        reactionIntervalTimer?.invalidate()
        reactionIntervalTimer = nil
        startupReactionTrigger = nil
        if let trigger = environment["SNOOPY_REACTION_TRIGGER"], !trigger.isEmpty {
            // Fired literally at startup it would expire during the initial
            // ActiveScene; it is armed for the first idle boundary after one
            // character animation instead.
            startupReactionTrigger = trigger
            NSLog("SnoopyTVScreenSaver: reaction trigger=%@ source=env armed for the first idle scene", trigger)
        }
        if let seconds = environment["SNOOPY_REACTION_INTERVAL_SECONDS"].flatMap(Double.init), seconds >= 1 {
            let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
                guard let self, !self.isStopping else { return }
                let triggers = ReactionTrigger.all.filter { $0 != ReactionTrigger.generic }
                let trigger = triggers[PlaybackSessionState.mixedIndex(seed: self.seed, count: triggers.count)]
                self.seed &+= 1
                self.fireReactionTrigger(trigger, source: "interval")
            }
            // Common modes, like the host clock, so a menu or window drag
            // does not stop the interval.
            RunLoop.main.add(timer, forMode: .common)
            reactionIntervalTimer = timer
            NSLog("SnoopyTVScreenSaver: reaction interval=%.0fs source=interval armed", seconds)
        }
    }

    private func fireReactionTrigger(_ trigger: String, source: String) {
        guard !isStopping else {
            NSLog("SnoopyTVScreenSaver: reaction trigger=%@ ignored (stopped)", trigger)
            return
        }
        let known = ReactionTrigger.all.contains(trigger)
        // Newest wins, like tvOS "Updated reactionTriggerEvent". Unknown
        // tokens are kept: they can still be answered by a generic hold.
        pendingReactionTrigger = ReactionTriggerEvent(
            trigger: trigger, firedAt: ProcessInfo.processInfo.systemUptime, source: source
        )
        NSLog("SnoopyTVScreenSaver: reaction trigger=%@ source=%@ known=%d pending until +%.0fs",
              trigger, source, known ? 1 : 0, Self.reactionTriggerTimeout)
    }

    /// The pending trigger if it is still fresh and was not handled; expired
    /// or already-handled events are dropped here.
    private func consumeFreshReactionTrigger() -> ReactionTriggerEvent? {
        guard let event = pendingReactionTrigger else { return nil }
        let age = ProcessInfo.processInfo.systemUptime - event.firedAt
        if age > Self.reactionTriggerTimeout {
            pendingReactionTrigger = nil
            NSLog("SnoopyTVScreenSaver: reaction trigger=%@ expired after %.1fs", event.trigger, age)
            return nil
        }
        if event == lastHandledReactionTrigger {
            pendingReactionTrigger = nil
            NSLog("SnoopyTVScreenSaver: reaction trigger=%@ already handled; not replayed", event.trigger)
            return nil
        }
        return event
    }

    private func markReactionTriggerHandled(_ event: ReactionTriggerEvent, outcome: String) {
        lastHandledReactionTrigger = event
        if pendingReactionTrigger == event { pendingReactionTrigger = nil }
        NSLog("SnoopyTVScreenSaver: reaction trigger=%@ handled (%@)", event.trigger, outcome)
    }

    /// The reaction poses that can answer `event` from `originID` (a BP or an
    /// AP): every style with an authored enter from there, poses tagged with
    /// the trigger before the generic holds. `SNOOPY_FORCE_REACTION_ID` pins
    /// one pose (and yields nothing when it is not enterable from here).
    private func reactionPoseCandidates(for event: ReactionTriggerEvent, from originID: String) -> [AssetRecord] {
        guard let graph = playbackGraph else { return [] }
        var specific: [AssetRecord] = []
        var generic: [AssetRecord] = []
        for style in graph.supportedReactionStyles(from: originID) {
            for pose in graph.reactionPoses(style: style, trigger: event.trigger) {
                if pose.reactionTriggers.contains(event.trigger) {
                    specific.append(pose)
                } else {
                    generic.append(pose)
                }
            }
        }
        if let forced = ProcessInfo.processInfo.environment["SNOOPY_FORCE_REACTION_ID"] {
            return (specific + generic).filter { $0.id == forced }
        }
        // Specific before generic is decided here: the weighted draw only
        // ranks them 3:2, but tvOS plays the tagged pose when one exists.
        return specific.isEmpty ? generic : specific
    }

    /// A: `[BP_To_R**, pose, R**_To_BP, BP]` from the current base pose. Nil
    /// when nothing could be queued; then the standard idle animation plays.
    private func playReaction(
        _ event: ReactionTriggerEvent, from pose: AssetRecord, in stage: IdleSceneStage,
        store: AssetStore, visitor: VisitorPlaybackPlan?, context: SelectionContext
    ) -> Bool? {
        guard let graph = playbackGraph else { return nil }
        let candidates = reactionPoseCandidates(for: event, from: pose.id)
        guard !candidates.isEmpty else {
            markReactionTriggerHandled(event, outcome: "no reaction pose reachable from \(pose.id)")
            return nil
        }
        var triggerContext = context
        triggerContext.reactionTrigger = event.trigger
        guard let reaction = sessionChoice(from: candidates, pool: "reactionPoses", context: triggerContext),
              let sequence = graph.reactionSequence(from: pose.id, pose: reaction, to: pose.id) else {
            markReactionTriggerHandled(event, outcome: "graph could not build enter/exit")
            return nil
        }
        // The exit returns to the current BP; its resting loop closes the
        // item, so `pendingBasePoseID` stays a valid BP id.
        guard let plans = characterPlans(for: sequence, store: store) else {
            markReactionTriggerHandled(event, outcome: "media/proxy missing for \(sequence.assets.map(\.id))")
            return nil
        }
        NSLog("SnoopyTVScreenSaver: reaction queued trigger=%@ style=%@ pose=%@ from=%@ sequence=%@",
              event.trigger, ReactionStyle.nodeID(for: graph.reactionStyle(of: reaction)), reaction.id, pose.id,
              sequence.assets.map(\.id).joined(separator: " -> "))
        markReactionTriggerHandled(event, outcome: "queued \(reaction.id)")
        return playCharacterPlans(
            plans, assetIDs: sequence.assets.map(\.id), endPoseID: sequence.endPoseID,
            in: stage, visitor: visitor
        )
    }

    /// B: `[bridge?, AP intro, AP loop x N, AP_To_R**, pose, R**_To_BP, BP]`.
    /// Only APs with a V2 shortcut in a style that has a pose for the trigger
    /// are candidates (the companion styles from AP010/AP021/AP031). Nil when
    /// not applicable; A then reacts from the base pose right away.
    private func playReactionFromAdditionalPose(
        _ event: ReactionTriggerEvent, from pose: AssetRecord, actions: [AssetRecord],
        in stage: IdleSceneStage, store: AssetStore, visitor: VisitorPlaybackPlan?,
        context: SelectionContext
    ) -> Bool? {
        guard let graph = playbackGraph else { return nil }
        let shortcutActions = actions.filter { action in
            graph.actionSequence(currentPoseID: pose.id, target: action) != nil
                && !reactionPoseCandidates(for: event, from: action.id).isEmpty
        }
        guard !shortcutActions.isEmpty else {
            NSLog("SnoopyTVScreenSaver: reaction: no additional pose with a V2 shortcut answers trigger=%@ from %@; reacting from the base pose instead",
                  event.trigger, pose.id)
            return nil
        }
        // From here on the AP draw has been recorded in the session bag and
        // logged as a character queue, so every refusal says why that queue
        // never played.
        guard let sequence = characterAnimationSequence(
                  startingAt: pose.id, actions: shortcutActions, context: context
              ),
              let apIndex = sequence.assets.firstIndex(where: { $0.kind == "characterAdditionalPose" }),
              let apEndPoseID = sequence.assets[apIndex].endCharacterBasePoseID else {
            NSLog("SnoopyTVScreenSaver: reaction: AP shortcut sequence unavailable from %@ for trigger=%@; reacting from the base pose instead",
                  pose.id, event.trigger)
            return nil
        }
        let ap = sequence.assets[apIndex]
        var triggerContext = context
        triggerContext.reactionTrigger = event.trigger
        guard let reaction = sessionChoice(
                  from: reactionPoseCandidates(for: event, from: ap.id), pool: "reactionPoses", context: triggerContext
              ),
              let tail = graph.reactionSequence(from: ap.id, pose: reaction, to: apEndPoseID) else {
            NSLog("SnoopyTVScreenSaver: reaction: AP shortcut from %@ has no playable pose or exit for trigger=%@; reacting from the base pose instead",
                  ap.id, event.trigger)
            return nil
        }
        // [bridge?, ap] + [AP_To_R**, pose, R**_To_BP, BP]; the target BP is
        // the AP's authored end pose, where its outro would have led.
        let head = Array(sequence.assets[...apIndex])
        let full = CharacterPlaybackSequence(
            startPoseID: pose.id, endPoseID: tail.endPoseID, assets: head + tail.assets
        )
        guard var plans = characterPlans(for: full, store: store) else {
            // Never the segment fallback: it would play the outro and the
            // AP's BP before the shortcut enter.
            NSLog("SnoopyTVScreenSaver: reaction: AP shortcut needs proxies for %@; reacting from the base pose instead",
                  full.assets.map(\.id).joined(separator: " -> "))
            return nil
        }
        let apPlan = plans[apIndex]
        plans[apIndex] = PhasedVideoPlan(urls: apPlan.urlsWithoutOutro, sprite: apPlan.sprite, loopCount: apPlan.loopCount)
        NSLog("SnoopyTVScreenSaver: reaction queued trigger=%@ style=%@ pose=%@ from=%@ (AP shortcut, outro skipped, loops=%d) sequence=%@",
              event.trigger, ReactionStyle.nodeID(for: graph.reactionStyle(of: reaction)), reaction.id, ap.id,
              apPlan.loopCount, full.assets.map(\.id).joined(separator: " -> "))
        markReactionTriggerHandled(event, outcome: "queued \(reaction.id)")
        return playCharacterPlans(
            plans, assetIDs: full.assets.map(\.id), endPoseID: full.endPoseID, in: stage, visitor: visitor
        )
    }

    /// The generic hold of `style` repeated to cover the transition preroll,
    /// or nil when the V2 hold is absent or `SNOOPY_DISABLE_REACTION_HOLD=1`.
    private func reactionHoldTail(
        style: String, store: AssetStore
    ) -> (hold: AssetRecord, plan: PhasedVideoPlan, repeats: Int, seconds: TimeInterval)? {
        guard ProcessInfo.processInfo.environment["SNOOPY_DISABLE_REACTION_HOLD"] != "1",
              let graph = playbackGraph,
              let hold = graph.reactionHold(style: style),
              let holdPlan = phasedVideoPlan(for: hold, store: store) else { return nil }
        let holdSeconds = max(0.5, estimatedDuration(of: holdPlan.urls))
        let repeats = max(1, Int(ceil(Self.reactionHoldSeconds / holdSeconds)))
        var urls: [URL] = []
        for _ in 0..<repeats { urls.append(contentsOf: holdPlan.urls) }
        let plan = PhasedVideoPlan(urls: urls, sprite: holdPlan.sprite, loopCount: repeats)
        return (hold, plan, repeats, holdSeconds * Double(repeats))
    }

    /// D: when the idle scene will be due to rotate once this AP sequence
    /// ends and the AP has a V2 `AP_To_RPH` shortcut, the loop leaves through
    /// it (outro and BP skipped) into the hold; the rotation then starts from
    /// RPH without a `BP_To_RPH` exit. Nil when not applicable (the caller
    /// plays the sequence as today); the plans are built once either way.
    private func playRotationParkedSequence(
        _ sequence: CharacterPlaybackSequence, from pose: AssetRecord, in stage: IdleSceneStage,
        store: AssetStore, visitor: VisitorPlaybackPlan?
    ) -> Bool? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SNOOPY_FORCE_PLAYBACK_KIND"] == nil,
              environment["SNOOPY_TEST_NATIVE_SEQUENCE"] != "1",
              let apIndex = sequence.assets.firstIndex(where: { $0.kind == "characterAdditionalPose" }),
              let graph = playbackGraph,
              let enter = graph.reactionEnter(from: sequence.assets[apIndex].id, style: ReactionStyle.standard)
        else { return nil }
        let ap = sequence.assets[apIndex]
        let endPoseID = ap.endCharacterBasePoseID ?? pose.id
        guard let plans = characterPlans(for: sequence, store: store) else {
            return playCharacterSequenceFallback(sequence, in: stage, store: store, visitor: visitor)
        }
        // Media time, scaled to wall time like the scene budget it is
        // compared with.
        let headSeconds = (plans[..<apIndex].reduce(0) { $0 + estimatedDuration(of: $1.urls) }
            + estimatedDuration(of: plans[apIndex].urlsWithoutOutro)) / playbackRate
        let elapsed = idleSceneStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let rotationDueAfterThisAnimation = idleSceneAnimationCount >= idleSceneTargetAnimationCount
            || elapsed + headSeconds >= idleSceneTargetDuration
        guard rotationDueAfterThisAnimation, let enterPlan = phasedVideoPlan(for: enter, store: store) else {
            return playCharacterPlans(
                plans, assetIDs: sequence.assets.map(\.id), endPoseID: sequence.endPoseID,
                in: stage, visitor: visitor
            )
        }
        var parkedPlans = Array(plans[...apIndex])
        let apPlan = plans[apIndex]
        parkedPlans[apIndex] = PhasedVideoPlan(urls: apPlan.urlsWithoutOutro, sprite: apPlan.sprite, loopCount: apPlan.loopCount)
        parkedPlans.append(enterPlan)
        var ids = sequence.assets[...apIndex].map(\.id) + [enter.id]
        var holdBoundary: Int?
        if let tail = reactionHoldTail(style: ReactionStyle.standard, store: store) {
            holdBoundary = parkedPlans.reduce(0) { $0 + $1.urls.count } - 1
            parkedPlans.append(tail.plan)
            ids.append("\(tail.hold.id)x\(tail.repeats)")
        }
        NSLog("SnoopyTVScreenSaver: reaction parked: %@ leaves through %@ (outro skipped, loops=%d) for idle rotation elapsed=%.1f target=%.0f",
              ap.id, enter.id, apPlan.loopCount, elapsed, idleSceneTargetDuration)
        // No visitor on a parked item: its end observer survives the
        // preserving cleanup and would abort the reveal from its preroll.
        let started = playCharacterPlans(
            parkedPlans, assetIDs: ids, endPoseID: endPoseID, in: stage, visitor: nil,
            holdBoundaryAfterSegment: holdBoundary
        )
        // Park only once the item is really under way: a failed composition
        // leaves no RPH surface, and the retry must replay the AP as today.
        if started {
            parkedCharacter = ParkedCharacter(style: ReactionStyle.standard, returnPoseID: endPoseID, forRotation: true)
        }
        return started
    }

    private func visitorPlaybackPlan(
        for idle: AssetRecord, among assets: [AssetRecord],
        context: SelectionContext, store: AssetStore
    ) -> VisitorPlaybackPlan? {
        // VI/WE prefixes are production waves. Cross-wave IDs appear in the
        // official idle-scene exclusion lists, proving the pool is global.
        var candidates = playbackGraph?.visitors(for: idle, among: assets) ?? []
        let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_VISITOR_ID"]
        if let forcedID { candidates = candidates.filter { $0.id == forcedID } }
        let selected = forcedID == nil
            ? sessionChoice(from: candidates, pool: "visitors", context: context)
            : candidates.first
        guard let asset = selected,
              let media = phasedVideoPlan(for: asset, store: store, visitorLoop: true) else { return nil }
        let plane = media.sprite.plane ?? "foregroundVisitor"
        return VisitorPlaybackPlan(
            assetID: asset.id, media: media,
            ignoresSceneOffset: asset.visitor?.ignoresSceneOffset ?? false,
            isFullscreenEffect: asset.visitor?.isFullscreenEffect ?? false,
            isBackgroundPlane: plane.hasPrefix("background")
        )
    }

    private func normalizedStartPoseID(for asset: AssetRecord) -> String? {
        asset.startCharacterBasePoseID ?? poseID(in: asset, after: "From_")
    }

    private func normalizedEndPoseID(for asset: AssetRecord) -> String? {
        asset.endCharacterBasePoseID ?? poseID(in: asset, after: "To_")
    }

    private func poseID(in asset: AssetRecord, after marker: String) -> String? {
        let candidates = [asset.id] + asset.sprites.compactMap(\.assetBaseName)
        for candidate in candidates {
            guard let range = candidate.range(of: marker, options: .caseInsensitive) else { continue }
            let suffix = candidate[range.upperBound...]
            let token = suffix.split(separator: "_").first.map(String.init) ?? ""
            guard token.hasPrefix("BP") else { continue }
            return "\(asset.id.prefix(3))_\(token)"
        }
        return nil
    }

    private func phasedFrameURLs(for asset: AssetRecord, store: AssetStore, minimumDuration: TimeInterval) -> [URL] {
        guard let directory = try? store.url(for: asset) else { return [] }
        let phaseRank: (SpriteRecord) -> Int = { sprite in
            let path = sprite.contentPath ?? sprite.metadataPath ?? ""
            if path.localizedCaseInsensitiveContains("intro") { return 0 }
            if path.localizedCaseInsensitiveContains("loop") { return 1 }
            if path.localizedCaseInsensitiveContains("outro") { return 2 }
            return 1
        }
        var intro: [URL] = []
        var loop: [URL] = []
        var outro: [URL] = []
        for sprite in asset.sprites.filter({ $0.spriteType == "frameSequence" }).sorted(by: { phaseRank($0) < phaseRank($1) }) {
            guard let base = sprite.assetBaseName else { continue }
            let indexedNames = (asset.media ?? []).compactMap(\.name)
            let names = indexedNames.isEmpty ? (sprite.mediaFiles ?? []) : indexedNames
            let urls = names
                .filter { $0.hasPrefix(base) && ["heic", "png", "jpg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                .sorted { naturalFrameNumber($0) < naturalFrameNumber($1) }
                .map { directory.appendingPathComponent($0) }
            switch phaseRank(sprite) {
            case 0: intro.append(contentsOf: urls)
            case 2: outro.append(contentsOf: urls)
            default: loop.append(contentsOf: urls)
            }
        }
        if loop.isEmpty { loop = intro.isEmpty ? outro : intro }
        var result = intro
        result.append(contentsOf: loop)
        // `minimumDuration` is retained for source compatibility with older
        // callers, but OneShotSprites must preserve the authored frame list
        // exactly. Repeating frames here changes the metadata state machine.
        _ = minimumDuration
        result.append(contentsOf: outro)
        if let testSeconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_SEGMENT_SECONDS"].flatMap(Double.init) {
            return Array(result.prefix(max(1, Int(testSeconds * 24))))
        }
        return result
    }

    private func firstHEICName(in asset: AssetRecord) -> String? {
        if let name = asset.media?.first(where: { $0.suffix == ".heic" })?.name { return name }
        return asset.sprites.lazy.flatMap { $0.mediaFiles ?? [] }.first {
            URL(fileURLWithPath: $0).pathExtension.lowercased() == "heic"
        }
    }

    private func startFrameComposition(
        assetID: String,
        backgroundImage: URL?,
        backgroundVideo: URL? = nil,
        backgroundSprite: SpriteRecord?,
        frameURLs: [URL],
        foregroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?),
        pendingPoseID: String? = nil,
        visitor: VisitorPlaybackPlan? = nil,
        characterAnimationKind: CharacterAnimationKind? = nil
    ) -> Bool {
        guard !frameURLs.isEmpty else { return false }
        let estimatedSeconds = TimeInterval(frameURLs.count) / 24.0
        let visitorSeconds = visitor.map { estimatedDuration(of: $0.media.urls) } ?? 0
        var visitorInstalled = false
        installCompositeBackdrop(backgroundImage: backgroundImage, backgroundVideo: backgroundVideo,
                                 backgroundSprite: backgroundSprite, palette: palette)
        if let visitor, visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        self.foregroundSprite = foregroundSprite
        let sequenceView = NSImageView(frame: compositeFrame(for: foregroundSprite))
        sequenceView.wantsLayer = true
        sequenceView.layer?.contentsGravity = .resize
        let isReplacingRetainedSurface = hasRetiringPlaybackSurface
        sequenceView.layer?.opacity = isReplacingRetainedSurface ? 0.001 : 1
        addSubview(sequenceView)
        keepRetiringPlaybackSurfaceAbove(sequenceView)
        if let visitor, !visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        let visitorControlsCompletion = visitorInstalled && visitorSeconds > estimatedSeconds
        keepRetiringPlaybackSurfaceAbove(sequenceView)
        frameView = sequenceView
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        currentAssetID = assetID
        pendingBasePoseID = pendingPoseID
        isPlaying = true
        let backgroundFrame = compositeFrame(for: backgroundSprite)
        let foregroundFrame = compositeFrame(for: foregroundSprite)
        NSLog("SnoopyTVScreenSaver: composite %@ (%ld frames) background=%@ foreground=%@",
              assetID, frameURLs.count, NSStringFromRect(backgroundFrame), NSStringFromRect(foregroundFrame))
        NSLog("SnoopyTVScreenSaver: palette %@ overlay=%@", palette.background.description,
              palette.overlay?.description ?? "none")

        frameGeneration &+= 1
        let generation = frameGeneration
        let maxPixelSize = maximumPixelSize(for: foregroundSprite)
        // Decode only the first two frames synchronously. The display link
        // advances strictly one decoded frame at a time; asynchronous prefetch
        // therefore cannot cause a clock-driven jump or expose empty contents.
        for url in Array(frameURLs.prefix(2)) {
            cacheDecodedImage(at: url, maxPixelSize: maxPixelSize)
        }
        guard let firstFrame = cachedImage(for: frameURLs[0])
            ?? decodedCGImage(at: frameURLs[0], maxPixelSize: maxPixelSize) else {
            sequenceView.removeFromSuperview()
            frameView = nil
            currentAssetID = nil
            pendingBasePoseID = nil
            isPlaying = false
            NSLog("SnoopyTVScreenSaver: discarded undecodable HEIC composite %@; retaining outgoing surface",
                  assetID)
            return false
        }
        sequenceView.layer?.contents = firstFrame
        preloadFrames(frameURLs, from: 1, count: 8, generation: generation, maxPixelSize: maxPixelSize)
        frameDrawablePoll = { [weak self, weak sequenceView] in
            guard let self else { return }
            guard let sequenceView, self.isPlaying,
                  self.frameGeneration == generation, self.frameView === sequenceView else {
                if self.frameGeneration == generation { self.frameDrawablePoll = nil }
                return
            }
            if let backgroundLayer = self.backgroundVideoLayer,
               !backgroundLayer.isReadyForDisplay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                    guard let self, self.frameGeneration == generation else { return }
                    self.frameDrawablePoll?()
                }
                return
            }
            self.frameDrawablePoll = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sequenceView.layer?.opacity = 1
            self.backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
            self.backgroundVideoPlaceholderLayer = nil
            self.backgroundVideoReadyObservation = nil
            self.retirePreviousPlaybackSurfaces()
            CATransaction.commit()
            self.revealStartupFadeIfNeeded()
            if let characterAnimationKind {
                self.sessionState.recordCharacterAnimation(
                    characterAnimationKind, duration: TimeInterval(frameURLs.count) / 24.0
                )
            }
            if !self.startFrameDisplayLink(
                urls: frameURLs, generation: generation, maxPixelSize: maxPixelSize,
                visitorControlsCompletion: visitorControlsCompletion
            ) {
                // Keep the already-committed first frame mounted. The watchdog
                // can advance without exposing the palette or root layer.
                NSLog("SnoopyTVScreenSaver: unable to create HEIC display link for %@", assetID)
            }
            self.installWatchdog(defaultSeconds: max(15, estimatedSeconds, visitorSeconds) + 3)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frameGeneration == generation else { return }
            self.frameDrawablePoll?()
        }
        return true
    }

    private func startFrameDisplayLink(
        urls: [URL], generation: UInt64, maxPixelSize: Int,
        visitorControlsCompletion: Bool
    ) -> Bool {
        stopFrameDisplayLink()
        frameSequenceURLs = urls
        frameSequenceGeneration = generation
        frameSequenceMaxPixelSize = maxPixelSize
        frameSequenceVisitorControlsCompletion = visitorControlsCompletion
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        return recreateFrameDisplayLink()
    }

    /// (Re)create the CVDisplayLink for the current frame sequence, keeping the
    /// sequence position. Also used after a pause, on display changes and by the
    /// stall recovery: a link created before a display slept or the display set
    /// changed can stop delivering callbacks while still reporting as running.
    @discardableResult
    private func recreateFrameDisplayLink() -> Bool {
        guard !frameSequenceURLs.isEmpty else { return false }
        if let frameDisplayLink { CVDisplayLinkStop(frameDisplayLink) }
        frameDisplayLink = nil
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, context in
            guard let context else { return kCVReturnError }
            let view = Unmanaged<SnoopySceneView>.fromOpaque(context).takeUnretainedValue()
            let hostTime = outputTime.pointee.hostTime
            DispatchQueue.main.async { [weak view] in view?.advanceFrameSequence(hostTime: hostTime) }
            return kCVReturnSuccess
        }, context)
        frameDisplayLink = link
        frameSequenceLastHostTime = 0
        return CVDisplayLinkStart(link) == kCVReturnSuccess
    }

    /// Display sleep/wake and arrangement changes can orphan a CVDisplayLink.
    @objc private func screenParametersDidChange(_ note: Notification) {
        guard frameDisplayLink != nil, !isPaused else { return }
        recreateFrameDisplayLink()
    }

    private func advanceFrameSequence(hostTime: UInt64) {
        guard isPlaying, frameGeneration == frameSequenceGeneration,
              !frameSequenceURLs.isEmpty, frameView != nil else { return }
        if frameSequenceLastHostTime == 0 {
            frameSequenceLastHostTime = hostTime
            NSLog("SnoopyTVScreenSaver: HEIC display link started frames=%ld hostTime=%llu",
                  frameSequenceURLs.count, hostTime)
            return
        }
        let frameInterval = UInt64(CVGetHostClockFrequency() / (24.0 * playbackRate))
        guard hostTime >= frameSequenceLastHostTime + frameInterval else { return }
        let nextIndex = frameSequenceIndex + 1
        guard nextIndex < frameSequenceURLs.count else {
            let misses = frameSequenceDecodeMisses
            let visitorControls = frameSequenceVisitorControlsCompletion
            stopFrameDisplayLink()
            if !visitorControls {
                finishCurrentPlayback("composite ended; decodeMisses=\(misses)")
            }
            return
        }
        let nextURL = frameSequenceURLs[nextIndex]
        guard let image = cachedImage(for: nextURL) else {
            frameSequenceDecodeMisses += 1
            requestDecodedImage(at: nextURL, generation: frameSequenceGeneration,
                                maxPixelSize: frameSequenceMaxPixelSize)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameView?.layer?.contents = image
        CATransaction.commit()
        frameSequenceIndex = nextIndex
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        stallRecoveryAttempted = false
        if nextIndex == 1 {
            NSLog("SnoopyTVScreenSaver: HEIC sequence advancing at display refresh")
        }
        // Schedule from the ideal time so the sequence really runs at 24 fps
        // (on a 60 Hz display anchoring to the vsync-quantised presentation
        // time slows it to 20 fps), but never fall more than one interval
        // behind: a decode stall costs at most one hurried frame afterwards,
        // and authored frames are never skipped.
        frameSequenceLastHostTime = max(frameSequenceLastHostTime + frameInterval, hostTime - frameInterval)
        preloadFrames(frameSequenceURLs, from: nextIndex + 1, count: 8,
                      generation: frameSequenceGeneration, maxPixelSize: frameSequenceMaxPixelSize)
    }

    private func maximumPixelSize(for sprite: SpriteRecord?) -> Int {
        let frame = SpritePlacementResolver.frame(for: sprite, in: bounds)
        let displaySize = Int(ceil(max(frame.size.width, frame.size.height)))
        // 1440 px preserves the line-art detail on desktop displays while
        // avoiding the steep HEIC decode cost of a new 1920 px image 24 times
        // per second. CALayer performs the final display-size stretch.
        return max(1, min(sprite?.assetSize?.max() ?? 1920, displaySize, 1440))
    }

    private func compositeFrame(for sprite: SpriteRecord?, ignoresSceneOffset: Bool = false) -> CGRect {
        SpritePlacementResolver.frame(
            for: sprite, in: bounds, sceneOffset: currentSceneOffset,
            ignoresSceneOffset: ignoresSceneOffset
        )
    }

    private func playbackViewportFrame() -> CGRect {
        SpritePlacementResolver.playbackViewport(in: bounds)
    }

    private func activeVideoViewportFrame() -> CGRect {
        SpritePlacementResolver.activeVideoViewport(in: bounds)
    }

    private func videoPlaceholderImage(at url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
        return try? generator.copyCGImage(
            at: CMTime(seconds: 0.04, preferredTimescale: 600), actualTime: nil
        )
    }

    private func cachedImage(for url: URL) -> CGImage? {
        decodedFrameCache.object(forKey: url.path as NSString)
    }

    private func cacheDecodedImage(at url: URL, maxPixelSize: Int) {
        guard cachedImage(for: url) == nil,
              let image = decodedCGImage(at: url, maxPixelSize: maxPixelSize) else { return }
        let cost = image.bytesPerRow * image.height
        decodedFrameCache.setObject(image, forKey: url.path as NSString, cost: cost)
    }

    private func requestDecodedImage(at url: URL, generation: UInt64, maxPixelSize: Int) {
        let key = url.path
        guard cachedImage(for: url) == nil else { return }
        frameDecodeLock.lock()
        let inserted = pendingFrameKeys.insert(key).inserted
        frameDecodeLock.unlock()
        guard inserted else { return }
        frameDecodeQueue.addOperation { [weak self] in
            guard let self else { return }
            defer {
                self.frameDecodeLock.lock()
                self.pendingFrameKeys.remove(key)
                self.frameDecodeLock.unlock()
            }
            guard self.frameGeneration == generation else { return }
            autoreleasepool {
                if let milliseconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_HEIC_DECODE_DELAY_MS"]
                    .flatMap(Double.init), milliseconds > 0 {
                    Thread.sleep(forTimeInterval: milliseconds / 1_000.0)
                }
                self.cacheDecodedImage(at: url, maxPixelSize: maxPixelSize)
            }
        }
    }

    private func preloadFrames(_ urls: [URL], from start: Int, count: Int, generation: UInt64, maxPixelSize: Int) {
        guard start < urls.count else { return }
        let end = min(urls.count, start + count)
        var seen = Set<String>()
        for url in urls[start..<end] where seen.insert(url.path).inserted {
            requestDecodedImage(at: url, generation: generation, maxPixelSize: maxPixelSize)
        }
    }

    private func decodedCGImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func paletteColors(
        from store: AssetStore, context: SelectionContext, idleScene: AssetRecord? = nil
    ) -> (background: NSColor, overlay: NSColor?) {
        var palettes = store.eligible(store.index.assets, on: context.date).filter { $0.kind == "scenePalette" }
        if let idleScene {
            let related = palettes.filter { $0.scenePalette?.parentIdleSceneIDs?.contains(idleScene.id) == true }
            if !related.isEmpty { palettes = related }
            let excluded = Set(idleScene.idleScene?.exclusions?.excludedPalettes ?? [])
            palettes.removeAll { excluded.contains($0.id) }
        }
        let asset: AssetRecord?
        if idleScene != nil, let currentPaletteAssetID,
           let current = palettes.first(where: { $0.id == currentPaletteAssetID }) {
            asset = current
        } else {
            asset = sessionChoice(from: palettes, pool: "palettes", context: context)
            if idleScene != nil { currentPaletteAssetID = asset?.id }
        }
        guard let asset else {
            return (NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1), nil)
        }
        if let palette = asset.scenePalette {
            return (
                palette.backgroundColor.map(color(from:))
                    ?? NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1),
                palette.overlayColor.map(color(from:))
            )
        }
        guard let directory = try? store.url(for: asset),
              let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.icmetadata")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let node = (plist["scenePalette"] as? [String: Any])?["_0"] as? [String: Any] else {
            return (NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1), nil)
        }
        return (
            color(from: node["backgroundColor"] as? [String: Any], defaultAlpha: 1)
                ?? NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1),
            color(from: node["overlayColor"] as? [String: Any], defaultAlpha: 0.25)
        )
    }

    private func color(from record: ColorRecord) -> NSColor {
        NSColor(calibratedRed: record.red / 255, green: record.green / 255,
                blue: record.blue / 255, alpha: record.alpha)
    }

    private func color(from dictionary: [String: Any]?, defaultAlpha: CGFloat) -> NSColor? {
        guard let dictionary,
              let red = (dictionary["red"] as? NSNumber)?.doubleValue,
              let green = (dictionary["green"] as? NSNumber)?.doubleValue,
              let blue = (dictionary["blue"] as? NSNumber)?.doubleValue else { return nil }
        let alpha = (dictionary["alpha"] as? NSNumber)?.doubleValue ?? Double(defaultAlpha)
        return NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private func naturalFrameNumber(_ name: String) -> Int {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let digits = stem.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 0
    }

    private func currentTimeOfDay() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 6..<12: return "morning"
        case 12..<18: return "afternoon"
        case 18..<23: return "evening"
        default: return "lateNight"
        }
    }

    private func loadSelectionMemory() {
        guard let data = SnoopyPreferences.defaults.data(forKey: SnoopyPreferences.selectionMemoryKey),
              let decoded = try? JSONDecoder().decode(SelectionMemory.self, from: data) else { return }
        memory = decoded
    }

    private func saveSelectionMemory() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        SnoopyPreferences.defaults.set(data, forKey: SnoopyPreferences.selectionMemoryKey)
    }

    public override func layout() {
        super.layout()
        playerLayer?.frame = activeVideoViewportFrame()
        activeVideoPlaceholderLayer?.frame = activeVideoViewportFrame()
        backgroundColorView?.frame = bounds
        halftoneView?.frame = bounds
        backgroundImageView?.frame = compositeFrame(for: backgroundSprite)
        if let host = backgroundVideoHostView {
            host.frame = compositeFrame(for: backgroundSprite)
            backgroundVideoLayer?.frame = host.bounds
        }
        overlayView?.frame = bounds
        frameView?.frame = compositeFrame(for: foregroundSprite)
        if let host = compositeVideoHostView {
            host.frame = compositeFrame(for: foregroundSprite)
            compositeVideoLayer?.frame = host.bounds
        }
        if let host = visitorHostView {
            host.frame = visitorIsFullscreenEffect
                ? playbackViewportFrame()
                : compositeFrame(for: visitorSprite, ignoresSceneOffset: visitorIgnoresSceneOffset)
            visitorLayer?.frame = host.bounds
            visitorPlaceholderLayer?.frame = host.bounds
        }
        transitionHostView?.frame = bounds
    }

    // MARK: - Host clock (for hosts that are not a ScreenSaverView)

    private var hostClock: Timer?

    /// Playback speed multiplier (1 = authored speed), clamped to 0.25…4. It is
    /// applied to every video player (AVPlayer.defaultRate, and live to players
    /// already running) and to the HEIC frame-sequence clock. Scene budgets and
    /// visitor schedules stay in wall time, as on tvOS.
    public var playbackRate: Double = 1.0 {
        didSet {
            let clamped = min(max(playbackRate, 0.25), 4.0)
            if clamped != playbackRate { playbackRate = clamped }
            if playbackRate != oldValue { applyPlaybackRateToActivePlayers() }
        }
    }

    private var allPlayers: [AVPlayer] {
        var players: [AVPlayer] = transitionPlayers + retiringTransitionPlayers
        if let player { players.append(player) }
        if let retiringCompositePlayer { players.append(retiringCompositePlayer) }
        if let visitorPlayer { players.append(visitorPlayer) }
        if let backgroundVideoPlayer { players.append(backgroundVideoPlayer) }
        return players
    }

    private func applyPlaybackRateToActivePlayers() {
        let rate = Float(playbackRate)
        for candidate in allPlayers {
            candidate.defaultRate = rate
            if candidate.rate != 0 { candidate.rate = rate }
        }
    }

    // MARK: - Pause / resume (host-driven)

    /// True while the host has frozen playback with `pause()`.
    public private(set) var isPaused = false
    private var pauseStartedAt: TimeInterval = 0
    private var pausedPlayers: [AVPlayer] = []
    private var deferredWhilePaused: [() -> Void] = []
    private var watchdogDeadline: TimeInterval = 0
    private var watchdogRearm: ((TimeInterval) -> Void)?
    private var advanceDeadline: TimeInterval = 0
    private var lastProgressAt: TimeInterval = 0
    private var stallRecoveryAttempted = false

    /// Freeze playback on the current frame: video players pause where they
    /// are, the HEIC frame clock stops, and pending advances, watchdogs and
    /// preroll timeouts are held until `resume()`. Nothing is torn down, so
    /// the same clip continues afterwards. The idle-scene budget and visitor
    /// schedule are shifted by the paused duration on resume.
    public func pause() {
        guard !isPaused, !isStopping else { return }
        isPaused = true
        pauseStartedAt = ProcessInfo.processInfo.systemUptime
        // Hold the timers as well, so a short pause neither cuts the clip short
        // (a watchdog firing at its original deadline) nor skips its advance.
        if watchdogWorkItem != nil, let rearm = watchdogRearm {
            let remaining = max(0.5, watchdogDeadline - pauseStartedAt)
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            deferredWhilePaused.append { rearm(remaining) }
        }
        if advanceWorkItem != nil {
            let remaining = max(0, advanceDeadline - pauseStartedAt)
            advanceWorkItem?.cancel()
            advanceWorkItem = nil
            deferredWhilePaused.append { [weak self] in self?.scheduleNext(after: remaining) }
        }
        pausedPlayers = allPlayers.filter { $0.rate != 0 }
        pausedPlayers.forEach { $0.pause() }
        if let frameDisplayLink { CVDisplayLinkStop(frameDisplayLink) }
        NSLog("SnoopyTVScreenSaver: paused (%ld players, %@)", pausedPlayers.count, currentAssetID ?? "idle")
    }

    /// Continue exactly where `pause()` froze playback.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        let now = ProcessInfo.processInfo.systemUptime
        let pausedFor = now - pauseStartedAt
        if let startedAt = idleSceneStartedAt { idleSceneStartedAt = startedAt + pausedFor }
        // A pause must not silently expire a pending reaction trigger. Only
        // the paused time after the fire is excluded: an event fired during
        // the pause (the interval timer keeps running) is fresh as of now,
        // never dated in the future.
        if let firedAt = pendingReactionTrigger?.firedAt {
            pendingReactionTrigger?.firedAt = min(firedAt + pausedFor, now)
        }
        let rate = Float(playbackRate)
        for candidate in pausedPlayers {
            candidate.defaultRate = rate
            candidate.play()
        }
        pausedPlayers.removeAll()
        if frameDisplayLink != nil {
            // A fresh link: one created before the pause may never fire again
            // if a display slept in the meantime.
            recreateFrameDisplayLink()
        }
        lastProgressAt = ProcessInfo.processInfo.systemUptime
        stallRecoveryAttempted = false
        let deferred = deferredWhilePaused
        deferredWhilePaused.removeAll()
        deferred.forEach { $0() }
        NSLog("SnoopyTVScreenSaver: resumed after %.1fs (%ld deferred)", pausedFor, deferred.count)
    }

    private func resetPauseState() {
        isPaused = false
        pausedPlayers.removeAll()
        deferredWhilePaused.removeAll()
    }

    // MARK: - Scene navigation and previews (host UI)

    private var previousIdleSceneID: String?
    private var forcedNextIdleSceneID: String?

    /// The idle scene ("room") currently on screen, if any.
    public var currentIdleSceneID: String? { sessionState.currentIdleSceneID }

    public var canSkipToPreviousScene: Bool { previousIdleSceneID != nil }

    /// Leave the current room now: the next character segment is drawn in a
    /// freshly selected idle scene, swapped in like any other segment change.
    public func skipToNextScene() {
        jumpToScene(nil, reason: "next scene requested")
    }

    /// Go back to the room shown before this one.
    public func skipToPreviousScene() {
        guard let previous = previousIdleSceneID else { return }
        jumpToScene(previous, reason: "previous scene requested")
    }

    // MARK: - Reactions (host API)

    /// Fire a reaction trigger (a `ReactionTrigger` token such as "doorbell"),
    /// like tvOS's `reactionTriggerEvent`. It is consumed at the next
    /// character boundary of an idle scene while still fresh (30 s, paused
    /// time excluded); a newer trigger replaces a pending one, and a consumed
    /// one is never replayed. Unknown tokens are accepted and can only be
    /// answered by a generic hold. Main thread.
    public func triggerReaction(_ trigger: String) {
        fireReactionTrigger(trigger, source: "host")
    }

    /// The trigger waiting to be consumed (nil once consumed or expired). The
    /// freshness test is the one the boundary consumer applies; a pause
    /// freezes the age the way `resume()` will account for it.
    public var pendingReactionTriggerName: String? {
        guard let event = pendingReactionTrigger else { return nil }
        let now = isPaused ? pauseStartedAt : ProcessInfo.processInfo.systemUptime
        return now - event.firedAt <= Self.reactionTriggerTimeout ? event.trigger : nil
    }

    /// The triggers a host can fire and the loaded index can answer: the
    /// tokens of every `characterReactionPose` whose style is enterable from
    /// some base or additional pose, in `ReactionTrigger.all` order (unknown
    /// tokens last). `generic` is a fallback tag on the holds, not a trigger,
    /// so it is never listed. Empty on a V1-only index, where reactions are
    /// not available.
    public var availableReactionTriggers: [String] {
        guard let graph = playbackGraph else { return [] }
        let origins = graph.assetsByID.values.filter {
            $0.kind == "characterBasePose" || $0.kind == "characterAdditionalPose"
        }
        let styles = Set(origins.flatMap { graph.supportedReactionStyles(from: $0.id) })
        let triggers = Set(styles.flatMap { graph.reactionPoses(style: $0).flatMap(\.reactionTriggers) })
            .subtracting([ReactionTrigger.generic])
        let known = ReactionTrigger.all.filter(triggers.contains)
        return known + triggers.subtracting(known).sorted()
    }

    private func jumpToScene(_ forcedID: String?, reason: String) {
        guard !isStopping, store != nil else { return }
        forcedNextIdleSceneID = forcedID
        clearIdleSceneState()
        idleSceneChangeRequested = false
        hasPlayedInitialActiveScene = true
        pendingSceneStages.removeAll()
        pendingIdleEntrySequence = nil
        NSLog("SnoopyTVScreenSaver: %@", reason)
        if isPlaying {
            finishCurrentPlayback(reason)
        } else if advanceWorkItem == nil {
            scheduleNext(after: 0)
        }
    }

    private func chooseIdleScene(from idleAssets: [AssetRecord], context: SelectionContext) -> AssetRecord? {
        if let forcedID = forcedNextIdleSceneID {
            forcedNextIdleSceneID = nil
            if let forced = idleAssets.first(where: { $0.id == forcedID }) {
                let limit = SelectionPolicy().recentLimit(for: "idleScenes", candidateCount: idleAssets.count)
                memory.record(forced.id, in: "idleScenes", recentLimit: limit)
                return forced
            }
        }
        return sessionChoice(from: idleAssets, pool: "idleScenes", context: context)
    }

    public struct SceneCandidate: Identifiable {
        public let id: String
        public let thumbnailURL: URL?
        /// Share of the weighted draw, 0…1.
        public let chance: Double
    }

    /// The first background frame of an idle scene (nil for video-only rooms).
    public func thumbnailURL(forIdleScene id: String) -> URL? {
        guard let store, let asset = store.playableAssets().first(where: { $0.id == id }),
              let directory = try? store.url(for: asset), let name = firstHEICName(in: asset) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// The rooms that could come next under the current context, most likely
    /// first, with the share of the weighted draw each would get. Recently
    /// shown rooms are excluded the same way the session draw excludes them.
    public func upcomingSceneCandidates(limit: Int = 4) -> [SceneCandidate] {
        guard let store else { return [] }
        let context = currentContext()
        let idleAssets = store.eligible(store.playableAssets(), on: context.date).filter { $0.kind == "idleScene" }
        let policy = SelectionPolicy()
        var weighted = policy.weightedAssets(from: idleAssets, context: context, memory: memory, pool: "idleScenes")
        let recentLimit = policy.recentLimit(for: "idleScenes", candidateCount: weighted.count)
        let recent = Set(memory.recentIDs(in: "idleScenes", limit: recentLimit))
        let fresh = weighted.filter { !recent.contains($0.asset.id) }
        if !fresh.isEmpty { weighted = fresh }
        weighted.removeAll { $0.asset.id == sessionState.currentIdleSceneID }
        let total = weighted.reduce(0.0) { $0 + Double($1.weight) }
        guard total > 0 else { return [] }
        return weighted.sorted { $0.weight > $1.weight }.prefix(limit).map {
            SceneCandidate(id: $0.asset.id, thumbnailURL: thumbnailURL(forIdleScene: $0.asset.id),
                           chance: Double($0.weight) / total)
        }
    }

    /// Drive `tick()` from an internal timer. A `ScreenSaverView` host calls
    /// `tick()` from `animateOneFrame` instead and must not start this clock.
    public func startClock(interval: TimeInterval = 1.0 / 30.0) {
        stopClock()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common modes so the clock keeps running while a menu is open or a
        // window is being dragged (the default mode pauses timers then).
        RunLoop.main.add(timer, forMode: .common)
        hostClock = timer
    }

    public func stopClock() {
        hostClock?.invalidate()
        hostClock = nil
    }
}
