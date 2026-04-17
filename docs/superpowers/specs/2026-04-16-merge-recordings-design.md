# Merge Recordings

**Date:** 2026-04-16
**Status:** Approved

## Goal

Allow users to merge multiple recordings into a single MP3 file, then re-transcribe and summarize the combined result.

## Use cases

1. HiDock splits long recordings into multiple files (Part 1, Part 2) — merge them back.
2. Multiple whisper memos about the same topic — stitch into one coherent recording.

## UX Flow

1. Select 2+ recordings in the library list
2. Right-click → "Merge Selected Recordings..." (also in Edit menu)
3. Recordings sorted chronologically. User can reorder via drag.
4. MP3 files concatenated (byte append, no re-encoding)
5. Rename dialog for the merged file
6. Prompt: "Delete original recordings?" → Keep / Delete
7. Merged recording appears in library. No auto-transcribe.

## Implementation

### MP3 concatenation

MP3 frames are self-contained. Concatenation = appending raw bytes in order. Valid MP3 output.

`RecordingStore.mergeRecordings(filenames: [String], as newFilename: String) throws -> RecordingMetadata`

### Metadata

- `library.json`: merged entry has mode from first file, `deviceFilename: null`, new `mergedFrom: [String]` array
- `RecordingMetadata`: `recordedAt` = earliest date, `mode` = first file's mode

### Sidecar handling

- If user deletes originals: their sidecars (.transcript.json, .summary.json, .txt) are cleaned up
- No transcript/summary for the merged file until user triggers them

### UI entry points

- Context menu in `RecordingListPane`: "Merge Selected Recordings..." (2+ selected)
- Menu bar: Edit → Merge Selected Recordings...
- NOT in toolbar (too niche)

### Architecture

- `RecordingStore.mergeRecordings(filenames:as:)` — MP3 concatenation + library.json update
- `AppState.mergeSelectedRecordings()` — orchestrates merge, shows rename sheet, delete prompt
- Context menu item + menu bar item
