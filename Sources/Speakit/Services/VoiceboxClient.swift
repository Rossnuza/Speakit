import Foundation

/// Thin client for the Voicebox (https://voicebox.sh) local REST API.
///
/// Voicebox is a free, open-source AI voice studio that runs entirely on
/// this Mac and serves a REST API on http://127.0.0.1:17493 (see its
/// Settings, and http://127.0.0.1:17493/docs for the live API reference).
///
/// Generation is job-based and non-blocking: POST /generate returns a
/// generation record (id, status, audio_path, versions, …) immediately,
/// and the audio_path fills in once the render finishes. This client
/// polls the record until it's done, then downloads the audio. It is
/// deliberately tolerant about endpoint and payload shapes so it keeps
/// working across Voicebox versions.
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
        case generationFailed(String)
        case generationTimedOut(String)
        case pollingUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .serverUnreachable(let detail):
                return "Couldn't reach the Voicebox server. Make sure the Voicebox app is running (and its API server is enabled in Voicebox's settings). \(detail)"
            case .badResponse(let status, let body):
                return "Voicebox returned HTTP \(status): \(body.prefix(300))"
            case .unrecognizedAudioPayload(let detail):
                return "Voicebox replied, but the audio payload wasn't recognized (\(detail)). Check http://127.0.0.1:17493/docs for your version's API format."
            case .generationFailed(let reason):
                return "Voicebox couldn't generate this audio: \(reason)"
            case .generationTimedOut(let trace):
                return "Voicebox is taking too long to render this audio. Large models can be slow on first use while they load — try again in a moment. Recent API activity: \(trace)"
            case .pollingUnsupported(let detail):
                return "Voicebox accepted the request but Speakit couldn't find its status endpoint to wait for the result (\(detail)). Check http://127.0.0.1:17493/docs and report the /generate flow shown there."
            }
        }
    }

    var baseURL: URL {
        let stored = UserDefaults.standard.string(forKey: "voiceboxBaseURL") ?? ""
        return URL(string: stored.isEmpty ? Self.defaultBaseURLString : stored)
            ?? URL(string: Self.defaultBaseURLString)!
    }

    private let session: URLSession

    /// Path template (with %@ for the generation id) that worked for
    /// polling, discovered on first use.
    private var cachedPollTemplate: String?

    /// Engines learned from "profile X only supports engine 'Y'" errors,
    /// keyed by profile id, so we only pay the failed round-trip once.
    private var learnedEngines: [String: String] = [:]

    /// Set once POST /generate/stream 404s, so older servers skip
    /// straight to the job-based flow.
    private var streamUnsupported = false

    /// Ring buffer of recent HTTP interactions, included in timeout
    /// errors so problems are diagnosable from the error message alone.
    private var requestTrace: [String] = []
    private let traceLock = NSLock()

    private func note(_ entry: String) {
        traceLock.lock()
        requestTrace.append(entry)
        if requestTrace.count > 14 { requestTrace.removeFirst() }
        traceLock.unlock()
        NSLog("Speakit/Voicebox: \(entry)")
    }

    private func traceSummary() -> String {
        traceLock.lock()
        defer { traceLock.unlock() }
        return requestTrace.joined(separator: " | ")
    }

    /// How long to wait for a render before giving up. First-time model
    /// loads can take a while.
    private let generationTimeout: TimeInterval = 300
    private let pollInterval: TimeInterval = 0.5

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
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
                engine: Self.string(dict, keys: ["default_engine", "engine", "tts_engine", "provider"]),
                language: Self.string(dict, keys: ["language", "lang", "locale"])
            )
        }
    }

    // MARK: - Speech generation

    /// Renders `text` with the given profile and returns playable audio
    /// data (WAV). Handles both immediate-audio responses and Voicebox's
    /// job-based flow (create → poll status → download audio_path).
    ///
    /// Voicebox validates that the request's TTS `engine` matches the
    /// profile's engine, so we pass the profile's engine when known and
    /// self-correct from the server's error message when not.
    func generate(text: String, profileID: String?, engine: String? = nil) async throws -> Data {
        var effectiveEngine = engine ?? profileID.flatMap { learnedEngines[$0] }

        // Selections saved without an engine (or by older Speakit builds)
        // self-heal by looking the profile up once.
        if effectiveEngine == nil, let profileID {
            if let profile = try? await fetchProfiles().first(where: { $0.id == profileID }),
               let profileEngine = profile.engine {
                effectiveEngine = profileEngine
                learnedEngines[profileID] = profileEngine
            }
        }

        do {
            return try await submitGeneration(text: text, profileID: profileID, engine: effectiveEngine)
        } catch ClientError.badResponse(let status, let body) {
            // e.g. {"detail":"Preset profile … only supports engine 'kokoro', not 'qwen'"}
            if status == 400,
               let required = Self.requiredEngine(inErrorBody: body),
               required != effectiveEngine {
                if let profileID { learnedEngines[profileID] = required }
                return try await submitGeneration(text: text, profileID: profileID, engine: required)
            }
            throw ClientError.badResponse(status: status, body: body)
        }
    }

    private func submitGeneration(text: String, profileID: String?, engine: String?) async throws -> Data {
        let body = Self.requestBody(text: text, profileID: profileID, engine: engine)

        // Preferred: POST /generate/stream returns the WAV directly —
        // no polling, and nothing added to the user's Voicebox history.
        if !streamUnsupported {
            do {
                return try await postForAudio(path: "generate/stream", body: body)
            } catch ClientError.badResponse(let status, let bodyText) {
                if status == 404 || status == 405 {
                    streamUnsupported = true // older server; use the job flow
                } else {
                    throw ClientError.badResponse(status: status, body: bodyText)
                }
            }
        }

        // Fallback: POST /generate creates a job; the finished audio is
        // served at GET /audio/{generation_id}.
        var request = URLRequest(url: baseURL.appendingPathComponent("generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("speakit", forHTTPHeaderField: "X-Voicebox-Client-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataOrThrow(for: request)
        try Self.checkHTTP(response, data: data)

        if Self.looksLikeAudio(data) {
            return data
        }
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.unrecognizedAudioPayload("neither audio bytes nor JSON")
        }
        if let failure = Self.failureMessage(in: record) {
            throw ClientError.generationFailed(failure)
        }
        if let audio = try await resolveAudio(in: record) {
            return audio
        }
        guard let jobID = Self.string(record, keys: ["id", "generation_id", "generationId", "job_id", "jobId"]) else {
            let keys = record.keys.sorted().joined(separator: ", ")
            throw ClientError.unrecognizedAudioPayload("JSON keys: \(keys)")
        }
        return try await pollForAudio(jobID: jobID)
    }

    /// POSTs a generation request to an endpoint that answers with raw
    /// audio bytes (the /generate/stream route).
    private func postForAudio(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("speakit", forHTTPHeaderField: "X-Voicebox-Client-Id")
        request.timeoutInterval = generationTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataOrThrow(for: request)
        try Self.checkHTTP(response, data: data)

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard Self.looksLikeAudio(data) || (contentType.contains("audio") && data.count > 200) else {
            let bodyText = String(data: data.prefix(300), encoding: .utf8) ?? "\(data.count) bytes"
            throw ClientError.generationFailed("the stream endpoint answered with: \(bodyText)")
        }
        return data
    }

    private static func requestBody(text: String, profileID: String?, engine: String?) -> [String: Any] {
        var body: [String: Any] = ["text": text]
        if let profileID {
            body["profile_id"] = profileID
        }
        if let engine, !engine.isEmpty {
            body["engine"] = engine
        }
        return body
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

    // MARK: - Job polling

    private static let pollTemplates = [
        "generations/%@",
        "generation/%@",
        "generate/%@",
        "jobs/%@",
        "history/%@"
    ]

    private func pollForAudio(jobID: String) async throws -> Data {
        let deadline = Date().addingTimeInterval(generationTimeout)
        let audioURL = baseURL.appendingPathComponent("audio").appendingPathComponent(jobID)

        // Preferred: follow the server-sent-events status stream at
        // GET /generate/{id}/status — it reports completed/failed (with
        // the server's error text) the moment it happens.
        do {
            try await followStatusStream(jobID: jobID)
            for _ in 0..<6 {
                if let data = try? await fetchAudioData(from: audioURL), let data {
                    return data
                }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        } catch let error as ClientError {
            if case .generationFailed = error { throw error }
            // Other client errors: fall through to dumb polling below.
        } catch {
            // SSE hiccup (unsupported endpoint, idle timeout…): fall back.
            note("status stream failed: \(error.localizedDescription)")
        }

        // Fallback: poll GET /audio/{generation_id} until it exists.
        var attempt = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            attempt += 1

            if let data = try? await fetchAudioData(from: audioURL), let data {
                return data
            }

            // Every few attempts, look up the record itself so a failed
            // generation aborts promptly instead of waiting for timeout.
            if attempt % 6 == 0, let record = try? await fetchGenerationRecord(id: jobID), let record {
                if let failure = Self.failureMessage(in: record) {
                    throw ClientError.generationFailed(failure)
                }
                if let audio = try await resolveAudio(in: record) {
                    return audio
                }
            }
        }
        throw ClientError.generationTimedOut(traceSummary())
    }

    /// Reads the SSE stream at GET /generate/{id}/status until the
    /// generation completes (returns) or fails (throws generationFailed).
    private func followStatusStream(jobID: String) async throws {
        let url = baseURL.appendingPathComponent("generate")
            .appendingPathComponent(jobID)
            .appendingPathComponent("status")
        var request = URLRequest(url: url)
        request.timeoutInterval = generationTimeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            note("GET \(url.path) → \(status) (status stream unavailable)")
            throw ClientError.badResponse(status: status, body: "status stream unavailable")
        }
        note("GET \(url.path) → SSE open")

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                continue
            }
            let status = (Self.string(event, keys: ["status", "state"]) ?? "").lowercased()
            if status.contains("fail") || status.contains("error") || status.contains("cancel") {
                let reason = Self.string(event, keys: ["error", "detail", "message"]) ?? "status was “\(status)”"
                note("SSE status: \(status) — \(reason)")
                throw ClientError.generationFailed(reason)
            }
            if status.contains("complet") || status.contains("done") || status.contains("succe") {
                note("SSE status: \(status)")
                return
            }
        }
        // Stream ended without a terminal status; let the audio fetch decide.
        note("SSE stream ended")
    }

    /// Fetches the generation record by id, discovering which endpoint
    /// this Voicebox version serves it on and caching the result.
    private func fetchGenerationRecord(id: String) async throws -> [String: Any]? {
        // Fast path: a template we already validated.
        if let template = cachedPollTemplate,
           let record = try? await getRecord(path: String(format: template, id)) {
            return record
        }

        // Discover: try each candidate detail endpoint.
        for template in Self.pollTemplates {
            if let record = try? await getRecord(path: String(format: template, id)) {
                cachedPollTemplate = template
                return record
            }
        }

        // Fall back to list endpoints and find our record by id.
        for listPath in ["generations", "history"] {
            guard let (data, response) = try? await dataOrThrow(
                for: URLRequest(url: baseURL.appendingPathComponent(listPath))
            ), (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
            let json = try? JSONSerialization.jsonObject(with: data) else { continue }

            let items: [Any]
            if let array = json as? [Any] {
                items = array
            } else if let dict = json as? [String: Any] {
                items = (dict["items"] as? [Any])
                    ?? (dict["generations"] as? [Any])
                    ?? (dict["data"] as? [Any]) ?? []
            } else {
                items = []
            }
            for case let item as [String: Any] in items
            where Self.string(item, keys: ["id", "generation_id", "generationId"]) == id {
                return item
            }
        }
        return nil
    }

    private func getRecord(path: String) async throws -> [String: Any]? {
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await dataOrThrow(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Audio extraction

    /// Pulls playable audio out of a generation record, if it's ready:
    /// base64 fields, the record's audio_path/url, or its versions list.
    private func resolveAudio(in record: [String: Any]) async throws -> Data? {
        // Embedded base64 audio.
        if let base64 = Self.string(record, keys: ["audio", "audio_base64", "audioBase64", "wav"]),
           let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           Self.looksLikeAudio(decoded) {
            return decoded
        }

        for location in audioLocations(in: record) {
            if let data = try await fetchAudio(atLocation: location) {
                return data
            }
        }

        // Voicebox serves finished audio at /audio/{generation_id} and
        // /audio/version/{version_id}.
        if let generationID = Self.string(record, keys: ["id", "generation_id", "generationId"]) {
            let url = baseURL.appendingPathComponent("audio").appendingPathComponent(generationID)
            if let data = try? await fetchAudioData(from: url), let data {
                return data
            }
        }
        if let versions = record["versions"] as? [[String: Any]] {
            for version in versions.reversed() {
                guard let versionID = Self.string(version, keys: ["id", "version_id", "versionId"]) else { continue }
                let url = baseURL.appendingPathComponent("audio")
                    .appendingPathComponent("version")
                    .appendingPathComponent(versionID)
                if let data = try? await fetchAudioData(from: url), let data {
                    return data
                }
            }
        }
        return nil
    }

    /// Collects candidate audio locations from the record itself and its
    /// versions array (preferring the active version, then the newest).
    private func audioLocations(in record: [String: Any]) -> [String] {
        var locations: [String] = []
        let keys = ["audio_path", "audioPath", "audio_url", "audioUrl", "url", "file", "path", "output_path", "outputPath"]

        if let direct = Self.string(record, keys: keys) {
            locations.append(direct)
        }

        if let versions = record["versions"] as? [[String: Any]], !versions.isEmpty {
            let activeID = Self.string(record, keys: ["active_version_id", "activeVersionId"])
            var ordered = versions
            if let activeID,
               let activeIndex = versions.firstIndex(where: { Self.string($0, keys: ["id", "version_id", "versionId"]) == activeID }) {
                ordered.swapAt(0, activeIndex)
            } else {
                ordered.reverse() // newest last in most APIs → check newest first
            }
            for version in ordered {
                if Self.failureMessage(in: version) != nil { continue }
                if let location = Self.string(version, keys: keys) {
                    locations.append(location)
                }
            }
        }
        return locations
    }

    /// Fetches audio bytes for a location that may be an absolute URL, a
    /// server-relative path, or a filesystem path on this Mac.
    private func fetchAudio(atLocation location: String) async throws -> Data? {
        // Absolute URL.
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            if let url = URL(string: location) {
                return try? await fetchAudioData(from: url)
            }
            return nil
        }

        // Filesystem path (the Voicebox server runs on this same Mac).
        if location.hasPrefix("/"), FileManager.default.fileExists(atPath: location) {
            let data = try Data(contentsOf: URL(fileURLWithPath: location))
            return Self.looksLikeAudio(data) ? data : nil
        }
        if location.hasPrefix("~") {
            let expanded = NSString(string: location).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
                return Self.looksLikeAudio(data) ? data : nil
            }
        }

        // Server-relative: try the path as-is, then common file routes.
        let trimmed = location.hasPrefix("/") ? String(location.dropFirst()) : location
        var candidates = [
            baseURL.appendingPathComponent(trimmed),
            baseURL.appendingPathComponent("audio").appendingPathComponent(trimmed),
            baseURL.appendingPathComponent("files").appendingPathComponent(trimmed)
        ]
        // Relative on-disk path inside Voicebox's data directory.
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for folder in ["Voicebox", "voicebox"] {
                let fileURL = appSupport.appendingPathComponent(folder).appendingPathComponent(trimmed)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    candidates.insert(fileURL, at: 0)
                }
            }
        }

        for candidate in candidates {
            if candidate.isFileURL {
                if let data = try? Data(contentsOf: candidate), Self.looksLikeAudio(data) {
                    return data
                }
            } else if let data = try? await fetchAudioData(from: candidate) {
                return data
            }
        }
        return nil
    }

    private func fetchAudioData(from url: URL) async throws -> Data? {
        let (data, response) = try await dataOrThrow(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return Self.looksLikeAudio(data) ? data : nil
    }

    // MARK: - Helpers

    /// Extracts the engine name from errors like
    /// "Preset profile … only supports engine 'kokoro', not 'qwen'".
    private static func requiredEngine(inErrorBody body: String) -> String? {
        for pattern in ["supports engine '([^']+)'", "requires engine '([^']+)'"] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: body, options: [],
                                            range: NSRange(body.startIndex..., in: body)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: body) {
                return String(body[range])
            }
        }
        return nil
    }

    /// A human-readable failure if the record reports one.
    private static func failureMessage(in record: [String: Any]) -> String? {
        if let error = string(record, keys: ["error", "error_message", "errorMessage", "failure_reason"]),
           !error.isEmpty {
            return error
        }
        if let status = string(record, keys: ["status", "state"])?.lowercased(),
           status.contains("fail") || status.contains("error") || status.contains("cancel") {
            return "generation status was “\(status)”"
        }
        return nil
    }

    private func dataOrThrow(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "?"
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var entry = "\(method) \(path) → \(status), \(data.count)B"
            if !Self.looksLikeAudio(data), status >= 300 || data.count < 600,
               let text = String(data: data.prefix(160), encoding: .utf8),
               !text.isEmpty {
                entry += " “\(text.replacingOccurrences(of: "\n", with: " "))”"
            }
            note(entry)
            return (data, response)
        } catch {
            note("\(method) \(path) → transport error: \(error.localizedDescription)")
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

    static func looksLikeAudio(_ data: Data) -> Bool {
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
