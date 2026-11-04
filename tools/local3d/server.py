#!/usr/bin/env python3
"""Moonlight Local 3D — picture → 3D model on your own computer.

The Moonlight app (AI 生成 3D → 电脑生成) uploads one picture over your
local Wi-Fi and downloads a GLB. Runs one job at a time.

Backends (install the one you want, see README.md):
  triposr    TripoSR (VAST AI / Stability AI, MIT)  — fast, CUDA or CPU / Apple MPS
  hunyuan3d  Hunyuan3D-2 / 2mini (Tencent; Tencent Hunyuan Community License,
             not licensed in the EU, UK and South Korea) — shape + texture, CUDA
  dummy      a coloured cube, for checking the connection

Usage:
  python server.py --backend triposr [--port 8765] [--token SECRET]
Only use on a network you trust. Without --token anyone on the network can
submit jobs.
"""
import argparse
import io
import json
import socket
import struct
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.75"
MAX_UPLOAD = 25 * 1024 * 1024


# ---------------------------------------------------------------- GLB writer

def glb_bytes(vertices, faces, colors=None, uvs=None, texture_png=None):
    """Minimal binary glTF 2.0: positions, optional vertex colours or UVs + PNG."""
    def pack_f32(values):
        return struct.pack("<%df" % len(values), *values)

    flat_v = [c for v in vertices for c in v]
    flat_i = [i for f in faces for i in f]
    bin_parts, views, accessors = [], [], []

    def add(data, target=None):
        offset = sum(len(p) for p in bin_parts)
        pad = (4 - len(data) % 4) % 4
        bin_parts.append(data + b"\x00" * pad)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target:
            view["target"] = target
        views.append(view)
        return len(views) - 1

    mins = [min(v[k] for v in vertices) for k in range(3)]
    maxs = [max(v[k] for v in vertices) for k in range(3)]
    accessors.append({"bufferView": add(pack_f32(flat_v), 34962), "componentType": 5126, "count": len(vertices), "type": "VEC3", "min": mins, "max": maxs})
    accessors.append({"bufferView": add(struct.pack("<%dI" % len(flat_i), *flat_i), 34963), "componentType": 5125, "count": len(flat_i), "type": "SCALAR"})
    attributes = {"POSITION": 0}
    if colors is not None:
        accessors.append({"bufferView": add(pack_f32([c for col in colors for c in col[:3]]), 34962), "componentType": 5126, "count": len(colors), "type": "VEC3"})
        attributes["COLOR_0"] = len(accessors) - 1
    material = {"pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0.8}}
    gltf = {"asset": {"version": "2.0", "generator": "Moonlight Local 3D " + VERSION}, "scene": 0, "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}], "materials": [material]}
    if uvs is not None and texture_png is not None:
        accessors.append({"bufferView": add(pack_f32([c for uv in uvs for c in uv]), 34962), "componentType": 5126, "count": len(uvs), "type": "VEC2"})
        attributes["TEXCOORD_0"] = len(accessors) - 1
        image_view = add(texture_png)
        gltf["images"] = [{"bufferView": image_view, "mimeType": "image/png"}]
        gltf["textures"] = [{"source": 0}]
        material["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 0}
    gltf["meshes"] = [{"primitives": [{"attributes": attributes, "indices": 1, "material": 0, "mode": 4}]}]
    gltf["accessors"] = accessors
    gltf["bufferViews"] = views
    binary = b"".join(bin_parts)
    gltf["buffers"] = [{"byteLength": len(binary)}]
    js = json.dumps(gltf).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(binary)
    return (struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


# ---------------------------------------------------------------- backends

class DummyBackend:
    name = "dummy"

    def generate(self, image_bytes, options, progress, cancelled):
        for i in range(5):
            if cancelled():
                raise InterruptedError()
            progress(i / 5)
            time.sleep(0.2)
        v = [(x, y, z) for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)]
        f = [(0, 2, 3), (0, 3, 1), (4, 5, 7), (4, 7, 6), (0, 1, 5), (0, 5, 4), (2, 6, 7), (2, 7, 3), (0, 4, 6), (0, 6, 2), (1, 3, 7), (1, 7, 5)]
        c = [((x + 0.5), (y + 0.5), (z + 0.5)) for (x, y, z) in v]
        return glb_bytes(v, f, colors=c)


class TripoSRBackend:
    """TripoSR (https://github.com/VAST-AI-Research/TripoSR). Put its repo on
    PYTHONPATH (or pass --triposr-path)."""
    name = "triposr"

    def __init__(self, args):
        import sys
        if args.triposr_path:
            sys.path.insert(0, args.triposr_path)
        import torch
        from tsr.system import TSR
        import rembg
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else ("mps" if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available() else "cpu")
        self.model = TSR.from_pretrained("stabilityai/TripoSR", config_name="config.yaml", weight_name="model.ckpt")
        self.model.renderer.set_chunk_size(8192)
        self.model.to(self.device)
        self.rembg = rembg.new_session()
        self.resolution = args.resolution

    def generate(self, image_bytes, options, progress, cancelled):
        import numpy as np
        from PIL import Image
        from tsr.utils import remove_background, resize_foreground
        progress(0.05)
        image = remove_background(Image.open(io.BytesIO(image_bytes)), self.rembg)
        image = resize_foreground(image, 0.85)
        a = np.array(image).astype(np.float32) / 255.0
        a = a[:, :, :3] * a[:, :, 3:4] + (1 - a[:, :, 3:4]) * 0.5
        image = Image.fromarray((a * 255.0).astype(np.uint8))
        if cancelled():
            raise InterruptedError()
        progress(0.3)
        with self.torch.no_grad():
            codes = self.model([image], device=self.device)
        if cancelled():
            raise InterruptedError()
        progress(0.6)
        mesh = self.model.extract_mesh(codes, True, resolution=self.resolution)[0]
        # TripoSR is z-up; the app expects y-up, front +z (same turn as TripoSR's own viewer).
        import trimesh
        mesh.apply_transform(trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0]))
        mesh.apply_transform(trimesh.transformations.rotation_matrix(np.pi / 2, [0, 1, 0]))
        progress(0.9)
        colors = mesh.visual.vertex_colors[:, :3].astype(np.float32) / 255.0
        return glb_bytes(mesh.vertices.tolist(), mesh.faces.tolist(), colors=colors.tolist())


class Hunyuan3DBackend:
    """Hunyuan3D-2 (https://github.com/Tencent/Hunyuan3D-2), installed with its
    instructions. --mini uses Hunyuan3D-2mini for the shape."""
    name = "hunyuan3d"

    def __init__(self, args):
        from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline
        from hy3dgen.rembg import BackgroundRemover
        if args.mini:
            self.shape = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained("tencent/Hunyuan3D-2mini", subfolder="hunyuan3d-dit-v2-mini")
        else:
            self.shape = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained("tencent/Hunyuan3D-2")
        self.rembg = BackgroundRemover()
        self.paint = None
        if not args.no_texture:
            try:
                from hy3dgen.texgen import Hunyuan3DPaintPipeline
                self.paint = Hunyuan3DPaintPipeline.from_pretrained("tencent/Hunyuan3D-2")
            except Exception as e:  # texture is optional (needs its own build steps)
                print("Texture pipeline unavailable, shapes only:", e)

    def generate(self, image_bytes, options, progress, cancelled):
        from PIL import Image
        progress(0.05)
        image = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
        image = self.rembg(image)
        progress(0.2)
        mesh = self.shape(image=image)[0]
        if cancelled():
            raise InterruptedError()
        progress(0.6)
        if self.paint is not None and options.get("texture", True):
            mesh = self.paint(mesh, image=image)
        progress(0.95)
        out = io.BytesIO()
        mesh.export(out, file_type="glb")
        return out.getvalue()


# ---------------------------------------------------------------- jobs + HTTP

class Jobs:
    def __init__(self, backend):
        self.backend = backend
        self.jobs = {}
        self.lock = threading.Lock()
        self.queue = threading.Semaphore(1)

    def create(self, image, options):
        job_id = uuid.uuid4().hex[:12]
        job = {"id": job_id, "status": "queued", "progress": 0.0, "message": None, "result": None, "cancel": False, "created": time.time()}
        with self.lock:
            self.jobs[job_id] = job
        threading.Thread(target=self.run, args=(job, image, options), daemon=True).start()
        return job

    def run(self, job, image, options):
        with self.queue:
            if job["cancel"]:
                job["status"] = "cancelled"
                return
            job["status"] = "running"
            try:
                def progress(value):
                    job["progress"] = float(value)
                job["result"] = self.backend.generate(image, options, progress, lambda: job["cancel"])
                job["progress"] = 1.0
                job["status"] = "succeeded"
            except InterruptedError:
                job["status"] = "cancelled"
            except Exception as e:
                traceback.print_exc()
                job["status"] = "failed"
                job["message"] = str(e)[:300]

    def public(self, job):
        return {"id": job["id"], "status": job["status"], "progress": job["progress"], "message": job["message"]}


def make_handler(jobs, token):
    class Handler(BaseHTTPRequestHandler):
        server_version = "MoonlightLocal3D/" + VERSION

        def send_json(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorised(self):
            if not token:
                return True
            if self.headers.get("Authorization", "") == "Bearer " + token:
                return True
            self.send_json(401, {"message": "bad token"})
            return False

        def job(self, parts):
            with jobs.lock:
                job = jobs.jobs.get(parts[4]) if len(parts) > 4 else None
            if job is None:
                self.send_json(404, {"message": "no such job"})
            return job

        def do_GET(self):
            parts = self.path.rstrip("/").split("/")
            if self.path.startswith("/v1/health"):
                return self.send_json(200, {"name": "Moonlight Local 3D", "backend": jobs.backend.name, "version": VERSION})
            if not self.authorised():
                return
            if self.path.startswith("/v1/image3d/jobs/"):
                job = self.job(parts)
                if job is None:
                    return
                if len(parts) > 5 and parts[5] == "result":
                    if job["status"] != "succeeded":
                        return self.send_json(409, {"message": "not finished"})
                    data = job["result"]
                    self.send_response(200)
                    self.send_header("Content-Type", "model/gltf-binary")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                return self.send_json(200, jobs.public(job))
            self.send_json(404, {"message": "not found"})

        def do_POST(self):
            if not self.authorised():
                return
            parts = self.path.rstrip("/").split("/")
            if self.path.rstrip("/") == "/v1/image3d/jobs":
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > MAX_UPLOAD:
                    return self.send_json(413, {"message": "picture too large or empty"})
                image = self.rfile.read(length)
                try:
                    options = json.loads(self.headers.get("X-Options", "{}"))
                except ValueError:
                    options = {}
                return self.send_json(201, jobs.public(jobs.create(image, options)))
            if len(parts) > 5 and parts[5] == "cancel":
                job = self.job(parts)
                if job is None:
                    return
                job["cancel"] = True
                if job["status"] == "queued":
                    job["status"] = "cancelled"
                return self.send_json(200, jobs.public(job))
            self.send_json(404, {"message": "not found"})

        def do_DELETE(self):
            if not self.authorised():
                return
            parts = self.path.rstrip("/").split("/")
            job = self.job(parts)
            if job is None:
                return
            job["cancel"] = True
            with jobs.lock:
                jobs.jobs.pop(job["id"], None)
            self.send_json(200, {"id": job["id"], "status": "deleted"})

        def log_message(self, fmt, *args):
            print("%s %s" % (self.address_string(), fmt % args))

    return Handler


def lan_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--backend", choices=["triposr", "hunyuan3d", "dummy"], default="triposr")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--token", default="", help="require this token (enter it in the app)")
    p.add_argument("--triposr-path", default="", help="folder of the TripoSR repository")
    p.add_argument("--resolution", type=int, default=256, help="TripoSR marching-cubes resolution")
    p.add_argument("--mini", action="store_true", help="Hunyuan3D-2mini shape model (less GPU memory)")
    p.add_argument("--no-texture", action="store_true", help="Hunyuan3D: shapes only")
    args = p.parse_args()
    backend = {"dummy": lambda: DummyBackend(), "triposr": lambda: TripoSRBackend(args), "hunyuan3d": lambda: Hunyuan3DBackend(args)}[args.backend]()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(Jobs(backend), args.token))
    print("Moonlight Local 3D %s (%s)" % (VERSION, backend.name))
    print("In the app enter:  %s:%d%s" % (lan_address(), args.port, "   token: " + args.token if args.token else ""))
    server.serve_forever()


if __name__ == "__main__":
    main()
