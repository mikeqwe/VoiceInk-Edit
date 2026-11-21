#!/bin/zsh
# Re-signs a built VoiceInk.app with the identity from make-signing-identity.sh, inside out,
# keeping each component's entitlements, flags and hardened runtime. The app's designated
# requirement then names that certificate, so macOS keeps its permissions across rebuilds.
# Usage: sign-app.sh <path/to/VoiceInk.app>
# Settings (environment): VOICEINK_SIGNING_DIR, as in make-signing-identity.sh.
set -eu
: "${HOME:?HOME is not set}"
A=${1:?usage: sign-app.sh <path/to/VoiceInk.app>}
D=${VOICEINK_SIGNING_DIR:-$HOME/Library/Application Support/VoiceInkForkSigning}
KC="$D/signing.keychain-db"
U="$D/unlock"
[[ -d "$A" ]] || { echo "sign-app: no app at $A" >&2; exit 2; }
[[ -r "$KC" && -r "$U" && -r "$D/cert.pem" ]] || { echo "sign-app: no signing keychain in $D: run make-signing-identity.sh first" >&2; exit 2; }
SHA1=$(/usr/bin/openssl x509 -in "$D/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
security unlock-keychain -p "$(cat "$U")" "$KC"
sign() {
  echo "sign ${1#$A/}"
  codesign --force --sign "$SHA1" --keychain "$KC" --timestamp=none \
    --preserve-metadata=entitlements,flags,runtime "$1"
}
# find -depth lists children before their parents, so every container is sealed over
# already-signed nested code. Symlinked aliases (e.g. Sparkle.framework/Updater.app) are
# skipped by -type.
typeset -a nested
nested=( ${(f)"$(find "$A/Contents" -depth \( \
  \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' \) \) -o \
  \( -type f \( -name '*.dylib' -o -path '*/Sparkle.framework/Versions/*/Autoupdate' \) \) \) -print)"} )
for c in $nested; do sign "$c"; done
sign "$A"
codesign --verify --deep --strict --verbose=2 "$A"
