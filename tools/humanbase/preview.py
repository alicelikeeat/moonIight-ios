#!/usr/bin/env python3
"""Renders HumanBase.hbm (all LODs, front and side, plus shaped bodies) to a
PNG, reading the same binary the app reads. A check of the build, not part
of the app.   python3 tools/humanbase/preview.py out.png
"""
import math
import os
import struct
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "..", "Resources", "HumanBase", "HumanBase.hbm")


def read(path=PATH):
    b = open(path, "rb").read()
    o = 0

    def take(n):
        nonlocal o
        s = b[o:o + n]
        o += n
        return s

    def u32():
        return struct.unpack("<I", take(4))[0]

    def f32(n):
        return np.frombuffer(take(4 * n), "<f4").astype(np.float64)

    def string():
        return take(u32()).decode()

    assert take(4) == b"HBM1" and u32() == 1
    n = u32()
    pos = f32(n * 3).reshape(n, 3)
    joints_idx = np.frombuffer(take(n * 4), "<u1").reshape(n, 4)
    weights = f32(n * 4).reshape(n, 4)
    joints = []
    for _ in range(u32()):
        name = string()
        parent = u32()
        joints.append((name, None if parent == 0xFFFFFFFF else parent, f32(3)))
    channels = {}
    for _ in range(u32()):
        name = string()
        sides = []
        for _ in range(2):
            m = u32()
            scale = struct.unpack("<f", take(4))[0]
            idx = np.frombuffer(take(2 * m), "<u2")
            d = np.frombuffer(take(6 * m), "<i2").reshape(m, 3) * scale
            jd = f32(len(joints) * 3).reshape(-1, 3)
            dense = np.zeros((n, 3))
            dense[idx] = d
            sides.append((dense, jd))
        channels[name] = sides
    lods = []
    for _ in range(u32()):
        r = u32()
        master = np.frombuffer(take(2 * r), "<u2")
        uv = f32(r * 2).reshape(r, 2)
        t = u32()
        tris = np.frombuffer(take(6 * t), "<u2").reshape(t, 3)
        lods.append((master, uv, tris))
    assert o == len(b), (o, len(b))
    return pos, joints_idx, weights, joints, channels, lods


def shaped(pos, joints, channels, values):
    p = pos.copy()
    j = np.array([x[2] for x in joints])
    for name, v in values.items():
        dense, jd = channels[name][1 if v > 0 else 0]
        p += dense * abs(v)
        j += jd * abs(v)
    return p, j


def render(p, tris, yaw, size=360, extent=1.0):
    c, s = math.cos(yaw), math.sin(yaw)
    q = np.stack([p[:, 0] * c + p[:, 2] * s, p[:, 1], -p[:, 0] * s + p[:, 2] * c], axis=1)
    img = np.full((size, size, 3), 30, np.uint8)
    depth = np.full((size, size), -1e9)
    k = size / (2 * extent) * 0.95
    sx = size / 2 + q[:, 0] * k
    sy = size - 8 - q[:, 1] * k
    light = np.array([0.4, 0.5, 0.75])
    light /= np.linalg.norm(light)
    for t in tris:
        a, b2, c2 = q[t[0]], q[t[1]], q[t[2]]
        nrm = np.cross(b2 - a, c2 - a)
        ln = np.linalg.norm(nrm)
        if ln < 1e-12 or nrm[2] <= 0:
            continue
        shade = int(60 + 190 * max(0.0, float(np.dot(nrm / ln, light))))
        xs, ys = sx[t], sy[t]
        x0, x1 = max(0, int(xs.min())), min(size - 1, int(xs.max()) + 1)
        y0, y1 = max(0, int(ys.min())), min(size - 1, int(ys.max()) + 1)
        if x1 < x0 or y1 < y0:
            continue
        X, Y = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        d = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if abs(d) < 1e-9:
            continue
        w0 = ((ys[1] - ys[2]) * (X - xs[2]) + (xs[2] - xs[1]) * (Y - ys[2])) / d
        w1 = ((ys[2] - ys[0]) * (X - xs[2]) + (xs[0] - xs[2]) * (Y - ys[2])) / d
        w2 = 1 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        z = w0 * a[2] + w1 * b2[2] + w2 * c2[2]
        region = depth[y0:y1 + 1, x0:x1 + 1]
        hit = inside & (z > region)
        region[hit] = z[hit]
        img[y0:y1 + 1, x0:x1 + 1][hit] = (shade, shade, min(255, shade + 15))
    return img


def main():
    pos, ji, w, joints, channels, lods = read()
    panels = []
    for lod in lods:
        tris = lod[0][lod[2]]
        panels.append(render(pos - [0, 0.875, 0] + [0, 0.875, 0], tris, 0, extent=1.0))
        panels.append(render(pos, tris, math.pi / 2, extent=1.0))
    tris0 = lods[0][0][lods[0][2]]
    for values in ({"weight": -1, "muscle": -0.5}, {"weight": 1, "muscle": 1, "shoulders": 1, "gender": 1}, {"head": 1, "upperLeg": -1, "lowerLeg": -1, "faceRound": 1}):
        p, _ = shaped(pos, joints, channels, values)
        panels.append(render(p, tris0, 0, extent=1.0))
    rows = [np.concatenate(panels[i:i + 3], axis=1) for i in range(0, 9, 3)]
    Image.fromarray(np.concatenate(rows, axis=0)).save(sys.argv[1] if len(sys.argv) > 1 else "humanbase.png")
    print("joints", len(joints), "channels", list(channels))


if __name__ == "__main__":
    main()
