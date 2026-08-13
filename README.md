# wmp-ไทย

Fixes text typed with the wrong keyboard layout on macOS, between Thai and English.

Type `l;ylfu` when you meant `สวัสดี` and it becomes `สวัสดี`, with the keyboard
switched to Thai so the rest of the word lands correctly. Nothing to press.

Requires macOS 26 on Apple Silicon, plus a Thai and a Latin input source.

## What it does

- Corrects mid-word, usually within 3 to 5 keystrokes
- Corrects when you pause typing, with the delay adjustable from 150 to 2000 ms
- Corrects on the space bar for anything the first two moments were unsure about
- Switches the input source after a fix, so typing continues in the right language
- Converts a selection on demand, including text you never typed yourself
- Undoes a correction and remembers the word, so it is not corrected again
- Runs in one direction only, if you only ever forget one of the two switches

Every one of these can be turned off.

## How it decides

The keyboard tap is listen-only. It cannot swallow or delay a keystroke even if
the app stalls, so typing stays exactly as responsive as it was.

Words are held as the keys that were pressed rather than the characters that
appeared, so re-rendering them through the other layout is exact rather than a
guess. The layout tables come from the system through `TISInputSource` and
`UCKeyTranslate`, so any installed pair works, including Pattachote.

Both readings are then scored, and a correction happens only when one wins
clearly. Ambiguous pairs are left alone: typing `ok` on the Thai layout gives
`นา`, a real Thai word, so nothing happens.

Thai is judged on spelling rules first. English typed on the Thai layout usually
breaks one within a character or two, since `hello` lands as `้ำสสน`, which opens
with a tone mark that cannot start a word. Word lists and ICU segmentation
follow. English is judged against the system dictionary, the spell checker, and a
list of words people actually type, since a full dictionary contains plenty of
words nobody ever types.

A word in neither list can still be corrected when what was typed is unreadable
in the language it landed in and the other reading is not. That is what catches
names, brands and slang: `emma`, `github`, `kubernetes`, `จุงเบย`.

## Shortcuts

| Key | Action |
|---|---|
| ⌃⌥Z | Undo the last correction and remember the word |
| ⌃⌥L | Convert the selection, or the last word if nothing is selected |

A mixed selection is judged word by word, so the half that was already right
survives.

## Where it stays out

- Secure input fields, which it cannot read at all
- Password fields on the web, recognised through the accessibility subrole
- Fields labelled as email, username or password, in either language
- Sites on the excluded list, matched on host including subdomains
- Apps on the excluded list

## What it stores

- Nothing typed is written to disk, except words you undo a correction on
- Correction history stays in memory and is lost when the app quits
- Nothing leaves the machine, apart from a version check against GitHub

## Word lists

Built on first launch from what is already installed on the machine, in about
half a minute, and kept in Application Support. A small curated list ships with
the app for words the machine cannot know about, and anything you add yourself
sits alongside both.

Reading the system Thai dictionary is offered as an option and is off by
default. It needs an undocumented format holding licensed content, and measuring
says it barely helps: roughly 5,000 words is where accuracy stops improving, and
the lists built from UI text already pass that.

## Installing

Download the latest zip from [Releases](https://github.com/suparattanatree/wmp-thai/releases),
unpack it, move the app to /Applications and open it. Grant Accessibility access
in System Settings under Privacy & Security; the app starts working the moment
permission is given, without a relaunch.

The build is not notarized yet, so macOS refuses the first launch. Open System
Settings, go to Privacy & Security, and press Open Anyway near the bottom. This
is needed once; Control-clicking the app no longer bypasses this on macOS 15 and
later.

Updates are checked quietly and shown in the settings window, never as a popup.
Pressing the button downloads and installs through Sparkle, with each update
verified against a signing key before it is applied.

## Building

```bash
./build_app.sh
```

`build_app.sh` signs with whatever certificate is on the machine. A real
certificate keeps the app's identity stable, which is what lets macOS keep the
Accessibility permission across rebuilds.

`./release.sh <version>` builds, packages, signs the update, publishes it to
GitHub Releases and updates the appcast the app reads.

## Development

```bash
swift run wmp --selftest              # the full test suite
swift run wmp --typo "สวัสดี github"   # simulate typing it on the wrong layout
swift run wmp --try "l;ylfu8iy["      # verdicts for text already mistyped
swift run wmp --probe                 # what it can see about the focused field
swift run wmp --preview               # settings window only, no keyboard tap
swift run wmp --sweep                 # measure how large the word list must be
```

The test suite replays wrong-layout typing keystroke by keystroke, and types
several thousand correctly spelled words to count how often the tool would have
interfered. That number should stay at zero.

## License

MIT. See [LICENSE](LICENSE).

## Support

If this is useful to you: https://ko-fi.com/memorist
