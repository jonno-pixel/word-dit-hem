import Foundation

struct JJSFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum MessageRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

enum MessageState: String, Codable, Sendable, Equatable {
    case queued
    case running
    case complete
    case stopped
    case failed
}

struct ChatSummary: Identifiable, Sendable {
    let id: String
    var title: String
    var updated: Date
}

struct ChatMessage: Identifiable, Codable, Sendable {
    var id: String
    var role: MessageRole
    var content: String
    var state: MessageState
    var created: Date
    var note: String
}

struct ModelEntry: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bytes: Int64
}

struct GenerationOptions: Codable, Sendable {
    var modelPath: String
    var contextSize: UInt32
    var temperature: Float
    var useMetal: Bool
    var template: String
}

struct EngineTurn: Sendable {
    let role: String
    let content: String
}

enum EngineUpdate: Sendable {
    case status(String)
    case text(String)
}

struct GenerationResult: Sendable {
    let tokenCount: Int
    let contextShifts: Int
}
