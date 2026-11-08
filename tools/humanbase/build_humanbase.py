#!/usr/bin/env python3
"""Builds Moonlight's HumanBase (the universal character base body).

Source: the MakeHuman hm08 base mesh, default skeleton, default weights and
body targets, all released as CC0 1.0 by the MakeHuman project (see
LICENSE.ASSETS.md and SOURCE.md next to this script). They are fetched at a
pinned commit, so the build is reproducible.

What the build does (all of it is in this one file, so it can be edited):
  1. Bakes a neutral mannequin: half female / half male, young adult,
     average muscle and weight, ethnic targets averaged (MakeHuman defaults).
  2. Keeps only the body surface (no eyes, teeth, tongue, lashes or clothes
     helpers) and triangulates it.
  3. Maps the 163 MakeHuman bones onto Moonlight's 27 standard joints plus
     33 extension joints (15 finger joints per hand, jaw, two eyes), summing
     the authored weights; keeps the four strongest per vertex.
  4. Poses the A-pose mesh into a T-pose with linear blend skinning (upper
     arm and forearm straightened along ±x); morph deltas and joints are
     turned by the same transforms, so they stay valid in the T-pose.
  5. Builds 17 body-shape channels from the targets (build, muscle, gender,
     shoulders, hips, waist, limb lengths, hands, feet, head, face shape).
  6. Simplifies the surface into three levels of detail with quadric edge
     collapse (half-edge collapses, so every LOD vertex is an original
     vertex and shares its weights and morphs); UV seams and open borders
     are kept, and joints with different weights are not merged across.
  7. Writes Resources/HumanBase/HumanBase.hbm (binary, read by
     HumanBaseAsset.swift), HumanBase_LOD0.obj (editable in Blender) and
     HumanBase_joints.json.

Run from the repository root:  python3 tools/humanbase/build_humanbase.py
Needs Python 3.9+ and numpy. Takes a few minutes (pure Python simplifier).
"""
import heapq
import json
import math
import os
import struct
import sys
import urllib.request

import numpy as np

COMMIT = "a8bc2d54ff0ac92e78ff71431b1023eda42bf482"
RAW = f"https://raw.githubusercontent.com/makehumancommunity/makehuman/{COMMIT}/makehuman/data/"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
OUT = os.path.join(HERE, "..", "..", "Resources", "HumanBase")
BODY_VERTICES = 13380          # hm08: the body surface is vertices 0..13379
LOD_TRIANGLES = [19500, 7800, 1950]
TARGET_HEIGHT = 1.75           # metres, the reference body


def fetch(path):
    local = os.path.join(CACHE, path.replace("/", "__"))
    if not os.path.exists(local):
        os.makedirs(CACHE, exist_ok=True)
        print("fetch", path)
        with urllib.request.urlopen(RAW + path) as r:
            data = r.read()
        with open(local, "wb") as f:
            f.write(data)
    return local


def target(path, count):
    """A .target file: 'index dx dy dz' lines → dense (count, 3) deltas."""
    d = np.zeros((count, 3))
    for line in open(fetch("targets/" + path)):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split()
        d[int(p[0])] = [float(p[1]), float(p[2]), float(p[3])]
    return d


# --- 1. Mesh and neutral mannequin ------------------------------------------

def load_obj():
    vs, vts, faces = [], [], []
    group = None
    for line in open(fetch("3dobjs/base.obj")):
        if line.startswith("v "):
            vs.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("vt "):
            vts.append([float(x) for x in line.split()[1:3]])
        elif line.startswith("g "):
            group = line.split()[1]
        elif line.startswith("f ") and group == "body":
            corners = [tuple(int(x) - 1 for x in c.split("/")[:2]) for c in line.split()[1:]]
            faces.append(corners)
    return np.array(vs), np.array(vts), faces


def neutral_and_channels(count):
    def young(gender):
        ethnic = sum(target(f"macrodetails/{e}-{gender}-young.target", count) for e in ("african", "asian", "caucasian")) / 3
        return ethnic + target(f"macrodetails/universal-{gender}-young-averagemuscle-averageweight.target", count)

    female, male = young("female"), young("male")
    neutral = 0.5 * female + 0.5 * male

    def universal(variant):
        return sum(0.5 * (target(f"macrodetails/universal-{g}-young-{variant}.target", count)
                          - target(f"macrodetails/universal-{g}-young-averagemuscle-averageweight.target", count))
                   for g in ("female", "male"))

    def pair(name):
        return target(name + "-decr.target", count), target(name + "-incr.target", count)

    def sides(name):  # both sides of the body
        dr, ir = pair("armslegs/r-" + name)
        dl, il = pair("armslegs/l-" + name)
        return dr + dl, ir + il

    head = [pair("head/head-scale-" + a) for a in ("vert", "horiz", "depth")]
    gender = 0.5 * (male - female)
    channels = [
        # name, negative delta, positive delta
        ("weight", universal("averagemuscle-minweight"), universal("averagemuscle-maxweight")),
        ("muscle", universal("minmuscle-averageweight"), universal("maxmuscle-averageweight")),
        ("gender", -gender, gender),
        ("shoulders", *pair("torso/torso-scale-horiz")),
        ("vshape", *pair("torso/torso-vshape")),
        ("hips", *pair("hip/hip-scale-horiz")),
        ("belly", *pair("stomach/stomach-pregnant")),
        ("neck", *pair("neck/neck-scale-vert")),
        ("upperArm", *sides("upperarm-scale-vert")),
        ("lowerArm", *sides("lowerarm-scale-vert")),
        ("upperLeg", *sides("upperleg-scale-vert")),
        ("lowerLeg", *sides("lowerleg-scale-vert")),
        ("hands", *sides("hand-scale")),
        ("feet", *sides("foot-scale")),
        ("head", sum(h[0] for h in head), sum(h[1] for h in head)),
        ("faceOval", np.zeros((count, 3)), target("head/head-oval.target", count)),
        ("faceRound", np.zeros((count, 3)), target("head/head-round.target", count)),
        ("faceSquare", np.zeros((count, 3)), target("head/head-square.target", count)),
    ]
    return neutral, channels


# --- 2. Skeleton -------------------------------------------------------------

# MakeHuman bone → Moonlight joint (27 standard tags; ext.* are extensions).
def joint_for_bone(bone):
    side = "right" if bone.endswith(".R") else "left" if bone.endswith(".L") else ""
    base = bone[:-2] if side else bone
    if base in ("root", "pelvis", "special01"):
        return "pelvis"
    if base in ("spine05", "spine04"):
        return "spine"
    if base == "spine03":
        return "spine1"
    if base in ("spine02", "spine01", "breast"):
        return "chest"
    if base.startswith("neck"):
        return "neck"
    if base == "jaw" or base.startswith("tongue"):
        return "ext.jaw"
    if base == "eye":
        return f"ext.{side}Eye"
    if base == "clavicle":
        return side + "Clavicle"
    if base in ("shoulder01", "upperarm01", "upperarm02"):
        return side + "UpperArm"
    if base in ("lowerarm01", "lowerarm02"):
        return side + "Forearm"
    if base == "wrist" or base.startswith("metacarpal"):
        return side + "Hand"
    if base.startswith("finger"):
        return f"ext.{side}Finger{base[6]}.{base[8]}"
    if base in ("upperleg01", "upperleg02"):
        return side + "Thigh"
    if base in ("lowerleg01", "lowerleg02"):
        return side + "Shin"
    if base == "foot":
        return side + "Foot"
    if base.startswith("toe"):
        return side + "Toe"
    # Face muscles (levator, oculi, orbicularis, oris, risorius, temporalis, special0x).
    return "head"


FINGERS = {"1": "Thumb", "2": "Index", "3": "Middle", "4": "Ring", "5": "Pinky"}


def moonlight_joints(skel, J):
    """Moonlight joints: name, parent, position (from MakeHuman bone heads / tails)."""
    def head(b):
        return J[skel["bones"][b]["head"]]

    def tail(b):
        return J[skel["bones"][b]["tail"]]

    out = [
        ("pelvis", None, 0.5 * (head("upperleg01.R") + head("upperleg01.L")) + np.array([0, 0.25, 0])),
        ("spine", "pelvis", head("spine04")),
        ("spine1", "spine", head("spine03")),
        ("chest", "spine1", head("spine02")),
        ("neck", "chest", head("neck01")),
        ("head", "neck", head("head")),
        ("headEnd", "head", tail("head")),
    ]
    for side, s in (("right", "R"), ("left", "L")):
        out += [
            (side + "Clavicle", "chest", head(f"clavicle.{s}")),
            (side + "UpperArm", side + "Clavicle", head(f"upperarm01.{s}")),
            (side + "Forearm", side + "UpperArm", head(f"lowerarm01.{s}")),
            (side + "Hand", side + "Forearm", head(f"wrist.{s}")),
            (side + "HandEnd", side + "Hand", tail(f"finger3-3.{s}")),
            (side + "Thigh", "pelvis", head(f"upperleg01.{s}")),
            (side + "Shin", side + "Thigh", head(f"lowerleg01.{s}")),
            (side + "Foot", side + "Shin", head(f"foot.{s}")),
            (side + "Toe", side + "Foot", np.mean([head(f"toe{t}-1.{s}") for t in range(1, 6)], axis=0)),
            (side + "ToeEnd", side + "Toe", np.mean([tail(f"toe{t}-{3 if t > 1 else 2}.{s}") for t in range(1, 6)], axis=0)),
        ]
    out.append(("ext.jaw", "head", head("jaw")))
    for side, s in (("right", "R"), ("left", "L")):
        out.append((f"ext.{side}Eye", "head", head(f"eye.{s}")))
        for f in "12345":
            for seg in "123":
                parent = side + "Hand" if seg == "1" else f"ext.{side}Finger{f}.{int(seg) - 1}"
                out.append((f"ext.{side}Finger{f}.{seg}", parent, head(f"finger{f}-{seg}.{s}")))
    return out


# --- 3. T-pose ---------------------------------------------------------------

def rotation_between(a, b):
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    s = np.linalg.norm(v)
    if s < 1e-9:
        return np.eye(3)
    k = v / s
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    angle = math.atan2(s, c)
    return np.eye(3) + math.sin(angle) * K + (1 - math.cos(angle)) * K @ K


def scaled_rotation(R, f):
    """The rotation R turned only a share f of the way (axis-angle)."""
    angle = math.acos(max(-1.0, min(1.0, (np.trace(R) - 1) / 2)))
    if angle < 1e-9:
        return np.eye(3)
    axis = np.array([R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]]) / (2 * math.sin(angle))
    K = np.array([[0, -axis[2], axis[1]], [axis[2], 0, -axis[0]], [-axis[1], axis[0], 0]])
    a = angle * f
    return np.eye(3) + math.sin(a) * K + (1 - math.cos(a)) * K @ K


def tpose_transforms(skel, J):
    """Per MakeHuman bone: (R, t) so that posed = R @ p + t."""
    bones = skel["bones"]

    def head(b):
        return J[bones[b]["head"]]

    def descendants(root):
        out = {root}
        changed = True
        while changed:
            changed = False
            for b, info in bones.items():
                if info["parent"] in out and b not in out:
                    out.add(b)
                    changed = True
        return out

    T = {b: (np.eye(3), np.zeros(3)) for b in bones}
    for s, out_x in (("R", -1.0), ("L", 1.0)):
        shoulder, elbow, wrist = head(f"upperarm01.{s}"), head(f"lowerarm01.{s}"), head(f"wrist.{s}")
        R1 = rotation_between(elbow - shoulder, np.array([out_x, 0, 0]))
        t1 = shoulder - R1 @ shoulder
        elbow1 = R1 @ elbow + t1
        wrist1 = R1 @ wrist + t1
        R2 = rotation_between(wrist1 - elbow1, np.array([out_x, 0, 0]))
        t2 = elbow1 - R2 @ elbow1
        for b in descendants(f"upperarm01.{s}"):
            T[b] = (R1, t1)
        for b in descendants(f"lowerarm01.{s}"):
            T[b] = (R2 @ R1, R2 @ t1 + t2)
        # The deltoid follows halfway, so the shoulder does not crease.
        Rh = scaled_rotation(R1, 0.5)
        T[f"shoulder01.{s}"] = (Rh, shoulder - Rh @ shoulder)
    return T


def blend(weights_by_bone, T, count):
    """Per vertex blended (3×3, 3) transform from bone weights."""
    A = np.zeros((count, 3, 3))
    t = np.zeros((count, 3))
    total = np.zeros(count)
    for bone, entries in weights_by_bone.items():
        R, tr = T.get(bone, (np.eye(3), np.zeros(3)))
        for i, w in entries:
            if i < count:
                A[i] += w * R
                t[i] += w * tr
                total[i] += w
    missing = total < 1e-6
    A[missing] = np.eye(3)
    total[missing] = 1
    return A / total[:, None, None], t / total[:, None]


# --- 4. Simplification -------------------------------------------------------

def simplify(positions, tris, weights, locked, seam, targets):
    """Progressive half-edge collapse; returns the triangle list at each target count."""
    n = len(positions)
    P = positions.astype(np.float64)
    tris = [list(t) for t in tris]
    alive = [True] * len(tris)
    vfaces = [set() for _ in range(n)]
    for f, t in enumerate(tris):
        for v in t:
            vfaces[v].add(f)
    Q = np.zeros((n, 4, 4))
    for t in tris:
        a, b, c = P[t[0]], P[t[1]], P[t[2]]
        nrm = np.cross(b - a, c - a)
        area = np.linalg.norm(nrm)
        if area < 1e-12:
            continue
        nrm /= area
        plane = np.append(nrm, -np.dot(nrm, a))
        K = np.outer(plane, plane) * area
        for v in t:
            Q[v] += K
    scale = float(np.ptp(P, axis=0).max())
    version = [0] * n
    removed = [False] * n

    def cost(u, v):
        q = Q[u] + Q[v]
        p = np.append(P[v], 1.0)
        c = float(p @ q @ p)
        dw = weights[u] - weights[v]
        c += 0.002 * scale * scale * float(dw @ dw)
        # Moving a UV-seam vertex off its seam smears the texture: allowed, but last.
        if seam[u] and not seam[v]:
            c += 0.0005 * scale * scale
        return c

    heap = []

    def push(u, v):
        if locked[u] or removed[u] or removed[v]:
            return
        heapq.heappush(heap, (cost(u, v), u, v, version[u], version[v]))

    for t in tris:
        for i in range(3):
            u, v = t[i], t[(i + 1) % 3]
            push(u, v)
            push(v, u)

    def neighbours(x):
        out = set()
        for f in vfaces[x]:
            out.update(tris[f])
        out.discard(x)
        return out

    def valid(u, v):
        shared = vfaces[u] & vfaces[v]
        if len(shared) != 2:
            return False
        if len(neighbours(u) & neighbours(v)) != 2:
            return False
        for f in vfaces[u] - shared:
            t = tris[f]
            a = [P[x] for x in t]
            before = np.cross(a[1] - a[0], a[2] - a[0])
            b = [P[v] if x == u else P[x] for x in t]
            after = np.cross(b[1] - b[0], b[2] - b[0])
            la, lb = np.linalg.norm(before), np.linalg.norm(after)
            if lb < 1e-12 or np.dot(before, after) < 0.3 * la * lb:
                return False
            # No slivers: 4√3·area / sum of squared sides (1 = equilateral).
            sides = sum(float(np.dot(b[i] - b[(i + 1) % 3], b[i] - b[(i + 1) % 3])) for i in range(3))
            if 2 * math.sqrt(3) * lb / max(sides, 1e-12) < 0.12:
                return False
        return True

    count = sum(alive)
    results = []
    goals = sorted(targets, reverse=True)
    while goals:
        while count > goals[0] and heap:
            c, u, v, vu, vv = heapq.heappop(heap)
            if removed[u] or removed[v] or vu != version[u] or vv != version[v]:
                continue
            if not valid(u, v):
                continue
            for f in vfaces[u] & vfaces[v]:
                alive[f] = False
                count -= 1
                for x in tris[f]:
                    vfaces[x].discard(f)
            for f in list(vfaces[u]):
                tris[f] = [v if x == u else x for x in tris[f]]
                vfaces[v].add(f)
            vfaces[u].clear()
            removed[u] = True
            Q[v] += Q[u]
            version[v] += 1
            for w in neighbours(v):
                version[w] += 1
            for w in neighbours(v):
                push(v, w)
                push(w, v)
                for x in neighbours(w):
                    push(w, x)
        results.append([list(tris[f]) for f in range(len(tris)) if alive[f]])
        print(f"  LOD with {count} triangles (goal {goals[0]})")
        goals.pop(0)
    return results


# --- 5. Output ---------------------------------------------------------------

def main():
    skel = json.load(open(fetch("rigs/default.mhskel")))
    weights_mh = json.load(open(fetch("rigs/default_weights.mhw")))["weights"]
    V, VT, faces = load_obj()
    count = len(V)
    print("base mesh", count, "vertices,", len(faces), "body quads")
    neutral, channels = neutral_and_channels(count)
    V = V + neutral

    def joints_at(positions):
        return {k: positions[idx].mean(axis=0) for k, idx in skel["joints"].items()}

    J = joints_at(V)
    T = tpose_transforms(skel, J)
    A, tt = blend(weights_mh, T, count)
    posed = np.einsum("nij,nj->ni", A, V) + tt
    # Joints: a bone's head moves with its parent (it is the parent's end).
    bone_transform = {}
    for name, info in skel["bones"].items():
        bone_transform[name] = T.get(info["parent"], (np.eye(3), np.zeros(3))) if info["parent"] else (np.eye(3), np.zeros(3))
    JT = {}
    for name, info in skel["bones"].items():
        R, t = bone_transform[name]
        JT[info["head"]] = R @ J[info["head"]] + t
        R2, t2 = T[name]
        JT[info["tail"]] = R2 @ J[info["tail"]] + t2
    for k in J:
        JT.setdefault(k, J[k])
    joints = moonlight_joints(skel, JT)

    # Per-channel joint deltas: joints recomputed from the A-pose target, turned like their bone.
    def joint_deltas(delta):
        moved = joints_at(V + delta)
        JD = {}
        for name, info in skel["bones"].items():
            R, _ = bone_transform[name]
            JD[info["head"]] = R @ (moved[info["head"]] - J[info["head"]])
            R2, _ = T[name]
            JD[info["tail"]] = R2 @ (moved[info["tail"]] - J[info["tail"]])
        for k in J:
            JD.setdefault(k, moved[k] - J[k])
        base = dict((n, p) for n, _, p in moonlight_joints(skel, JT))
        shifted = {k: JT[k] + JD[k] for k in JT}
        return {n: p - base[n] for n, _, p in moonlight_joints(skel, shifted)}

    # Units and placement: decimetres → metres, feet on y = 0, 1.75 m tall.
    body = posed[:BODY_VERTICES]
    floor = body[:, 1].min()
    k = TARGET_HEIGHT / (body[:, 1].max() - floor)
    origin = np.array([0.0, floor, 0.0])

    def place(p):
        return (p - origin) * k

    body = place(body)
    joints = [(n, parent, place(p)) for n, parent, p in joints]
    names = [n for n, _, _ in joints]
    print("height", body[:, 1].max(), "width", np.ptp(body[:, 0]))

    # Weights onto Moonlight joints, four strongest per vertex.
    W = np.zeros((BODY_VERTICES, len(names)))
    for bone, entries in weights_mh.items():
        j = joint_for_bone(bone)
        if j is None:
            continue
        col = names.index(j)
        for i, w in entries:
            if i < BODY_VERTICES:
                W[i, col] += w
    empty = W.sum(axis=1) < 1e-6
    W[empty, names.index("pelvis")] = 1
    print("vertices without MakeHuman weights:", int(empty.sum()))
    top = np.argsort(-W, axis=1)[:, :4]
    topw = np.take_along_axis(W, top, axis=1)
    topw[topw < 0.01] = 0
    topw /= topw.sum(axis=1, keepdims=True)

    # Channels: deltas turned into the T-pose and placed (scale only).
    channel_data = []
    for name, neg, pos in channels:
        sides = []
        for d in (neg, pos):
            turned = np.einsum("nij,nj->ni", A, d)[:BODY_VERTICES] * k
            jd = {n: v * k for n, v in joint_deltas(d).items()}
            sides.append((turned, jd))
        channel_data.append((name, sides))

    # Triangles (shorter diagonal), render vertices per (vertex, uv).
    tris, tri_uv = [], []
    for f in faces:
        (a, ta), (b, tb), (c, tc), (d, td) = f
        if np.linalg.norm(body[a] - body[c]) <= np.linalg.norm(body[b] - body[d]):
            tris += [[a, b, c], [a, c, d]]
            tri_uv += [[ta, tb, tc], [ta, tc, td]]
        else:
            tris += [[a, b, d], [b, c, d]]
            tri_uv += [[ta, tb, td], [tb, tc, td]]
    uv_of = {}
    for t, u in zip(tris, tri_uv):
        for v, x in zip(t, u):
            uv_of.setdefault(v, set()).add(x)
    seam = np.array([len(uv_of.get(v, ())) > 1 for v in range(BODY_VERTICES)])
    edges = {}
    for t in tris:
        for i in range(3):
            e = tuple(sorted((t[i], t[(i + 1) % 3])))
            edges[e] = edges.get(e, 0) + 1
    border = np.zeros(BODY_VERTICES, bool)
    for (a, b), c in edges.items():
        if c != 2:
            border[a] = border[b] = True
    locked = border
    print("triangles", len(tris), "seam vertices", int(seam.sum()), "border vertices", int(border.sum()))
    lods = simplify(body, tris, W, locked, seam, LOD_TRIANGLES)

    # Vertices off the seams have a single UV.
    single_uv = {v: next(iter(s)) for v, s in uv_of.items() if len(s) == 1}

    def lod_render(lod):
        render, index, out_tris = [], {}, []
        for t in lod:
            corner = []
            for v in t:
                if v in single_uv:
                    x = single_uv[v]
                else:  # seam vertex: the UV this triangle's side uses
                    x = seam_uv(v, t)
                key = (v, x)
                if key not in index:
                    index[key] = len(render)
                    render.append(key)
                corner.append(index[key])
            out_tris.append(corner)
        return render, out_tris

    # A LOD corner on a UV seam takes the UV of the original triangle around
    # that vertex nearest to the LOD triangle (the side of the seam it is on).
    tris_of_vertex = {}
    for f, t in enumerate(tris):
        for v in t:
            tris_of_vertex.setdefault(v, []).append(f)
    centre = np.array([body[t].mean(axis=0) for t in tris])

    def seam_uv(v, t):
        c = body[t].mean(axis=0)
        best = min(tris_of_vertex[v], key=lambda f: float(np.sum((centre[f] - c) ** 2)))
        return tri_uv[best][tris[best].index(v)]

    lod_data = [lod_render(l) for l in lods]

    # Normals for the OBJ (the app recomputes them after shaping).
    def normals(lod):
        n = np.zeros((BODY_VERTICES, 3))
        for t in lod:
            a, b, c = body[t[0]], body[t[1]], body[t[2]]
            n[t] += np.cross(b - a, c - a)
        l = np.linalg.norm(n, axis=1, keepdims=True)
        l[l < 1e-12] = 1
        return n / l

    os.makedirs(OUT, exist_ok=True)
    write_hbm(os.path.join(OUT, "HumanBase.hbm"), body, topw, top, joints, names, channel_data, lod_data, VT)
    nrm = normals(lods[0])
    render, out_tris = lod_data[0]
    with open(os.path.join(OUT, "HumanBase_LOD0.obj"), "w") as f:
        f.write("# Moonlight HumanBase LOD0, neutral T-pose, metres, y up, faces +z.\n")
        f.write("# Built from the MakeHuman hm08 base mesh (CC0 1.0) by tools/humanbase/build_humanbase.py\n")
        for v, x in render:
            f.write("v %.5f %.5f %.5f\n" % tuple(body[v]))
        for v, x in render:
            f.write("vt %.5f %.5f\n" % tuple(VT[x]))
        for v, x in render:
            f.write("vn %.4f %.4f %.4f\n" % tuple(nrm[v]))
        for t in out_tris:
            f.write("f " + " ".join(f"{i + 1}/{i + 1}/{i + 1}" for i in t) + "\n")
    with open(os.path.join(OUT, "HumanBase_joints.json"), "w") as f:
        json.dump({"source": "MakeHuman hm08 default skeleton (CC0 1.0), commit " + COMMIT,
                   "joints": [{"name": n, "parent": p, "position": [round(float(x), 5) for x in pos]} for n, p, pos in joints]}, f, indent=1)
    print("written", [len(r) for r, _ in lod_data], "render vertices;", [len(t) for _, t in lod_data], "triangles")


def write_hbm(path, body, topw, top, joints, names, channel_data, lod_data, VT):
    """HBM1: little-endian. See HumanBaseAsset.swift for the reader."""
    out = bytearray(b"HBM1")

    def u32(x):
        out.extend(struct.pack("<I", x))

    def f32s(a):
        a = np.asarray(a, dtype="<f4").ravel()
        out.extend(a.tobytes())

    def string(s):
        b = s.encode()
        u32(len(b))
        out.extend(b)

    u32(1)                       # format version
    u32(BODY_VERTICES)
    f32s(body)
    out.extend(np.asarray(top, dtype="<u1").ravel().tobytes())
    f32s(topw)
    u32(len(joints))
    for n, parent, p in joints:
        string(n)
        u32(0xFFFFFFFF if parent is None else names.index(parent))
        f32s(p)
    u32(len(channel_data))
    for name, sides in channel_data:
        string(name)
        for deltas, jd in sides:
            moving = np.nonzero(np.linalg.norm(deltas, axis=1) > 1e-6)[0]
            peak = float(np.abs(deltas[moving]).max()) if len(moving) else 0.0
            scale = peak / 32767 if peak > 0 else 1.0
            u32(len(moving))
            out.extend(struct.pack("<f", scale))
            out.extend(np.asarray(moving, dtype="<u2").tobytes())
            out.extend(np.round(deltas[moving] / scale).astype("<i2").ravel().tobytes())
            f32s([jd[n] for n in names])
    u32(len(lod_data))
    for render, tris in lod_data:
        u32(len(render))
        out.extend(np.asarray([v for v, _ in render], dtype="<u2").tobytes())
        f32s([VT[x] for _, x in render])
        u32(len(tris))
        out.extend(np.asarray(tris, dtype="<u2").ravel().tobytes())
    with open(path, "wb") as f:
        f.write(out)
    print("HumanBase.hbm", len(out), "bytes")


if __name__ == "__main__":
    sys.exit(main())
