// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class TranscriptTests: XCTestCase {

    func testTranscriptPlainText() {
        let transcript = Transcript(
            recordingFilename: "2026Mar30-172146-Rec00.hda",
            transcriptionModel: "test",
            hasSpeakerLabels: true,
            segments: [
                .init(startTime: 0, endTime: 5, text: "Hello, good morning.", speakerID: "S1"),
                .init(startTime: 5, endTime: 10, text: "Good morning. Let's begin.", speakerID: "S2"),
                .init(startTime: 10, endTime: 15, text: "Sure, let me pull up the numbers.", speakerID: "S1"),
            ],
            speakerNames: ["S1": "Analyst", "S2": "CEO"]
        )

        let text = transcript.plainText()
        XCTAssertTrue(text.contains("[Analyst] Hello, good morning."))
        XCTAssertTrue(text.contains("[CEO] Good morning. Let's begin."))
    }

    func testSpeakerIDs() {
        let transcript = Transcript(
            recordingFilename: "test.hda",
            transcriptionModel: "test",
            hasSpeakerLabels: true,
            segments: [
                .init(startTime: 0, endTime: 5, text: "A", speakerID: "S1"),
                .init(startTime: 5, endTime: 10, text: "B", speakerID: "S2"),
                .init(startTime: 10, endTime: 15, text: "C", speakerID: "S1"),
            ]
        )

        XCTAssertEqual(transcript.speakerIDs, ["S1", "S2"])
        XCTAssertEqual(transcript.segments(for: "S1").count, 2)
        XCTAssertEqual(transcript.segments(for: "S2").count, 1)
    }

    func testTotalDuration() {
        let transcript = Transcript(
            recordingFilename: "test.hda",
            transcriptionModel: "test",
            hasSpeakerLabels: false,
            segments: [
                .init(startTime: 0, endTime: 30, text: "First"),
                .init(startTime: 30, endTime: 90, text: "Last"),
            ]
        )

        XCTAssertEqual(transcript.totalDuration, 90)
    }

    func testMergeSpeakers() {
        let transcription: [Transcript.Segment] = [
            .init(startTime: 0, endTime: 5, text: "Hello."),
            .init(startTime: 5, endTime: 10, text: "Hi there."),
            .init(startTime: 10, endTime: 15, text: "Let's discuss."),
        ]

        let diarization: [SpeakerSegment] = [
            SpeakerSegment(speakerID: "Speaker 1", startTime: 0, endTime: 7),
            SpeakerSegment(speakerID: "Speaker 2", startTime: 7, endTime: 15),
        ]

        let merged = TranscriptionPipeline.mergeSpeakersAtWordLevel(
            transcription: transcription,
            diarization: diarization
        )

        // Speaker 1 gets "Hello." (midpoint 2.5 -> S1)
        // Speaker 2 gets "Hi there." and "Let's discuss." merged into one turn
        XCTAssertEqual(merged[0].speakerID, "Speaker 1")
        XCTAssertEqual(merged[0].text, "Hello.")
        XCTAssertEqual(merged[1].speakerID, "Speaker 2")
        // S2 segments merged into a single turn, then split at sentence boundaries
        XCTAssertTrue(merged.filter { $0.speakerID == "Speaker 2" }.count >= 1)
    }
}
