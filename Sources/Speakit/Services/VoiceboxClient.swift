import Foundation

/// Thin client for the Voicebox (https://voicebox.sh) local REST API.
///
/// Voicebox is a free, open-source AI voice studio that runs entirely on
/// this Mac and serves a REST API on http://127.0.0.1:17493 (see its
/// Settings, and http://127.0.0.1:17493/docs for the live API reference).
///
/// The client is deliberately tolerant about response shapes — it accepts
/// raw WAV bytes, base64-encoded audio in JSON, or a file path / URL that
/// points at the rendered audio — so it keeps working across Voicebox
/// versions.
final class VoiceboxClient {

    static let shared = VoiceboxClient()

    static let defaultBaseURLString = "http://127.0.0.1:17493"

    struct Profile: Identifiable, Hashable {
        let id: String
        let name: String
        let engine: String?
        let language: String?
    }

    enum ClientError: LocalizedError {
        case serverUnreachable(String)
        case badResponse(status: Int, body: String)
        case unrecognizedAudioPayload(String)

        var errorDescription: String? {
            switch self {
            case .serverUnreachable(let detail):
                return "Couldn't reach the Voicebox server. Make sure the Voicebox app is running (and its API server is enabled in Voicebox's settings). \(detail)"
            case .badResponse(let status, let body):
                return "Voicebox returned HTTP \(status): \(body.prefix(300))"
            case .unrecognizedAudioPayload(let detail):
                return "Voicebox replied, but the audio payload wasn't recognized (\(detail)). Check http://127.0.0.1:17493/docs for your version's API format."
            }
        }
    }

    var baseURL: URL {
        let stored = UserDefaults.standard.string(forKey: "voiceboxBaseURL") ?? ""
        return URL(string: stored.isEmpty ? Self.defaultBaseURLString : stored)
            ?? URL(string: Self.defaultBaseURLString)!
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180  // model inference can be slow on first run
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }

    // MARK: - Profiles

    /// Lists the voice profiles configured in Voicebox.
    func fetchProfiles() async throws -> [Profile] {
        let url = baseURL.appendingPathComponent("profiles")
        let (data, response) = try await dataOrThrow(for: URLRequest(url: url))
        try Self.checkHTTP(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ClientError.unrecognizedAudioPayload("profiles response was not JSON")
        }
        let rawList: [Any]
        if let array = json as? [Any] {
            rawList = array
        } else if let dict = json as? [String: Any] {
            rawList = (dict["profiles"] as? [Any])
                ?? (dict["data"] as? [Any])
                ?? (dict["items"] as? [Any])
                ?? []
        } else {
            rawList = []
        }

        return rawList.compactMap { item -> Profile? in
            guard let dict = item as? [String: Any] else { return nil }
            let id = Self.string(dict, keys: ["id", "profile_id", "profileId", "uuid", "slug"])
            let name = Self.string(dict, keys: ["name", "title", "display_name", "displayName", "label"])
            guard let id = id ?? name else { return nil }
            return Profile(
                id: id,
                name: name ?? id,
                engine: Self.string(dict, keys: ["engine", "model", "tts_engine", "provider"]),
                language: Self.string(dict, keys: ["language", "lang", "locale"])
            )
        }
    }

    // MARK: - Speech generation

    /// Renders `text` with the given profile and returns playable audio
    /// data (WAV).
    func generate(text: String, profileID: String?) async throws -> Data {
        let url = baseURL.appendingPathComponent("generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("speakit", forHTTPHeaderField: "X-Voicebox-Client-Id")

        // FastAPI-style servers ignore unknown fields, so we send the
        // profile under the common spellings to be version-proof.
        var body: [String: Any] = ["text": text]
        if let profileID {
            body["profile_id"] = profileID
            body["profileId"] = profileID
            body["profile"] = profileID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataOrThrow(for: request)
        try Self.checkHTTP(response, data: data)
        return try await audioData(from: data, response: response)
    }

    /// Quick health check used by Settings and the voice picker.
    func checkConnection() async -> Result<Int, Error> {
        do {
            let profiles = try await fetchProfiles()
            return .success(profiles.count)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Response handling

    private func audioData(from data: Data, response: URLResponse) async throws -> Data {
        // Raw audio body?
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("audio") || Self.looksLikeAudio(data) {
            return data
        }

        // JSON envelope: base64 audio, a served URL, or a local file path.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.unrecognizedAudioPayload("neither audio bytes nor JSON")
        }

        if let base64 = Self.string(json, keys: ["audio", "audio_base64", "audioBase64", "data", "wav"]),
           let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           Self.looksLikeAudio(decoded) {
            return decoded
        }

        if let location = Self.string(json, keys: ["url", "audio_url", "audioUrl", "file", "path", "output_path", "audio_path"]) {
            // Absolute local file path (the server runs on this Mac).
            if location.hasPrefix("/"), FileManager.default.fileExists(atPath: location) {
                return try Data(contentsOf: URL(fileURLWithPath: location))
            }
            // Absolute or server-relative URL.
            let fileURL = URL(string: location).flatMap { $0.host == nil ? nil : $0 }
                ?? baseURL.appendingPathComponent(location)
            let (fileData, fileResponse) = try await dataOrThrow(for: URLRequest(url: fileURL))
            try Self.checkHTTP(fileResponse, data: fileData)
            return fileData
        }

        let keys = json.keys.sorted().joined(separator: ", ")
        throw ClientError.unrecognizedAudioPayload("JSON keys: \(keys)")
    }

    private func dataOrThrow(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ClientError.serverUnreachable(error.localizedDescription)
        }
    }

    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            throw ClientError.badResponse(status: http.statusCode, body: body)
        }
    }

    private static func looksLikeAudio(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        let riff = data.prefix(4)
        let form = data.dropFirst(8).prefix(4)
        // "RIFF"...."WAVE", or an M4A/CAF/MP3/FLAC/OGG signature.
        if riff == Data("RIFF".utf8) && form == Data("WAVE".utf8) { return true }
        if data.prefix(4) == Data("caff".utf8) { return true }
        if data.prefix(4) == Data("fLaC".utf8) { return true }
        if data.prefix(4) == Data("OggS".utf8) { return true }
        if data.prefix(3) == Data("ID3".utf8) { return true }
        if data.dropFirst(4).prefix(4) == Data("ftyp".utf8) { return true }
        if data.prefix(2) == Data([0xFF, 0xFB]) || data.prefix(2) == Data([0xFF, 0xF3]) { return true }
        return false
    }

    private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
        }
        return nil
    }
}
