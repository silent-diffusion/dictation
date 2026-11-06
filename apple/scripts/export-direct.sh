#!/bin/zsh
# The direct download: archive the "Oberton Direct" scheme, export it signed with Developer ID, notarize it, staple the
# ticket and zip it for Sparkle. Publishes nothing: the result stays in apple/build-direct/ (git ignores it).
#
#   scripts/export-direct.sh                  archive, export, notarize, staple, zip
#   scripts/export-direct.sh --no-notarize    stop after the signed export (to check the signing)
#
# Needs: DEVELOPMENT_TEAM in Local.xcconfig and a "Developer ID Application" certificate for that team in the login
# keychain. Notarization credentials are read, never stored here, from one of:
#   NOTARY_PROFILE=<name>     a notarytool keychain profile, made once with
#                             xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
#                             (it asks for an app-specific password and keeps it in the keychain); default "oberton-notary"
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER    an App Store Connect API key (.p8 path, key ID, issuer ID)
#   NOTARY_APPLE_ID, NOTARY_PASSWORD            an Apple ID and an app-specific password (the team from Local.xcconfig)
set -euo pipefail

cd "${0:A:h}/.."
notarize=1
[[ "${1:-}" == "--no-notarize" ]] && notarize=0

out=build-direct
archive=$out/Oberton.xcarchive
export_dir=$out/export
rm -rf "$archive" "$export_dir"
mkdir -p "$out"

settings=$(xcodebuild -project Oberton.xcodeproj -scheme "Oberton Direct" -configuration Release -showBuildSettings 2>/dev/null)
team=$(print -r -- "$settings" | sed -n 's/^ *DEVELOPMENT_TEAM = //p' | head -1)
version=$(print -r -- "$settings" | sed -n 's/^ *MARKETING_VERSION = //p' | head -1)
key=$(print -r -- "$settings" | sed -n 's/^ *OBERTON_SPARKLE_PUBLIC_KEY = //p' | head -1)
if [[ -z "$team" ]]; then
    print -u2 "DEVELOPMENT_TEAM is empty: copy Local.xcconfig.example to Local.xcconfig and fill it in."
    exit 1
fi
if [[ -z "$key" ]]; then
    print -u2 "OBERTON_SPARKLE_PUBLIC_KEY (Direct.xcconfig) is empty: a build without it can never update itself."
    exit 1
fi

print "Archiving Oberton $version (Oberton Direct, Release)…"
xcodebuild -project Oberton.xcodeproj -scheme "Oberton Direct" -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" -allowProvisioningUpdates archive -quiet

# Developer ID, signed by Xcode with the archive's team (nothing team-specific is written to disk).
options=$out/ExportOptions.plist
cat > "$options" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
print "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$export_dir" -allowProvisioningUpdates -quiet
app=$export_dir/Oberton.app

codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
if ! print -r -- "$details" | grep -q "^Authority=Developer ID Application"; then
    print -u2 "The app is not signed with a Developer ID Application certificate."
    exit 1
fi
if ! print -r -- "$details" | grep -q "flags=.*runtime"; then
    print -u2 "The hardened runtime is off; notarization would fail."
    exit 1
fi
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    print -u2 "The direct build carries the App Sandbox entitlement; it shouldn't."
    exit 1
fi
print "Signed: $app"
(( notarize )) || exit 0

zip=$out/Oberton-$version.zip
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

credentials=()
if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    credentials=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    credentials=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$team")
else
    credentials=(--keychain-profile "${NOTARY_PROFILE:-oberton-notary}")
fi
print "Notarizing (this takes a few minutes)…"
xcrun notarytool submit "$zip" "${credentials[@]}" --wait
xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"

# Zip the stapled app again: this zip is what the appcast points to.
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
print "\nReady: $zip"
print "Next, by hand and only when publishing: sign the zip and write the appcast with Sparkle's generate_appcast"
print "(in the Sparkle package's artifacts under DerivedData, SourcePackages/artifacts/sparkle/Sparkle/bin), then upload both."
