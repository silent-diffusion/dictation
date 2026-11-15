#!/bin/zsh
# Debug builds are development copies with their own bundle ID, com.silentdiffusion.oberton.dev, so they never share
# macOS privacy grants (Accessibility, microphone), the sandbox container, settings or Keychain items with the App Store /
# TestFlight copy or the direct download. Release (App Store and direct) stays com.silentdiffusion.oberton. CI runs this.
set -euo pipefail
cd "${0:A:h}/.."
release=com.silentdiffusion.oberton
fail=0
for target in Oberton "Oberton Direct"; do
    for config in Debug Release; do
        [[ $config == Debug ]] && want=$release.dev || want=$release
        got=$(xcodebuild -project Oberton.xcodeproj -target "$target" -configuration $config -showBuildSettings 2>/dev/null \
            | awk -F' = ' '$1 ~ /^ *PRODUCT_BUNDLE_IDENTIFIER$/ { print $2; exit }')
        if [[ $got != $want ]]; then
            print -u2 "$target ($config): bundle ID is '$got', expected $want"
            fail=1
        fi
    done
done
(( fail == 0 )) && print "Bundle IDs: Debug $release.dev, Release $release."
exit $fail
