#!/bin/zsh
# Builds Mac Duo in Release, checks the bundle and packages it as build/MacDuo-<version>-arm64.zip
# with a SHA-256 file next to it. Unlike install.sh it installs nothing and never launches the app,
# so it is safe to run in CI.
#
# Usage: Scripts/package.sh [--notarize PROFILE]
#
# By default signing comes from Config/Signing.xcconfig: ad hoc, or your own certificate from
# Config/Signing.local.xcconfig. With --notarize the app is signed with the Developer ID Application
# certificate in the keychain, notarized with the notarytool keychain profile PROFILE and stapled.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

BUILT=build/DerivedData/Build/Products/Release/MacDuo.app

fail() {
    print -u2 "package: $1"
    exit 1
}

notary_profile=
if (( $# )); then
    [[ $1 == --notarize && $# == 2 ]] || fail "usage: Scripts/package.sh [--notarize PROFILE]"
    notary_profile=$2
fi

[[ $(uname -m) == arm64 ]] || fail "Mac Duo requires an Apple silicon Mac"
command -v xcodegen >/dev/null || fail "XcodeGen is not installed (brew install xcodegen)"
command -v xcodebuild >/dev/null || fail "Xcode is not installed"

signing=()
if [[ -n $notary_profile ]]; then
    identities=(${(f)"$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p')"})
    (( ${#identities} == 1 )) || fail "expected one Developer ID Application identity, found ${#identities}"
    identity=$identities[1]
    team=${${identity##*\(}%\)}
    # Notarization requires the hardened runtime, a secure timestamp and no get-task-allow entitlement.
    signing=(CODE_SIGN_IDENTITY=$identity DEVELOPMENT_TEAM=$team ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
    print "Signing with $identity"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

print "Building (Release)…"
xcodegen generate --quiet
xcodebuild -project MacDuo.xcodeproj -scheme MacDuo -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData $signing build -quiet \
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
# Not named `path`: in zsh that variable is tied to PATH.
for entry in Contents/Resources/default.metallib Contents/Resources/Assets.car Contents/Resources/AppIcon.icns \
        Contents/Resources/zh-Hans.lproj Contents/Frameworks/MacDuoKit.framework/Versions/A/MacDuoKit; do
    [[ -e $BUILT/$entry ]] || missing+=($entry)
done
if (( ${#missing} )); then
    print -u2 "package: missing from the bundle: ${missing[*]}"
    find "$BUILT/Contents" -maxdepth 3 | sort >&2
    exit 1
fi
# The rpath is stored as plain text in the Mach-O load commands.
grep -aq '@executable_path/../Frameworks' "$BUILT/Contents/MacOS/MacDuo" \
    || fail "the executable cannot find the embedded framework"
codesign --verify --strict --deep "$BUILT" || fail "the built app's signature does not verify"

if [[ -n $notary_profile ]]; then
    print "Notarizing…"
    ditto -c -k --keepParent "$BUILT" "$tmp/submission.zip"
    xcrun notarytool submit "$tmp/submission.zip" --keychain-profile "$notary_profile" --wait \
        --output-format json > "$tmp/notary.json" || fail "the notarization request failed"
    notary_status=$(plutil -extract status raw -o - "$tmp/notary.json")
    if [[ $notary_status != Accepted ]]; then
        xcrun notarytool log "$(plutil -extract id raw -o - "$tmp/notary.json")" \
            --keychain-profile "$notary_profile" >&2 || true
        fail "notarization finished with status $notary_status"
    fi
    xcrun stapler staple -q "$BUILT" || fail "stapling failed"
    spctl --assess --type execute "$BUILT" || fail "Gatekeeper rejects the app"
fi

print "Packaging…"
zip=build/MacDuo-$version-arm64.zip
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$BUILT" "$zip"

# The archive must unpack to the same, still valid app.
ditto -x -k "$zip" "$tmp/check"
codesign --verify --strict --deep "$tmp/check/MacDuo.app" || fail "the signature does not survive the zip"
cdhash() { codesign -d -vvv "$1" 2>&1 | sed -n 's/^CDHash=//p' }
[[ $(cdhash "$BUILT") == $(cdhash "$tmp/check/MacDuo.app") ]] || fail "the unpacked app differs from the built one"
if [[ -n $notary_profile ]]; then
    xcrun stapler validate -q "$tmp/check/MacDuo.app" || fail "the notarization ticket does not survive the zip"
fi

(cd build && shasum -a 256 "${zip:t}" > "${zip:t}.sha256")
print "Packaged $zip"
cat "$zip.sha256"
