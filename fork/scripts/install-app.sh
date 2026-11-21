#!/bin/zsh
# Installs a signed VoiceInk.app into /Applications and launches it.
#  - A running VoiceInk is asked to quit first; the installed bundle goes to the Trash.
#  - Permissions are not reset. When the old and new apps have the same designated requirement
#    (both signed by your identity), macOS keeps the Accessibility and Microphone grants. When they
#    differ (the first install over another build), the script says so: grant them again in
#    System Settings → Privacy & Security, then quit and reopen VoiceInk.
# Usage: install-app.sh <signed VoiceInk.app> [--no-launch]
set -u
NEW=${1:?usage: install-app.sh <signed VoiceInk.app> [--no-launch]}
LAUNCH=1
[[ ${2:-} == --no-launch ]] && LAUNCH=0
DST=/Applications/VoiceInk.app
fail() { echo "install-app: $*" >&2; exit 2; }
[[ -d "$NEW" ]] || fail "no app at $NEW"
codesign --verify --deep --strict "$NEW" || fail "the new app fails codesign --verify"
new_dr=$(codesign -d -r- "$NEW" 2>&1 | grep '^designated')
[[ $new_dr == *certificate* || $new_dr == *anchor* ]] || fail "the new app is ad-hoc signed; run sign-app.sh first"
if [[ -d "$DST" ]]; then
  old_dr=$(codesign -d -r- "$DST" 2>&1 | grep '^designated')
  if [[ "$old_dr" == "$new_dr" ]]; then
    echo "designated requirement unchanged: permissions carry over"
  else
    echo "designated requirement differs from the installed app: grant Accessibility and Microphone again after launch"
  fi
  if pgrep -xq VoiceInk; then
    osascript -e 'tell application id "com.prakashjoshipax.VoiceInk" to quit' >/dev/null 2>&1
    for _ in {1..20}; do pgrep -xq VoiceInk || break; sleep 0.5; done
    pgrep -xq VoiceInk && fail "VoiceInk did not quit; quit it and rerun"
  fi
  /usr/bin/trash "$DST" || fail "could not move $DST to the Trash"
fi
ditto "$NEW" "$DST" || fail "copy to $DST failed"
codesign --verify --deep --strict "$DST" || fail "the installed app fails codesign --verify"
echo "installed: $DST"
if (( LAUNCH )); then open -g "$DST"; echo "launched in the background"; fi
