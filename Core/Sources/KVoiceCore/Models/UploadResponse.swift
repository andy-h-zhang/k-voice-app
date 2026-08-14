/// Response body from `POST /v2/upload` (api-notes §1).
///
/// ```json
/// { "upload_url": "https://cdn.assemblyai.com/upload/<id>" }
/// ```
///
/// The URL is readable only by AssemblyAI's servers, and only by API keys
/// from the same project that performed the upload.
public struct UploadResponse: Codable, Sendable, Equatable {
    public var uploadURL: String

    public init(uploadURL: String) {
        self.uploadURL = uploadURL
    }

    private enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
    }
}
