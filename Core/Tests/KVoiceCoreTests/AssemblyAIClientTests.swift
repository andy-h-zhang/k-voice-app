import Foundation
import Testing

@testable import KVoiceCore

/// Exercises the real `AssemblyAIClient` against a `URLProtocol` stub.
///
/// Nothing here touches the network or needs an API key: every request is
/// intercepted in-process, which is what lets us assert the exact wire format
/// `docs/api-notes.md` specifies.
///
/// Serialized because `URLProtocol` registration is process-wide.
@Suite("AssemblyAI client", .serialized)
struct AssemblyAIClientTests {

    // MARK: - Harness

    private func makeClient(
        speechModels: [String] = AssemblyAIConstants.defaultSpeechModels,
        maxRequestAttempts: Int = AssemblyAIConstants.maxRequestAttempts,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> AssemblyAIClient {
        StubURLProtocol.box.handler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]

        return AssemblyAIClient(
            apiKey: "test-key",
            session: URLSession(configuration: configuration),
            configuration: .init(speechModels: speechModels, maxRequestAttempts: maxRequestAttempts),
            sleep: { _ in }  // no real backoff waiting in tests
        )
    }

    private func ok(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(json.utf8)
        )
    }

    // MARK: - Upload (api-notes §1)

    @Test("upload posts raw octet-stream bytes with bearer auth")
    func uploadRequestShape() async throws {
        let captured = CapturedRequests()
        let client = makeClient { request in
            captured.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"upload_url":"https://cdn.assemblyai.com/upload/abc"}"#.utf8)
            )
        }

        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let file = directory.file("audio.m4a")
        try Data(repeating: 0x41, count: 4_096).write(to: file)

        let url = try await client.upload(fileURL: file)

        #expect(url.absoluteString == "https://cdn.assemblyai.com/upload/abc")

        let request = try #require(captured.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/upload")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test("a malformed upload_url is reported rather than silently accepted")
    func uploadRejectsBadURL() async throws {
        let client = makeClient { request in
            self.ok(request, #"{"upload_url":""}"#)
        }

        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let file = directory.file("audio.m4a")
        try Data([0x00]).write(to: file)

        await #expect(throws: TranscriptionError.self) {
            try await client.upload(fileURL: file)
        }
    }

    // MARK: - Create transcript (api-notes §2)

    @Test("create sends the documented body and returns the transcript id")
    func createRequestBody() async throws {
        let captured = CapturedRequests()
        let client = makeClient { request in
            captured.record(request)
            return self.ok(request, #"{"id":"t-123","status":"queued"}"#)
        }

        let id = try await client.createTranscript(
            TranscriptRequest(
                audioURL: "https://cdn.assemblyai.com/upload/abc",
                speechModels: ["universal-3-5-pro", "universal-2"],
                speakerLabels: true,
                keytermsPrompt: ["KVoice", "diarization"]
            )
        )

        #expect(id == "t-123")

        let request = try #require(captured.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/transcript")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let body = try #require(captured.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["audio_url"] as? String == "https://cdn.assemblyai.com/upload/abc")
        #expect(json["speech_models"] as? [String] == ["universal-3-5-pro", "universal-2"])
        #expect(json["speaker_labels"] as? Bool == true)
        #expect(json["keyterms_prompt"] as? [String] == ["KVoice", "diarization"])
        // We never send punctuate:false — speaker_labels depends on it.
        #expect(json["punctuate"] == nil)
    }

    @Test("an empty keyterms list is omitted from the body entirely")
    func createOmitsEmptyKeyterms() async throws {
        let captured = CapturedRequests()
        let client = makeClient { request in
            captured.record(request)
            return self.ok(request, #"{"id":"t-123","status":"queued"}"#)
        }

        _ = try await client.createTranscript(
            TranscriptRequest(audioURL: "https://cdn/1", keytermsPrompt: [])
        )

        let body = try #require(captured.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["keyterms_prompt"] == nil)
        #expect(json.keys.sorted() == ["audio_url", "speaker_labels", "speech_models"])
    }

    // MARK: - Poll (api-notes §3)

    @Test("poll issues a GET against the transcript id and decodes the response")
    func pollDecodes() async throws {
        let captured = CapturedRequests()
        let client = makeClient { request in
            captured.record(request)
            return self.ok(
                request,
                """
                {"id":"t-123","status":"completed","audio_duration":612,
                 "language_code":"en_us","speech_model_used":"universal-3-5-pro",
                 "utterances":[{"speaker":"A","text":"hi","start":0,"end":900,
                   "words":[{"text":"hi","start":0,"end":900,"confidence":0.9,"speaker":"A"}]}]}
                """
            )
        }

        let response = try await client.poll(id: "t-123")

        #expect(response.status == .completed)
        #expect(response.audioDuration == 612)
        #expect(response.speechModelUsed == "universal-3-5-pro")
        #expect(response.utterances?.count == 1)

        let request = try #require(captured.all.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/transcript/t-123")
    }

    /// api-notes decision 1: the verbatim body is persisted *before* decoding,
    /// so a DTO mismatch can never cost us the response.
    @Test("the raw body reaches the persist hook before decoding is attempted")
    func rawBodyIsPersistedBeforeDecoding() async throws {
        let undecodable = #"{"unexpected":"shape"}"#
        let client = makeClient { request in
            self.ok(request, undecodable)
        }

        let saved = CapturedData()
        await #expect(throws: TranscriptionError.self) {
            try await client.pollRaw(id: "t-123", persist: { saved.record($0) })
        }

        // Decoding failed, but the response is still in hand.
        let data = try #require(saved.all.first)
        #expect(String(decoding: data, as: UTF8.self) == undecodable)
    }

    @Test("pollRaw returns the exact bytes alongside the decoded value")
    func rawBodyMatchesDecoded() async throws {
        let body = #"{"id":"t-9","status":"queued"}"#
        let client = makeClient { request in self.ok(request, body) }

        let raw = try await client.pollRaw(id: "t-9")

        #expect(String(decoding: raw.data, as: UTF8.self) == body)
        #expect(raw.response.id == "t-9")
        #expect(raw.response.status == .queued)
    }

    @Test("waitForCompletion persists only the terminal body")
    func waitForCompletionPersistsTerminalBody() async throws {
        let responses = ResponseSequence([
            #"{"id":"t-1","status":"queued"}"#,
            #"{"id":"t-1","status":"processing"}"#,
            #"{"id":"t-1","status":"completed","audio_duration":12}"#
        ])
        let client = makeClient { request in
            self.ok(request, responses.next())
        }

        let saved = CapturedData()
        let response = try await client.waitForCompletion(
            id: "t-1",
            persistRaw: { saved.record($0) }
        )

        #expect(response.status == .completed)
        #expect(saved.all.count == 1)
        let persisted = String(decoding: try #require(saved.all.first), as: UTF8.self)
        #expect(persisted.contains("completed"))
    }

    // MARK: - Error taxonomy (api-notes decision 3)

    @Test("401 maps to unauthorized and is not retried")
    func unauthorizedIsTerminal() async throws {
        let calls = CallCounter()
        let client = makeClient { request in
            calls.increment()
            return self.ok(request, #"{"error":"Invalid API key"}"#, status: 401)
        }

        await #expect(throws: TranscriptionError.unauthorized(message: "Invalid API key")) {
            try await client.poll(id: "t-1")
        }
        #expect(calls.count == 1)
    }

    @Test("403 keeps the server's cross-project explanation")
    func forbiddenCarriesMessage() async throws {
        let client = makeClient { request in
            self.ok(request, #"{"error":"Cannot access uploaded file"}"#, status: 403)
        }

        await #expect(throws: TranscriptionError.forbidden(message: "Cannot access uploaded file")) {
            try await client.poll(id: "t-1")
        }
    }

    /// api-notes §1: the upload endpoint's 422 body is plain text, not JSON.
    @Test("a plain-text 422 body still yields a useful message")
    func plainTextErrorBody() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data("Unprocessable Entity: file is empty".utf8)
            )
        }

        await #expect(
            throws: TranscriptionError.invalidRequest(
                status: 422,
                message: "Unprocessable Entity: file is empty"
            )
        ) {
            try await client.poll(id: "t-1")
        }
    }

    @Test("5xx is retried and then succeeds")
    func serverErrorIsRetried() async throws {
        let calls = CallCounter()
        let client = makeClient { request in
            let attempt = calls.increment()
            if attempt < 3 {
                return self.ok(request, #"{"error":"upstream"}"#, status: 503)
            }
            return self.ok(request, #"{"id":"t-1","status":"completed"}"#)
        }

        let response = try await client.poll(id: "t-1")

        #expect(response.status == .completed)
        #expect(calls.count == 3)
    }

    @Test("retries are bounded by maxRequestAttempts")
    func retriesAreBounded() async throws {
        let calls = CallCounter()
        let client = makeClient(maxRequestAttempts: 3) { request in
            calls.increment()
            return self.ok(request, #"{"error":"upstream"}"#, status: 500)
        }

        await #expect(throws: TranscriptionError.serverError(status: 500, message: "upstream")) {
            try await client.poll(id: "t-1")
        }
        #expect(calls.count == 3)
    }

    @Test("429 is retryable and 400 is not")
    func retryClassification() {
        #expect(TranscriptionError.from(status: 429, message: nil).isRetryable)
        #expect(TranscriptionError.from(status: 500, message: nil).isRetryable)
        #expect(TranscriptionError.from(status: 503, message: nil).isRetryable)
        #expect(!TranscriptionError.from(status: 400, message: nil).isRetryable)
        #expect(!TranscriptionError.from(status: 401, message: nil).isRetryable)
        #expect(!TranscriptionError.from(status: 404, message: nil).isRetryable)
        #expect(TranscriptionError.transport(description: "offline").isRetryable)
    }

    @Test("Retry-After is parsed from the response headers")
    func parsesRetryAfter() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.assemblyai.com/v2/transcript/t")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "17"]
            )
        )
        #expect(AssemblyAIClient.retryAfter(from: response) == 17)
    }

    @Test("an undecodable success body reports a decoding error with a snippet")
    func decodingErrorIncludesBody() async throws {
        let client = makeClient { request in
            self.ok(request, "not json at all")
        }

        do {
            _ = try await client.poll(id: "t-1")
            Issue.record("expected a decoding failure")
        } catch let error as TranscriptionError {
            guard case .decoding(let description) = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
            #expect(description.contains("not json at all"))
        }
    }

    // MARK: - Environment

    @Test("a missing or blank API key is a precondition failure")
    func missingAPIKey() {
        #expect(throws: TranscriptionError.missingAPIKey) {
            try AssemblyAIClient.fromEnvironment(environment: [:])
        }
        #expect(throws: TranscriptionError.missingAPIKey) {
            try AssemblyAIClient.fromEnvironment(environment: ["ASSEMBLYAI_API_KEY": "   "])
        }
    }

    @Test("an API key from the environment is accepted")
    func apiKeyFromEnvironment() throws {
        _ = try AssemblyAIClient.fromEnvironment(environment: ["ASSEMBLYAI_API_KEY": "abc123"])
    }
}

// MARK: - URLProtocol stub

/// Intercepts every request in-process. Registered only on the ephemeral
/// sessions these tests create, so it can never reach the network.
final class StubURLProtocol: URLProtocol {

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
            get { lock.withLock { _handler } }
            set { lock.withLock { _handler = newValue } }
        }
    }

    static let box = Box()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.box.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Capture helpers

/// URLSession converts `httpBody` into `httpBodyStream` before a `URLProtocol`
/// sees it, so bodies are captured by draining the stream.
final class CapturedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var capturedBodies: [Data] = []

    var all: [URLRequest] { lock.withLock { requests } }
    var bodies: [Data] { lock.withLock { capturedBodies } }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        lock.withLock {
            requests.append(request)
            if let body { capturedBodies.append(body) }
        }
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4_096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class CapturedData: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    var all: [Data] { lock.withLock { items } }

    func record(_ data: Data) {
        lock.withLock { items.append(data) }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// Returns a scripted sequence of response bodies, repeating the last one.
final class ResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String]
    private var index = 0

    init(_ bodies: [String]) {
        self.bodies = bodies
    }

    func next() -> String {
        lock.withLock {
            let body = bodies[min(index, bodies.count - 1)]
            index += 1
            return body
        }
    }
}
