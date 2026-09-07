# Reaction poses (RPH / RPD / RWH / RWD)

This document records what the newer reaction-pose clips are, where the evidence comes
from, and how this engine uses them. Everything in §1–§3 is derived from Apple's own
metadata and binaries; nothing there is guessed from file names.

## 1. Where the assets and their metadata live

The 44 "unknown" `.mov` clips in the user's extraction are byte-for-byte copies of the
`DefaultAssetBundleV2` folder that ships inside the tvOS 26.5 (23L470) simulator runtime:

```
/Library/Developer/CoreSimulator/Volumes/tvOS_23L470/Library/Developer/CoreSimulator/Profiles/Runtimes/tvOS 26.5.simruntime/
  Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/IdleCharacterUI.framework/
    DefaultAssetBundle/     146 .icasset + manifest.icassetmanifest   (the "V1" model: BP/AP/CM/IS/AS/ST/TM/…)
    DefaultAssetBundleV2/    44 .icasset + manifest.icassetmanifest   (overrideModelVersion 2.0: the reaction poses)
```

Each `.icasset` is a folder with `metadata.icmetadata` (an XML property list), `version.icversion`
(`{majorVersion, minorVersion}`), the media, and — V2 only — a `media.txt` with the animator's
original file name and delivery date. The V1 metadata in the runtime is identical to the
metadata in the 7.2 GB 4K package except for `mediaVersion` (`-1` in the runtime, `0` in the
package). The tvOS 27.0 (24J5356a) runtime carries the same two bundles with the same 190 ids.

The V2 clips are HEVC-with-alpha, 2880×1620, 24 fps, exactly like the package's `.mov` sprites;
`assetSize` in the metadata is `[1920, 1080]` (the design viewport), also exactly like the package.

## 2. The two record types

### `characterReactionTransitionPose` (enter / exit clips)

Same shape as the V1 `BP00x_To_RPH` / `RPH_To_BP00x` HEIC records, plus one new key:

```
characterReactionTransitionPose._0:
  assetContainer.content.oneShotSprites.oneShotSprites.sprites[0]   (spriteType video, endBehavior freeze)
  phase: { enter: { startCharacterPoseID } } | { exit: { endCharacterPoseID } }
  reactionStyleID: <style>                                            ← new in V2
```

`startCharacterPoseID` is a base pose **or an additional pose** (`101_AP001`, `103_AP021`, …):
V2 adds shortcuts that leave an AP loop directly, without playing the AP outro. `endCharacterPoseID`
is always a base pose.

### `characterReactionPose` (the reaction itself) — new metadataType

```
characterReactionPose._0:
  assetContainer.content.oneShotSprites.oneShotSprites.sprites[0]   (spriteType video, endBehavior freeze)
  reactionStyleID: <style>
  relevancyData.info: [ { reactionTrigger: { reactionTrigger: <trigger> } } ]
```

## 3. Decoded semantics

### Styles (`reactionStyleID`)

| Filename code | `reactionStyleID` | What the frames show |
|---|---|---|
| `RPH` | `standardReactionTransitionStyleID` | Snoopy seated, facing the viewer (the V1 reaction pose; V1 records carry no `reactionStyleID`, the binary calls this `CharacterReactionPoseDefaultStyleID`) |
| `RPD` | `alternateReactionTransitionStyleID` | Snoopy seated in profile, facing right |
| `RWH` | `standardWithCompanionReactionTransitionStyleID` | as RPH, with Woodstock present during the reaction |
| `RWD` | `alternateWithCompanionReactionTransitionStyleID` | as RPD, with Woodstock present (his flight-trail dots are visible in `101_RWD001`) |

So `R` = reaction, `P`/`W` = alone / **W**ith companion, `H`/`D` = the standard / alternate seated
pose. The letters H and D themselves are not named anywhere in the binaries; only the style ids are.

A style is a closed family: an enter, the reaction pose and an exit must all carry the same
`reactionStyleID` (IdleCharacterCore keeps `reactionPosesByStyleID`, `supportedReactionStylesByAnimationID`
and logs `No CharacterReactionPoseStorage found for CharacterReactionStyleID`).

### Which style applies is decided by the *current animation*

| Current animation | Enter clips that exist | Styles reachable |
|---|---|---|
| `101_BP001…004` | `BP00x_To_RPH` (V1, HEIC) and `BP00x_To_RPD` (V2) | standard, alternate |
| `101_AP001`, `101_AP002`, `101_AP003`, `101_AP007`, `104_AP028` (Snoopy alone) | `AP0xx_To_RPH`, `AP0xx_To_RPD` | standard, alternate |
| `101_AP010`, `103_AP021`, `104_AP031` (Woodstock is on screen in these poses) | `AP0xx_To_RWH`, `AP0xx_To_RWD` | standardWithCompanion, alternateWithCompanion |

There is no `BP00x_To_RW*` enter: the companion styles can only be entered from the three
additional poses in which Woodstock is already present, so he cannot pop into existence. The
companion **exits** are the solo exits re-delivered under a new name (`media.txt`:
`101_RWD_To_BP001` ← `101_RPD_To_BP001_V5.mov`, `101_RWH_To_BP001` ← `101_RPH_To_BP001_v3.mov`):
Woodstock leaves during the reaction clip, and the last frame of every `RW*` pose shows Snoopy alone.

### Triggers (`relevancyData.info[].reactionTrigger`)

| Trigger | Reaction poses | Notes |
|---|---|---|
| `doorbell` | `101_RPD001`, `101_RWD001` | Snoopy barks ("ARF!") |
| `alarm` | `103_RPH002`, `103_RWH002` | |
| `music` | `104_RPH003`, `104_RWH003` | |
| `environment` | `104_RPH004`, `104_RWH004` | |
| `presence` | `104_RPD005`, `104_RWD005` | |
| `generic` | `101_RPH_Loop`, `101_RPD_Loop` | a 40-frame hold in the reaction pose; "may generically apply" to any trigger |

The numbered reactions (001 doorbell, 002 alarm, 003 music, 004 environment, 005 presence) are
numbered globally and each exists in one seated pose (D or H) with a solo and a companion flavour.

IdleCharacterUI's `ReactionTriggerBooster` scores a reaction pose against the current
`reactionTriggerEvent`:

```
"%s matches reactionTriggerEvent: %s. Boost with %f"               (reactionTriggerSpecificBoost)
"%s may generically apply to reactionTriggerEvent: %s. Boost with %f"   (reactionTriggerGenericBoost)
"%s does not match reactionTriggerEvent: %s. Fully deboost."
"%s is tagged with %s, but reactionTriggerEvent is nil or expired: %s. Fully deboost."
```

Events expire (`defaultReactionTriggerTimeout`), a handled event is not replayed
(`lastHandledReactionTriggerEvent`), and a simulated trigger can be injected for testing
(`icSimulatedReactionTrigger`, "Detected simulated ReactionTrigger: %s").

### Playback sequence (from IdleCharacterUI's log strings)

```
"Updated reactionTriggerEvent: %s was eligible to play a reactionPose, attempting to queue."
"Attempting to queue a CharacterReactionPose, but the currentAnimation is not a basePose/additionalPose: %s"
"Should not attempt reactionPose for %s, currentAnimation: %s is currently playing its outro."
"Ending looping and skipping outro of currentAnimation: %s for incoming reaction: %s."
"Unable to find enter reactionTransitionPose for id: %s to enqueue alongside %s"
"Unable to find exit reactionTransitionPose for: %s to queue alongside %s"
"A reactionPose was queued for %s, skipping standard idle animation."
"We only expect to load additionalPoses from a basePose or enter reactionTransitionPose."
```

That is: a reaction may start only from a base pose or an additional pose that is not in its
outro; the AP's loop is cut short and its outro skipped (`AP_To_R**`); the queue becomes
`enter → reactionPose → exit → BP`.

Scene transitions are unchanged from V1: `BP → BP_To_RPH → [ST hide | active scene | ST reveal] → RPH_To_BP → BP`.
The `characterSceneTransitionPose` hide/reveal clips are authored from the standard (front-facing)
pose, and V2 adds no ST clips for the other styles, so hide/reveal always use the standard style.

## 4. Inventory of the 44 V2 records

```
characterReactionPose (12):
  101_RPH_Loop  generic  standard              101_RPD_Loop  generic  alternate
  103_RPH002    alarm    standard              103_RWH002    alarm    standardWithCompanion
  104_RPH003    music    standard              104_RWH003    music    standardWithCompanion
  104_RPH004    environment standard           104_RWH004    environment standardWithCompanion
  101_RPD001    doorbell alternate             101_RWD001    doorbell alternateWithCompanion
  104_RPD005    presence alternate             104_RWD005    presence alternateWithCompanion
characterReactionTransitionPose, enter (20):
  101_BP001..004_To_RPD                        alternate
  101_AP001/002/003/007_To_RPD, 104_AP028_To_RPD   alternate
  103_AP001/002/003/007_To_RPH, 104_AP028_To_RPH   standard
  103_AP021_To_RWH, 104_AP010_To_RWH, 104_AP031_To_RWH   standardWithCompanion
  103_AP021_To_RWD, 104_AP010_To_RWD, 104_AP031_To_RWD   alternateWithCompanion
characterReactionTransitionPose, exit (12):
  101_RPD_To_BP001..004  alternate      101_RWD_To_BP001..004  alternateWithCompanion
  101_RWH_To_BP001..004  standardWithCompanion   (standard exits stay the V1 HEIC 101_RPH_To_BP00x)
```

Clip lengths: enters 12–22 frames (the companion enters from AP010 are 52), exits 26 frames, holds 40 frames, reactions 62–134 frames.

## 5. How this engine uses them

### Index

`Tools/build_asset_index.py` turns `.icasset` folders into schema-1 records (it reproduces the
shipped `Resources/asset-index.json` field for field for the ten package bundles, which is how it
is validated). The V2 folder is copied to `Resources/SnoopyAssets/idlechara_defaultV2_v1/` (media
stays out of git) and indexed as bundle `idlechara_defaultV2_v1`. New record keys:

- `reactionStyleID` (top level) on `characterReactionPose` and `characterReactionTransitionPose`.
- `relevancyData.info[].reactionTrigger` is kept as authored; `AssetRecord.reactionTriggers`
  reads it.

### Core model (`SnoopyTVCore`)

- `ReactionStyle` — the four style ids, `defaultStyle` = standard, `isCompanion`, `nodeID` (RPH/RPD/RWH/RWD).
- `ReactionTrigger` — the six trigger tokens.
- `AssetRecord.reactionStyleID`, `AssetRecord.reactionTriggers`, `AssetRecord.isReactionHold`
  (the generic `_Loop` records).
- `SelectionContext.reactionTrigger` and a `reactionTrigger` family in `RelevancyScorer`: a
  reaction pose tagged with the current trigger scores as a specific match, a `generic` pose as a
  weaker match, and any reaction pose is ineligible while no trigger is pending (Apple's booster).
- `PlaybackGraph`
  - `reactionStyle(of:)`, `reactionEnter(from:style:)`, `reactionExit(to:style:)` — style-aware;
    the style defaults to standard so V1 callers and the V1-only index behave exactly as before.
  - `supportedReactionStyles(from animationID:)` — styles with an enter from that BP or AP.
  - `reactionPoses(style:)`, `reactionHold(style:)`.
  - `reactionSequence(from:pose:to:)` — `[enter, pose, exit, BP]` in one style.
  - `idleEntrySequence` / `idleExitSequence` / `reactionQueue` keep their signatures (style optional).

### Compositor (`SnoopySceneView`)

- `triggerReaction(_:)` — hosts fire a trigger; it is consumed at the next character boundary
  while it is still fresh (30 s), like tvOS's `reactionTriggerEvent`.
- Reactions from an AP use the `AP_To_R**` shortcut (loop cut short, outro skipped); reactions from
  a BP use `BP_To_R**`. The style is chosen from the current animation, the pose from the trigger.
- During a scene transition the character holds in `101_RPH_Loop` while the hide/reveal prerolls
  instead of freezing on the last enter frame; if the hold asset is absent the old freeze is used.
- When an idle scene is due to rotate and the next action is an AP with an `AP_To_RPH` shortcut,
  the exit into the transition leaves the AP loop directly.
- Environment: `SNOOPY_REACTION_TRIGGER=<trigger>` arms one simulated trigger for the first idle
  scene (fired at its second character boundary, so it cannot expire during the opening active
  scene), `SNOOPY_REACTION_INTERVAL_SECONDS=<n>` fires a random trigger every n seconds,
  `SNOOPY_FORCE_REACTION_ID=<id>` pins the reaction pose, `SNOOPY_DISABLE_REACTION_HOLD=1` keeps
  the old freeze on the enter's last frame, and `SNOOPY_ASSET_INDEX_PATH=<file>` plays from another
  index (development only).

- Host API on `SnoopySceneView`: `triggerReaction(_:)`, `pendingReactionTriggerName` (nil once
  consumed or older than 30 s) and `availableReactionTriggers` (the fireable triggers the loaded
  index can answer, without `generic`; empty on a V1-only index).

The wallpaper app's status panel exposes the five triggers (Doorbell, Alarm, Music, Environment,
Presence) in a "Reactions" row so the clips can be seen on demand; the row is hidden when the
index has no reaction clips.

## 6. Verification (2026-09-07)

`swift build`, `swift test` (44 tests) and `python3 Tools/build_asset_index.py validate` (441/441
records regenerated identically, round trip byte-identical) are green. The compositor paths were
exercised one instance at a time with the wallpaper app built from the tree
(`SNOOPY_ASSETS=link sh scripts/build_wallpaper_app.sh`, then the binary launched with the
argument-domain overrides `-SnoopyPauseWhenHidden 0 -SnoopyWallpaperEnabled 1` so no saved
preference changes) and the `SnoopyTVScreenSaver:` lines on stderr:

| Scenario | Environment | Decisive log lines |
|---|---|---|
| Reaction from a BP, standard style | `SNOOPY_TEST_START_WITH_COMPOSITE=1 SNOOPY_FORCE_BASE_POSE_ONLY=1 SNOOPY_REACTION_TRIGGER=alarm` | `reaction queued trigger=alarm style=RPH pose=103_RPH002 from=101_BP003 sequence=101_BP003_To_RPH -> 103_RPH002 -> 101_RPH_To_BP003 -> 101_BP003` |
| Reaction from a BP, alternate style | `… SNOOPY_REACTION_TRIGGER=doorbell` | `reaction queued trigger=doorbell style=RPD pose=101_RPD001 from=101_BP001 sequence=101_BP001_To_RPD -> 101_RPD001 -> 101_RPD_To_BP001 -> 101_BP001` |
| Companion reaction through the AP shortcut | `SNOOPY_TEST_START_WITH_COMPOSITE=1 SNOOPY_FORCE_CHARACTER_KIND=additional SNOOPY_FORCE_REACTION_ID=103_RWH002 SNOOPY_REACTION_TRIGGER=alarm` | `reaction queued … style=RWH pose=103_RWH002 from=103_AP021 (AP shortcut, outro skipped, loops=4) sequence=101_BP004_To_BP003 -> 103_AP021 -> 103_AP021_To_RWH -> 103_RWH002 -> 101_RWH_To_BP001 -> 101_BP001` |
| Hold during the reveal | `SNOOPY_TEST_START_WITH_COMPOSITE=1 SNOOPY_TEST_IDLE_ROTATION_SECONDS=25 SNOOPY_FORCE_BASE_POSE_ONLY=1` | `reaction hold: 101_BP001_To_RPH then 101_RPH_Loop x6 (11.6s)` … `reached logical end at 1.542 (item end 11.542); keeps playing while the next stage prerolls` … `transition synchronized stage=reveal` … `idle exit completed` |
| Rotation through the AP shortcut | `SNOOPY_TEST_START_WITH_COMPOSITE=1 SNOOPY_TEST_IDLE_ROTATION_SECONDS=20 SNOOPY_FORCE_CHARACTER_KIND=additional SNOOPY_FORCE_CHARACTER_ASSET_ID=101_AP001` | `reaction parked: 101_AP001 leaves through 103_AP001_To_RPH (outro skipped, loops=4)` … `reaction parked at RPH; skipping idleExitSequence and starting 102_AS014 + reveal` |
| Interval triggers | `SNOOPY_TEST_START_WITH_COMPOSITE=1 SNOOPY_REACTION_INTERVAL_SECONDS=20` | one `reaction queued` per `reaction trigger=… source=interval`, never two for one trigger |
| V1-only index (no V2 bundle) | `SNOOPY_ASSET_INDEX_PATH=<HEAD index> … SNOOPY_REACTION_TRIGGER=alarm` | `reaction trigger=alarm handled (no reaction pose reachable from 101_BP004)`, the exit is `101_BP004_To_RPH items=1` and finishes with `phased video ended`: today's behaviour |

Only the reaction-pose model is new; the 71/20/9 character mix, visitors, weather effects and the
transition pairs are untouched.
