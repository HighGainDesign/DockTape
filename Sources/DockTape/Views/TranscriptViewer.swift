import SwiftUI
import HiDockKit

struct TranscriptViewer: View {
    let transcript: Transcript
    var playbackState: PlaybackState?
    var activeSegmentIndex: Int? = nil
    var onSeek: ((TimeInterval) -> Void)?
    var onSaveSpeakerNames: (([String: String]) -> Void)?
    var onSplitSpeaker: ((_ segmentID: UUID, _ allFollowing: Bool) -> Void)?
    var onMergeSpeaker: ((_ sourceSID: String, _ targetSID: String) -> Void)?

    @State private var filterSpeaker: String? = nil
    @State private var speakerNames: [String: String] = [:]
    @State private var editingSpeaker: String? = nil
    @State private var editText: String = ""
    @State private var mergeConfirmation: MergeConfirmation? = nil
    @FocusState private var editFieldFocused: Bool

    private struct MergeConfirmation: Identifiable {
        let id = UUID()
        let sourceSID: String
        let targetSID: String
        let name: String
    }

    private var hasNameChanges: Bool {
        speakerNames != transcript.speakerNames
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Label(DurationCalculator.formatDuration(transcript.totalDuration), systemImage: "clock")
                        Label("\(transcript.segments.count) segments", systemImage: "text.alignleft")
                        Label("\(transcript.speakerIDs.count) speakers", systemImage: "person.2")
                        if let lang = transcript.language {
                            Label(lang, systemImage: "globe")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                // Speaker filter
                if transcript.speakerIDs.count > 1 {
                    Picker("Speaker", selection: $filterSpeaker) {
                        Text("All Speakers").tag(String?.none)
                        Divider()
                        ForEach(transcript.speakerIDs, id: \.self) { sid in
                            Text(speakerNames[sid] ?? sid).tag(Optional(sid))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if hasNameChanges {
                    Button("Save Names") {
                        onSaveSpeakerNames?(speakerNames)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding()

            // Speaker name editor
            if !transcript.speakerIDs.isEmpty {
                Divider()
                speakerNamesEditor
            }

            Divider()

            // Transcript content with auto-scroll
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let currentActive = playbackState?.activeSegmentIndex ?? activeSegmentIndex
                        ForEach(Array(filteredSegments.enumerated()), id: \.element.id) { index, segment in
                            let globalIndex = transcript.segments.firstIndex(where: { $0.id == segment.id })
                            let isActive = globalIndex != nil && globalIndex == currentActive

                            SegmentRow(
                                segment: segment,
                                speakerNames: speakerNames,
                                isActive: isActive,
                                onSeek: onSeek,
                                onTapSpeaker: { sid in
                                    editingSpeaker = sid
                                    editText = speakerNames[sid] ?? sid
                                },
                                onSplitSpeaker: onSplitSpeaker,
                                onMergeSpeaker: onMergeSpeaker,
                                allSpeakerIDs: transcript.speakerIDs
                            )
                            .id(segment.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: playbackState?.activeSegmentIndex ?? activeSegmentIndex) { _, newIndex in
                    guard let newIndex, newIndex < transcript.segments.count else { return }
                    let segmentID = transcript.segments[newIndex].id
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(segmentID, anchor: .center)
                    }
                }
            }
        }
        .onAppear {
            speakerNames = transcript.speakerNames
            for sid in transcript.speakerIDs where speakerNames[sid] == nil {
                speakerNames[sid] = sid
            }
        }
        .onChange(of: transcript.speakerNames) { _, newNames in
            speakerNames = newNames
            for sid in transcript.speakerIDs where speakerNames[sid] == nil {
                speakerNames[sid] = sid
            }
        }
        .alert("Merge Speakers?", isPresented: Binding(
            get: { mergeConfirmation != nil },
            set: { if !$0 { mergeConfirmation = nil } }
        )) {
            Button("Merge") {
                if let merge = mergeConfirmation {
                    speakerNames[merge.sourceSID] = merge.name
                    onSaveSpeakerNames?(speakerNames)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let merge = mergeConfirmation {
                Text("\"\(merge.name)\" is already used by another speaker. Merge their segments together?")
            }
        }
    }

    // MARK: - Speaker Names Editor

    private var speakerNamesEditor: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(transcript.speakerIDs, id: \.self) { sid in
                speakerChip(sid: sid)
            }

            Spacer()

            if hasNameChanges {
                Text("Names changed")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder
    private func speakerChip(sid: String) -> some View {
        let displayName = speakerNames[sid] ?? sid

        if editingSpeaker == sid {
            HStack(spacing: 4) {
                Circle()
                    .fill(speakerColor(sid))
                    .frame(width: 8, height: 8)
                TextField("Speaker name", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .frame(width: 150)
                    .focused($editFieldFocused)
                    .onSubmit { commitEdit(sid: sid) }
                    .onAppear { editFieldFocused = true }
                Button {
                    commitEdit(sid: sid)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save speaker name")
                Button {
                    editingSpeaker = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel rename")
            }
        } else {
            Button {
                editingSpeaker = sid
                editText = displayName
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(speakerColor(sid))
                        .frame(width: 8, height: 8)
                    Text(displayName)
                        .font(.caption.weight(.medium))
                    Image(systemName: "pencil")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(speakerColor(sid).opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Click to rename speaker")
        }
    }

    // MARK: - Helpers

    private func commitEdit(sid: String) {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            editingSpeaker = nil
            return
        }
        if let existingID = speakerNames.first(where: { $0.key != sid && $0.value == trimmed })?.key {
            editingSpeaker = nil
            mergeConfirmation = MergeConfirmation(sourceSID: sid, targetSID: existingID, name: trimmed)
            return
        }
        speakerNames[sid] = trimmed
        editingSpeaker = nil
    }

    private var filteredSegments: [Transcript.Segment] {
        if let speaker = filterSpeaker {
            return transcript.segments.filter { $0.speakerID == speaker }
        }
        return transcript.segments
    }

    private func copyToClipboard() {
        var copy = transcript
        copy.speakerNames = speakerNames
        let text = copy.plainText(includeSpeakers: true)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

// MARK: - Speaker Color

private func speakerColor(_ sid: String) -> Color {
    let colors: [Color] = [.blue, .green, .purple, .orange, .pink, .cyan]
    let hash = abs(sid.utf8.reduce(0) { ($0 &* 31) &+ Int($1) })
    return colors[hash % colors.count]
}

// MARK: - Segment Row

private struct SegmentRow: View {
    let segment: Transcript.Segment
    let speakerNames: [String: String]
    var isActive: Bool = false
    var onSeek: ((TimeInterval) -> Void)?
    var onTapSpeaker: ((String) -> Void)?
    var onSplitSpeaker: ((_ segmentID: UUID, _ allFollowing: Bool) -> Void)?
    var onMergeSpeaker: ((_ sourceSID: String, _ targetSID: String) -> Void)?
    var allSpeakerIDs: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Active segment indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .padding(.trailing, 8)

            // Timestamp
            Text(formatTime(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(onSeek != nil ? Color.accentColor : Color.secondary)
                .frame(width: 60, alignment: .trailing)

            Spacer().frame(width: 12)

            // Speaker label
            if let sid = segment.speakerID {
                Button {
                    onTapSpeaker?(sid)
                } label: {
                    Text(speakerNames[sid] ?? sid)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(speakerColor(sid))
                }
                .buttonStyle(.plain)
                .frame(width: 80, alignment: .leading)
                .help("Click to rename speaker")
            }

            // Text
            Text(segment.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSeek?(segment.startTime)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contextMenu {
            segmentContextMenu
        }
    }

    @ViewBuilder
    private var segmentContextMenu: some View {
        if let sid = segment.speakerID {
            Button("Split Speaker From Here") {
                onSplitSpeaker?(segment.id, false)
            }
            Button("Split Speaker From Here to End") {
                onSplitSpeaker?(segment.id, true)
            }

            if allSpeakerIDs.count > 1 {
                Divider()
                Menu("Merge Into...") {
                    ForEach(allSpeakerIDs.filter { $0 != sid }, id: \.self) { targetSID in
                        Button(speakerNames[targetSID] ?? targetSID) {
                            onMergeSpeaker?(sid, targetSID)
                        }
                    }
                }
            }
        }

        Divider()

        if onSeek != nil {
            Button("Play From Here") {
                onSeek?(segment.startTime)
            }
        }

        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.text, forType: .string)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

}
