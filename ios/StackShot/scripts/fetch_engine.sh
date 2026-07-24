#!/usr/bin/env bash
# Vendors the open-source stacking engine for embedding:
#   - PetteriAimonen/focus-stack (MIT) C++ sources
#   - OpenCV iOS xcframework (Apache-2.0)
# Run from ios/StackShot/. After it succeeds:
#   1. Add Vendor/opencv2.xcframework to the Xcode target (embed & sign not required; static).
#   2. Add Vendor/focus-stack/src/*.cc(.hh) to the target (exclude its main.cc CLI entry).
#   3. Uncomment ENGINE_EMBEDDED flags in project.yml and re-run `xcodegen generate`.
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")/.." && pwd)/Vendor"
OPENCV_VERSION="4.9.0"

mkdir -p "$VENDOR_DIR"
cd "$VENDOR_DIR"

echo "==> Fetching focus-stack (MIT)"
if [ ! -d focus-stack ]; then
  git clone --depth 1 https://github.com/PetteriAimonen/focus-stack.git
else
  echo "    already present, skipping clone"
fi

echo "==> Fetching OpenCV ${OPENCV_VERSION} iOS framework (Apache-2.0)"
if [ ! -d opencv2.xcframework ]; then
  curl -L -o opencv-ios.zip \
    "https://github.com/opencv/opencv/releases/download/${OPENCV_VERSION}/opencv-${OPENCV_VERSION}-ios-framework.zip"
  unzip -q opencv-ios.zip
  rm opencv-ios.zip
else
  echo "    already present, skipping download"
fi

echo "==> Copying license texts for the in-app Acknowledgements screen"
mkdir -p licenses
cp focus-stack/LICENSE licenses/focus-stack-MIT.txt 2>/dev/null || true

echo
echo "Done. Now follow steps 1–3 in the header of this script."
