"""Offline source/resource invariants, plus independent ZIP and optional OpenUSD checks.

This does not run iOS Vision, Core ML, RealityKit, or device performance tests.
"""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
provenance = json.loads((root / "Resources/Local3D/provenance.json").read_text())
assert provenance["license"] == "Apache-2.0" and provenance["variant"] == "Small F16"
for record in provenance["files"]:
    data = (root / "Resources/Local3D" / record["path"]).read_bytes()
    assert len(data) == record["bytes"], record["path"]
    assert hashlib.sha256(data).hexdigest() == record["sha256"], record["path"]

project = (root / "Moonlight-iOS.xcodeproj/project.pbxproj").read_text()
assert "Resources/Local3D" in project
assert all(target == "16.0" for target in re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+)", project))
for path in (root / "Features/Local3D").rglob("*.swift"):
    assert str(path.relative_to(root)) in project, f"Unregistered source {path}"
    source = path.read_text()
    assert not re.search(r"URLSession|https?://|URLRequest|NWConnection", source), f"Network code in {path}"
print("PASS: pinned model checksums, Apache license, source registration, iOS 16 target, no network clients in Local3D")

if len(sys.argv) > 1:
    usdz = Path(sys.argv[1]).resolve()
    with zipfile.ZipFile(usdz) as archive:
        assert archive.testzip() is None
        assert archive.namelist() == ["model.usda", "texture.png"]
        with usdz.open("rb") as raw:
            for info in archive.infolist():
                assert info.compress_type == zipfile.ZIP_STORED
                raw.seek(info.header_offset + 26)
                name_size, extra_size = struct.unpack("<HH", raw.read(4))
                assert (info.header_offset + 30 + name_size + extra_size) % 64 == 0
        usd = archive.read("model.usda").decode()
        assert 'def Mesh "Geometry"' in usd and 'inputs:file = @texture.png@' in usd
    print("PASS: independent ZIP CRC, uncompressed USDZ, 64-byte alignment, mesh + texture")
    try:
        from pxr import Usd, UsdGeom, UsdShade
    except ImportError:
        print("SKIP: OpenUSD parser not installed; this is not a RealityKit load test")
    else:
        stage = Usd.Stage.Open(str(usdz))
        assert stage
        mesh = UsdGeom.Mesh(stage.GetPrimAtPath("/DepthSurface/Geometry"))
        points = mesh.GetPointsAttr().Get()
        faces = mesh.GetFaceVertexIndicesAttr().Get()
        assert len(points) == 4096 and len(faces) == 23814
        assert max(p[2] for p in points) - min(p[2] for p in points) > 0.25
        assert UsdShade.MaterialBindingAPI(mesh).ComputeBoundMaterial()[0]
        assert stage.GetPrimAtPath("/DepthSurface/Material/Texture").GetAttribute("inputs:file").Get().resolvedPath
        print("PASS: OpenUSD loads actual nonplanar geometry and resolves bound material + packaged texture")
