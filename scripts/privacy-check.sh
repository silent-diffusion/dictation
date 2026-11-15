#!/bin/sh
# Privacy check for what is about to be pushed: personal paths, the signing team, host names, keys and tokens, non-noreply
# e-mail addresses, and files that never belong in the repository (signing material, recordings, Xcode user state).
# Only lines a commit adds are checked, and commit messages.
#
#   scripts/privacy-check.sh                  the commits no remote has yet (HEAD --not --remotes)
#   scripts/privacy-check.sh origin/main..    any range git log takes
#
# It can also run as git's pre-push hook, which passes the remote's name and URL and the refs on stdin. It is not
# installed as one; to install it:  ln -s ../../scripts/privacy-check.sh "$(git rev-parse --git-common-dir)/hooks/pre-push"
#
# The values that identify this machine (user name, home folder, host names, the team in apple/Local.xcconfig) are read
# here at run time, so this file names none of them. Some patterns are written so they don't match themselves.

z=0000000000000000000000000000000000000000
root=$(git rev-parse --show-toplevel) || exit 2

# Generic: home folders and volumes, temp folders, Windows profiles, keys and tokens, a team ID in a build setting.
pat='/Users/[A-Za-z]|/Volume[s]/|[A-Za-z]:\\Users\\|/private/(tmp|var)/|privaterela[y]|DESKTOP-[A-Z0-9]{5,}|BEGIN [A-Z ]*PRIVATE KEY|sk-an[t]-|sk-[A-Za-z0-9]{32}|gh[pousr]_[A-Za-z0-9]{20}|github_pa[t]_|xox[abprs]-[A-Za-z0-9]|AKIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{30}|AIza[0-9A-Za-z_-]{30}|DEVELOPMENT_TEAM *= *[A-Z0-9]{10}'

# This machine's own values, escaped for grep -E.
esc() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
add() { [ -n "$1" ] && [ ${#1} -ge 4 ] && pat="$pat|$(esc "$1")"; }
add "$(id -un)"
add "$HOME"
if command -v scutil >/dev/null 2>&1; then
    add "$(scutil --get LocalHostName 2>/dev/null)"
    add "$(scutil --get ComputerName 2>/dev/null)"
fi
add "$(hostname -s 2>/dev/null)"
team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$root/apple/Local.xcconfig" 2>/dev/null | head -1)
add "$team"
me=$(git config user.email)
case "$me" in *noreply*) ;; *) add "$me" ;; esac

# Files that never belong in the repository.
bad='(^|/)(\.DS_Store|xcuserdata/|[^/]*\.xcuserstate|Local\.xcconfig|\.env(\.[^/]*)?|DerivedData/|[^/]*\.(p12|p8|cer|mobileprovision|provisionprofile|xcarchive|wav|m4a|jsonl))($|/)'
# Commit e-mail addresses that may be published.
mail='^([0-9]+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com$|^noreply@github\.com$|^noreply@anthropic\.com$'

found=$(mktemp) || exit 2
trap 'rm -f "$found"' EXIT
check() { # git log arguments selecting the commits
    git log --format='%ae%n%ce' "$@" | sort -u | grep -vE "$mail" | sed 's/^/e-mail that is not a noreply address: /' >>"$found"
    git log --format='%h %B' "$@" | grep -E "$pat" | sed 's/^/commit message: /' >>"$found"
    git log -p --no-ext-diff --format='commit %h' "$@" \
        | awk '/^commit [0-9a-f]+$/ { c = $2; next } /^\+\+\+ / { f = substr($0, 7); next } /^\+/ { print c " " f ": " substr($0, 2) }' \
        | grep -E "$pat" >>"$found"
    git log --name-only --diff-filter=AMR --format= "$@" | sort -u | grep -E "$bad" | sed 's/^/file that should not be pushed: /' >>"$found"
}

if [ $# -eq 2 ] && { [ "$1" = "$2" ] || git remote | grep -qx -- "$1"; }; then
    # The pre-push hook: called with the remote's name and URL, "<local ref> <local sha> <remote ref> <remote sha>" per line on stdin.
    while read -r lref lsha rref rsha; do
        [ "$lsha" = $z ] && continue # a deleted branch
        if [ "$rsha" = $z ]; then check "$lsha" --not --remotes; else check "$rsha..$lsha"; fi
    done
elif [ $# -ge 1 ]; then
    check "$@"
else
    check HEAD --not --remotes
fi

if [ -s "$found" ]; then
    cat "$found"
    echo "Privacy check failed: the lines above would be published. Fix them (or rewrite those commits) before pushing." >&2
    exit 1
fi
echo "Privacy check passed."
exit 0
