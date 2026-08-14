import Foundation

/// The verbatim provider response on disk, inside a recording's folder.
///
/// Plan §1 keeps the raw response as a **file, not a column**: the spec wants
/// it retained for re-processing, it is the word-level source of truth (words
/// are deliberately not rows), and next to the `.m4a` in a user-visible folder
/// it stays greppable and grabbable in Finder.
public struct RawTranscriptStore: Sendable {

    /// Name used inside every recording folder.
    public static let defaultFileName = "transcript.raw.json"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The store for a recording folder.
    public init(folderURL: URL, fileName: String = RawTranscriptStore.defaultFileName) {
        self.url = folderURL.appendingPathComponent(fileName)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes bytes atomically, creating the folder if needed.
    ///
    /// Atomic because this is called once per poll: a crash mid-write must not
    /// leave a truncated file where a valid transcript used to be.
    public func write(_ data: Data) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw TranscriptionJobError.rawTranscriptUnwritable(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    public func readData() throws -> Data {
        guard exists else {
            throw TranscriptionJobError.rawTranscriptMissing(path: url.path)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TranscriptionJobError.rawTranscriptUnreadable(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    /// Decodes the file, requiring a `completed` transcript.
    ///
    /// The status check is what makes "re-process without a network" safe:
    /// every poll persists its body before decoding, so a file left behind by
    /// an interrupted run may hold `{"status": "processing"}` or an error
    /// body. Those are not transcripts and must send the caller back to the
    /// network rather than produce an empty one.
    public func readCompleted() throws -> TranscriptResponse {
        let data = try readData()
        let response: TranscriptResponse
        do {
            response = try JSONDecoder().decode(TranscriptResponse.self, from: data)
        } catch {
            throw TranscriptionJobError.rawTranscriptUnreadable(
                path: url.path,
                reason: "not an AssemblyAI transcript response — \(error)"
            )
        }
        guard response.status == .completed else {
            throw TranscriptionJobError.rawTranscriptIncomplete(
                path: url.path,
                status: response.status.rawValue
            )
        }
        return response
    }

    /// Non-throwing probe used when planning a resume: "is there a finished
    /// transcript here?"
    public var holdsCompletedTranscript: Bool {
        (try? readCompleted()) != nil
    }
}

/// Failures raised by `TranscriptionJob` itself, as opposed to by the provider
/// (`TranscriptionError`) or the filesystem (`StorageError`).
public enum TranscriptionJobError: Error, Sendable, Equatable {
    /// The job's recording row is gone (deleted while the job was queued).
    case recordingNotFound(id: UUID)
    /// The audio file the job would upload is missing.
    case audioFileMissing(path: String)
    /// A re-process was asked for with no raw response on disk.
    case rawTranscriptMissing(path: String)
    /// The raw response on disk is not a finished transcript.
    case rawTranscriptIncomplete(path: String, status: String)
    /// The raw response on disk could not be read or decoded.
    case rawTranscriptUnreadable(path: String, reason: String)
    /// The raw response could not be written — a real error, because losing
    /// the body is exactly what api-notes decision 1 exists to prevent.
    case rawTranscriptUnwritable(path: String, reason: String)
}

extension TranscriptionJobError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .recordingNotFound(let id):
            return "The recording \(id) is no longer in the library."
        case .audioFileMissing(let path):
            return "The recording's audio file is missing: \(path)"
        case .rawTranscriptMissing(let path):
            return "No saved transcript to re-process at \(path)."
        case .rawTranscriptIncomplete(let path, let status):
            return """
                The saved transcript at \(path) is not finished (status: \(status)), \
                so it cannot be re-processed. Retry the transcription instead.
                """
        case .rawTranscriptUnreadable(let path, let reason):
            return "Could not read the saved transcript at \(path): \(reason)"
        case .rawTranscriptUnwritable(let path, let reason):
            return "Could not save the transcript response to \(path): \(reason)"
        }
    }
}
