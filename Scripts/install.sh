#!/bin/zsh
# Builds Mac Duo in Release, runs its self-test and installs it as /Applications/MacDuo.app,
# replacing any earlier copy, then launches it. Run it again to update.
#
# Signing comes from Config/Signing.xcconfig: ad-hoc by default, or your own certificate from
# Config/Signing.local.xcconfig. With a certificate the Screen Recording permission survives updates.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

TARGET=/Applications/MacDuo.app
BUILT=build/DerivedData/Build/Products/Release/MacDuo.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() {
    print -u2 "install: $1"
    exit 1
}

[[ $(uname -m) == arm64 ]] || fail "Mac Duo requires an Apple silicon Mac"
command -v xcodegen >/dev/null || fail "XcodeGen is not installed (brew install xcodegen)"
command -v xcodebuild >/dev/null || fail "Xcode is not installed"

print "Building (Release)…"
xcodegen generate --quiet
xcodebuild -project MacDuo.xcodeproj -scheme MacDuo -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build -quiet \
    || fail "build failed"

settings=$(xcodebuild -project MacDuo.xcodeproj -target MacDuo -configuration Release -showBuildSettings 2>/dev/null)
setting() { print -r -- "$settings" | sed -n "s/^ *$1 = //p" | head -1 }
bundle_id=$(setting PRODUCT_BUNDLE_IDENTIFIER)
identity=$(setting CODE_SIGN_IDENTITY)

codesign --verify --strict --deep "$BUILT" || fail "the built app's signature does not verify"
if [[ $identity == "-" ]]; then
    adhoc=1
else
    adhoc=0
    requirement=$(codesign -d -r- "$BUILT" 2>&1)
    [[ $requirement == *"identifier \"$bundle_id\""* && $requirement == *"certificate leaf[subject.CN] = \"$identity\""* ]] \
        || fail "the build is not signed as $bundle_id by \"$identity\""
fi

print "Self-test…"
if ! report=$("$BUILT/Contents/MacOS/MacDuo" --self-test 2>&1); then
    print -u2 "$report"
    fail "self-test failed; nothing was installed"
fi

pids=(${(f)"$(pgrep -x MacDuo || true)"})
if (( ${#pids} )); then
    print "Quitting the running copy…"
    kill -TERM $pids
    for pid in $pids; do
        for _ in {1..50}; do
            kill -0 $pid 2>/dev/null || break
            sleep 0.1
        done
        kill -0 $pid 2>/dev/null && fail "pid $pid did not quit"
    done
fi

print "Installing to $TARGET…"
rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"
codesign --verify --strict --deep "$TARGET" || fail "the installed copy's signature does not verify"
"$LSREGISTER" -f "$TARGET"

open "$TARGET"
print "Installed and launched Mac Duo $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString)."
if (( adhoc )); then
    print "Note: this build is signed ad hoc. macOS asks for Screen Recording permission again after each"
    print "update. To keep it, sign with your own certificate (Config/Signing.local.xcconfig.example)."
fi
