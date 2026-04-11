// © 2026 High Gain Design. All rights reserved.

// Sources/HiDockKit/Summarization/Summary.swift
import Foundation

/// A structured AI-generated summary of a transcript.
public struct Summary: Codable, Sendable, Identifiable, Equatable {
    public var id: String { recordingFilename }

    public let recordingFilename: String
    public let createdAt: Date
    public let model: String
    public let provider: String
    public let templateUsed: String
    public let customPrompt: String?
    public var sections: [Section]

    public init(
        recordingFilename: String,
        createdAt: Date = Date(),
        model: String,
        provider: String,
        templateUsed: String,
        customPrompt: String? = nil,
        sections: [Section]
    ) {
        self.recordingFilename = recordingFilename
        self.createdAt = createdAt
        self.model = model
        self.provider = provider
        self.templateUsed = templateUsed
        self.customPrompt = customPrompt
        self.sections = sections
    }

    public struct Section: Codable, Sendable, Identifiable, Equatable {
        public let id: UUID
        public let heading: String
        public let content: String
        public let items: [Item]?

        public init(id: UUID = UUID(), heading: String, content: String, items: [Item]? = nil) {
            self.id = id
            self.heading = heading
            self.content = content
            self.items = items
        }
    }

    public struct Item: Codable, Sendable, Identifiable, Equatable {
        public let id: UUID
        public let text: String
        public var isCompleted: Bool

        public init(id: UUID = UUID(), text: String, isCompleted: Bool = false) {
            self.id = id
            self.text = text
            self.isCompleted = isCompleted
        }
    }
}
