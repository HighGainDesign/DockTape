// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

/// Library/recording-owned editor state survives transient content-view reloads.
@Observable @MainActor final class TranscriptSpeakerDraft {
    var names: [String: String] = [:]
    var editingSpeaker: String?
    var editText = ""
    var filterSpeaker: String?
    struct MergeConfirmation: Identifiable {
        let id = UUID()
        let sourceSID: String
        let targetSID: String
        let name: String
    }
    var mergeConfirmation: MergeConfirmation?
    private var baseline: [String: String] = [:]
    private enum Generation: Equatable {
        case shared(UUID)
        case legacy(Date, String, [UUID], [String?])
    }
    private var generation: Generation?
    var hasChanges: Bool { names != baseline }

    func synchronize(with transcript: Transcript) {
        let incoming = transcript.sharedGenerationID.map(Generation.shared)
            ?? .legacy(transcript.createdAt, transcript.transcriptionModel, transcript.segments.map(\.id), transcript.segments.map(\.speakerID))
        if let generation, generation != incoming {
            names = [:]; baseline = [:]; editingSpeaker = nil; editText = ""
            filterSpeaker = nil; mergeConfirmation = nil
        }
        generation = incoming
        let speakers = Set(transcript.speakerIDs)
        var current = transcript.speakerNames
        for (speaker, name) in names where name != baseline[speaker] && speakers.contains(speaker) {
            current[speaker] = name
        }
        names = current
        baseline = transcript.speakerNames
        if let editingSpeaker, !speakers.contains(editingSpeaker) {
            self.editingSpeaker = nil; editText = ""
        }
        if let filterSpeaker, !speakers.contains(filterSpeaker) { self.filterSpeaker = nil }
        if let mergeConfirmation,
           !speakers.contains(mergeConfirmation.sourceSID) || !speakers.contains(mergeConfirmation.targetSID) {
            self.mergeConfirmation = nil
        }
    }
}
