import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// `TranscriptionProvider` backed by AssemblyAI's async transcription API.
///
/// Request surface verified 2026-08-13 — `docs/api-notes.md` is the ground
/// truth for every identifier, limit, and policy below, and all four of its
/// "Decisions locked for the code" are implemented here:
///
/// 1. **Raw body first.** `pollRaw` hands the verbatim response bytes to a
///    `persist` closure *before* any decoding, so a DTO mismatch can never
///    cost us the response (the spec requires retaining it for re-processing).
/// 2. **Backoff.** Delegated to `PollBackoff` / `TranscriptPoller`.
/// 3. **Error taxonomy.** Delegated to `TranscriptionError.from(status:)`;
///    429/5xx/transport are retried in `send`, other 4xx fail fast.
/// 4. **Constants.** All identifiers live in `AssemblyAIConstants`.
///
/// The type is a `Sendable` value: it holds only an API key, a `URLSession`,
/// and configuration, so it can be shared freely across tasks.
public struct AssemblyAIClient: TranscriptionProvider {

    /// Tunables that are not API identifiers. Endpoint paths, model names, and
    /// documented limits live in `AssemblyAIConstants` instead.
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var speechModels: [String]
        public var maxRequestAttempts: Int
        public var backoff: PollBackoff

        public init(
            baseURL: URL = AssemblyAIConstants.baseURL,
            speechModels: [String] = AssemblyAIConstants.defaultSpeechModels,
            maxRequestAttempts: Int = AssemblyAIConstants.maxRequestAttempts,
            backoff: PollBackoff = PollBackoff()
        ) {
            self.baseURL = baseURL
            self.speechModels = speechModels
            self.maxRequestAttempts = maxRequestAttempts
            self.backoff = backoff
        }
    }

    /// Verbatim response bytes plus the value decoded from them. Returned
    /// together so callers can persist exactly what the server sent
    /// (api-notes decision 1) rather than a re-encoding of our partial DTO.
    public struct RawTranscript: Sendable {
        public let data: Data
        public let response: TranscriptResponse

        public init(data: Data, response: TranscriptResponse) {
            self.data = data
            self.response = response
        }
    }

    private let apiKey: String
    private let session: URLSession
    private let configuration: Configuration
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - apiKey: AssemblyAI key. The CLI reads `ASSEMBLYAI_API_KEY`; the app
    ///     will read the Keychain (Phase 3). **The upload and the transcript
    ///     request must use a key from the same project** or the API answers
    ///     403 "Cannot access uploaded file" (api-notes §Auth).
    ///   - session: Injectable for tests (a `URLProtocol` stub) — the test
    ///     suite never touches the network.
    ///   - sleep: Injectable so retry backoff is instant under test.
    public init(
        apiKey: String,
        session: URLSession = .shared,
        configuration: Configuration = Configuration(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        }
    ) {
        self.apiKey = apiKey
        self.session = session
        self.configuration = configuration
        self.sleep = sleep
    }

    /// Builds a client from `ASSEMBLYAI_API_KEY` and nothing else.
    ///
    /// Deliberately does **not** consult the Keychain: a bare
    /// `fromEnvironment` must stay a pure function of its argument so tests
    /// can call it without a system dialog appearing on someone's screen. Use
    /// ``resolved(environment:keychain:session:configuration:)`` for the
    /// fallback behavior.
    ///
    /// - Throws: `TranscriptionError.missingAPIKey` when unset or blank.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        configuration: Configuration = Configuration()
    ) throws -> AssemblyAIClient {
        let key = environment["ASSEMBLYAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw TranscriptionError.missingAPIKey }
        return AssemblyAIClient(apiKey: key, session: session, configuration: configuration)
    }

    /// Builds a client from the environment, falling back to a stored key.
    ///
    /// `ASSEMBLYAI_API_KEY` still wins, so every documented CLI invocation
    /// behaves exactly as it did in Phase 1; the Keychain is only consulted
    /// when the variable is absent or blank. That is what lets the CLI and the
    /// app share one key without the CLI growing a settings file.
    ///
    /// - Throws: `TranscriptionError.missingAPIKey` when neither source has one.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: any APIKeyStore = KeychainAPIKeyStore(),
        session: URLSession = .shared,
        configuration: Configuration = Configuration()
    ) throws -> AssemblyAIClient {
        let key = try APIKeyResolver.require(environment: environment, keychain: keychain)
        return AssemblyAIClient(apiKey: key, session: session, configuration: configuration)
    }

    // MARK: - TranscriptionProvider

    /// `POST /v2/upload` — raw `application/octet-stream` bytes, **streamed
    /// from the file** rather than read into memory (a 2-hour recording is a
    /// large file; api-notes §1 also rules out multipart).
    public func upload(fileURL: URL) async throws -> URL {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(AssemblyAIConstants.uploadPath))
        request.httpMethod = "POST"
        request.setValue(
            AssemblyAIConstants.authorizationValue(apiKey: apiKey),
            forHTTPHeaderField: AssemblyAIConstants.authorizationHeader
        )
        request.setValue(
            AssemblyAIConstants.octetStreamContentType,
            forHTTPHeaderField: AssemblyAIConstants.contentTypeHeader
        )

        let data = try await send(request, uploadingFile: fileURL)
        let decoded: UploadResponse = try decode(data, as: UploadResponse.self)

        guard let url = URL(string: decoded.uploadURL) else {
            throw TranscriptionError.malformedResponse(description: "upload_url is not a valid URL: \(decoded.uploadURL)")
        }
        return url
    }

    /// `POST /v2/transcript` — creates the job and returns its id.
    public func createTranscript(_ request: TranscriptRequest) async throws -> String {
        var urlRequest = URLRequest(
            url: configuration.baseURL.appendingPathComponent(AssemblyAIConstants.transcriptPath)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            AssemblyAIConstants.authorizationValue(apiKey: apiKey),
            forHTTPHeaderField: AssemblyAIConstants.authorizationHeader
        )
        urlRequest.setValue(
            AssemblyAIConstants.jsonContentType,
            forHTTPHeaderField: AssemblyAIConstants.contentTypeHeader
        )

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw TranscriptionError.decoding(description: "Could not encode the request body: \(error)")
        }

        let data = try await send(urlRequest)
        let decoded: TranscriptResponse = try decode(data, as: TranscriptResponse.self)
        return decoded.id
    }

    /// `GET /v2/transcript/{id}`.
    public func poll(id: String) async throws -> TranscriptResponse {
        try await pollRaw(id: id).response
    }

    /// `TranscriptionProvider`'s raw-body hook, backed by `pollRaw`. Overrides
    /// the protocol's re-encoding default with the genuine transport bytes.
    public func pollPersistingRaw(
        id: String,
        persist: @escaping @Sendable (Data) throws -> Void
    ) async throws -> TranscriptResponse {
        try await pollRaw(id: id, persist: persist).response
    }

    // MARK: - Raw-body access (api-notes decision 1)

    /// Polls and returns the verbatim body alongside the decoded value.
    ///
    /// - Parameter persist: Invoked with the raw bytes **before** decoding is
    ///   attempted. This ordering is the whole point: if the API adds or
    ///   renames a field and our DTO chokes, the response is already on disk.
    ///   A throw from `persist` propagates (a failed write is a real error).
    public func pollRaw(
        id: String,
        persist: (@Sendable (Data) throws -> Void)? = nil
    ) async throws -> RawTranscript {
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent(AssemblyAIConstants.transcriptPath(id: id))
        )
        request.httpMethod = "GET"
        request.setValue(
            AssemblyAIConstants.authorizationValue(apiKey: apiKey),
            forHTTPHeaderField: AssemblyAIConstants.authorizationHeader
        )

        let data = try await send(request)
        try persist?(data)
        let decoded: TranscriptResponse = try decode(data, as: TranscriptResponse.self)
        return RawTranscript(data: data, response: decoded)
    }

    /// Polls until the job is `completed`, persisting the verbatim body of the
    /// **terminal** response (completed *or* error) before decoding it.
    ///
    /// Intermediate `queued`/`processing` bodies are not persisted: they carry
    /// no transcript content and would only churn the file.
    @discardableResult
    public func waitForCompletion(
        id: String,
        audioDurationSeconds: TimeInterval? = nil,
        persistRaw: (@Sendable (Data) throws -> Void)? = nil,
        onUpdate: TranscriptPoller.UpdateHandler? = nil
    ) async throws -> TranscriptResponse {
        let poller = TranscriptPoller(
            backoff: configuration.backoff,
            maxConsecutiveFailures: configuration.maxRequestAttempts,
            sleep: sleep
        )

        return try await poller.waitForCompletion(
            id: id,
            audioDurationSeconds: audioDurationSeconds,
            poll: { transcriptID in
                // Peek at the status before deciding to persist, so only the
                // terminal body hits the disk — but still persist *before*
                // this method returns a decoded value to the caller.
                let raw = try await pollRaw(id: transcriptID)
                if raw.response.status.isTerminal {
                    try persistRaw?(raw.data)
                }
                return raw.response
            },
            onUpdate: onUpdate
        )
    }

    // MARK: - Transport

    /// Issues a request, retrying retryable failures (429/5xx/transport) with
    /// backoff per api-notes decision 3.
    private func send(_ request: URLRequest, uploadingFile fileURL: URL? = nil) async throws -> Data {
        var lastError: TranscriptionError = .transport(description: "no attempt was made")

        for attempt in 0..<max(1, configuration.maxRequestAttempts) {
            try Task.checkCancellation()

            do {
                let (data, response) = try await perform(request, uploadingFile: fileURL)

                guard let http = response as? HTTPURLResponse else {
                    throw TranscriptionError.malformedResponse(description: "response was not HTTP")
                }

                guard (200..<300).contains(http.statusCode) else {
                    throw TranscriptionError.from(
                        status: http.statusCode,
                        message: Self.errorMessage(from: data),
                        retryAfter: Self.retryAfter(from: http)
                    )
                }

                return data
            } catch let error as TranscriptionError {
                guard error.isRetryable, attempt + 1 < max(1, configuration.maxRequestAttempts) else { throw error }
                lastError = error
                var retryAfter: TimeInterval?
                if case .rateLimited(let after) = error { retryAfter = after }
                try await sleep(PollBackoff.retryDelay(forAttempt: attempt, retryAfter: retryAfter))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let wrapped = TranscriptionError.transport(description: error.localizedDescription)
                guard attempt + 1 < max(1, configuration.maxRequestAttempts) else { throw wrapped }
                lastError = wrapped
                try await sleep(PollBackoff.retryDelay(forAttempt: attempt))
            }
        }

        throw lastError
    }

    private func perform(_ request: URLRequest, uploadingFile fileURL: URL?) async throws -> (Data, URLResponse) {
        if let fileURL {
            // Streams the file body from disk — never loads it into memory.
            return try await session.upload(for: request, fromFile: fileURL)
        }
        return try await session.data(for: request)
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TranscriptionError.decoding(
                description: "\(error) — body: \(Self.snippet(of: data))"
            )
        }
    }

    /// Pulls a human-readable message out of an error body.
    ///
    /// AssemblyAI answers `{"error": "..."}` for most failures, but the upload
    /// endpoint's 422 body is **plain text** (api-notes §1), so fall back to
    /// the raw string.
    static func errorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "detail"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        let text = snippet(of: data)
        return text.isEmpty ? nil : text
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) { return seconds }
        return nil
    }

    private static func snippet(of data: Data, limit: Int = 300) -> String {
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return data.count > limit ? text + "…" : text
    }
}
