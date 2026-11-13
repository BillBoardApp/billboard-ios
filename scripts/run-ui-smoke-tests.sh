#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.ui-tests"

if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
fi

if [ -z "${BB_UI_TEST_EMAIL:-}" ] || [ -z "${BB_UI_TEST_PASSWORD:-}" ]; then
  echo "Missing BB_UI_TEST_EMAIL or BB_UI_TEST_PASSWORD."
  echo "Set them in $ENV_FILE before running signed-in UI smoke tests."
  exit 1
fi

# xcodebuild passes TEST_RUNNER_-prefixed variables to the test process with the prefix
# stripped, so the UI tests read BB_UI_TEST_EMAIL/BB_UI_TEST_PASSWORD from their own
# environment. Nothing is written into the build products.
export TEST_RUNNER_BB_UI_TEST_EMAIL="$BB_UI_TEST_EMAIL"
export TEST_RUNNER_BB_UI_TEST_PASSWORD="$BB_UI_TEST_PASSWORD"

xcodebuild \
  -workspace "$ROOT_DIR/BillBoard.xcworkspace" \
  -scheme Billboard \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:BillboardUITests \
  test | xcpretty
