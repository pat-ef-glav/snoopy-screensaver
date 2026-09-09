# Snoopy Wallpaper — the desktop live-wallpaper host

`Sources/SnoopyWallpaper` is a small menu-bar app that runs the same Snoopy
engine as the screen saver on the desktop, behind your windows and icons, on
every display. It exists because the engine was split into a hostable view:

```
SnoopyTVCore      selection model, calendar/weather context, playback graph (no UI)
SnoopySceneKit    SnoopySceneView — the AppKit compositor — plus the weather settings panel
  ├─ SNOOPY.saver          ScreenSaver/SnoopySaverView.swift (thin ScreenSaverView shell)
  └─ Snoopy Wallpaper.app  Sources/SnoopyWallpaper (desktop-level windows + menu bar)
```

Both hosts play identically: the scene view owns idle scenes, the 71/20/9
character mix, visitors, weather effects and transitions. The wallpaper app
only decides *when* to play and at what speed.

## Build and install

```sh
# Requires Xcode command-line tools (Swift 5.9+) and Resources/SnoopyAssets (see README).
sh scripts/build_wallpaper_app.sh                 # → .build/SnoopyWallpaper.app
SNOOPY_INSTALL=1 sh scripts/build_wallpaper_app.sh   # also copies to /Applications and launches
```

`SNOOPY_ASSETS=link` symlinks the 7 GB asset folder into the bundle instead of
copying it (fine for a local build). If `.derived-media` exists (created by
`scripts/build_and_install.sh`), the proxies are bundled too.

## The panel

Clicking the dog in the menu bar opens a card (a SwiftUI `MenuBarExtra` in its
window style, like Klack or Little Snitch) that stays open while you use it:

| Area | What it does |
|---|---|
| Header | "Snoopy", the status line (Playing on 2 displays / Paused: covered by windows / Off), a settings button (gear) and the master switch. Off hides the windows; the system wallpaper shows, and the preview shows a placeholder with no room caption. |
| Scene | A live frame of the wallpaper on the main display, re-rendered every 2 s while the panel is open — the panel's window reports whether it is on screen, and nothing is rendered while it is closed (the engine composites its layer tree off the main thread and never touches playback; until the first frame arrives the room's first background frame stands in). The capsule names the room ("Scene 33 · bundle 104") or the full-screen video ("Video AS014"). Below it, from the engine's playback status: **Now** — the asset of the composite that is playing ("Pose AP007", "Resting BP002", "Moment CM001", "Bridge BP001→BP002", "Enter RPH" / "Exit RPH", "Reaction RPD001", "Hold RPH", "Video AS002", "Transition ClockWipe hide") with the wall-clock seconds until it ends — and **Then**, the next asset inside the same composite ("—" when the next one has not been drawn yet). The status names an incoming composite as soon as the engine has built it, so for its preroll (normally well under a second) the line can run ahead of the picture. Then **Previous** / **Next Scene** (the next character segment is drawn in another room, swapped in like any segment change) and **Restart**. |
| Speed | Two pop-ups, Wallpaper and Screen Saver: 0.5× … 2× (a stored speed outside that list, e.g. 1.75× from an older build, appears as an extra item so the pop-up always names the speed that is playing). Video players run at that rate and the HEIC frame clock is scaled; scene budgets and visitor schedules stay in wall time, as on tvOS. |
| Weather | "Toronto · Clear · checked 3 min ago" — the city, the conditions and when the app last fetched (not the service's quarter-hour observation time). Clicking the row opens the Weather tab of settings; the button on the right fetches now on every display (ignoring the snapshot's refresh gate and failure backoff; disabled while weather linking is off). |
| Footer | Launch at Login, Quit. |

The wallpaper also pauses while the displays sleep and while the system screen
saver runs, and restarts when a display is added or its geometry changes.

Pausing freezes the current frame in place: video players pause where they are,
the HEIC frame clock stops, and pending scene changes and watchdogs wait, so the
same clip continues on resume (the idle-scene budget is shifted by the paused
time). The window stays on screen, so you keep seeing Snoopy rather than the
system wallpaper. Only turning the wallpaper off hides the windows.

## App icon

`scripts/build_wallpaper_app.sh` renders `AppIcon.icns` from
`Resources/ScreenSaverPreview.png` (Snoopy and Woodstock on the yellow field)
with `Tools/MakeAppIcon.swift`, cropped into the standard macOS rounded-square
grid. Use another picture with `SNOOPY_ICON_SOURCE=path` and adjust the square
crop with `SNOOPY_ICON_CROP="centerX centerY side"`.

## Derived media (needed for smooth loops)

The base-pose loops (Snoopy resting, sleeping, …), the pose and reaction transitions,
the idle-scene backgrounds and the wipe masks are HEIC frame sequences in the asset
package. Played directly they are decoded from 4K HEIC files 24 times a second through
a small cache, which stutters. The port's `SnoopySequenceProxyBuilder` re-encodes every
frame sequence into an HEVC-with-alpha proxy, and both hosts play those instead.

`scripts/build_wallpaper_app.sh` obtains them automatically: it reuses the `DerivedMedia`
folder of an installed saver when one exists (the port's prebuilt `Snoopy TV.saver`
ships one), otherwise it builds them once into `.derived-media` (several minutes).
`SNOOPY_SKIP_PROXY_BUILD=1` skips this. `scripts/build_and_install.sh` builds them too.

To check what a running build uses:

```sh
log stream --style compact --predicate 'process == "SnoopyWallpaper"' | grep -E "proxy missing|decodeMisses|derived proxies"
```

"derived proxies=0" or "proxy missing … falling back to HEIC" means the bundle has no
proxies; a non-zero "decodeMisses" at the end of a composite is a live-decode stall.

## Settings

The gear in the panel (and the screen saver's Options button in System Settings) opens the same
window, a grouped form with three tabs. Everything applies as it changes; **Done** closes it.

| Tab | Contents |
|---|---|
| Weather | The weather-linking switch, the city (resolved through Open-Meteo's geocoder; no location permission), the current snapshot ("Toronto · Clear · checked 3 min ago") and **Update Now**. The weather is re-checked on its own at media boundaries, five minutes after a failed fetch, and as soon as the network returns. |
| Playback | Wallpaper and screen saver speeds (0.5× … 2×); **On battery** (*Keep playing*, *Pause*, *Pause when battery is low*); **Pause when covered by windows** with a slider for how much of a display must be covered (30 … 95 %, default 60 %; coverage is measured once a second on a 50 × 50 grid, only other apps' ordinary windows count). |
| Reactions | The real-world events Snoopy reacts to (see docs/REACTION_POSES.md): **Music** (another app has been playing audio for 8 s), **Presence** (screen unlocked or the Mac woke), **Environment** (the weather changed, dawn and dusk included) are on by default and need no permission; **Alarm** (a calendar event starts; asks for calendar access) and **Doorbell** (a download finished; asks for access to Downloads) are off until enabled. A reaction plays at Snoopy's next pause in a scene, within about 90 s of the event, each kind at most once every three minutes. |

## Settings storage

Everything lives in the shared suite `com.dingdangnao.snoopy.shared`
(`SnoopyPreferences`), so the saver and the wallpaper agree on speed and weather:

| Key | Values |
|---|---|
| `SnoopyWallpaperEnabled` | bool, default true |
| `SnoopyPlaybackRate.wallpaper` / `SnoopyPlaybackRate.screenSaver` | 0.25 … 4, default 1 (the legacy `SnoopyPlaybackRate` is the fallback for both) |
| `SnoopyOnBatteryMode` | 0 keep playing · 1 pause · 2 pause when low |
| `SnoopyPauseWhenHidden` | bool, default true |
| `SnoopyPauseCoverageThreshold` | 0.3 … 0.95, default 0.6 — the covered fraction that pauses a display |
| `SnoopyReactionSource.<trigger>` | bool per reaction source (`music`, `presence`, `environment` default true; `alarm`, `doorbell` default false) |
| `SnoopyWallpaperLevelOffset` | int, default 0 — offset from `CGWindowLevelForKey(.desktopWindow)`; try `-1` (Aerial's choice) if the wallpaper ever appears above your desktop icons |

## Window recipe

Per screen: a borderless `NSWindow` at desktop level that joins all Spaces, is
stationary, never becomes key, ignores the mouse, has no shadow and is opaque
black, hosting a `SnoopySceneView` driven by its own 30 Hz clock
(`startClock()`); HEIC sequences advance from a `CVDisplayLink` inside the view.
This is the recipe Aerial's desktop mode and other wallpaper apps use.

## Where to keep the media

Put `SnoopyAssets` (or an APFS clone of it) somewhere that is not consent-protected. An app
launched by LaunchServices needs Files & Folders permission for anything under `~/Documents`,
`~/Desktop` or `~/Downloads`, and macOS asks with a dialog that blocks the app's first media
`open()` until it is answered; because the local build is signed ad hoc, the grant does not
survive a rebuild either. The build script links the bundle to the physical folder and warns
when that folder is inside one of those locations. A clone costs no space on APFS:

```sh
mkdir -p ~/Library/Application\ Support/Snoopy\ Wallpaper
cp -Rc ~/Documents/…/SnoopyAssets ~/Library/Application\ Support/Snoopy\ Wallpaper/SnoopyAssets
ln -sfn ~/Library/Application\ Support/Snoopy\ Wallpaper/SnoopyAssets Resources/SnoopyAssets
```

## Signing and sharing the app

The app is a small (~30 MB) bundle that reads its clips from
`~/Library/Application Support/Snoopy Wallpaper/SnoopyAssets`, so it can be signed and notarized
without embedding Apple's 7 GB media. Build a Developer-ID-signed, hardened-runtime bundle by
passing your identity:

```sh
SNOOPY_ASSETS=none SNOOPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  SNOOPY_APP_OUTPUT="$PWD/.build/SnoopyWallpaper.app" sh scripts/build_wallpaper_app.sh
```

No new Apple ID, App ID or app-specific setup is needed beyond what you already use: the
Developer ID certificate is per-team and signs every app, an app-specific password is per Apple
ID (reuse the one you notarize other software with), and a Developer-ID bundle identifier is not
registered with Apple — it just has to be your own reverse-DNS string (the default is
`com.pat-ef-glav.snoopy.wallpaper`, override with `SNOOPY_BUNDLE_ID`). Then notarize and staple:

```sh
ditto -c -k --keepParent .build/SnoopyWallpaper.app /tmp/SnoopyWallpaper.zip
xcrun notarytool submit /tmp/SnoopyWallpaper.zip --keychain-profile "<profile>" --wait
xcrun stapler staple .build/SnoopyWallpaper.app
```

(First time only, store the credentials once:
`xcrun notarytool store-credentials "<profile>" --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`.)

A friend then drops the `SnoopyAssets` bundles into their own
`~/Library/Application Support/Snoopy Wallpaper/SnoopyAssets`; on first launch, with that folder
empty, the app creates it and opens Settings with a banner walking them through it. The screen
saver is separate and self-contained — it bundles its own clips, so it is signed and shared as
one `.saver` (see `scripts/build_and_install.sh`), not through this folder.

## First run and troubleshooting

1. `sh scripts/build_wallpaper_app.sh` then `open .build/SnoopyWallpaper.app` — a dog icon
   appears in the menu bar and Snoopy should start on every display within a few seconds.
2. Watch the engine's log while it runs:

   ```sh
   log stream --style compact --predicate 'process == "SnoopyWallpaper"'
   ```

   The compositor logs with the `SnoopyTVScreenSaver:` prefix (asset index found, derived
   proxies, HEIC display link, scene changes). "asset-index.json not found" means the bundle has
   no index — rebuild after placing `Resources/SnoopyAssets`.
3. Black windows but no errors: the assets folder is missing or empty in the bundle
   (`ls .build/SnoopyWallpaper.app/Contents/Resources/SnoopyAssets | head`).
4. Snoopy appears above your desktop icons, or not at all: adjust the window level and relaunch:

   ```sh
   defaults write com.dingdangnao.snoopy.shared SnoopyWallpaperLevelOffset -int -1
   ```
5. Nothing plays and the menu says "Paused: covered by windows": that display is more than
   60 % covered; hide some windows or turn off *Pause When Covered by Windows*.
6. The menu says "Playing" but nothing moves: pick *Restart Snoopy*, then send the log lines
   around "paused", "resumed", "recreating the display link" or "no playback progress" — the
   engine logs each recovery step it takes.

## Testing the engine

The scene view reads a few environment variables meant for development (semantics in
`docs/REACTION_POSES.md` §5). They only reach the app when it is started from a shell —
`SNOOPY_REACTION_TRIGGER=doorbell .build/SnoopyWallpaper.app/Contents/MacOS/SnoopyWallpaper` —
so quit the installed copy first; two instances fight over the desktop.

- `SNOOPY_REACTION_TRIGGER=<trigger>` — arms one simulated trigger for the first idle scene, fired at its second character boundary so it cannot expire during the opening active scene.
- `SNOOPY_REACTION_INTERVAL_SECONDS=<n>` — fires a random trigger every *n* seconds (minimum 1).
- `SNOOPY_FORCE_REACTION_ID=<id>` — pins the reaction pose (for example `103_RPH002`) instead of drawing one for the trigger.
- `SNOOPY_DISABLE_REACTION_HOLD=1` — during a scene transition keep the old freeze on the enter's last frame instead of holding in `101_RPH_Loop`.
- `SNOOPY_ASSET_INDEX_PATH=<file>` — play from another asset index (development only; the media paths in it must resolve).
