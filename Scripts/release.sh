#!/bin/bash
#
# Build and sign a Release-configuration KVoice.app.
#
# Signing policy (see README "Release builds"):
#   * If a "Developer ID Application" identity exists in the keychain we sign
#     with it, enable the hardened runtime, and apply Scripts/KVoice.entitlements
#     (the mic entitlement is REQUIRED under the hardened runtime — without it
#     AVAudioEngine input is refused no matter what TCC says).
#   * Otherwise we ad-hoc sign. Ad-hoc deliberately does NOT get the hardened
#     runtime: an ad-hoc signature can't be notarized, and the runtime's
#     restrictions only make a local build harder to run.
#
# We sign explicitly, inside-out (nested Mach-O first, bundle last) rather than
# using `codesign --deep`, which is discouraged by Apple: --deep re-signs nested
# code with the OUTER bundle's entitlements and silently mis-signs anything with
# its own requirements. `--deep` is used only for *verification*, where it is
# the documented way to walk the whole bundle.
#
# Usage: Scripts/release.sh          (normally invoked as `make release`)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODEPROJ="$REPO_ROOT/KVoice.xcodeproj"
SCHEME="KVoice"
CONFIGURATION="Release"
BUILD_DIR="$REPO_ROOT/build/release"
APP="$BUILD_DIR/Build/Products/$CONFIGURATION/KVoice.app"
ENTITLEMENTS="$REPO_ROOT/Scripts/KVoice.entitlements"

step()  { printf '\n==> %s\n' "$1"; }
fail()  { printf 'error: %s\n' "$1" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is not available. Install full Xcode, then 'sudo xcode-select -s /Applications/Xcode.app'."
[ -d "$XCODEPROJ" ] || fail "$XCODEPROJ not found — run 'make generate' first."

# ---------------------------------------------------------------- identity ---
# `security find-identity -v -p codesigning` lists only valid (unexpired, with
# private key) identities, one per line:
#   1) A1B2C3... "Developer ID Application: Some Name (TEAMID)"
# We key off the SHA-1 hash, not the display name: names are ambiguous when the
# keychain holds several certificates for the same team.
step "Detecting code-signing identity"
IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
IDENTITY_LINE="$(printf '%s\n' "$IDENTITY_LIST" | grep 'Developer ID Application' | head -1 || true)"

if [ -n "$IDENTITY_LINE" ]; then
    IDENTITY_HASH="$(printf '%s\n' "$IDENTITY_LINE" | awk '{print $2}')"
    IDENTITY_NAME="$(printf '%s\n' "$IDENTITY_LINE" | sed -n 's/.*"\(.*\)".*/\1/p')"
    SIGN_MODE="Developer ID"
    SIGN_ARGS=(--sign "$IDENTITY_HASH" --options runtime --timestamp --entitlements "$ENTITLEMENTS")
    [ -f "$ENTITLEMENTS" ] || fail "hardened runtime requested but $ENTITLEMENTS is missing."
    echo "found: $IDENTITY_NAME"
    echo "mode:  Developer ID + hardened runtime + $(basename "$ENTITLEMENTS")"
else
    IDENTITY_HASH="-"
    IDENTITY_NAME="ad-hoc (no Developer ID Application identity in the keychain)"
    SIGN_MODE="ad-hoc"
    # --timestamp=none: the secure timestamp service is for distributable
    # signatures; an ad-hoc signature can never be notarized, so skip the
    # network round-trip (and the failure mode when offline).
    SIGN_ARGS=(--sign - --timestamp=none)
    echo "found: none"
    echo "mode:  ad-hoc, no hardened runtime (local use only; see README to switch)"
fi

# ------------------------------------------------------------------- build ---
step "Building $SCHEME ($CONFIGURATION)"
# CODE_SIGNING_ALLOWED=NO keeps xcodebuild from applying its own (automatic,
# ad-hoc) signature: we want exactly one signing pass, ours, so that the
# identity/entitlements/runtime flags above are what actually ends up on disk.
xcodebuild \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build

[ -d "$APP" ] || fail "build reported success but $APP is missing."

# -------------------------------------------------------------------- sign ---
step "Signing $(basename "$APP") ($SIGN_MODE)"
# -depth walks children before their parent, so a dylib inside a framework is
# signed before the framework that seals it — the inside-out order codesign
# requires. Nothing nested exists today (Core links statically), but a future
# embedded framework or XPC service must not silently ship unsigned.
NESTED_COUNT=0
while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    echo "  nested: ${nested#"$APP"/}"
    codesign --force "${SIGN_ARGS[@]}" "$nested"
    NESTED_COUNT=$((NESTED_COUNT + 1))
done < <(find "$APP/Contents" -depth \
    \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' -o -name '*.appex' -o -name '*.xpc' \) 2>/dev/null)
echo "  nested code signed: $NESTED_COUNT"

codesign --force "${SIGN_ARGS[@]}" "$APP"

# ------------------------------------------------------------------ verify ---
step "Verifying signature"
# --deep here is verification-only (walks nested code); see header note.
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature|TeamIdentifier|Authority)' || true

# Gatekeeper will reject an ad-hoc build ("not notarized"); that is expected for
# a personal build and must not fail the release, so this is informational.
step "Gatekeeper assessment (informational)"
if spctl --assess --type exec --verbose=4 "$APP" 2>&1; then
    echo "Gatekeeper: accepted"
else
    echo "Gatekeeper: rejected — expected for $SIGN_MODE builds."
    echo "Right-click > Open (once) to run it locally, or sign with a Developer ID and notarize."
fi

# ------------------------------------------------------------------ report ---
APP_SIZE="$(du -sh "$APP" | awk '{print $1}')"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"

cat <<EOF

──────────────────────────────────────────────────────────────────────
 KVoice $VERSION ($BUILD_NUM) — $CONFIGURATION, signed: $SIGN_MODE
 identity: $IDENTITY_NAME
 size:     $APP_SIZE

 App: $APP
──────────────────────────────────────────────────────────────────────
EOF
