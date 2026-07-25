#!/usr/bin/env bash
# Vendors the open-source stacking engine for embedding:
#   - PetteriAimonen/focus-stack (MIT) C++ sources
#   - OpenCV iOS xcframework (Apache-2.0)
# Run from ios/StackShot/. This is the one command needed to get the real,
# aligning C++ engine building on device — see the "Done" message at the
# bottom of this script for what to do once it finishes.
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
# The release zip contains opencv2.framework (a classic fat framework with
# device + simulator slices), NOT an xcframework.
if [ ! -d opencv2.framework ]; then
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

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Generating StackShotEngine.xcodeproj"
if command -v xcodegen >/dev/null 2>&1; then
  (cd "$PROJECT_DIR" && xcodegen generate --spec project-engine.yml)
  echo
  echo "Done. Two separate Xcode projects now exist in ios/StackShot/:"
  echo "  - StackShotEngine.xcodeproj  -> open this to build and run on device WITH"
  echo "    the real focus-stack + OpenCV C++ engine (frame alignment included)."
  echo "  - StackShot.xcodeproj        -> the plain project (from project.yml), used"
  echo "    for the unit tests and the pure-Swift fallback engine. Unaffected by this"
  echo "    script; regenerate it separately with \`xcodegen generate\` if needed."
else
  echo
  echo "xcodegen not found on PATH — vendoring is done, but StackShotEngine.xcodeproj"
  echo "was not generated. Install it and re-run this script:"
  echo "    brew install xcodegen"
  echo "    ./scripts/fetch_engine.sh"
  exit 0
fi
