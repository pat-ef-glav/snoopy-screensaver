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
| Header | "Snoopy", the status line (Playing on 2 displays / Paused: on battery / Off) and the master switch. Off hides the windows; the system wallpaper shows. |
| Scene | A thumbnail of the room currently on screen with its id, **Previous** / **Next Scene** (the next character segment is drawn in another room, swapped in like any segment change), a restart button, and "Up next, by chance": the three most likely next rooms with their share of the weighted draw under the current context. |
| Reactions | **Doorbell** / **Alarm** / **Music** / **Environment** / **Presence** fire a reaction trigger on every display, the way a tvOS app fires `reactionTriggerEvent`: at his next pause between animations (within 30 s of playing time) Snoopy plays a reaction pose tagged for that trigger, then returns to his base pose. The caption names the queued trigger; a newer one replaces it. The row only appears when the asset index carries the reaction clips (bundle `idlechara_defaultV2_v1`). |
| Speeds | Sliders for the wallpaper and the screen saver, 0.5× … 2× in quarter steps. Video players run at that rate and the HEIC frame clock is scaled; scene budgets and visitor schedules stay in wall time, as on tvOS. |
| On Battery | *Keep playing*, *Pause*, or *Pause when battery is low* (< 20 %); hidden on desktops. |
| Pause When Covered by Windows | Polls window coverage once a second (Aerial's algorithm: 50×50 grid, threshold 60 %) and pauses that display while it is mostly covered. |
| Weather | The cached snapshot (place · conditions · time) and the Options sheet (city / weather linking and the screen saver's speed). |
| Footer | Launch at Login, version, Quit. |

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

## Settings storage

Everything lives in the shared suite `com.dingdangnao.snoopy.shared`
(`SnoopyPreferences`), so the saver and the wallpaper agree on speed and weather:

| Key | Values |
|---|---|
| `SnoopyWallpaperEnabled` | bool, default true |
| `SnoopyPlaybackRate.wallpaper` / `SnoopyPlaybackRate.screenSaver` | 0.25 … 4, default 1 (the legacy `SnoopyPlaybackRate` is the fallback for both) |
| `SnoopyOnBatteryMode` | 0 keep playing · 1 pause · 2 pause when low |
| `SnoopyPauseWhenHidden` | bool, default true |
| `SnoopyWallpaperLevelOffset` | int, default 0 — offset from `CGWindowLevelForKey(.desktopWindow)`; try `-1` (Aerial's choice) if the wallpaper ever appears above your desktop icons |

## Window recipe

Per screen: a borderless `NSWindow` at desktop level that joins all Spaces, is
stationary, never becomes key, ignores the mouse, has no shadow and is opaque
black, hosting a `SnoopySceneView` driven by its own 30 Hz clock
(`startClock()`); HEIC sequences advance from a `CVDisplayLink` inside the view.
This is the recipe Aerial's desktop mode and other wallpaper apps use.

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
