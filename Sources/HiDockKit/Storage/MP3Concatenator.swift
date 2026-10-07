// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Concatenates encoded audio frames and replaces per-file duration metadata.
/// Audio is never decoded or re-encoded.
struct MP3Concatenator {
    private var audio = Data()
    private var frameCount = 0
    private var firstHeader: Header?
    private var uniformClock = true

    mutating func append(_ recording: Data) throws {
        let scan = try recording.withUnsafeBytes { bytes -> Scan in
            var ranges: [Range<Int>] = []
            var first: Header?
            var sameClock = true
            var offset = 0
            while offset + 4 <= bytes.count {
                if matches("ID3", in: bytes, at: offset), offset + 10 <= bytes.count {
                    let sizeBytes = (6...9).map { bytes[offset + $0] }
                    guard sizeBytes.allSatisfy({ $0 < 128 }) else {
                        throw HiDockError.conversionFailed("Invalid MP3 ID3 tag")
                    }
                    let size = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
                    guard size <= bytes.count - offset - 10 else {
                        throw HiDockError.conversionFailed("Truncated MP3 ID3 tag")
                    }
                    offset += 10 + size
                    continue
                }
                if bytes.count - offset == 128, matches("TAG", in: bytes, at: offset) {
                    break
                }
                let raw = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
                guard let header = Header(raw) else {
                    offset += 1
                    continue
                }
                guard header.length <= bytes.count - offset else {
                    throw HiDockError.conversionFailed("Truncated MP3 audio frame")
                }
                let tag = offset + header.xingOffset
                let unprotectedTag = tag - (header.raw & 0x0001_0000 == 0 ? 2 : 0)
                let metadata = (header.xingOffset + 4 <= header.length
                    && (matches("Xing", in: bytes, at: tag) || matches("Info", in: bytes, at: tag)))
                    || (unprotectedTag + 4 <= offset + header.length
                        && (matches("Xing", in: bytes, at: unprotectedTag)
                            || matches("Info", in: bytes, at: unprotectedTag)))
                    || (header.length >= 40 && matches("VBRI", in: bytes, at: offset + 36))
                if !metadata {
                    if let first {
                        sameClock = sameClock && first.sameClock(as: header)
                    } else {
                        first = header
                    }
                    ranges.append(offset..<(offset + header.length))
                }
                offset += header.length
            }
            guard let first, !ranges.isEmpty else {
                throw HiDockError.conversionFailed("Recording contains no supported MP3 audio frames")
            }
            return Scan(ranges: ranges, header: first, uniformClock: sameClock)
        }

        // Validate an entire input before modifying the accumulated output.
        if let firstHeader {
            uniformClock = uniformClock && firstHeader.sameClock(as: scan.header)
        } else {
            firstHeader = scan.header
        }
        uniformClock = uniformClock && scan.uniformClock
        for range in scan.ranges {
            let start = recording.index(recording.startIndex, offsetBy: range.lowerBound)
            audio.append(recording[start..<(start + range.count)])
        }
        frameCount += scan.ranges.count
    }

    func output() throws -> Data {
        guard let firstHeader, !audio.isEmpty else {
            throw HiDockError.conversionFailed("No audio to merge")
        }
        // A single Xing sample count cannot describe changing sample clocks.
        // Preserve such streams without copying an incorrect source-file count.
        guard uniformClock, let header = Header(firstHeader.raw | 0x0001_0000),
              header.xingOffset + 16 <= header.length,
              frameCount <= Int(UInt32.max), audio.count <= Int(UInt32.max) - header.length else {
            return audio
        }
        var result = Data(repeating: 0, count: header.length)
        put(header.raw, in: &result, at: 0)
        result.replaceSubrange(header.xingOffset..<(header.xingOffset + 4), with: "Xing".utf8)
        put(3, in: &result, at: header.xingOffset + 4) // frame count and byte count
        put(UInt32(frameCount), in: &result, at: header.xingOffset + 8)
        put(UInt32(header.length + audio.count), in: &result, at: header.xingOffset + 12)
        result.append(audio)
        return result
    }

    private struct Scan {
        let ranges: [Range<Int>]
        let header: Header
        let uniformClock: Bool
    }

    private struct Header {
        let raw: UInt32
        let length: Int
        let sampleRate: Int
        let samplesPerFrame: Int
        let xingOffset: Int

        init?(_ raw: UInt32) {
            let version = Int((raw >> 19) & 3)
            let bitrateIndex = Int((raw >> 12) & 15)
            let sampleIndex = Int((raw >> 10) & 3)
            guard raw & 0xFFE0_0000 == 0xFFE0_0000, version != 1,
                  (raw >> 17) & 3 == 1, (1...14).contains(bitrateIndex), sampleIndex < 3 else {
                return nil
            }
            let mpeg1 = version == 3
            let bitrates = mpeg1
                ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            let divisor = version == 3 ? 1 : (version == 2 ? 2 : 4)
            sampleRate = [44_100, 48_000, 32_000][sampleIndex] / divisor
            samplesPerFrame = mpeg1 ? 1152 : 576
            length = (mpeg1 ? 144 : 72) * bitrates[bitrateIndex] * 1000 / sampleRate
                + Int((raw >> 9) & 1)
            let mono = (raw >> 6) & 3 == 3
            let sideInfo = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
            let crc = raw & 0x0001_0000 == 0 ? 2 : 0
            xingOffset = 4 + crc + sideInfo
            self.raw = raw
        }

        func sameClock(as other: Header) -> Bool {
            sampleRate == other.sampleRate && samplesPerFrame == other.samplesPerFrame
        }
    }

    private func matches(_ tag: String, in bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        let expected = Array(tag.utf8)
        guard offset >= 0, offset + expected.count <= bytes.count else { return false }
        return expected.enumerated().allSatisfy { bytes[offset + $0.offset] == $0.element }
    }

    private func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 4), with: (0..<4).map {
            UInt8(truncatingIfNeeded: value >> (24 - 8 * $0))
        })
    }
}
