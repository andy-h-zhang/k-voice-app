import Foundation
import Testing

@testable import KVoiceCore

@Suite("Profile store")
struct ProfileStoreTests {

    @Test("the default location is ~/.speakerlab/profiles.json")
    func defaultLocation() {
        let url = ProfileStore.defaultURL
        #expect(url.lastPathComponent == "profiles.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == ".speakerlab")
    }

    @Test("a library round-trips through the file, embeddings intact")
    func roundTrip() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let store = ProfileStore(url: directory.file("profiles.json"))

        var library = ProfileLibrary()
        let alice = library.upsert(name: "Alice")
        library.profiles[alice].foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        library.profiles[alice].foldIn(TestVectors.unit(seed: 2), source: .autolearn)
        let bob = library.upsert(name: "Bob")
        library.profiles[bob].foldIn(TestVectors.unit(seed: 3), source: .upload)

        try store.save(library)
        let loaded = try store.load()

        #expect(loaded.version == library.version)
        #expect(loaded.profiles.count == 2)
        #expect(loaded.profiles.map(\.name) == library.profiles.map(\.name))
        #expect(loaded.profiles.map(\.id) == library.profiles.map(\.id))
        // Embedding vectors must survive byte-for-byte — this is the payload.
        #expect(loaded.profiles.map(\.vectors) == library.profiles.map(\.vectors))
        #expect(
            loaded.profiles.flatMap { $0.embeddings.map(\.id) }
                == library.profiles.flatMap { $0.embeddings.map(\.id) }
        )

        // Timestamps are stored as whole-second ISO-8601, so they round-trip to
        // the second rather than to the bit (see ProfileStore).
        for (stored, original) in zip(loaded.profiles, library.profiles) {
            #expect(abs(stored.createdAt.timeIntervalSince(original.createdAt)) < 1)
        }

        let loadedAlice = try #require(loaded.profile(named: "Alice"))
        #expect(loadedAlice.embeddingCount == 2)
        #expect(loadedAlice.embeddings.map(\.source) == [.enrollment, .autolearn])
        #expect(loadedAlice.embeddings[0].vector.count == 256)
    }

    @Test("loading a file that does not exist yields an empty library, not an error")
    func missingFileIsEmpty() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let library = try ProfileStore(url: directory.file("nothing-here.json")).load()
        #expect(library.profiles.isEmpty)
        #expect(library.version == ProfileLibrary.currentVersion)
    }

    @Test("save creates missing parent directories")
    func createsParentDirectories() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let nested = directory.url
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("profiles.json")

        try ProfileStore(url: nested).save(ProfileLibrary())
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    /// A half-written file from a crash shouldn't wedge the CLI permanently.
    @Test("an empty file loads as an empty library")
    func emptyFileIsEmptyLibrary() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("profiles.json")
        try Data().write(to: url)

        #expect(try ProfileStore(url: url).load().profiles.isEmpty)
    }

    @Test("a corrupt file reports a clear error instead of silently resetting")
    func corruptFileThrows() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("profiles.json")
        try Data("{ this is not json".utf8).write(to: url)

        #expect(throws: ProfileStoreError.self) {
            try ProfileStore(url: url).load()
        }
    }

    @Test("a newer schema version is refused rather than mis-decoded")
    func futureVersionRefused() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("profiles.json")
        try Data(#"{"version":99,"profiles":[]}"#.utf8).write(to: url)

        #expect(
            throws: ProfileStoreError.unsupportedVersion(found: 99, supported: ProfileLibrary.currentVersion)
        ) {
            try ProfileStore(url: url).load()
        }
    }

    @Test("update loads, mutates, and saves in one step")
    func updateRoundTrip() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let store = ProfileStore(url: directory.file("profiles.json"))

        let count = try store.update { library -> Int in
            let index = library.upsert(name: "Alice")
            library.profiles[index].foldIn(TestVectors.unit(seed: 5), source: .enrollment)
            return library.profiles[index].embeddingCount
        }

        #expect(count == 1)
        #expect(try store.load().profile(named: "Alice")?.embeddingCount == 1)
    }

    @Test("saving twice overwrites rather than appending")
    func overwrites() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let store = ProfileStore(url: directory.file("profiles.json"))
        var library = ProfileLibrary()
        _ = library.upsert(name: "Alice")
        try store.save(library)

        _ = library.upsert(name: "Bob")
        try store.save(library)

        #expect(try store.load().profiles.count == 2)
    }

    @Test("the on-disk format is human-readable JSON with ISO-8601 dates")
    func fileIsReadable() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("profiles.json")
        var library = ProfileLibrary()
        let index = library.upsert(name: "Alice")
        library.profiles[index].foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        try ProfileStore(url: url).save(library)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"name\" : \"Alice\""))
        #expect(text.contains("\"source\" : \"enrollment\""))
        #expect(text.contains("T"))  // ISO-8601 timestamp separator
    }
}
