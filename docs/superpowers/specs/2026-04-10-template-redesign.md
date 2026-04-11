# Template Redesign — Design Spec

## Problem

The current template system is a 4-case Swift enum (`meeting`, `call`, `memo`, `recording`) tied 1:1 to HiDock device recording modes (Mee/Pho/Wip/Rec). These are too coarse — a "Meeting" recording could be a standup, a board meeting, a 1:1, or an interview. Users need more specific templates, and power users want to create their own.

## Solution

Replace the enum with a data-driven template system: 7 built-in templates covering distinct recording scenarios, user-created templates, and a one-shot custom prompt option.

## Built-in Templates

| Template | ID | Description | Key Sections |
|---|---|---|---|
| Meeting/1:1 | `meeting` | Action items, decisions, and next steps | Action Items, Summary, Key Decisions, Next Steps |
| Lecture/Class | `lecture` | Key concepts and takeaways from educational content | Key Concepts, Summary, Questions Raised, Takeaways |
| Interview | `interview` | Q&A pairs, key quotes, and assessment | Q&A Pairs, Key Quotes, Assessment |
| Memo | `memo` | Brief gist of a voice note | Gist |
| Discussion | `discussion` | Topics, perspectives, and notable quotes | Topics, Perspectives, Notable Quotes |
| Consultation | `consultation` | Expert insights, recommendations, and follow-ups | Key Insights, Recommendations, Q&A, Follow-ups |
| Coaching/Counseling | `coaching` | Themes, observations, goals, and plan | Themes, Observations, Goals Discussed, Plan |

### Design Rationale

Templates were selected based on distinct summary structures and user personas:
- Knowledge workers → Meeting/1:1
- Students → Lecture/Class
- Journalists/researchers → Interview
- Consultants/experts, medical/legal visits → Consultation
- Therapists/coaches → Coaching/Counseling
- Multi-person conversations → Discussion
- Quick personal notes → Memo

The slash naming convention (Meeting/1:1, Lecture/Class) helps different user types recognize "their" template without requiring separate templates that produce identical output.

### Device Mode Auto-Selection

| Device mode | Default template |
|---|---|
| Mee (meeting) | Meeting/1:1 |
| Pho (Bluetooth catch) | Consultation |
| Wip (whisper) | Memo |
| Rec (room recording) | Meeting/1:1 |

User can always change the template before summarizing.

## Template Data Model

```swift
struct Template: Codable, Identifiable, Sendable {
    let id: String           // stable ID: "meeting", "lecture", or UUID string for user templates
    var name: String         // display name: "Meeting/1:1"
    var description: String  // one-liner: "Action items, decisions, and next steps"
    var promptText: String   // system prompt sent to LLM (without JSON schema)
    let isBuiltIn: Bool      // determines deletability and reset-to-default
}
```

- Built-in templates use stable string IDs (`"meeting"`, `"lecture"`, etc.)
- User templates use UUID strings as IDs
- The JSON output schema is appended automatically (same as today) — templates only control the prompt text

## User-Created Templates

Users can create, edit, and delete their own templates. Each has a name, one-line description, and prompt text. Created via the Settings > Templates tab.

## One-Shot Custom Prompt

Selecting "Custom prompt..." in the template picker opens a text field for a one-off prompt that is not saved as a template. Same behavior as today's "Custom" option.

## Storage

### File: `~/Documents/HiDock Recordings/.templates.json`

- Array of template objects
- Built-in templates only appear if the user has customized their prompt or description (override-only)
- User templates are always stored
- Loaded by a `TemplateStore` actor at app startup

### Migration from Current System

- Current customizations in UserDefaults (`templatePrompt_meeting`, etc.) are migrated on first launch
- Existing summary `templateUsed` values map: `"call"` → `"consultation"`, `"recording"` → `"meeting"`
- UserDefaults keys cleared after migration

## UI: Template Picker (Summary Tab)

- **Grouped dropdown** (SwiftUI `Picker`): sections for Built-in, My Templates, separator, "Custom prompt..."
- **Description bar** below picker: shows selected template's one-liner with left accent border
- Auto-selects based on device mode; user can change before summarizing
- When re-summarizing, shows which template was originally used

## UI: Settings > Templates Tab

**Split view (master-detail):**

### Left panel — template list
- Two sections: "Built-in" and "My Templates"
- Single selection loads template in editor
- "+" button at bottom creates new user template
- User templates deletable via context menu or Delete key

### Right panel — editor
- **Name** field (read-only for built-in, editable for user)
- **Description** field (editable for all)
- **Prompt** field (monospaced TextEditor, editable for all)
- **Reset to Default** button (built-in only — clears customizations)
- **Delete Template** button (user templates only, with confirmation)

### Changes to AI tab
- Template disclosure groups removed entirely
- AI tab retains: Provider, API Key, Automation
- Auto-summarize default template picker updated to show new full template list

## What Changes in HiDockKit

- `SummaryTemplate` enum replaced by `Template` struct
- New `TemplateStore` actor: loads/saves `.templates.json`, provides built-in defaults, handles migration
- `makeLLMProvider()` and `parseSections()` stay as-is — templates only affect prompt text
- `SummaryTemplate.forMode()` → `TemplateStore.defaultTemplate(forMode:)`
- `SummaryTemplate.promptText(customLookup:)` → `Template.promptText` (direct property, no lookup needed since storage is file-based)
- `SummaryTemplate.systemPrompt(customLookup:)` → builds from `Template.promptText` + JSON schema (same logic, moved to `TemplateStore` or `Template` extension)

## Future Enhancements (Out of Scope)

- Transcription model selection (alternative ASR models)
- Folder-based default templates
- Template import/export
- Template sharing
