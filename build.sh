#!/bin/sh
# SideDock (Mac app) build script.
#   ./build.sh           build into build/ (signed for development)
#   ./build.sh install   build and install into /Applications, then start it
#   ./build.sh release   Developer ID signed + Apple-notarized app in build/release/SideDock.dmg (for any Mac)
set -e
cd "$(dirname "$0")"
PROJECT=SideDock.xcodeproj
APP=build/Build/Products/Release/SideDock.app

case "$1" in
release)
  rm -rf build/release && mkdir -p build/release
  xcodebuild -project $PROJECT -scheme SideDock -configuration Release -allowProvisioningUpdates \
    archive -archivePath build/release/SideDock.xcarchive | grep -E "error|ARCHIVE" || true
  # Developer ID export with destination=upload sends it to Apple's notary service with the Xcode account
  cat > build/release/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>6GB39JB2A6</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath build/release/SideDock.xcarchive \
    -exportOptionsPlist build/release/ExportOptions.plist -exportPath build/release -allowProvisioningUpdates \
    | grep -E "error|EXPORT|Upload" || true
  echo "Waiting for Apple to notarize (usually 1-5 minutes)..."
  until xcodebuild -exportNotarizedApp -archivePath build/release/SideDock.xcarchive \
          -exportPath build/release/notarized >/dev/null 2>&1; do sleep 20; done
  STAGE=$(mktemp -d)
  cp -R build/release/notarized/SideDock.app "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname SideDock -srcfolder "$STAGE" -ov -format UDZO build/release/SideDock.dmg >/dev/null
  rm -rf "$STAGE"
  spctl -a -vv build/release/notarized/SideDock.app
  echo "Done: build/release/SideDock.dmg"
  ;;
*)
  xcodebuild -project $PROJECT -scheme SideDock -configuration Release -allowProvisioningUpdates \
    -derivedDataPath build build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  if [ "$1" = "install" ]; then
    pkill -TERM -x SideDock 2>/dev/null && sleep 2 || true # its quit handler restores the macOS Dock
    rm -rf /Applications/SideDock.app
    ditto $APP /Applications/SideDock.app
    open /Applications/SideDock.app
    echo "Installed /Applications/SideDock.app"
  fi
  ;;
esac
