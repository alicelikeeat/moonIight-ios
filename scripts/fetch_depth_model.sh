#!/bin/bash
set -euo pipefail
model_dir='Resources/DepthModel/DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights'
mkdir -p "$model_dir"
curl -fLsS --retry 3 'https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/cfef6f6f2a70783dedc0bfae40cecbc2052285d3/DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights/weight.bin' -o "$model_dir/weight.bin"
echo "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed  $model_dir/weight.bin" | shasum -a 256 -c -
