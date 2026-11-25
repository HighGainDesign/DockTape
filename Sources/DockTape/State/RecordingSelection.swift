// © 2026 High Gain Design. All rights reserved.
import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import HiDockKit

/// An internal action/drag value captured from the displayed library.
struct RecordingSelection: Hashable, Codable, Sendable, Transferable {
    let filename: String
    let reference: SharedRecordingReference?
    let libraryBinding: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "design.highgain.docktape.recording-selection", conformingTo: .data))
    }
}
