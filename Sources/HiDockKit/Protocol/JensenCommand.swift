// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Jensen protocol command IDs (big-endian on wire).
public enum JensenCommand: UInt16, Sendable {
    case deviceInfo         = 0x0001
    case getTime            = 0x0002
    case setTime            = 0x0003
    case fileList           = 0x0004
    case transferFile       = 0x0005
    case fileCount          = 0x0006
    case deleteFile         = 0x0007
    case firmwareUpgrade    = 0x0008
    case firmwareUpload     = 0x0009
    case getSettings        = 0x000B
    case setSettings        = 0x000C
    case fileBlock          = 0x000D
    case cardInfo           = 0x0010
    case formatCard         = 0x0011
    case getRecordingFile   = 0x0012
    case readFile           = 0x0015
    case battery            = 0x1004
    case testFirmwareVersion = 0xF001
    case massStorage        = 0xF00F
}
