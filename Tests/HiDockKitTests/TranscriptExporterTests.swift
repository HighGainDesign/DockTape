import XCTest
@testable import HiDockKit

final class TranscriptExporterTests: XCTestCase {

    private func sampleTranscript() -> Transcript {
        Transcript(
            recordingFilename: "2026Mar30-172146-Rec00.hda",
            transcriptionModel: "parakeet-tdt-1.0",
            hasSpeakerLabels: true,
            segments: [
                .init(startTime: 0, endTime: 10, text: "Let me start with the Q4 numbers.", speakerID: "S1"),
                .init(startTime: 10, endTime: 20, text: "Revenue was up 15% year over year.", speakerID: "S1"),
                .init(startTime: 20, endTime: 35, text: "That's impressive. What drove the growth?", speakerID: "S2"),
                .init(startTime: 35, endTime: 50, text: "Primarily the enterprise segment.", speakerID: "S1"),
            ],
            speakerNames: ["S1": "Analyst", "S2": "Portfolio Manager"]
        )
    }

    func testChunking() {
        let transcript = sampleTranscript()
        let chunks = TranscriptExporter.chunkTranscript(
            transcript: transcript, recordingMetadata: nil, maxChunkChars: 5000
        )

        // S1 speaks segments 0,1 consecutively, then S2, then S1 again = 3 chunks
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].speaker, "Analyst")
        XCTAssertTrue(chunks[0].text.contains("Q4 numbers"))
        XCTAssertTrue(chunks[0].text.contains("Revenue"))
        XCTAssertEqual(chunks[1].speaker, "Portfolio Manager")
        XCTAssertEqual(chunks[2].speaker, "Analyst")
    }

    func testChunkIDs() {
        let transcript = sampleTranscript()
        let chunks = TranscriptExporter.chunkTranscript(
            transcript: transcript, recordingMetadata: nil, maxChunkChars: 5000
        )

        XCTAssertEqual(chunks[0].id, "2026Mar30-172146-Rec00_chunk0")
        XCTAssertEqual(chunks[0].chunkIndex, 0)
        XCTAssertEqual(chunks[0].totalChunks, 3)
        XCTAssertEqual(chunks[0].mode, "Rec")
    }

    func testChunkSplitsLongText() {
        var segments: [Transcript.Segment] = []
        // Create a single speaker with lots of text
        for i in 0..<20 {
            let t = Double(i) * 5
            segments.append(.init(startTime: t, endTime: t + 5,
                text: "This is segment number \(i) with enough text to fill up space.", speakerID: "S1"))
        }

        let transcript = Transcript(
            recordingFilename: "test.hda",
            transcriptionModel: "test",
            hasSpeakerLabels: true,
            segments: segments,
            speakerNames: ["S1": "Speaker"]
        )

        let chunks = TranscriptExporter.chunkTranscript(
            transcript: transcript, recordingMetadata: nil, maxChunkChars: 200
        )

        // Should split into multiple chunks
        XCTAssertGreaterThan(chunks.count, 1)
        // Each chunk should be under the limit
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 250) // some slack for last segment
        }
    }

    func testJSONLinesExport() {
        let transcript = sampleTranscript()
        let data = TranscriptExporter.exportJSONLines(transcript: transcript)
        let text = String(data: data, encoding: .utf8)!
        let lines = text.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3) // 3 chunks
        // Each line should be valid JSON
        for line in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testPlainTextExport() {
        let transcript = sampleTranscript()
        let text = TranscriptExporter.exportPlainText(transcript: transcript)

        XCTAssertTrue(text.contains("Analyst:"))
        XCTAssertTrue(text.contains("Portfolio Manager:"))
        XCTAssertTrue(text.contains("Q4 numbers"))
    }

    func testSRTExport() {
        let transcript = sampleTranscript()
        let srt = TranscriptExporter.exportSRT(transcript: transcript)

        XCTAssertTrue(srt.contains("1\n"))
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:10,000"))
        XCTAssertTrue(srt.contains("[Analyst]"))
    }
}
