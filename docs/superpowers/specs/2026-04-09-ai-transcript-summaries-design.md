# AI Transcript Summaries — Design Spec

## Overview

Add LLM-powered summaries to DockTape recordings. Summaries are generated from
existing transcripts via cloud API (Anthropic, OpenAI, or OpenRouter). The user
provides their own API key. Summaries are mode-adaptive (meeting, call, memo,
recording) with structured sections and checkable action items.

MVP is cloud API only. Local model support (llama.cpp / MLX) is a follow-on.

## Data Model

### Summary (`{basename}.summary.json`)

Stored alongside the MP3 and transcript JSON. Independent lifecycle — re-summarizing
overwrites the summary; re-transcribing doesn't touch it.

```swift
struct Summary: Codable, Sendable, Identifiable {
    var id: String { recordingFilename }
    let recordingFilename: String
    let createdAt: Date
    let model: String              // "claude-sonnet-4-6", "gpt-4o"
    let provider: String           // "anthropic", "openai", "openrouter"
    let templateUsed: String       // "meeting", "call", "memo", "recording", "custom"
    let customPrompt: String?      // Non-nil when templateUsed == "custom"
    let sections: [Section]

    struct Section: Codable, Sendable, Identifiable {
        let id: UUID
        let heading: String        // "Action Items", "Key Decisions", "Summary"
        let content: String        // Markdown-formatted text
        let items: [Item]?         // For list-style sections
    }

    struct Item: Codable, Sendable, Identifiable {
        let id: UUID
        let text: String
        var isCompleted: Bool      // Checkbox state, persisted to disk
    }
}
```

### SummaryStore (actor)

Mirrors `TranscriptStore`. Responsibilities:
- `loadAll()` — scan library directory for `.summary.json` files
- `save(_:mp3Filename:)` — write JSON, update in-memory cache
- `summary(for:)` — query cache by recording filename
- `updateItem(_:inSummary:)` — toggle action item completion, save

## LLM Provider Abstraction

### Protocol

```swift
protocol LLMProvider: Sendable {
    var name: String { get }
    var defaultModel: String { get }
    var availableModels: [String] { get }

    func summarize(
        transcript: String,
        systemPrompt: String,
        model: String
    ) async throws -> String
}
```

### Implementations (all in HiDockKit)

| Provider | API | Auth Header | Base URL |
|----------|-----|-------------|----------|
| `AnthropicProvider` | Messages API | `x-api-key` | `api.anthropic.com/v1/messages` |
| `OpenAIProvider` | Chat Completions | `Bearer` token | `api.openai.com/v1/chat/completions` |
| `OpenRouterProvider` | OpenAI-compatible | `Bearer` token + `HTTP-Referer` | `openrouter.ai/api/v1/chat/completions` |

Each provider is ~80 lines: build request, send via `URLSession`, decode response,
extract text content. No streaming — summarization responses are a few hundred tokens.

### API Key Storage

macOS Keychain via `Security.framework`. A small `KeychainHelper` utility with
`save(key:service:account:)`, `read(service:account:)`, `delete(service:account:)`.
No third-party keychain wrapper.

### Model Selection

Each provider exposes a curated static list of recommended models. User picks in
Settings. OpenRouter could fetch from their `/models` endpoint in a future iteration.

## Prompt Templates

### Template Enum

```swift
enum SummaryTemplate: String, Codable, CaseIterable {
    case meeting    // Mee mode recordings
    case call       // Pho mode recordings
    case memo       // Wip mode recordings
    case recording  // Rec mode (general)
    case custom     // User-provided prompt
}
```

### Auto-detection

Recording `mode` field maps to template:
- `Mee` -> `.meeting`
- `Pho` -> `.call`
- `Wip` -> `.memo`
- `Rec` -> `.recording`

User can override before generating.

### Default Sections by Mode

| Mode | Sections |
|------|----------|
| Meeting | Action Items, Summary, Key Decisions, Next Steps |
| Call | Action Items, Synopsis, Commitments, Follow-ups |
| Memo | Gist (1-2 sentences) |
| Recording | Summary, Key Points |

Action Items are always the first section (when present) for scannability.

### Prompt Structure

Each template has a system prompt that:
1. Describes the recording context (mode, speakers, duration)
2. Specifies the JSON output schema matching `Summary.Section` / `Summary.Item`
3. Tailors section headings and depth to the recording type

Custom prompt: user writes free-text; the system wraps it with the JSON output
schema instruction so parsing still works. The custom prompt text is stored in
the `Summary` as an additional `customPrompt: String?` field so re-summarizing
can reuse it.

### Transcript Preparation

- Use `Transcript.plainText(includeSpeakers: true)` as input
- For most recordings under 2 hours, full text fits in 100k+ context windows
- For longer recordings: truncate with a note. Progressive chunked summarization
  is a future enhancement.

### Fallback

If the LLM returns malformed JSON, store the raw text as a single "Summary"
section. The user still sees something useful.

## State Management

### SummarizationState

New sub-object on `AppState`, following the `TranscriptionState` pattern:

```swift
@Observable @MainActor
class SummarizationState {
    var summarizingFile: String?
    var phase: String = ""
    var queue: [RecordingMetadata] = []
    var queueIndex: Int = 0
    var summaryStore: SummaryStore

    func summarize(recordings:template:provider:...) async
    func cancel()
}
```

### Flow

1. User clicks "Summarize" -> `AppState.summarizeRecordings(_)`
2. `SummarizationState` loads transcript via `TranscriptStore`
3. Picks template based on recording mode (or user override)
4. Calls `provider.summarize(transcript:systemPrompt:model:)`
5. Parses JSON response into `Summary`; falls back to raw text on failure
6. `SummaryStore.save()` writes `.summary.json` to disk
7. UI refreshes — Summary tab shows result

### Auto-summarize

After `TranscriptionState` completes its `onComplete` callback, `AppState` checks
the auto-summarize setting. If enabled and API key is configured, queues summaries
for newly transcribed recordings.

## UI

### Detail Pane — Summary Tab

Third tab alongside Info and Transcript.

**No summary yet:**
- Template picker dropdown (auto-selected from recording mode)
- "Summarize" button
- If no API key configured, button triggers first-use setup flow

**Summary exists:**
- Sections rendered with headings and markdown content
- Action items with checkable checkboxes (state persists to disk)
- Caption showing model, provider, and timestamp
- "Re-summarize" button in header

**In progress:**
- Spinner with phase text ("Summarizing with Claude Sonnet 4.6...")

### Recording Context Menu

Add "Summarize" below the existing "Transcribe" action in `RecordingListPane`.
Disabled if no transcript exists. Works with batch multi-select.

### Settings — AI Tab

Fourth tab in SettingsView:
- **Provider picker:** Anthropic / OpenAI / OpenRouter
- **API key:** SecureField, stored in Keychain. "Verify" button sends a
  minimal request (e.g., Anthropic: 1-token message; OpenAI: list models;
  OpenRouter: `/auth/key` endpoint) to confirm the key is valid.
- **Model picker:** Populated from selected provider's `availableModels`
- **Auto-summarize toggle:** "Automatically summarize after transcription"
  (default off)
- **Default template:** Which template to use for auto-summarize

### First-Use Flow

When user clicks "Summarize" with no API key configured, show an inline prompt
(not a sheet) in the Summary tab: provider picker, API key field, verify button.
Once verified, proceed with summarization. Settings tab available for later changes.

## Architecture Summary

```
HiDockKit/
  Summarization/
    Summary.swift              — data model
    SummaryStore.swift         — actor, disk I/O + cache
    SummaryTemplate.swift      — template enum + prompt strings
    LLMProvider.swift          — protocol
    AnthropicProvider.swift    — ~80 lines
    OpenAIProvider.swift       — ~80 lines
    OpenRouterProvider.swift   — ~80 lines
    KeychainHelper.swift       — read/write/delete Keychain strings

DockTape/
  State/
    SummarizationState.swift   — @Observable, queue, progress
  Views/
    SummaryTabView.swift       — Summary tab in DetailPane
    AISettingsView.swift       — Settings > AI tab
```

## Out of Scope (Future)

- Local model inference (llama.cpp / MLX) — second provider backend
- Cross-recording action item aggregation view
- Integration with Reminders, Things, Todoist, Calendar
- Progressive summarization for very long recordings
- Translation of summaries
- Smart labels / auto-categorization
- Fetching OpenRouter model list from API
