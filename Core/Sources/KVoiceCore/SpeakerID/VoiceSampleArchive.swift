import Foundation

/// A portable file of people and their voice samples, for handing one KVoice's
/// speaker recognition to another.
///
/// ## What a "voice sample" is here
///
/// Not audio. Enrollment audio is a temporary file that is thrown away once
/// it has been embedded; what KVoice keeps, and what recognition actually
/// compares against, is each person's stored embeddings — up to
/// ``SpeakerProfile/defaultEmbeddingCap`` 256-d vectors. Copying those vectors
/// gives the other install exactly the profiles this one matches with, which
/// is the point: the same people are recognized the same way on both.
///
/// ## Why the embedding model is in the file
///
/// A vector only means something to the model that produced it. Scoring
/// vectors from a different model would not fail loudly, it would quietly
/// match the wrong people, so a file from an incompatible model is refused at
/// import rather than trusted.
public struct VoiceSampleArchive: Codable, Sendable, Equatable {

    /// Identifies the file as this format, whatever its extension says.
    public static let formatIdentifier = "ai.kizaki.kvoice.voice-samples"

    /// Bumped on any change an older reader would misread.
    public static let currentVersion = 1

    /// The extension the app saves with.
    public static let fileExtension = "kvoicevoices"

    /// The model behind ``FluidAudioEmbedder`` — the one every stored vector
    /// came from.
    public static let currentEmbeddingModel = "wespeaker_v2"

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var embeddingModel: String
    public var embeddingDimension: Int
    /// Each person with their samples, oldest sample first.
    public var people: [SpeakerProfile]

    public init(
        people: [SpeakerProfile],
        exportedAt: Date = Date(),
        embeddingModel: String = VoiceSampleArchive.currentEmbeddingModel,
        embeddingDimension: Int = FluidAudioEmbedder.embeddingDimension
    ) {
        self.format = Self.formatIdentifier
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.embeddingModel = embeddingModel
        self.embeddingDimension = embeddingDimension
        self.people = people
    }

    /// Total voice samples across everyone in the file.
    public var sampleCount: Int { people.reduce(0) { $0 + $1.embeddingCount } }

    // MARK: - Encoding

    /// The file's bytes: JSON, so a curious person can open it and see names
    /// and dates, and so a future version can read it without guesswork.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads and validates a file.
    ///
    /// - Throws: ``VoiceSampleArchiveError`` for anything that is not a
    ///   readable voice-sample file from a compatible model.
    public static func decode(_ data: Data) throws -> VoiceSampleArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // The header first, so a newer or foreign file gets a precise message
        // instead of whatever field happened to fail to decode.
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == formatIdentifier
        else {
            throw VoiceSampleArchiveError.notAVoiceSampleFile
        }
        guard header.version <= currentVersion else {
            throw VoiceSampleArchiveError.unsupportedVersion(header.version)
        }

        let archive: VoiceSampleArchive
        do {
            archive = try decoder.decode(VoiceSampleArchive.self, from: data)
        } catch {
            throw VoiceSampleArchiveError.notAVoiceSampleFile
        }

        guard archive.embeddingModel == currentEmbeddingModel,
              archive.embeddingDimension == FluidAudioEmbedder.embeddingDimension
        else {
            throw VoiceSampleArchiveError.incompatibleModel(
                model: archive.embeddingModel,
                dimension: archive.embeddingDimension
            )
        }
        // The header can claim the right model while a vector says otherwise.
        let wrongLength = archive.people.contains { person in
            person.embeddings.contains { $0.vector.count != archive.embeddingDimension }
        }
        guard !wrongLength else {
            throw VoiceSampleArchiveError.incompatibleModel(
                model: archive.embeddingModel,
                dimension: archive.embeddingDimension
            )
        }
        return archive
    }

    private struct Header: Decodable {
        let format: String
        let version: Int
    }
}

/// Why a voice-sample file could not be used.
public enum VoiceSampleArchiveError: Error, Sendable, Equatable {
    case notAVoiceSampleFile
    case unsupportedVersion(Int)
    case incompatibleModel(model: String, dimension: Int)
    /// Export found nobody with a recorded voice.
    case nothingToExport
    /// The file is valid but holds nobody with voice samples.
    case nothingToImport
}

extension VoiceSampleArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAVoiceSampleFile:
            return "That file is not a KVoice voice-samples file, or it is damaged."
        case .unsupportedVersion(let version):
            return "That file was made by a newer version of KVoice (format \(version)). "
                + "Update KVoice, then import it again."
        case .incompatibleModel(let model, let dimension):
            return "Those voice samples were made with a different voice model "
                + "(\(model), \(dimension)-d), so they cannot be matched against this one."
        case .nothingToExport:
            return "Nobody has voice samples yet. Record or add a voice for someone first."
        case .nothingToImport:
            return "That file has no voice samples in it."
        }
    }
}

/// What importing a file did — or, from a preview, would do — by name.
public struct VoiceSampleImportSummary: Sendable, Equatable {
    /// People who did not exist and were created.
    public var added: [String]
    /// People who already existed, whose voice samples were replaced by the
    /// file's.
    public var replaced: [String]
    /// Voice samples written.
    public var sampleCount: Int

    public init(added: [String] = [], replaced: [String] = [], sampleCount: Int = 0) {
        self.added = added
        self.replaced = replaced
        self.sampleCount = sampleCount
    }

    public var isEmpty: Bool { added.isEmpty && replaced.isEmpty }
}
