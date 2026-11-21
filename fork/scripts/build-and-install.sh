#!/bin/zsh
# Builds this fork with upstream's `make local` (ad-hoc), re-signs it with your persistent
# identity (created on the first run), and installs it into /Applications.
# Usage: fork/scripts/build-and-install.sh
set -eu
S=${0:A:h}
R=${S:h:h}
"$S/make-signing-identity.sh"
make -C "$R" local LOCAL_CODESIGN_IDENTITY=-
APP="$HOME/Downloads/VoiceInk.app"
"$S/sign-app.sh" "$APP"
"$S/install-app.sh" "$APP"
