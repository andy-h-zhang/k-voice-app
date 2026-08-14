import Foundation

/// Abstracts the async transcription API (AssemblyAI in v1) so
/// `TranscriptionJob` (Phase 3) can be driven against a mock in tests.
public protocol TranscriptionProvider: Sendable {
    /// Uploads the local audio file and returns a URL the provider can fetch
    /// the audio from when creating a transcript.
    func upload(fileURL: URL) async throws -> URL

    /// Submits a transcription request and returns the created transcript's id.
    func createTranscript(_ request: TranscriptRequest) async throws -> String

    /// Fetches the current state of a transcript by id. Callers poll this
    /// until `status` is `.completed` or `.error`.
    func poll(id: String) async throws -> TranscriptResponse
}
