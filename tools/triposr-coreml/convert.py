#!/usr/bin/env python3
"""Convert TripoSR (VAST AI / Stability AI, MIT licence) for Moonlight's
on-device picture → 3D (AI 生成 3D → AI 图片转完整 3D → 手机本机).

Produces a folder with
  TripoSREncoder.mlpackage   picture (1×3×512×512, RGB 0…1) → triplane (1×3×40×64×64)
  triposr_decoder.bin        the small decoder MLP + settings (read by the app)
Put the folder into Files (AirDrop / iCloud Drive) and import it in the app.

Run on a Mac (Apple silicon recommended, 16 GB RAM):
  git clone https://github.com/VAST-AI-Research/TripoSR
  python3 -m venv venv && . venv/bin/activate
  pip install torch coremltools omegaconf einops trimesh huggingface-hub transformers pillow
  python convert.py --triposr ./TripoSR --out ./TripoSR-CoreML
The script downloads the weights from Hugging Face (stabilityai/TripoSR, ~1.7 GB).

Status: written against TripoSR's source; it was NOT run by the Moonlight
developers (their build machine could not execute the model). The script
checks its own wrapper against TripoSR before converting and, on a Mac,
compares the Core ML result with PyTorch.
"""
import argparse
import os
import struct
import sys
import types


def stub_torchmcubes():
    # Only TripoSR's mesh extraction needs torchmcubes (a compiled
    # extension); conversion does not.
    try:
        import torchmcubes  # noqa: F401
    except ImportError:
        module = types.ModuleType("torchmcubes")
        module.marching_cubes = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("not needed for conversion"))
        sys.modules["torchmcubes"] = module


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--triposr", required=True, help="path of the TripoSR repository")
    p.add_argument("--out", default="TripoSR-CoreML")
    p.add_argument("--fp32", action="store_true", help="keep float32 (bigger, slower, more exact)")
    args = p.parse_args()

    stub_torchmcubes()
    sys.path.insert(0, os.path.abspath(args.triposr))
    import numpy as np
    import torch
    import torch.nn.functional as F
    import coremltools as ct
    from tsr.system import TSR

    model = TSR.from_pretrained("stabilityai/TripoSR", config_name="config.yaml", weight_name="model.ckpt")
    model.eval()
    size = model.cfg.cond_image_size  # 512

    class Encoder(torch.nn.Module):
        """TSR.forward without the PIL preprocessing, and with the ViT
        position embeddings resized to 512 px once (Core ML has no bicubic
        resize)."""

        def __init__(self, m):
            super().__init__()
            vit = m.image_tokenizer.model
            self.patch = vit.embeddings.patch_embeddings.projection
            self.cls = vit.embeddings.cls_token
            with torch.no_grad():
                pos = vit.embeddings.position_embeddings
                cls_pos, patch_pos = pos[:, :1], pos[:, 1:]
                g = int(round(patch_pos.shape[1] ** 0.5))
                n = size // self.patch.kernel_size[0]
                grid = patch_pos.reshape(1, g, g, -1).permute(0, 3, 1, 2)
                try:
                    # Same resize the transformers ViT uses at runtime.
                    dummy = torch.zeros(1, 1 + n * n, pos.shape[-1])
                    fixed = vit.embeddings.interpolate_pos_encoding(dummy, size, size)
                except Exception:
                    grid = F.interpolate(grid, size=(n, n), mode="bicubic", align_corners=False)
                    fixed = torch.cat([cls_pos, grid.permute(0, 2, 3, 1).reshape(1, n * n, -1)], 1)
            self.register_buffer("pos", fixed.detach().clone())
            self.encoder = vit.encoder
            self.layernorm = vit.layernorm
            self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).reshape(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).reshape(1, 3, 1, 1))
            self.tokenizer = m.tokenizer
            self.backbone = m.backbone
            self.post = m.post_processor

        def forward(self, image):
            x = (image - self.mean) / self.std
            x = self.patch(x).flatten(2).transpose(1, 2)
            x = torch.cat([self.cls.expand(x.shape[0], -1, -1), x], 1) + self.pos
            h = self.layernorm(self.encoder(x)[0])
            tokens = self.backbone(self.tokenizer(1), encoder_hidden_states=h)
            return self.post(self.tokenizer.detokenize(tokens))

    encoder = Encoder(model).eval()
    example = torch.rand(1, 3, size, size)

    # 1. The wrapper must match TripoSR itself.
    with torch.no_grad():
        reference = model(example.permute(0, 2, 3, 1)[0].numpy(), device="cpu")
        ours = encoder(example)
    diff = (reference - ours).abs().max().item()
    print("wrapper vs TripoSR max difference:", diff, "triplane", tuple(ours.shape))
    if diff > 1e-2:
        sys.exit("The wrapper does not match TripoSR (different transformers version?). Not converting.")

    # 2. Convert.
    traced = torch.jit.trace(encoder, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=example.shape)],
        outputs=[ct.TensorType(name="triplane")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
    )
    mlmodel.short_description = "TripoSR encoder (VAST AI / Stability AI, MIT) for Moonlight"
    os.makedirs(args.out, exist_ok=True)
    mlmodel.save(os.path.join(args.out, "TripoSREncoder.mlpackage"))

    # 3. Decoder MLP in Moonlight's TSRD format.
    linears = [m for m in model.decoder.layers if isinstance(m, torch.nn.Linear)]
    r = model.renderer.cfg
    with open(os.path.join(args.out, "triposr_decoder.bin"), "wb") as f:
        f.write(b"TSRD")
        f.write(struct.pack("<I", 1))
        f.write(struct.pack("<fff", float(r.radius), float(r.density_bias), 25.0))
        f.write(struct.pack("<II", int(model.cfg.post_processor.out_channels), int(ours.shape[-1])))
        f.write(struct.pack("<I", len(linears)))
        for layer in linears:
            w = layer.weight.detach().float().numpy()
            b = layer.bias.detach().float().numpy()
            f.write(struct.pack("<II", w.shape[0], w.shape[1]))
            f.write(w.astype("<f4").tobytes())
            f.write(b.astype("<f4").tobytes())

    # 4. On a Mac, check Core ML against PyTorch.
    if sys.platform == "darwin":
        try:
            out = mlmodel.predict({"image": example.numpy()})["triplane"]
            print("Core ML vs PyTorch max difference:", float(np.abs(out - ours.numpy()).max()))
        except Exception as e:
            print("Could not run the Core ML check:", e)
    print("Done:", os.path.abspath(args.out))


if __name__ == "__main__":
    main()
