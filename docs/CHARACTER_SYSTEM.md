# Moonlight Universal Character System (MUCS) — v1.91

One character standard for Moonlight: a real base body, one skeleton
standard, one motion format and runtime, appearance kept apart from motion,
and one versioned asset format. This file records what was audited, what
was built, the formats, and — separately — what is verified where.

## 1. Audit of the code before this work (branch `claude/busy-ritchie-x38lh5`, v1.90)

| Area | What the code actually did | Done in v1.91 |
|---|---|---|
| Base body | `BaseBody` was 889 vertices of **separate tubes** per limb (not one connected surface) | `HumanBase`: the MakeHuman hm08 mesh (CC0), one connected surface, LOD0/1/2 |
| Skeletons | Two systems: the P2 **10-bone** `RigSkeleton` (depth reliefs) and the v1.73 **27-joint** `SkeletonDefinition` | 27 joints stay the base layer; 33 extension joints (fingers, jaw, eyes); `LegacyRigAdapter` maps the 10-bone rig |
| Motion formats | Four: `RigClip` (10-bone sine), `MotionClip` (27-joint sine, A-pose), `KeyframeClip` (model files), `ActionClip` (picture timing) | `UniversalMotion` + adapters for all four; one controller |
| World playback | Rigged looks played one **shared global clock** per action, wrapped in a `BillboardComponent` (a 3D model turned to face the camera like a picture) | `CharacterRuntime`: per-character controller and meshes on the world clock; real 3D facing (reliefs still face the camera) |
| Combo | No three-hit combo existed; only “the same one-shot restarts after 60 %” | `ComboRules` + `CharacterAnimationState.combo`; three authored attacks |
| Hit timing | Damage applied on the button press, the picture's “event time” only moved a spark | Rigged player: damage on the motion's hit moment by the world clock, once |
| Safety | NaN guards in two players (v1.89) | `CharacterValidator` before a model enters the world; last-good-pose fallback with an incident log |

## 2. Building blocks (all under `Features/Character/`)

| Part | File | Tested on Linux |
|---|---|---|
| HumanBase reader / shaping / skeleton / LODs | `Domain/HumanBaseAsset.swift`, `Domain/HumanBase.swift` | ✅ `HumanBaseTests` |
| Math (quaternions) | `Domain/CharacterMath.swift` | ✅ (through the others) |
| Unified motion, adapters | `Domain/UniversalMotion.swift` | ✅ `MotionSystemTests` |
| Standard motion library (25) | `Domain/MotionLibrary.swift` | ✅ |
| Animation controller, combo rules | `Domain/CharacterAnimationController.swift` | ✅ |
| Retargeting, two-bone IK, foot planting, look-at | `Domain/MotionRetargeter.swift` | ✅ |
| Legacy rigs | `Domain/LegacyRigAdapter.swift` | ✅ `CharacterSystemTests` |
| Appearance, outfit shells, equipment, materials | `Domain/CharacterAppearance.swift` | ✅ |
| Validator, CharacterPackage, store | `Domain/CharacterPackage.swift` | ✅ |
| Auto-fit routes A–E | `Domain/CharacterAutoFit.swift` | ✅ `characterAutoFitTests` |
| RealityKit runtime | `CharacterRuntime.swift` | compiled; simulator UI test |
| Packages in the app | `CharacterLibrary.swift` | compiled; simulator UI test |
| Character Workbench | `CharacterWorkbenchView.swift` | compiled; simulator UI test |

## 3. HumanBase

- Source: MakeHuman hm08 base mesh, default skeleton and weights, body
  targets, CC0 1.0 (`Resources/HumanBase/SOURCE.md`, `THIRD_PARTY_NOTICES.md`).
- Build: `python3 tools/humanbase/build_humanbase.py` (editable, documented);
  `tools/humanbase/preview.py` renders every LOD from the shipped binary.
  Editable output: `tools/humanbase/editable/HumanBase_LOD0.obj` (Blender).
- Conventions: metres, y up, faces +z, character's right = −x, **T-pose bind**,
  reference height 1.75 m, feet on y = 0.
- 13 380 surface vertices; LOD0 19 500, LOD1 7 800, LOD2 1 950 triangles
  (quadric half-edge collapse; LOD vertices are original vertices, so all
  LODs share one skeleton and the same weights and morphs).
- 60 joints: the 27 standard ones (same ids as every Moonlight rig) + 15
  finger joints per hand + jaw + two eyes. Every joint records its source.
- Shape: 18 morph channels (build, muscle, gender, shoulders, v-shape, hips,
  belly, neck, limb segments, hands, feet, head, three face shapes) and
  skinned bone-length / head scaling (legs, arms, torso, chibi head). Joints
  move with the surface; the body is re-grounded and scaled to its height,
  so sockets and colliders follow.

## 4. Motion

`UniversalMotion` (Codable, versioned): quaternion tracks per joint id in
the parent's bind frame, a root track in leg lengths, loop / speed /
interpolation, a body mask (full / upper / lower), events with stable ids,
combat phases (`activeStart`, `hit`, `activeEnd`, `cancelFrom`, `end`), an
interrupt rule and priority, its source, and a pass-through for model-file
keyframes.

Library (authored for the HumanBase T-pose): idle, walk, walkBack, run,
strafeLeft/Right, turn, jumpStart, jumpAir, land, dodge, roll, hurt,
stagger, knockdown, death, attack1–3, charge, cast, skillRelease,
weaponHold, equip, interact.

`CharacterAnimationController`: idle→walk→run on one shared cycle phase,
direction picks walk / back / strafe, air pose and landing, one-shots on
top (upper body while moving), hurt / death above all, cross-fades, events
fired once per play keyed `<motion>@<start>#<event>` — the same at 60 or 7
updates a second, and never twice for the same moment.

`MotionRetargeter`: every target bone is turned to point where its source
bone points, after removing the bind-pose difference (A↔T pose, different
limb lengths); a report lists the correction, the joints the target lacks
and the coverage. `CharacterIK`: two-bone IK toward a pole, foot planting
within reach (unchanged pose when a leg cannot do it within its limits),
head look-at within limits.

## 5. CharacterPackage (format 1)

```
<id>.mcpkg/
  Manifest.json             formatVersion, id, name, geometry (humanBase | custom LODs),
                            source {kind, hash, name, license}, mesh/skeleton/motion versions,
                            modelID, quality (verified | warnings | failed | unchecked), history
  Appearance.json           shape, skin material, outfit ids, equipment ids
  Skeleton/Skeleton.json    joints: id, parent, rest, inverse bind, limits, tag, confidence, source
  Motions/MotionLibrary.json  library ids + custom UniversalMotions
  Equipment/Sockets.json    attachment sockets
  Diagnostics/Validation.json  last check report
  Meshes/LOD<n>.m3dg, Skin/LOD<n>.skin   custom geometry only ("SKI1" weights)
  Preview/
```

- HumanBase characters store **no geometry**: rebuilt from the shared base
  body and their shape (no duplicated meshes).
- Saves write a temporary folder and swap it in; a newer `formatVersion` is
  neither read wrongly nor overwritten; a damaged package is listed apart.
- USDZ stays the exchange format (`USDZExport`); the package is the source
  of truth.

## 6. What is verified, and where

| Claim | Linux domain tests | Simulator UI test | iPhone |
|---|---|---|---|
| HumanBase loads, validates, T-pose, LOD budgets, three distinct bodies | ✅ | — | not yet |
| Every library motion deforms every body to finite positions | ✅ | — | not yet |
| Retargeting T↔A pose, legacy 10-bone playback equal to the old path | ✅ | — | — |
| Events once at any update rate; combo 1→2→3→1; IK reaches; foot planting | ✅ | — | — |
| Outfits follow the body, sword stays in the hand | ✅ | — | not yet |
| Validator refuses NaN / bad index / bad weights / joint loops / bad binds / bad motions | ✅ | — | — |
| Packages round-trip, refuse newer formats, survive damage | ✅ | — | — |
| Workbench → player → three demo characters → timed hits → pixel view and back | — | see `testCharacterWorkbenchPlayerDemoCastAndCombat` | not yet |
| 60 FPS with 10 characters, memory, heat | — | — | **not measured** |

## 7. Not finished (honest list)

- **Device performance**: no iPhone measurements yet (frame time, memory,
  heat with 1 + 10 characters). Diagnostics now print the runtime's numbers
  so they can be read on a phone. Metal compute skinning was not evaluated;
  skinning stays on the CPU (`LowLevelMesh`), with LOD and rate limits.
- **Native RealityKit skeletal path** for HumanBase characters (USDZ with
  joints played by RealityKit) is not used; USDZ export of rigged
  characters with real animation playback is not verified.
- **Pixel view**: the same 3D character instance is drawn by the pixel
  camera (one state, no restart); there are no pre-baked pixel sprites.
- **Clothing**: shells lifted from the body (tight clothes, short/long hair
  caps); no loose cloth, skirts or hair strands, no cloth simulation.
- **Hands**: fingers are rigged and curl in the motions; no hand IK grip
  per weapon; two-handed grips use the shared pose.
- **Video motion capture**: not done (videos use their sharpest frame).
- Root motion is metadata only; the game moves characters, never the clip.
- The motions are authored procedurally (keyframed poses), not motion
  capture; they were checked numerically and on screenshots, not by an
  animator.
