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

    /// Polls, handing the **verbatim** response body to `persist` *before* any
    /// decoding is attempted.
    ///
    /// This is api-notes decision 1 promoted to the protocol, because
    /// `TranscriptionJob` is what actually owes the spec a retained response
    /// and it only ever sees a provider. The ordering is the whole point: if
    /// the API renames a field and our DTO chokes, the bytes are already in
    /// the recording's folder and the transcript is recoverable by hand.
    ///
    /// A throw from `persist` propagates — a failed write is a real error.
    ///
    /// Has a default implementation, so conforming types (and test mocks) only
    /// override it when they can produce true raw bytes. `AssemblyAIClient`
    /// does, via its existing `pollRaw(id:persist:)`.
    func pollPersistingRaw(
        id: String,
        persist: @escaping @Sendable (Data) throws -> Void
    ) async throws -> TranscriptResponse
}

extension TranscriptionProvider {
    /// Default: poll normally, then persist a re-encoding of the decoded value.
    ///
    /// Honest but lossy — fields our DTO does not model (notably `words[]`
    /// detail beyond what we decode) are absent. Only a provider that cannot
    /// expose its transport bytes should land here; the real client overrides.
    public func pollPersistingRaw(
        id: String,
        persist: @escaping @Sendable (Data) throws -> Void
    ) async throws -> TranscriptResponse {
        let response = try await poll(id: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try persist(try encoder.encode(response))
        return response
    }
}
