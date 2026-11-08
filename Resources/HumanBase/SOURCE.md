# HumanBase — source and licence

- **What**: Moonlight's universal character base body (neutral mannequin,
  T-pose, metres, y up, faces +z, character's right = −x).
- **Made from**: the MakeHuman hm08 base mesh, default skeleton
  (`default.mhskel`), default skin weights (`default_weights.mhw`) and body
  targets, makehumancommunity/makehuman commit
  `a8bc2d54ff0ac92e78ff71431b1023eda42bf482`.
- **Licence**: those assets are released under **CC0 1.0 Universal** by the
  MakeHuman project (file headers and `LICENSE.md` of that repository; the
  CC0 text is in `LICENSE-MakeHuman-CC0.md`). CC0 allows commercial use,
  modification and redistribution without attribution; we credit it anyway.
- **Build**: `python3 tools/humanbase/build_humanbase.py` (editable; it
  documents every step). `python3 tools/humanbase/preview.py out.png` renders
  every LOD and some shaped bodies from the shipped binary.
- **Files**
  - `HumanBase.hbm` — what the app reads (`HumanBaseAsset.swift`): 13 380
    surface vertices, 60 joints (27 standard + 15 finger joints per hand,
    jaw, two eyes), four weights per vertex, 18 shape channels, LOD0 19 500 /
    LOD1 7 800 / LOD2 1 950 triangles.
  - `HumanBase_LOD0.obj` — the same LOD0 surface with UVs and normals, to
    open in Blender or any 3D editor.
  - `HumanBase_joints.json` — joint names, parents and positions.
