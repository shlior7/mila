# Mila on iPad

`MilaPad/` is a small iPad (and iPhone) app: record from the mic or import an
audio file, transcribe on the device with whisper.cpp, read the transcript,
and sync recordings with Mila on the Mac. It needs iPadOS 17 — an iPad Air 4
(A14, 4 GB) runs it.

What it does not do, and why:

- **No speaker labels.** The Mac diarizes with a Python subprocess; iOS has no
  subprocesses. Synced Mac recordings keep their speaker names.
- **No meeting capture.** iOS does not let an app record other apps' audio.
- **No summaries, MCP, Sparkle, calendar naming.** Mac-only; a Mac
  recording's summary is shown when it syncs over.

## Install (free Apple ID)

1. Xcode → Settings → Platforms: install iOS (or `xcodebuild -downloadPlatform iOS`).
2. Xcode → Settings → Accounts: add your Apple ID. Note its team id.
3. `MILA_PAD_TEAM=<team id> xcodegen generate`, open `Mila.xcodeproj`, pick the
   **MilaPad** scheme and your iPad (cable, Developer Mode on in
   Settings → Privacy & Security), Run.
4. On the iPad: Settings → General → VPN & Device Management → trust your
   Apple ID.

Free-account builds expire after 7 days: run it from Xcode again. Your
recordings stay; only the app's signature lapses.

## Models

Settings → Model downloads one from HuggingFace, SHA-256 pinned
(`PadModels.swift`):

- **Whisper large-v3-turbo q5** (574 MB) — default; English and Hebrew.
- **ivrit.ai large-v3-turbo** (1.6 GB) — best Hebrew, but tight on a 4 GB
  iPad; if Mila quits mid-transcription, go back to the q5 model.

Keep Mila open while it transcribes — iOS stops GPU work in the background.
Recording itself keeps going with the screen locked.

## Sync with the Mac

There is no server and no iCloud entitlement (a free Apple ID can't have
one): the two apps share a plain folder in iCloud Drive and use the Mac's
existing shared-folder sync (`SharedFolderSync`), one `<id>.milashare` per
recording.

1. Mac: create a folder in Mila's sidebar (e.g. "iPad"), right-click →
   **Share with Team…**, choose a new folder in iCloud Drive (e.g.
   `iCloud Drive/Mila Sync`).
2. iPad: Settings → **Choose Folder…** → the same folder.

Then:

- iPad recordings, once transcribed, appear on the Mac in that folder,
  attributed to the iPad's device name.
- Mac recordings in that folder appear on the iPad.
- Edits stay with the author: rename on the iPad re-publishes; edits to a
  Mac recording on the iPad aren't possible, and the Mac's edits sync over.
- Deleting a recording on either side removes your copy only; it isn't
  re-imported.

The iPad reads and writes bundles with MilaKit's `ShareBundle` / `ShareZip`
(no `ditto` on iOS). `ShareBundleCompatibilityTests` in MilaTests pins that
the Mac imports what the iPad writes and vice versa.
