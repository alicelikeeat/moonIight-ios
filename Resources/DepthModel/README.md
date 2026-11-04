# Depth Anything V2 Small (Core ML)

Apple's Core ML conversion of Depth Anything V2 Small, `DepthAnythingV2SmallF16.mlpackage`,
from https://huggingface.co/apple/coreml-depth-anything-v2-small (revision
`cfef6f6f2a70783dedc0bfae40cecbc2052285d3`), licensed under Apache-2.0.

`Manifest.json` and `model.mlmodel` are committed. The 49 MB `weights/weight.bin` is not
committed; the iOS build workflow downloads it from the pinned revision and checks its SHA-256
(`fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed`) before building.
Without it the app still builds and reports the AI depth engine as unavailable.

Paper: Lihe Yang et al., "Depth Anything V2", arXiv:2406.09414.
