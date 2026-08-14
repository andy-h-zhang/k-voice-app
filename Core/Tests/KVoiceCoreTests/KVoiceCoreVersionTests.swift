import Testing
@testable import KVoiceCore

@Suite("KVoiceCore version")
struct KVoiceCoreVersionTests {
    @Test("version is non-empty")
    func versionIsNonEmpty() {
        #expect(!KVoiceCore.version.isEmpty)
    }
}
