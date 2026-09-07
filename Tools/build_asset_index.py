#!/usr/bin/env python3
"""Build, validate and extend Resources/asset-index.json (schema 1) from .icasset folders.

Usage
-----
    Tools/build_asset_index.py validate            [--index PATH] [--assets DIR] [--bundle NAME ...]
    Tools/build_asset_index.py add-bundle NAME      [--index PATH] [--assets DIR]
    Tools/build_asset_index.py regenerate-bundle NAME [--index PATH] [--assets DIR]
    Tools/build_asset_index.py round-trip          [--index PATH]

    validate            Rebuild every record of every bundle listed in the index from
                        <assets>/<bundle>/<id>.icasset and compare it with the shipped record
                        (deep equality of the JSON values). Prints a per-metadataType summary,
                        the first differing key paths, checks the record order, the bundles list
                        and the summary block, and finishes with the pure JSON round-trip check.
                        Exit status 0 only when everything matches.
    add-bundle NAME     Index <assets>/NAME (which must not be in the index yet). Existing records
                        are left untouched and in their order; the new records are appended sorted
                        by id; {name, assetCount} is appended to `bundles`; `summary` is recomputed.
    regenerate-bundle   Rebuild the records of a bundle that is already in the index, in place.
    round-trip          json.load the index and re-serialise it with this script's writer
                        settings; the bytes must be identical to the file.

    --index   defaults to Resources/asset-index.json next to this script's repo root.
    --assets  defaults to <index dir>/SnoopyAssets (the media folder, gitignored).
    --no-carry-timing   (validate) do not import effectiveEndSeconds from the index; shows the
                        pixel-derived field as a difference instead of carrying it over.

Python 3 standard library only. The index is written atomically (temp file in the same
directory, then os.replace) because other tools read it while it is being rebuilt.

Record shape (schema 1)
-----------------------
Each `<id>.icasset` folder holds `metadata.icmetadata` (an XML plist with exactly one top-level
key, the metadataType, whose value is `{"_0": body}`), `version.icversion` (a plist with
majorVersion/minorVersion), the media files and, on some assets, `status.icstatus`
(`key=value` lines; the value of `status` is recorded as a string, e.g. "2").

    id                 folder name without .icasset
    bundle             bundle folder name
    relativePath       "<bundle>/<id>.icasset"
    metadataType       the single top-level plist key
    media              every media file in the folder (suffix in MEDIA_SUFFIXES), sorted by name:
                       {name, bytes, relativePath, suffix}; activeScene .mov files additionally carry
                       durationSeconds (mvhd duration / timescale, rounded to 3 decimals) and
                       effectiveEndSeconds (see below)
    sprites            one record per sprite of every sprite group in
                       body.assetContainer.content: oneShotSprites.oneShotSprites.sprites[i]
                       (phase "oneShot") and phasedSprites.phasedSprites.{intro,loop,outro}Sprites
                       .sprites[i] (phase intro/loop/outro), each flattened as {assetBaseName,
                       assetSize (floats), customTiming (dict or null), endBehavior,
                       frameIndexDigitCount, mediaFiles, metadataPath (plist key path),
                       phase, placement, plane, spriteType}. mediaFiles: for a video sprite the
                       "<assetBaseName>.mov" in the folder; for a frameSequence sprite every
                       "<assetBaseName>_<digits>.<ext>" in the folder, sorted.
    relevancyData      body.relevancyData as authored, {} when the plist has none
    transitionCategoryIDs   body.transitionCategoryIDs, [] when absent
    startCharacterBasePoseID / endCharacterBasePoseID   promoted when present
    phase              characterReactionTransitionPose: {kind: "enter"|"exit", ...inner keys}
                       from body.phase = {enter: {startCharacterPoseID}} | {exit: {endCharacterPoseID}}
    transitionPhase    characterSceneTransitionPose: body.transitionPhase
    transitionCategory sceneTransitionCategory: body minus assetContainer/relevancyData
    transitionPair     sceneTransitionPair: {hideParametersID, revealParametersID} from
                       body.hideStyle.sprite.parametersID / body.revealStyle.sprite.parametersID
    scenePalette       scenePalette: body minus assetContainer/relevancyData
                       (+ top-level parentIdleSceneIDs when the body has it)
    idleScene          idleScene: body minus assetContainer/relevancyData ({exclusions, sceneOffset?})
    visitor            idleSceneVisitor: {ignoresSceneOffset, isFullscreenEffect}
    reactionStyleID    characterReactionPose / characterReactionTransitionPose: body.reactionStyleID
                       (new with the V2 bundle; V1 records have none)
    integrity          {valid, metadata, mediaFileCount, missingMedia}; mediaFileCount is the number
                       of files the sprites reference (sum of sprites[].mediaFiles), which can be
                       smaller than len(media) when a folder holds stray media (103_TM006_*)
    status             value of `status` in status.icstatus, else null
    version            {majorVersion, minorVersion} from version.icversion

Fields that are not derivable from the .icasset folder
------------------------------------------------------
media[].effectiveEndSeconds on activeScene videos is the "last visually-changing timestamp"
(see MediaRecord in Sources/SnoopyTVCore/Models.swift): the original builder decoded the
frames to find where the picture stops changing. That is not reproducible from the container
metadata, so this script carries the value over from the existing index (matched by the
media relativePath) and falls back to durationSeconds when there is nothing to carry over
(the engine applies the same fallback at runtime: effectiveEndSeconds ?? durationSeconds).
In the shipped index 33 of the 73 active scenes have an effectiveEndSeconds that differs
from durationSeconds (`validate --no-carry-timing` lists them). Everything else in the 397 shipped records is regenerated from the
folders and matches field for field (`validate`).
"""

import argparse
import json
import os
import plistlib
import re
import struct
import sys
import tempfile

MEDIA_SUFFIXES = {".heic", ".heif", ".mov", ".mp4", ".m4v", ".png", ".jpg", ".jpeg"}
VIDEO_SUFFIXES = (".mov", ".mp4", ".m4v")
FRAME_SUFFIXES = ("heic", "heif", "png", "jpg", "jpeg")
ASSET_SUFFIX = ".icasset"
PHASED_GROUPS = (("introSprites", "intro"), ("loopSprites", "loop"), ("outroSprites", "outro"))
BODY_PRIVATE_KEYS = ("assetContainer", "relevancyData")
TIMED_METADATA_TYPES = {"activeScene"}


# --------------------------------------------------------------------------- helpers

def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_index_path():
    return os.path.join(repo_root(), "Resources", "asset-index.json")


def dump_index(index):
    """The exact serialisation of the shipped index: 2-space indent, sorted keys, ASCII, newline."""
    return json.dumps(index, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def load_index(path):
    with open(path, "rb") as handle:
        return json.load(handle)


def write_index_atomically(index, path):
    directory = os.path.dirname(os.path.abspath(path))
    try:
        mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        mode = 0o644
    fd, temp_path = tempfile.mkstemp(prefix=".asset-index.", suffix=".json.tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(dump_index(index))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, mode)  # mkstemp creates 0600; keep the index readable like before
        os.replace(temp_path, path)
    except BaseException:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def json_normalise(value):
    """Round-trip through JSON so plist types (tuples, ints vs floats) compare like the file."""
    return json.loads(json.dumps(value, sort_keys=True))


def canonical_json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True)


# --------------------------------------------------------------------------- QuickTime duration

def _iter_atoms(handle, start, end):
    position = start
    while position + 8 <= end:
        handle.seek(position)
        header = handle.read(8)
        if len(header) < 8:
            return
        size, kind = struct.unpack(">I4s", header)
        header_size = 8
        if size == 1:
            size = struct.unpack(">Q", handle.read(8))[0]
            header_size = 16
        elif size == 0:
            size = end - position
        if size < header_size:
            return
        yield kind, position + header_size, position + size
        position += size


def movie_duration_seconds(path):
    """Duration of a QuickTime/MP4 file from the moov/mvhd atom, rounded to 3 decimals."""
    file_size = os.path.getsize(path)
    with open(path, "rb") as handle:
        for kind, body_start, body_end in _iter_atoms(handle, 0, file_size):
            if kind != b"moov":
                continue
            for inner_kind, inner_start, _ in _iter_atoms(handle, body_start, body_end):
                if inner_kind != b"mvhd":
                    continue
                handle.seek(inner_start)
                version = handle.read(1)[0]
                handle.seek(inner_start + 4)
                if version == 1:
                    _, _, timescale, duration = struct.unpack(">QQIQ", handle.read(28))
                else:
                    _, _, timescale, duration = struct.unpack(">IIII", handle.read(16))
                if timescale == 0:
                    return None
                return round(duration / timescale, 3)
    return None


# --------------------------------------------------------------------------- record builder

class RecordError(Exception):
    pass


def read_version(asset_dir):
    path = os.path.join(asset_dir, "version.icversion")
    if not os.path.exists(path):
        return None
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    return {"majorVersion": plist.get("majorVersion"), "minorVersion": plist.get("minorVersion")}


def read_status(asset_dir):
    path = os.path.join(asset_dir, "status.icstatus")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            key, separator, value = line.strip().partition("=")
            if separator and key.strip() == "status":
                return value.strip()
    return None


def body_extras(body):
    return {key: value for key, value in body.items() if key not in BODY_PRIVATE_KEYS}


def style_parameters_id(style):
    if isinstance(style, dict) and isinstance(style.get("sprite"), dict):
        return style["sprite"].get("parametersID")
    return None


def sprite_media_files(sprite, atlas, folder_files):
    """The media files backing one sprite, and the ones its metadata expects but the folder lacks."""
    base_name = atlas.get("assetBaseName")
    sprite_type = sprite.get("spriteType")
    if not base_name:
        return [], []
    if sprite_type == "video":
        present = [base_name + suffix for suffix in VIDEO_SUFFIXES if base_name + suffix in folder_files]
        missing = [] if present else [base_name + ".mov"]
        return present, missing
    pattern = re.compile(r"^%s_(\d+)\.(%s)$" % (re.escape(base_name), "|".join(FRAME_SUFFIXES)))
    present = sorted(name for name in folder_files if pattern.match(name))
    missing = []
    timing = sprite.get("customTiming")
    if isinstance(timing, dict) and "start" in timing and "end" in timing:
        digits = int(atlas.get("frameIndexDigitCount") or 0)
        present_stems = {os.path.splitext(name)[0] for name in present}
        for frame in range(int(timing["start"]), int(timing["end"]) + 1):
            stem = "%s_%0*d" % (base_name, digits, frame)
            if stem not in present_stems:
                missing.append(stem + ".heic")
    return present, missing


def build_sprite(sprite, metadata_path, phase, folder_files):
    atlas = sprite.get("atlas") or {}
    media_files, missing = sprite_media_files(sprite, atlas, folder_files)
    size = atlas.get("assetSize")
    record = {
        "assetBaseName": atlas.get("assetBaseName"),
        "assetSize": [float(value) for value in size] if isinstance(size, (list, tuple)) else None,
        "customTiming": sprite.get("customTiming"),
        "endBehavior": sprite.get("endBehavior"),
        "frameIndexDigitCount": atlas.get("frameIndexDigitCount"),
        "mediaFiles": media_files,
        "metadataPath": metadata_path,
        "phase": phase,
        "placement": sprite.get("placement"),
        "plane": sprite.get("plane"),
        "spriteType": sprite.get("spriteType"),
    }
    return record, missing


def build_sprites(metadata_type, content, folder_files):
    sprites, missing = [], []
    prefix = "%s._0.assetContainer.content" % metadata_type
    for content_key, group in content.items():
        if content_key == "oneShotSprites":
            inner = group.get("oneShotSprites", {}) if isinstance(group, dict) else {}
            for index, sprite in enumerate(inner.get("sprites", [])):
                path = "%s.oneShotSprites.oneShotSprites.sprites.%d" % (prefix, index)
                record, lost = build_sprite(sprite, path, "oneShot", folder_files)
                sprites.append(record)
                missing.extend(lost)
        elif content_key == "phasedSprites":
            inner = group.get("phasedSprites", {}) if isinstance(group, dict) else {}
            for group_key, phase in PHASED_GROUPS:
                for index, sprite in enumerate(inner.get(group_key, {}).get("sprites", [])):
                    path = "%s.phasedSprites.phasedSprites.%s.sprites.%d" % (prefix, group_key, index)
                    record, lost = build_sprite(sprite, path, phase, folder_files)
                    sprites.append(record)
                    missing.extend(lost)
        else:
            raise RecordError("unknown sprite group %r" % content_key)
    return sprites, missing


def build_media(asset_dir, relative_path, metadata_type, timing_source):
    media = []
    for name in sorted(os.listdir(asset_dir)):
        suffix = os.path.splitext(name)[1].lower()
        if suffix not in MEDIA_SUFFIXES or name.startswith("."):
            continue
        full = os.path.join(asset_dir, name)
        if not os.path.isfile(full):
            continue
        entry = {
            "bytes": os.path.getsize(full),
            "name": name,
            "relativePath": "%s/%s" % (relative_path, name),
            "suffix": suffix,
        }
        if metadata_type in TIMED_METADATA_TYPES and suffix in VIDEO_SUFFIXES:
            duration = movie_duration_seconds(full)
            if duration is not None:
                entry["durationSeconds"] = duration
                carried = timing_source.get(entry["relativePath"]) if timing_source else None
                if carried is not None and carried.get("effectiveEndSeconds") is not None:
                    entry["effectiveEndSeconds"] = carried["effectiveEndSeconds"]
                else:
                    entry["effectiveEndSeconds"] = duration
        media.append(entry)
    return media


def build_record(assets_root, bundle, folder_name, timing_source=None):
    if not folder_name.endswith(ASSET_SUFFIX):
        raise RecordError("not an .icasset folder: %s" % folder_name)
    asset_id = folder_name[: -len(ASSET_SUFFIX)]
    relative_path = "%s/%s" % (bundle, folder_name)
    asset_dir = os.path.join(assets_root, bundle, folder_name)
    metadata_path = os.path.join(asset_dir, "metadata.icmetadata")
    with open(metadata_path, "rb") as handle:
        plist = plistlib.load(handle)
    if not isinstance(plist, dict) or len(plist) != 1:
        raise RecordError("%s: expected exactly one top-level key, got %r" % (relative_path, list(plist)))
    metadata_type = next(iter(plist))
    wrapper = plist[metadata_type]
    body = wrapper.get("_0") if isinstance(wrapper, dict) else None
    if not isinstance(body, dict):
        raise RecordError("%s: missing _0 body" % relative_path)
    content = (body.get("assetContainer") or {}).get("content") or {}
    folder_files = set(os.listdir(asset_dir))

    sprites, missing = build_sprites(metadata_type, content, folder_files)
    media = build_media(asset_dir, relative_path, metadata_type, timing_source)

    record = {
        "bundle": bundle,
        "id": asset_id,
        "integrity": {
            # Counts the files the sprites reference, not the folder: a folder may hold
            # stray media that no sprite uses (103_TM006_* ship unreferenced .mov files).
            "mediaFileCount": sum(len(sprite["mediaFiles"]) for sprite in sprites),
            "metadata": True,
            "missingMedia": missing,
            "valid": not missing,
        },
        "media": media,
        "metadataType": metadata_type,
        "relativePath": relative_path,
        "relevancyData": body.get("relevancyData", {}),
        "sprites": sprites,
        "status": read_status(asset_dir),
        "transitionCategoryIDs": body.get("transitionCategoryIDs", []),
        "version": read_version(asset_dir),
    }
    for key in ("startCharacterBasePoseID", "endCharacterBasePoseID", "transitionPhase", "reactionStyleID"):
        if key in body:
            record[key] = body[key]

    if metadata_type == "characterReactionTransitionPose" and isinstance(body.get("phase"), dict) and body["phase"]:
        kind = next(iter(body["phase"]))
        inner = body["phase"][kind]
        phase = {"kind": kind}
        if isinstance(inner, dict):
            phase.update(inner)
        record["phase"] = phase
    elif metadata_type == "sceneTransitionCategory":
        record["transitionCategory"] = body_extras(body)
    elif metadata_type == "sceneTransitionPair":
        pair = {}
        hide_id = style_parameters_id(body.get("hideStyle"))
        reveal_id = style_parameters_id(body.get("revealStyle"))
        if hide_id is not None:
            pair["hideParametersID"] = hide_id
        elif "hideStyle" in body:
            pair["hideStyle"] = body["hideStyle"]
        if reveal_id is not None:
            pair["revealParametersID"] = reveal_id
        elif "revealStyle" in body:
            pair["revealStyle"] = body["revealStyle"]
        record["transitionPair"] = pair
    elif metadata_type == "scenePalette":
        record["scenePalette"] = body_extras(body)
        if "parentIdleSceneIDs" in body:
            record["parentIdleSceneIDs"] = body["parentIdleSceneIDs"]
    elif metadata_type == "idleScene":
        record["idleScene"] = body_extras(body)
    elif metadata_type == "idleSceneVisitor":
        record["visitor"] = {
            "ignoresSceneOffset": bool(body.get("ignoresSceneOffset", False)),
            "isFullscreenEffect": bool(body.get("isFullscreenEffect", False)),
        }
    return json_normalise(record)


def list_asset_folders(assets_root, bundle):
    bundle_dir = os.path.join(assets_root, bundle)
    if not os.path.isdir(bundle_dir):
        raise RecordError("bundle folder not found: %s" % bundle_dir)
    return sorted(
        name for name in os.listdir(bundle_dir)
        if name.endswith(ASSET_SUFFIX) and os.path.isdir(os.path.join(bundle_dir, name))
    )


def build_bundle(assets_root, bundle, timing_source=None, errors=None):
    """Records of one bundle, sorted by id (the folder order), plus any per-asset failures."""
    records = []
    for folder_name in list_asset_folders(assets_root, bundle):
        try:
            records.append(build_record(assets_root, bundle, folder_name, timing_source))
        except Exception as error:  # noqa: BLE001 - reported, not swallowed
            if errors is None:
                raise
            errors.append({"relativePath": "%s/%s" % (bundle, folder_name), "error": str(error)})
    records.sort(key=lambda record: record["id"])
    return records


def timing_source_from_index(index):
    source = {}
    for record in index.get("assets", []):
        for entry in record.get("media", []):
            if "durationSeconds" in entry or "effectiveEndSeconds" in entry:
                source[entry["relativePath"]] = {
                    "durationSeconds": entry.get("durationSeconds"),
                    "effectiveEndSeconds": entry.get("effectiveEndSeconds"),
                }
    return source


def compute_summary(index):
    assets = index["assets"]
    return {
        "assetCount": len(assets),
        "bundleCount": len(index["bundles"]),
        "invalidAssetCount": sum(1 for record in assets if not (record.get("integrity") or {}).get("valid", True)),
        "videoTimingCount": sum(
            1 for record in assets for entry in record.get("media", []) if "durationSeconds" in entry
        ),
    }


# --------------------------------------------------------------------------- diffing

def diff_paths(expected, actual, path="", out=None, limit=50):
    if out is None:
        out = []
    if len(out) >= limit:
        return out
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            child = "%s.%s" % (path, key) if path else key
            if key not in expected:
                out.append("%s: unexpected (builder=%s)" % (child, canonical_json(actual[key])[:80]))
            elif key not in actual:
                out.append("%s: missing (shipped=%s)" % (child, canonical_json(expected[key])[:80]))
            else:
                diff_paths(expected[key], actual[key], child, out, limit)
    elif isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            out.append("%s: length %d (shipped) vs %d (builder)" % (path, len(expected), len(actual)))
        for index, (left, right) in enumerate(zip(expected, actual)):
            diff_paths(left, right, "%s[%d]" % (path, index), out, limit)
    else:
        if isinstance(expected, (int, float)) and isinstance(actual, (int, float)) and not isinstance(expected, bool) and not isinstance(actual, bool):
            if expected == actual:
                return out
        if expected != actual:
            out.append("%s: shipped=%s builder=%s" % (path, canonical_json(expected)[:80], canonical_json(actual)[:80]))
    return out


def field_family(path):
    """Collapse a diff path into the field it belongs to, e.g. media[3].bytes -> media[].bytes."""
    return re.sub(r"\[\d+\]", "[]", path.split(":")[0])


# --------------------------------------------------------------------------- commands

def command_round_trip(index_path):
    with open(index_path, "rb") as handle:
        raw = handle.read()
    regenerated = dump_index(json.loads(raw)).encode("utf-8")
    identical = regenerated == raw
    print("round-trip: %s (%d bytes)" % ("identical" if identical else "DIFFERENT", len(raw)))
    return identical


def command_validate(index_path, assets_root, bundles, carry_timing=True):
    index = load_index(index_path)
    shipped = index["assets"]
    timing_source = timing_source_from_index(index) if carry_timing else None
    shipped_by_path = {record["relativePath"]: record for record in shipped}
    wanted = [entry["name"] for entry in index["bundles"]]
    if bundles:
        wanted = [name for name in wanted if name in set(bundles)]

    per_type = {}
    field_counts = {}
    example_lines = []
    matched = mismatched = extra = 0
    regenerated_order = []
    ok = True

    for bundle in wanted:
        errors = []
        records = build_bundle(assets_root, bundle, timing_source, errors)
        for error in errors:
            ok = False
            print("ERROR %s: %s" % (error["relativePath"], error["error"]))
        for record in records:
            regenerated_order.append(record["relativePath"])
            expected = shipped_by_path.get(record["relativePath"])
            kind = record["metadataType"]
            stats = per_type.setdefault(kind, {"total": 0, "match": 0, "diff": 0})
            if expected is None:
                extra += 1
                print("EXTRA  %s is on disk but not in the index" % record["relativePath"])
                continue
            stats["total"] += 1
            diffs = diff_paths(json_normalise(expected), record)
            if diffs:
                mismatched += 1
                stats["diff"] += 1
                for line in diffs:
                    field_counts[(kind, field_family(line))] = field_counts.get((kind, field_family(line)), 0) + 1
                if len(example_lines) < 40:
                    example_lines.append("  %s" % record["id"])
                    example_lines.extend("      %s" % line for line in diffs[:6])
            else:
                matched += 1
                stats["match"] += 1

    print("validate: %d/%d shipped records regenerated identically, %d differ, %d extra on disk"
          % (matched, len([r for r in shipped if r["bundle"] in set(wanted)]), mismatched, extra))
    print("per metadataType:")
    for kind in sorted(per_type):
        stats = per_type[kind]
        print("  %-36s %3d/%3d match%s" % (kind, stats["match"], stats["total"],
                                            ("  (%d differ)" % stats["diff"]) if stats["diff"] else ""))
    if field_counts:
        print("differing fields:")
        for (kind, field), count in sorted(field_counts.items()):
            print("  %-36s %-48s %d" % (kind, field, count))
        print("examples:")
        print("\n".join(example_lines))
        ok = False
    if extra:
        ok = False

    shipped_order = [record["relativePath"] for record in shipped if record["bundle"] in set(wanted)]
    shipped_bundle_order = [name for name in wanted]
    order_ok = regenerated_order == shipped_order and wanted == [entry["name"] for entry in index["bundles"] if entry["name"] in set(wanted)]
    print("record order (bundles in index order, ids sorted within each bundle): %s"
          % ("identical" if order_ok else "DIFFERENT"))
    ok = ok and order_ok

    if not bundles:
        bundle_entries = [{"assetCount": sum(1 for r in shipped if r["bundle"] == name), "name": name} for name in shipped_bundle_order]
        bundles_ok = bundle_entries == index["bundles"]
        summary_ok = compute_summary(index) == index["summary"]
        print("bundles block: %s; summary block: %s" % ("identical" if bundles_ok else "DIFFERENT",
                                                        "identical" if summary_ok else "DIFFERENT"))
        ok = ok and bundles_ok and summary_ok

    if timing_source:
        carried = 0
        differs = 0
        for record in shipped:
            for entry in record.get("media", []):
                if "effectiveEndSeconds" in entry:
                    carried += 1
                    if entry["effectiveEndSeconds"] != entry.get("durationSeconds"):
                        differs += 1
        print("note: effectiveEndSeconds carried over from the index for %d media entries (%d differ from "
              "durationSeconds); it is pixel-derived and not regenerated. durationSeconds is regenerated "
              "from the mvhd atom." % (carried, differs))

    ok = command_round_trip(index_path) and ok
    return ok


def _assert_unchanged(before, after, count):
    if before[:count] != after[:count]:
        raise RecordError("existing records changed during merge; aborting")


def command_add_bundle(index_path, assets_root, bundle):
    index = load_index(index_path)
    if any(entry["name"] == bundle for entry in index["bundles"]) or any(r["bundle"] == bundle for r in index["assets"]):
        raise RecordError("bundle %s is already in the index; use regenerate-bundle" % bundle)
    before = [canonical_json(record) for record in index["assets"]]
    errors = []
    records = build_bundle(assets_root, bundle, timing_source_from_index(index), errors)
    if errors:
        for error in errors:
            print("ERROR %s: %s" % (error["relativePath"], error["error"]))
        raise RecordError("%d asset(s) failed; index not written" % len(errors))
    if not records:
        raise RecordError("no .icasset folders found in %s" % os.path.join(assets_root, bundle))
    index["assets"].extend(records)
    index["bundles"].append({"assetCount": len(records), "name": bundle})
    index["summary"] = compute_summary(index)
    after = [canonical_json(record) for record in index["assets"]]
    _assert_unchanged(before, after, len(before))
    write_index_atomically(index, index_path)
    print("add-bundle: appended %d records for %s; index now has %d assets in %d bundles; summary %s"
          % (len(records), bundle, len(index["assets"]), len(index["bundles"]), canonical_json(index["summary"])))
    return True


def command_regenerate_bundle(index_path, assets_root, bundle):
    index = load_index(index_path)
    if not any(entry["name"] == bundle for entry in index["bundles"]):
        raise RecordError("bundle %s is not in the index; use add-bundle" % bundle)
    errors = []
    records = build_bundle(assets_root, bundle, timing_source_from_index(index), errors)
    if errors:
        for error in errors:
            print("ERROR %s: %s" % (error["relativePath"], error["error"]))
        raise RecordError("%d asset(s) failed; index not written" % len(errors))
    old_positions = [i for i, record in enumerate(index["assets"]) if record["bundle"] == bundle]
    insert_at = old_positions[0] if old_positions else len(index["assets"])
    kept = [record for record in index["assets"] if record["bundle"] != bundle]
    index["assets"] = kept[:insert_at] + records + kept[insert_at:]
    for entry in index["bundles"]:
        if entry["name"] == bundle:
            entry["assetCount"] = len(records)
    index["summary"] = compute_summary(index)
    write_index_atomically(index, index_path)
    print("regenerate-bundle: rebuilt %d records for %s (previously %d); index now has %d assets"
          % (len(records), bundle, len(old_positions), len(index["assets"])))
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["validate", "add-bundle", "regenerate-bundle", "round-trip"])
    parser.add_argument("name", nargs="?", help="bundle folder name (add-bundle / regenerate-bundle)")
    parser.add_argument("--index", default=default_index_path(), help="path to asset-index.json")
    parser.add_argument("--assets", help="media root holding <bundle>/<id>.icasset (default: <index dir>/SnoopyAssets)")
    parser.add_argument("--bundle", action="append", help="validate only these bundles (repeatable)")
    parser.add_argument("--no-carry-timing", action="store_true", help="validate: do not import effectiveEndSeconds")
    args = parser.parse_args(argv)

    index_path = os.path.abspath(args.index)
    assets_root = os.path.abspath(args.assets) if args.assets else os.path.join(os.path.dirname(index_path), "SnoopyAssets")

    try:
        if args.command == "round-trip":
            ok = command_round_trip(index_path)
        elif args.command == "validate":
            ok = command_validate(index_path, assets_root, args.bundle, carry_timing=not args.no_carry_timing)
        elif args.command in ("add-bundle", "regenerate-bundle"):
            if not args.name:
                parser.error("%s needs a bundle name" % args.command)
            if args.command == "add-bundle":
                ok = command_add_bundle(index_path, assets_root, args.name)
            else:
                ok = command_regenerate_bundle(index_path, assets_root, args.name)
        else:
            parser.error("unknown command")
            return 2
    except RecordError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
