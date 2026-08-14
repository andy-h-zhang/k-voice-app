import Foundation

/// File-backed persistence for the voice-profile library.
///
/// Phase 1 keeps profiles in a single JSON document so the CLI never touches
/// SwiftData (plan §2, Phase 1 item 8). Phase 3 introduces the SwiftData
/// schema for the app; this store stays as the CLI's storage and as the
/// import/export format.
public struct ProfileStore: Sendable {

    /// `~/.speakerlab/profiles.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speakerlab", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    public let url: URL

    public init(url: URL = ProfileStore.defaultURL) {
        self.url = url
    }

    /// Loads the library, returning an **empty** one when the file does not
    /// exist yet (first run is not an error).
    public func load() throws -> ProfileLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProfileLibrary()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProfileStoreError.unreadable(url: url, underlying: String(describing: error))
        }

        // An empty file is treated as an empty library — a half-written file
        // from a crash shouldn't wedge the CLI permanently.
        guard !data.isEmpty else { return ProfileLibrary() }

        do {
            let library = try Self.decoder.decode(ProfileLibrary.self, from: data)
            guard library.version <= ProfileLibrary.currentVersion else {
                throw ProfileStoreError.unsupportedVersion(
                    found: library.version,
                    supported: ProfileLibrary.currentVersion
                )
            }
            return library
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.corrupt(url: url, underlying: String(describing: error))
        }
    }

    /// Writes the library atomically, creating the parent directory if needed.
    public func save(_ library: ProfileLibrary) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProfileStoreError.unwritable(url: url, underlying: String(describing: error))
        }

        do {
            let data = try Self.encoder.encode(library)
            // `.atomic` writes to a temp file and renames, so an interrupted
            // save can't truncate an existing profile library.
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProfileStoreError.unwritable(url: url, underlying: String(describing: error))
        }
    }

    /// Load → mutate → save. Returns whatever the body returns.
    @discardableResult
    public func update<T>(_ body: (inout ProfileLibrary) throws -> T) throws -> T {
        var library = try load()
        let result = try body(&library)
        try save(library)
        return result
    }

    // ISO-8601 dates and sorted, pretty-printed keys: the profile file is
    // meant to be readable and diffable by hand.
    //
    // Note that ISO-8601 encoding keeps whole seconds, so timestamps round-trip
    // to the second, not to the bit. Nothing depends on sub-second resolution —
    // FIFO eviction order comes from array position, not from `addedAt`.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum ProfileStoreError: Error, Sendable, Equatable {
    case unreadable(url: URL, underlying: String)
    case unwritable(url: URL, underlying: String)
    case corrupt(url: URL, underlying: String)
    case unsupportedVersion(found: Int, supported: Int)
}

extension ProfileStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let underlying):
            return "Could not read the profile library at \(url.path): \(underlying)"
        case .unwritable(let url, let underlying):
            return "Could not write the profile library at \(url.path): \(underlying)"
        case .corrupt(let url, let underlying):
            return "The profile library at \(url.path) is not valid JSON for this schema: \(underlying)"
        case .unsupportedVersion(let found, let supported):
            return """
                The profile library was written by a newer version (schema \(found); \
                this build understands \(supported)). Upgrade, or point --profiles at a different file.
                """
        }
    }
}
