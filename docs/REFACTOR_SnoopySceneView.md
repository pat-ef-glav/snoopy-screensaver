# Refactor: extract the compositor into a hostable `SnoopySceneView`

Goal: make the playback/compositing engine hostable by any window — the existing
`.saver` shell today, a desktop-wallpaper window next — without changing behaviour.

## Finding

`SnoopySaverView` (3.3k lines) touches the ScreenSaver framework in only 8 places:
`init?(frame:isPreview:)`, `startAnimation`, `stopAnimation`, `animateOneFrame`,
`draw`, `layout`, `hasConfigureSheet`, `configureSheet` (+ `animationTimeInterval`).
Everything else — 105 stored properties, 85 functions — is AppKit/AVFoundation/CoreVideo
compositing and sequencing with no ScreenSaver dependency.

## Strategy (blind-safe: no Xcode project edits)

Keep both classes in the existing `ScreenSaver/SnoopySaverView.swift` so the Xcode
target needs no `project.pbxproj` change; split into files later with Xcode.

1. Rename the big class to `final class SnoopySceneView: NSView` and expose a small API:
   - `init(frame:)` (drop `isPreview`; keep an `isPreview` flag property if any code path needs it)
   - `func start()` / `func stop()`  ← bodies of `startAnimation` / `stopAnimation` minus `super`
   - `func tick()`                    ← body of `animateOneFrame`
   - `override func draw(_:)`, `override func layout()` stay (NSView API)
   - configuration-sheet members move to the shell
   - `animationTimeInterval` moves to the shell; add an optional self-driven clock
     (`start(drivingClockAt: 1/30)`) for hosts that are not a `ScreenSaverView`.
2. Add a thin shell in the same file:
   ```swift
   @objc(DingDangSnoopySaverView)
   final class SnoopySaverView: ScreenSaverView {   // principal class in Info.plist — name unchanged
       private let scene: SnoopySceneView
       override init?(frame: NSRect, isPreview: Bool) { … add scene as autoresizing subview; animationTimeInterval = 1/30 }
       override func startAnimation() { super.startAnimation(); scene.start() }
       override func stopAnimation()  { scene.stop(); super.stopAnimation() }
       override func animateOneFrame() { scene.tick() }
       override var hasConfigureSheet: Bool { true }
       override var configureSheet: NSWindow? { configurationController.window }
   }
   ```
3. CI (`.github/workflows/snoopy-ci.yml`) is the compiler: push, read the xcodebuild job.

## Then

- **Wallpaper host**: per-screen `NSWindow` at `CGWindowLevelForKey(.desktopWindow) - 1`,
  `ignoresMouseEvents`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`, hosting a
  `SnoopySceneView` driving its own clock; a menu-bar app to start/stop.
- **Settings**: on-battery mode (pause / reduced fps), pause when hidden (fullscreen app or
  screensaver active), playback speed (AVPlayer `rate` + HEIC display-link step + loop-count
  scaling) — mirroring Aerial's `OnBatteryMode` / auto-pause / `playbackSpeed`.
