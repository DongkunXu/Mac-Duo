#!/bin/zsh
# Publishes the current commit of main as a GitHub release: a clean Developer ID build, notarized
# and stapled, checked with the rendering self-test, tagged v<MARKETING_VERSION> and uploaded with
# its checksum.
#
# Usage: Scripts/release.sh PROFILE
#
# PROFILE is a notarytool keychain profile, made once with `xcrun notarytool store-credentials`.
# Requires the GitHub CLI (gh), signed in with write access to the repository.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

BUILT=build/DerivedData/Build/Products/Release/MacDuo.app

fail() {
    print -u2 "release: $1"
    exit 1
}

(( $# == 1 )) || fail "usage: Scripts/release.sh PROFILE"
command -v gh >/dev/null || fail "the GitHub CLI is not installed (brew install gh)"

[[ -z $(git status --porcelain) ]] || fail "the working tree has uncommitted changes"
[[ $(git branch --show-current) == main ]] || fail "releases are made from main"
git fetch --quiet origin
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main differs from origin/main"

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
[[ -n $version ]] || fail "MARKETING_VERSION was not found in project.yml"
tag=v$version
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "the tag $tag already exists"
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag") || fail "cannot reach origin"
[[ -z $remote_tag ]] || fail "the tag $tag already exists on GitHub"

rm -rf build/DerivedData
Scripts/package.sh --notarize "$1"

print "Self-test…"
if ! report=$("$BUILT/Contents/MacOS/MacDuo" --self-test 2>&1); then
    print -u2 "$report"
    fail "self-test failed; nothing was published"
fi

zip=build/MacDuo-$version-arm64.zip
flags=()
[[ $version == *-* ]] && flags+=(--prerelease)

print "Publishing $tag…"
git tag -a "$tag" -m "Mac Duo $version"
git push --quiet origin "$tag"
gh release create "$tag" "$zip" "$zip.sha256" --verify-tag --title "Mac Duo $version" $flags \
    --notes-file - <<'NOTES'
For Apple silicon MacBooks with macOS 26 or later. The app is signed with a Developer ID and notarized by Apple.

1. Unzip the download, move `MacDuo.app` to `/Applications` and open it.
2. Turn on Screen Recording for Mac Duo in System Settings → Privacy & Security → Screen Recording, then click **Relaunch** in Mac Duo's Settings → Status.

The SHA-256 of the zip is in the `.sha256` file.
NOTES
print "Published $tag"
