#!/usr/bin/env bash
# Builds a distributable DroidDrive (plan P4-07): archive, sign with a Developer ID
# identity, notarize, staple, and package as a DMG and a zip.
#
# Nothing here is run automatically. Signing identity, team and notary profile are
# parameters; none is stored in the repo. Updates (Sparkle or another feed) are not
# wired in yet: where the feed is hosted is still to be decided.
#
# Prerequisites, once per Mac:
#   - a "Developer ID Application: <Name> (<TEAMID>)" certificate in the login keychain;
#   - a notarytool keychain profile:
#       xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
#   - XcodeGen (brew install xcodegen).
#
# Usage:
#   scripts/release.sh --identity "Developer ID Application: Name (TEAMID)" --team TEAMID \
#                      --notary-profile <profile> [--version 0.2.0] [--build 2] [--skip-notarize] [--dry-run]
set -euo pipefail

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

IDENTITY=""
TEAM=""
PROFILE=""
VERSION=""
BUILD_NUMBER=""
SKIP_NOTARIZE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="${2:?}"; shift 2 ;;
    --team) TEAM="${2:?}"; shift 2 ;;
    --notary-profile) PROFILE="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --build) BUILD_NUMBER="${2:?}"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "${IDENTITY}" && -n "${TEAM}" ]] || { echo "--identity and --team are required" >&2; usage 1; }
[[ "${IDENTITY}" == "Developer ID Application:"* ]] || { echo "--identity must be a Developer ID Application identity" >&2; exit 1; }
[[ "${IDENTITY}" == *"(${TEAM})" ]] || { echo "--identity does not belong to team ${TEAM}" >&2; exit 1; }
[[ ${SKIP_NOTARIZE} -eq 1 || -n "${PROFILE}" ]] || { echo "--notary-profile is required (or --skip-notarize)" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/release"
ARCHIVE="${OUT}/DroidDrive.xcarchive"
EXPORT="${OUT}/export"
APP="${EXPORT}/DroidDrive.app"

run() {
  echo "+ $*"
  [[ ${DRY_RUN} -eq 1 ]] || "$@"
}

notarize() {
  local file="$1"
  run xcrun notarytool submit "${file}" --keychain-profile "${PROFILE}" --wait
}

cd "${ROOT}"
run rm -rf "${OUT}"
run mkdir -p "${OUT}"
run xcodegen generate

SETTINGS=(DEVELOPMENT_TEAM="${TEAM}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${IDENTITY}"
          PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS=--timestamp)
[[ -n "${VERSION}" ]] && SETTINGS+=(MARKETING_VERSION="${VERSION}")
[[ -n "${BUILD_NUMBER}" ]] && SETTINGS+=(CURRENT_PROJECT_VERSION="${BUILD_NUMBER}")

# 1. Archive (Release, universal: ARCHS_STANDARD in project.yml).
run xcodebuild -project DroidDrive.xcodeproj -scheme DroidDrive -configuration Release \
  -archivePath "${ARCHIVE}" -destination "generic/platform=macOS" "${SETTINGS[@]}" archive

# 2. Export signed with Developer ID. Team-prefixed App Groups need no provisioning
#    profile on macOS; if Xcode asks for one, add provisioningProfiles to the plist.
EXPORT_OPTIONS="${OUT}/ExportOptions.plist"
if [[ ${DRY_RUN} -eq 0 ]]; then
  cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${IDENTITY}</string>
  <key>teamID</key><string>${TEAM}</string>
</dict>
</plist>
PLIST
fi
run xcodebuild -exportArchive -archivePath "${ARCHIVE}" -exportPath "${EXPORT}" -exportOptionsPlist "${EXPORT_OPTIONS}"

# 3. Check the signature: hardened runtime, timestamp, the extension signed too.
run codesign --verify --deep --strict --verbose=2 "${APP}"
run codesign --display --verbose=2 "${APP}/Contents/PlugIns/DroidDriveFileProvider.appex"

# 4. Notarize the app and staple the ticket.
APP_ZIP="${OUT}/DroidDrive-notarize.zip"
if [[ ${SKIP_NOTARIZE} -eq 0 ]]; then
  run ditto -c -k --keepParent "${APP}" "${APP_ZIP}"
  notarize "${APP_ZIP}"
  run xcrun stapler staple "${APP}"
  run xcrun stapler validate "${APP}"
  run spctl --assess --type execute --verbose "${APP}"
fi

# 5. Package: a zip of the stapled app, and a signed (and notarized) DMG.
NAME="DroidDrive-${VERSION:-dev}"
run ditto -c -k --keepParent "${APP}" "${OUT}/${NAME}.zip"
STAGING="${OUT}/dmg"
run mkdir -p "${STAGING}"
run cp -R "${APP}" "${STAGING}/"
run ln -s /Applications "${STAGING}/Applications"
run hdiutil create -volname DroidDrive -srcfolder "${STAGING}" -ov -format UDZO "${OUT}/${NAME}.dmg"
run codesign --sign "${IDENTITY}" --timestamp "${OUT}/${NAME}.dmg"
if [[ ${SKIP_NOTARIZE} -eq 0 ]]; then
  notarize "${OUT}/${NAME}.dmg"
  run xcrun stapler staple "${OUT}/${NAME}.dmg"
fi

echo "Done: ${OUT}/${NAME}.dmg and ${OUT}/${NAME}.zip"
