# Handoff: integrate the newer reaction-pose clips into Snoopy-Screensaver

> **Status (2026-09-07):** done. The clips turned out to be Apple's V2 reaction-pose bundle and their
> metadata was found in the tvOS 26.5 simulator runtime; the decoded model, the evidence and the
> engine integration are documented in [REACTION_POSES.md](REACTION_POSES.md). The index builder is
> `Tools/build_asset_index.py`. This brief is kept as the original task description.

You are working in a local clone of `pat-ef-glav/snoopy-screensaver` (fork of
`dingdangnao/Snoopy-Screensaver`), branch `claude/snoopy-wallpaper-8fmsgn`, on a Mac
with Xcode. You can read the source, the 7.2 GB Apple asset package, and the user's own
extraction of newer tvOS assets. Your job: make the newer reaction-pose clips first-class
assets of this engine without breaking anything that works today. Work top-down: confirm
the structure before touching details, keep every change compiling (`swift build`,
`swift test`), and never commit media.

## 1. What the project is

- `Sources/SnoopyTVCore` — the model: `IndexStore.swift` (loads `Resources/asset-index.json`),
  `Models.swift` (`AssetRecord`, `SpriteRecord`, `SelectionContext`), `RelevancyScorer.swift`
  (context matching), `SelectionPolicy.swift` / `SelectionEngine.swift` (weighted draws with
  recency), `PlaybackStateMachine.swift` (`PlaybackGraph`: character pose graph, reaction
  poses, transition categories/pairs), `CalendarResolver.swift`, `WeatherSupport.swift`.
- `Sources/SnoopySceneKit/SnoopySceneView.swift` — the compositor (≈3.3k lines): plays
  active-scene videos, idle scenes with HEIC/HEVC-alpha character segments, visitors,
  weather effects, and the hide/reveal scene transitions. Hosted by the `.saver`
  (`ScreenSaver/SnoopySaverView.swift`) and the wallpaper app (`Sources/SnoopyWallpaper`).
- `Tests/SnoopyTVCoreTests` — XCTest suite (`swift test`). CI runs `swift build`, `swift test`,
  assembles the wallpaper app, and `xcodebuild`s the saver on every push
  (`.github/workflows/snoopy-ci.yml`).
- Media lives in `Resources/SnoopyAssets/<bundle>/<assetID>.icasset/…` (gitignored). The
  package's bundles are `idlechara_bundle0_4K_v9`, `idlechara_bundle1_4K_v6`,
  `idlechara_bundle1-5_4K_v2`, `idlechara_bundle2_4K_v4`, `idlechara_bundle3…8_4K_v1`.
- Docs to read first: `docs/WALLPAPER.md`, `docs/AS_TRIGGER_CONDITIONS.md`, and (in the
  sibling workbench repo `pat-ef-glav/Aerial-State-Machine`) `docs/apple-snoopy-model.md`.

## 2. Apple's model, as verified so far

- Each `.icasset` is one asset with a `metadataType`: `characterBasePose` (BP001–004, HEIC
  loops), `characterAdditionalPose` (AP: intro/loop/outro, mostly HEVC-alpha `.mov`),
  `characterMoment` (CM: one-shot `From_BPx_To_BPy`), `characterPoseTransition`
  (`BPx_To_BPy`, HEIC), `characterReactionTransitionPose` (`101_BP00x_To_RPH` enter /
  `101_RPH_To_BP00x` exit, HEIC, ~38/28 frames), `idleScene` (IS), `idleSceneVisitor` (VI,
  WE = fullscreen weather effects), `activeScene` (AS), `scenePalette`,
  `sceneTransitionCategory`, `sceneTransitionPair`, `characterSceneTransitionPose` (ST
  `Hide_A`/`Hide_B`/`Reveal`), `spriteTransitionParameters` (TM wipes), `switcherScene`.
- Scene change flow: BP → `BP_To_RPH` → RPH → [ST hide of the old scene | active scene |
  ST reveal of the new scene] → RPH → `RPH_To_BP` → BP. The graph code is
  `PlaybackGraph.reactionEnter(from:)`, `reactionExit(to:)`, `idleEntrySequence(to:)`,
  `idleExitSequence(from:)`, `reactionQueue(from:to:)` (all keyed on kind
  `characterReactionTransitionPose` and the single shared node named `RPH`).
- `relevancyData.info` is grouped by family: OR within a family, AND across families
  (`ScenePalette_Cloudy_Day` = cloudy ∧ (morning ∨ afternoon)). Implemented in
  `RelevancyScorer.matchedFamilyScore`. Family weights: calendar 80, hourlyEvent 65,
  weather/moon 50, timeOfDay 30, routine 25.
- Character mix in an idle scene is time-balanced 71 % BP / 20 % AP / 9 % CM; three visitors
  per ~240 s idle scene.
- Raw HEVC-alpha segments show an empty frame at t=0; `seamlessVideoItem` trims 1/24 s per
  segment (derived proxies carry the same trim).

## 3. Index schema (`Resources/asset-index.json`, schemaVersion 1)

Top level: `assetRoot` (string, path recorded at generation; the store prefers a
`SnoopyAssets` folder next to the index), `assets` (array), `bundles`
(`[{name, assetCount}]`), `errors`, `schemaVersion`, `summary`.

Asset record keys: `id`, `bundle`, `relativePath` (`<bundle>/<id>.icasset`), `metadataType`,
`media` (`[{name, bytes, relativePath, suffix}]`), `sprites`, `relevancyData`
(`{info, dependencies, exclusions}`), `startCharacterBasePoseID`, `endCharacterBasePoseID`,
`transitionCategoryIDs`, `integrity` (`{valid, metadata, mediaFileCount, missingMedia}`),
`status`, `version` (`{majorVersion, minorVersion}`).

Sprite record keys: `assetBaseName`, `assetSize` ([1920, 1080]), `customTiming`,
`endBehavior` (`freeze` | `loop`), `frameIndexDigitCount`, `mediaFiles`, `metadataPath`
(the plist keypath, e.g. `characterAdditionalPose._0.assetContainer.content.phasedSprites.phasedSprites.introSprites.sprites.0`),
`phase` (`intro` | `loop` | `outro` | `oneShot`), `placement`
(`{anchored: {alignment, to: viewport}}`), `plane` (`foregroundCharacter`, `backgroundCharacter`,
`centerpiece`, `mask`, `foregroundEffect`, …), `spriteType` (`video` | `frameSequence`).

Reference records to copy the shape from: `101_AP001` (phased video: intro `Intro_From_BP003`,
`Loop`, outro `Outro_To_BP001`; `endCharacterBasePoseID` 101_BP001),
`101_CM001_From_BP001_To_BP003` (oneShot video with start/end pose ids and an exclusion
`{category: sceneFullscreenEffectVisitor, info: [{weather: {condition: windy}}]}`),
`101_BP001_To_RPH` (38-frame HEIC reaction enter), `101_BP001_To_BP002` (HEIC pose transition).

## 4. The clips to integrate

The user's extraction (from a newer tvOS `IdleCharacterPoster` bundle) contains 44 `.mov`
clips the package does not have. Grouped by family (all HEVC-alpha, 24 fps unless you find
otherwise):

```
RPD: 101_RPD001.mov 101_RPD_Loop.mov
     101_BP001_To_RPD 101_BP002_To_RPD 101_BP003_To_RPD 101_BP004_To_RPD
     101_RPD_To_BP001 101_RPD_To_BP002 101_RPD_To_BP003 101_RPD_To_BP004
     101_AP001_To_RPD 101_AP002_To_RPD 101_AP003_To_RPD 101_AP007_To_RPD 104_AP028_To_RPD
     104_RPD005.mov
RWD: 101_RWD001.mov 104_RWD005.mov
     101_RWD_To_BP001 101_RWD_To_BP002 101_RWD_To_BP003 101_RWD_To_BP004
     103_AP021_To_RWD 104_AP010_To_RWD 104_AP031_To_RWD
RWH: 103_RWH002.mov 104_RWH003.mov 104_RWH004.mov
     101_RWH_To_BP001 101_RWH_To_BP002 101_RWH_To_BP003 101_RWH_To_BP004
     103_AP021_To_RWH 104_AP010_To_RWH 104_AP031_To_RWH
RPH: 101_RPH_Loop.mov 103_RPH002.mov 104_RPH003.mov 104_RPH004.mov
     103_AP001_To_RPH 103_AP002_To_RPH 103_AP003_To_RPH 103_AP007_To_RPH 104_AP028_To_RPH
```

Observed structure: each family has enter clips from base poses (`BP00x_To_R**`) and from
additional poses (`AP0xx_To_R**`, a shortcut the package lacks), a numbered pose clip
(`101_RPD001`, `103_RWH002`, `104_RPH003` …, numbered per bundle), a `_Loop` for RPD and RPH,
and exit clips (`R**_To_BP00x`). The package models only `RPH` (enter/exit as HEIC, no
loop, no AP shortcuts). `RPD`, `RWD`, `RWH` are unknown variants; `R` is surely *reaction*,
the other letters are not decoded. Do not guess them into the code: derive them from
metadata if you find any, otherwise from the clips themselves (watch first/last frames,
compare poses with the ST hide/reveal families: RealWorld / DayDream / SleepingDream /
Storytelling) and write down the evidence.

## 5. Plan

1. **Inventory.** Enumerate the extraction folder(s) the user points you at. Match every
   file against `Resources/asset-index.json` ids and media names; confirm the 44 above and
   note anything else new. Check for metadata: any `.icasset` folders, `*.plist`, or
   `Info.plist`/`metadata` files in the extraction; and search the tvOS runtimes on this Mac
   (`find /Library/Developer/CoreSimulator ~/Library/Developer /Applications/Xcode*.app -iname '*idlechara*' -o -iname '*.icasset' 2>/dev/null | head`,
   and `IdleCharacterPoster*` inside the AppleTVOS platform). Apple's runtime metadata for
   these clips is the only authoritative source for `relevancyData` and the transition
   category wiring.
2. **If metadata exists**, write an index builder (Swift executable target or a Python
   script under `Tools/`) that turns `.icasset` metadata into records of the schema in §3.
   Validate it by regenerating records for assets already in the shipped index and diffing
   against the shipped JSON — they must match field for field before you trust it on the
   new clips. Put the new clips in a new bundle folder
   (`Resources/SnoopyAssets/idlechara_extracted_v1/<id>.icasset/…`), regenerate the index,
   add the bundle to `bundles`.
3. **If no metadata exists**, author the records by analogy with §3 (video sprites with
   `phase` intro/loop/outro or oneShot; `startCharacterBasePoseID` / `endCharacterBasePoseID`
   from the names; `relevancyData` empty = generic; `integrity.valid = true`), tagged with
   a distinct bundle name so they can be replaced later, and say so in the docs.
4. **Engine.** Generalise the reaction pose. Today `PlaybackGraph` assumes one shared node
   named `RPH` with HEIC enter/exit only. Needed: reaction *variants* (RPH/RPD/RWD/RWH,
   numbered per bundle), enter from an additional pose's loop (`AP_To_R**`), a `_Loop` hold
   while the transition prerolls, and exits to any base pose. Pick the variant once per
   transition so hide and reveal use the same node. When only the classic RPH exists the
   behaviour must be byte-for-byte what it is now — keep the existing tests green
   (`testPlaybackGraphBuildsCompleteActionAndIdleBoundarySequences`,
   `testPlaybackGraphFollowsPoseEdgesAndTransitionCategories`,
   `testPlaybackGraphKeepsEveryAuthoredPoseBranchReachable`). In `SnoopySceneView`, the
   relevant code is `playRandomVideo` (exit sequence before reveal), `beginPendingIdleEntryTransition`,
   `completeSceneTransitionStage`, `playIdleCharacterComposite`, `phasedFrameURLs` /
   `PhasedVideoPlan` (intro/loop/outro naming), `seamlessVideoItem`.
5. **Verify.** Unit tests for the graph with the new records; `swift test`; then a real run:
   `SNOOPY_TEST_IDLE_ROTATION_SECONDS=20` forces frequent scene changes,
   `SNOOPY_FORCE_TRANSITION_PAIR_ID=<pair>`, `SNOOPY_FORCE_ASSET_ID=<AS id>`,
   `SNOOPY_FORCE_IDLE_ID=<IS id>`, `SNOOPY_FORCE_POSE_ID` / `SNOOPY_FORCE_CHARACTER_ASSET_ID`
   pin specific assets, `SNOOPY_DISABLE_DERIVED_MEDIA=1` skips proxies. Watch
   `log stream --style compact --predicate 'process == "SnoopyWallpaper"'` (or
   `legacyScreenSaver`) for `SnoopyTVScreenSaver:` lines. Build the derived proxies for any new
   frame sequences (`scripts/build_and_install.sh` does; `SNOOPY_SKIP_PROXY_BUILD=1` skips).
6. **Deliver.** A branch off `claude/snoopy-wallpaper-8fmsgn`; no media in git
   (`Resources/SnoopyAssets/` is ignored — keep it that way); the decoded semantics and the
   evidence in `docs/` (extend `AS_TRIGGER_CONDITIONS.md` or add `docs/REACTION_POSES.md`);
   CI green.

## 6. Build and run

```sh
swift build -c release && swift test
SNOOPY_ASSETS=link SNOOPY_INSTALL=1 sh scripts/build_wallpaper_app.sh   # wallpaper app
sh scripts/build_and_install.sh                                          # SNOOPY.saver (+ proxies)
```

## 7. Ask the user when you get there

- Where the extraction lives, and which Xcode / tvOS runtime version it came from.
- Whether the extraction can be redone keeping the `.icasset` folders (that is the fastest
  route to real metadata).
