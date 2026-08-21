#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Local Digest"
BUNDLE_ID="com.web.me.LocalDigest"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
PCC_ENTITLEMENTS="$ROOT_DIR/LocalDigest.entitlements"
PREVIEW_ENTITLEMENTS="$ROOT_DIR/LocalDigest/Support/LocalDigestPreview.entitlements"
SIGNING_IDENTITY="${LOCAL_DIGEST_SIGNING_IDENTITY:-}"
PROVISIONING_PROFILE="${LOCAL_DIGEST_PROVISIONING_PROFILE:-}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ -n "$SIGNING_IDENTITY" && -n "$PROVISIONING_PROFILE" ]]; then
  xcodebuild -project "$ROOT_DIR/LocalDigest.xcodeproj" -scheme LocalDigest -configuration Debug -sdk macosx -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
  if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
    echo "Provisioning profile not found: $PROVISIONING_PROFILE" >&2
    exit 1
  fi
  /usr/bin/ditto "$PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
  /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --entitlements "$PCC_ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "Built a provisioned Private Cloud Compute app."
elif xcodebuild -project "$ROOT_DIR/LocalDigest.xcodeproj" -scheme LocalDigest -configuration Debug -sdk macosx -derivedDataPath "$DERIVED_DATA" build; then
  echo "Built with the installed Local Digest PCC development profile."
else
  echo "The PCC development profile is unavailable; falling back to an Apple Local preview." >&2
  xcodebuild -project "$ROOT_DIR/LocalDigest.xcodeproj" -scheme LocalDigest -configuration Debug -sdk macosx -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
  /usr/bin/codesign --force --deep --sign - --entitlements "$PREVIEW_ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "Built a local preview. Apple Local works; PCC needs a locally configured development profile."
fi

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
