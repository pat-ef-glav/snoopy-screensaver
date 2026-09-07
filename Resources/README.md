# SnoopyAssets

This is the local media folder for the screen saver project. The media is not distributed with the public source repository.

Download the asset package from one of the links below,

then extract it and place the `SnoopyAssets` folder inside this `Resources` folder.

---

Google Drive
```
https://drive.google.com/file/d/1nMUCcU_zkRBOaJ5IQS8BWdLUJLnOv4Ai/view?usp=sharing
```

Quark Cloud Drive
```
Link: https://pan.quark.cn/s/554975cdd205?pwd=vKiR
Passcode: vKiR
```

Baidu Netdisk
```
Link: https://pan.baidu.com/s/1sfme9oQ2ruLxBNSkK5SFOg
Passcode: 53cm 
```

---

## The V2 reaction-pose bundle (`idlechara_defaultV2_v1`)

The asset package above is Apple's original (V1) bundle set. `asset-index.json` also lists a
second, small bundle, `idlechara_defaultV2_v1` (44 assets, 18 MB): the reaction poses
(`RPH`/`RPD`/`RWH`/`RWD`, see `docs/REACTION_POSES.md`). It is not part of the package
download; it is a copy of `IdleCharacterUI.framework/DefaultAssetBundleV2` from the tvOS 26.5
simulator runtime. If the folder is missing, the engine skips every reaction and behaves exactly
as before; to add it, copy the `.icasset` folders into `SnoopyAssets/idlechara_defaultV2_v1/`
(the index already describes them), or re-index any `.icasset` bundle with
`python3 Tools/build_asset_index.py add-bundle <folder-name>`.
