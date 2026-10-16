// © 2026 High Gain Design. All rights reserved.
import Foundation

/// One displayed review, including a fresh identity when the same plan is reopened.
struct FileReviewPreview<Review: Sendable>: Identifiable, Sendable {
    let id = UUID()
    let review: Review
}
