#!/bin/zsh
# The direct build has its own Info.plist (Info-Direct.plist, for Sparkle's keys). Every Mac key of the App Store build's
# Info.plist must be in it with the same value; the iPhone-only UI… keys are skipped. CI runs this.
set -euo pipefail
cd "${0:A:h}/.."
fail=0
for key in ${(f)"$(plutil -convert json -o - Info.plist | python3 -c 'import json, sys; print("\n".join(k for k in json.load(sys.stdin) if not k.startswith("UI")))')"}; do
    if ! diff -q <(plutil -extract "$key" xml1 -o - Info.plist) <(plutil -extract "$key" xml1 -o - Info-Direct.plist 2>/dev/null) >/dev/null; then
        print -u2 "Info-Direct.plist: $key is missing or differs from Info.plist"
        fail=1
    fi
done
(( fail == 0 )) && print "Info-Direct.plist has Info.plist's Mac keys."
exit $fail
