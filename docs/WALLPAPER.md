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

## Menu

| Item | What it does |
|---|---|
| Show Snoopy on the Desktop | Master on/off. Off hides the windows; the system wallpaper shows. |
| Playback Speed | 0.5× … 2×. Video players run at that rate and the HEIC frame clock is scaled. Scene budgets (~240 s per idle scene) and visitor schedules stay in wall time, as on tvOS. Shared with the screen saver. |
| On Battery | *Keep playing*, *Pause*, or *Pause when battery is low* (< 20 %). Greyed out on desktops. |
| Pause When Covered by Windows | Polls window coverage once a second (Aerial's algorithm: 50×50 grid, threshold 60 %) and pauses that display while it is mostly covered. |
| Weather Settings… | The same city / weather-linking panel as the screen saver's Options. |
| Launch at Login | Registers the app as a login item (needs the `.app` bundle). |

The wallpaper also pauses while the displays sleep and while the system screen
saver runs, and restarts when a display is added or its geometry changes.

Pausing stops playback and hides that display's window; resuming starts a fresh
session (new seed), like the screen saver does on each activation.

## Settings storage

Everything lives in the shared suite `com.dingdangnao.snoopy.shared`
(`SnoopyPreferences`), so the saver and the wallpaper agree on speed and weather:

| Key | Values |
|---|---|
| `SnoopyWallpaperEnabled` | bool, default true |
| `SnoopyPlaybackRate` | 0.25 … 4, default 1 |
| `SnoopyOnBatteryMode` | 0 keep playing · 1 pause · 2 pause when low |
| `SnoopyPauseWhenHidden` | bool, default true |
| `SnoopyWallpaperLevelOffset` | int, default 0 — offset from `CGWindowLevelForKey(.desktopWindow)`; try `-1` (Aerial's choice) if the wallpaper ever appears above your desktop icons |

## Window recipe

Per screen: a borderless `NSWindow` at desktop level that joins all Spaces, is
stationary, never becomes key, ignores the mouse, has no shadow and is opaque
black, hosting a `SnoopySceneView` driven by its own 30 Hz clock
(`startClock()`); HEIC sequences advance from a `CVDisplayLink` inside the view.
This is the recipe Aerial's desktop mode and other wallpaper apps use.
