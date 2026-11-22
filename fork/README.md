# VoiceInk Edit

VoiceInk Edit is a fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) with a few additions for
editing text by keyboard and voice. Everything works with a normal keyboard: bind the shortcuts
you like in VoiceInk's Settings. It is built from source and has no automatic updates: pull and
rebuild to update. Upstream's README, license (GPL-3.0) and build instructions apply.

## What it adds

| Feature | What it does | Where to set it up |
| --- | --- | --- |
| **Suggest Replacement** | Select a word, a phrase or a line in any app and press the shortcut. A small list opens at the selection with up to five replacements that fit the surrounding text. Press 1–5 (top row, or ⌘ + keypad 1–9) or click one to paste it over the selection; Esc closes the list and changes nothing, and so does typing a character, Backspace or Delete (the key still reaches the app; arrows and ⏎ keep the list). Press the shortcut again, or click *more*, for a new set. | Settings → Suggest → *Suggest Replacement*. It is unbound until you bind it. |
| **Quick Add takes the selection** | Quick Add to Dictionary opens with the selected text already filled in. | Dictionary → Dictionary Settings → *Quick Add to Dictionary*. |
| **Keep web accessibility on** | Electron apps (Slack, T3 Code, …) show their full text to Accessibility only while their web accessibility is on, and stock VoiceInk switches it off after each read. For the apps you list, VoiceInk turns it on and leaves it on, so Suggest and selected-text context can read them. Other apps are restored as before. | Settings → Suggest → *Keep Web Accessibility On*, and the app list under it (default: T3 Code and Slack). |
| **Hybrid hold threshold** | In the Hybrid recording mode, a press shorter than the threshold records hands-free and a longer hold records until release. Stock VoiceInk fixes it at 500 ms; here you choose 200–500 ms (default 300 ms). | Settings → Shortcuts → *Hybrid Hold Threshold* (shown when a shortcut uses Hybrid). |
| **Rewrite pastes nothing when nothing was rewritten** | A take in a mode with the built-in Rewrite prompt pastes only when a selection was captured and the AI returned text. A failed or empty rewrite leaves the selection as it was and shows a notice, instead of pasting the spoken instruction over it. | Automatic. |
| **Screen text only where a mode asks for it** | A mode's *Screen* context switch now decides whether a take reads the front window at all. Stock VoiceInk reads it on every take once Screen Recording is granted, and names from it reach every mode's vocabulary even with the switch off. Turning the switch on asks for Screen Recording. The text is read in the background while you speak, so a take does not start later. | Modes → a mode → Context → *Screen*. |
| **Screen text for Suggest** | Suggest also sends the front window's recognized text, labelled as possibly unrelated, inside its usual context limit. Reading it starts with the press, beside the selection; the request waits for it at most 0.8 s after the press, then goes without it. | Settings → Suggest → *Use Screen Text* (on by default). |
| **Claude effort setting** | For a Claude model that accepts an effort level (Claude Haiku 5.5 among them), every mode's AI enhancement (cleanup, Rewrite) and Suggest can send `effort: low`, so the model can skip thinking. Stock VoiceInk sends no effort, and Claude Haiku 5.5 then thinks at `medium` on every request. Both default to the stock request: in a test, `low` was about twice as fast at the median, but cleanup added words that were not said more often, and Suggest listed other forms of a correct word more often. Other providers, other models and VoiceInk's other AI features are unchanged. | Settings → Suggest → *Claude Effort: Suggest* and *Claude Effort: Modes*: Model default (default), Low, Medium, High. |
| **Fork settings in the backup** | Settings → Backup → Export also saves the Suggest shortcut, the hold threshold, the web accessibility switch and list, the Suggest footer key names, the Suggest screen text switch and both Claude effort settings; Import restores them. Upstream backups still import. | Settings → Backup. |

### Permissions and keys

- **Accessibility** (System Settings → Privacy & Security → Accessibility): Suggest reads the
  selection and pastes; Quick Add reads the selection. VoiceInk already asks for it to paste.
- **Microphone**, as in stock VoiceInk.
- **Screen Recording** (System Settings → Privacy & Security → Screen & System Audio Recording),
  only for screen text. Turning on a mode's *Screen* switch or Suggest's *Use Screen Text* asks for it.
- **An AI provider key**: Suggest uses the AI provider and model of your default mode (Settings →
  AI Models). Keys stay in your Keychain; a backup never contains them.

### What leaves the Mac with screen text

With a mode's *Screen* switch or Suggest's *Use Screen Text* on and Screen Recording granted,
VoiceInk takes a screenshot of the front app's focused window (never VoiceInk's own) and runs
Apple's text recognition on it, on this Mac. The screenshot is not sent or saved. What goes to the
AI provider of that mode, or of the default mode for Suggest, is the recognized **text**, with the
window's title and the app's name, as part of the request. That can include anything readable in
that window: other messages, names, numbers. VoiceInk's history keeps each request it sent,
screen text included, on this Mac. Turn the switches off for modes where that is not wanted.

### Suggest footer key names (optional)

The list's footer names the keys: "1–5 paste · ⌃⌥S more", with your bound Suggest shortcut. If a
keyboard or macro pad sends that shortcut from a key with another name, set the names it should
show (VoiceInk quit or running, no rebuild):

```bash
defaults write com.prakashjoshipax.VoiceInk suggestPickKeyLabel -string "Fn"   # "Fn + 1–5 paste"
defaults write com.prakashjoshipax.VoiceInk suggestMoreKeyLabel -string "F16"  # "F16 more"
```

`defaults delete com.prakashjoshipax.VoiceInk suggestPickKeyLabel` returns to the default.

## Build it yourself

Requirements: those in [BUILDING.md](../BUILDING.md) (macOS 15, Xcode with Swift 6.2, Git).

```bash
git clone --branch edit https://github.com/mikeqwe/VoiceInk-Edit.git
cd VoiceInk-Edit
fork/scripts/build-and-install.sh
```

The script runs four steps; each also works alone:

1. `fork/scripts/make-signing-identity.sh` creates, once, a self-signed code-signing certificate
   in its own keychain under `~/Library/Application Support/VoiceInkForkSigning`.
   `VOICEINK_SIGNING_NAME` and `VOICEINK_SIGNING_DIR` change its name and place.
2. `make local LOCAL_CODESIGN_IDENTITY=-` is upstream's build (ad-hoc signed, to `~/Downloads/VoiceInk.app`).
3. `fork/scripts/sign-app.sh ~/Downloads/VoiceInk.app` re-signs it with your certificate.
4. `fork/scripts/install-app.sh ~/Downloads/VoiceInk.app` quits VoiceInk, moves the installed app
   to the Trash, copies the new one to `/Applications` and launches it.

**Keeping permissions across rebuilds.** macOS ties Accessibility and Microphone grants to the app's
signature. Because every build is signed by the same certificate, the grants stay after a
rebuild. After the first install, or over a build signed differently (such as the official
app), grant both again in System Settings → Privacy & Security and reopen VoiceInk;
`install-app.sh` says when this is needed.

**The provider key prompt.** Each new build asks once to use the AI provider key in your login
keychain. Choose *Always Allow*.

## Files this fork changes

Fork-owned files: `fork/`, `VoiceInk/Features/Suggest/`, `VoiceInk/Features/Recording/Workflows/RewriteDeliveryGate.swift`,
`VoiceInk/Features/Dictionary/QuickAdd/QuickAddPrefill.swift`,
`VoiceInk/Infrastructure/SystemIntegration/Accessibility/WebAccessibilityKeepOn.swift`,
`VoiceInk/Features/Enhancement/Workflows/EditingModelEffort.swift`,
`VoiceInk/Infrastructure/Providers/Enhancement/Chat/AnthropicEffortClient.swift`,
`VoiceInk/Features/Recording/Context/RecordingScreenContext.swift`, and the test
packages `Tests/Suggest`, `Tests/RewriteDeliveryGate` and `Tests/EditingRequest` (`swift test` in each).

Upstream files it touches: `README.md` (this section's link), `VoiceInk/Info.plist`,
`VoiceInk/App/Lifecycle/AppDelegate.swift`, `VoiceInk/App/Updates/UpdaterViewModel.swift`,
`VoiceInk/Features/Dictionary/QuickAdd/DictionaryQuickAddPanel.swift`,
`VoiceInk/Features/Dictionary/Views/AutoLearnSuggestionContent.swift`,
`VoiceInk/Features/Recording/Workflows/TranscriptionPipeline.swift`,
`VoiceInk/Features/Settings/Backup/BackupTypes.swift`, `VoiceInk/Features/Settings/Backup/ImportExportService.swift`,
`VoiceInk/Features/Settings/Backup/BackupImporter.swift`, `VoiceInk/Features/Settings/Views/SettingsView.swift`,
`VoiceInk/Features/Shortcuts/Coordination/RecordingShortcutManager.swift`,
`VoiceInk/Features/Shortcuts/Models/ShortcutAction.swift`, `VoiceInk/Features/Shortcuts/State/ShortcutMigration.swift`,
`VoiceInk/Infrastructure/SystemIntegration/Accessibility/AccessibilityTextReader.swift`,
`VoiceInk/Features/Enhancement/Workflows/AIEnhancementService.swift`,
`VoiceInk/Infrastructure/Providers/Enhancement/Chat/AIChatCompletionService.swift`,
`VoiceInk/Features/Recording/Context/RecordingContextSnapshot.swift`,
`VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift`,
`VoiceInk/Features/Modes/Views/ModeConfigFormView.swift`.
