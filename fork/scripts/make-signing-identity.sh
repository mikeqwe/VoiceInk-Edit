#!/bin/zsh
# Creates a persistent, self-signed code-signing identity for your own VoiceInk builds, once.
#
# Why: macOS keeps the Accessibility and Microphone grants for an app whose code signature
# stays the same. Ad-hoc builds get a new signature on every rebuild, so the grants are lost.
# Signed with this identity, every rebuild keeps them.
#
# The identity lives in its own keychain with a random unlock string kept in a 0600 file beside
# it, so signing raises no password dialog. Anyone who runs code as your user can read that file
# and sign as this identity: use it only for your own builds.
#
# Settings (environment):
#   VOICEINK_SIGNING_NAME  certificate name   (default: VoiceInk Fork Signing)
#   VOICEINK_SIGNING_DIR   keychain directory (default: ~/Library/Application Support/VoiceInkForkSigning)
set -eu
: "${HOME:?HOME is not set}"
NAME=${VOICEINK_SIGNING_NAME:-VoiceInk Fork Signing}
D=${VOICEINK_SIGNING_DIR:-$HOME/Library/Application Support/VoiceInkForkSigning}
KC="$D/signing.keychain-db"
U="$D/unlock"
if [[ -e "$KC" ]]; then echo "signing keychain already present: $KC"; exit 0; fi
mkdir -p "$D"; chmod 700 "$D"
umask 077
/usr/bin/openssl rand -hex 24 > "$U"
security create-keychain -p "$(cat "$U")" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout, no lock on sleep
T=$(mktemp -d)
trap '/usr/bin/trash "$T" 2>/dev/null || true' EXIT
cat > "$T/req.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -config "$T/req.cnf" -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
P=$(/usr/bin/openssl rand -hex 16)   # transport passphrase for the .p12 only
/usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" \
  -out "$T/id.p12" -passout "pass:$P"
security import "$T/id.p12" -k "$KC" -f pkcs12 -P "$P" -T /usr/bin/codesign
# Let codesign use the key without a dialog.
security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$U")" "$KC" >/dev/null
cp "$T/cert.pem" "$D/cert.pem"
/usr/bin/openssl x509 -in "$T/cert.pem" -noout -subject -enddate -fingerprint -sha1
