# DockTape changelog

## 1.2.0

### Added

- New cassette app icon with default, dark, clear, and tinted appearances, plus fallback images for older macOS versions.

- iCloud Drive storage is now the default. Settings also offers local storage or a custom folder. Existing local recordings remain in place, with a prompt explaining how to move them or keep using local storage.
- Merge multiple recordings into one, with the option to keep the originals and generate a fresh transcript and summary.
- Export transcripts from the app as Markdown, plain text, SRT, JSONL, or JSON.
- Progress indicators for imports, transcription, and summaries.
- Summarize a recording directly: DockTape transcribes it first when needed. An optional setting generates summaries after transcription.
- AI and device preferences can sync through iCloud. Provider API keys remain in each Mac's Keychain.

### Improved

- Cloud-only audio, transcripts, and summaries show download/loading status and recoverable errors. Waiting for one iCloud file no longer stalls another recording; late results cannot replace the newly selected content.

- Cloud-only iCloud recordings and their transcript/summary sidecars remain visible, including hidden placeholder files.
- Transcripts and summaries load on demand for faster startup.
- Summary prompts use the recording mode to provide speaker context. Voice memos skip unnecessary speaker diarization.
- Renaming preserves recording dates, modes, folders, transcripts, and summaries. Moving recordings into folders updates their transcript and summary status.
- Merged audio plays and transcribes across every source recording, with corrected duration metadata and the earliest recording date.
- Command-F focuses toolbar search, and each transcript export keeps its correct file extension.
- Transcript metadata and controls remain readable in narrow detail panes.
- Cancelling or failing re-transcription preserves the existing transcript and restores queued recording statuses. Cancelling a summary preserves the previous summary and allows a new request afterward.
- Device busy guards prevent conflicting operations through the app, with useful error messages explaining why an operation failed.
- P1 battery voltage displays in volts with the correct firmware units.
- Selecting another recording no longer replaces the playing recording's transcript timestamps or highlights the wrong transcript.
- The vendored USB library now targets the app's macOS 14 minimum. Release builds preserve full diagnostic logs and verify signing strictly.
- The shared core has initial iOS support; an iOS app is still in development.

### Known issues

- A blank recording list has been reported on first launch with an iCloud library. Use Refresh if this occurs; investigation continues in [issue #30](https://github.com/HighGainDesign/DockTape/issues/30).
- iCloud conflict handling remains limited when multiple Macs edit the same sidecar files simultaneously.
- Recording-list durations are estimates. The playback bar uses the measured audio duration.
