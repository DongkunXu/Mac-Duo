#!/bin/zsh
# Builds Mac Duo in Release, checks the bundle and packages it as build/MacDuo-<version>-arm64.zip
# with a SHA-256 file next to it. Unlike install.sh it installs nothing and never launches the app,
# so it is safe to run in CI.
#
# Signing comes from Config/Signing.xcconfig: ad-hoc by default, or your own certificate from
# Config/Signing.local.xcconfig.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

BUILT=build/DerivedData/Build/Products/Release/MacDuo.app

fail() {
    print -u2 "package: $1"
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
[[ -d $BUILT ]] || fail "$BUILT was not produced"

print "Checking the bundle…"
plist=$BUILT/Contents/Info.plist
plist_value() { plutil -extract "$1" raw -o - "$plist" }
[[ $(plist_value CFBundleIdentifier) == com.dongkunxu.macduo ]] || fail "unexpected bundle identifier"
[[ $(plist_value LSMinimumSystemVersion) == 26.0 ]] || fail "unexpected minimum macOS version"
[[ $(plist_value LSUIElement) == true ]] || fail "LSUIElement is not set"
version=$(plist_value CFBundleShortVersionString)
[[ -n $version && $version != *'$('* ]] || fail "the version was not resolved"

[[ $(lipo -archs "$BUILT/Contents/MacOS/MacDuo") == arm64 ]] || fail "the executable is not arm64 only"
missing=()
for path in Contents/Resources/default.metallib Contents/Resources/Assets.car Contents/Resources/AppIcon.icns \
        Contents/Resources/zh-Hans.lproj Contents/Frameworks/MacDuoKit.framework/Versions/A/MacDuoKit; do
    [[ -e $BUILT/$path ]] || missing+=($path)
done
if (( ${#missing} )); then
    print -u2 "package: missing from the bundle: ${missing[*]}"
    find "$BUILT/Contents" -maxdepth 3 | sort >&2
    exit 1
fi
load_commands=$(otool -l "$BUILT/Contents/MacOS/MacDuo")
[[ $load_commands == *'@executable_path/../Frameworks'* ]] || fail "the executable cannot find the embedded framework"
codesign --verify --strict --deep "$BUILT" || fail "the built app's signature does not verify"

print "Packaging…"
zip=build/MacDuo-$version-arm64.zip
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$BUILT" "$zip"

# The archive must unpack to the same, still valid app.
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$zip" "$check"
codesign --verify --strict --deep "$check/MacDuo.app" || fail "the signature does not survive the zip"
cdhash() { codesign -d -vvv "$1" 2>&1 | sed -n 's/^CDHash=//p' }
[[ $(cdhash "$BUILT") == $(cdhash "$check/MacDuo.app") ]] || fail "the unpacked app differs from the built one"

(cd build && shasum -a 256 "${zip:t}" > "${zip:t}.sha256")
print "Packaged $zip"
cat "$zip.sha256"
