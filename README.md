# Gap Vocab for iPhone

A small native wrapper around your Gap Vocab site. It shows the site as normal, but answers
are typed into a native box that **switches between your Japanese and English keyboards
automatically** (Japanese for readings and recall, English for meanings).

Everything else (lessons, reviews, settings, progress) is still the website, so updates to the
server show up immediately without rebuilding this app.

## Files

- `Sources/GapVocabApp.swift` – app entry point and the first-run "server address" screen
- `Sources/BridgeViewController.swift` – web view + native answer bar + keyboard switching
- `project.yml` – project description (XcodeGen builds the Xcode project from it in the cloud)
- `.github/workflows/build.yml` – builds `GapVocab.ipa` on GitHub's cloud Macs

## Keyboard tip

The app picks the **first** Japanese keyboard in your list. If you have both Kana and Romaji,
put the one you want at the top: Settings → General → Keyboard → Keyboards → Edit.
