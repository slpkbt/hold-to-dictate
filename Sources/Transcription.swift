import Foundation
import AVFoundation
import Speech

@MainActor
protocol Transcription: AnyObject {
    var consume: (AVAudioPCMBuffer) -> Void { get }
    func finish()
    func cancel()
}

struct CodexAccount: Decodable {
    struct Tokens: Decodable {
        let access_token: String
        let account_id: String?
    }
    let auth_mode: String?
    let tokens: Tokens

    static func load() throws -> CodexAccount {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".codex", isDirectory: true)
        let path = directory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let account = try? JSONDecoder().decode(Self.self, from: data),
              account.auth_mode == nil || account.auth_mode == "chatgpt",
              !account.tokens.access_token.isEmpty else {
            throw DictationError("Войдите в Codex через ChatGPT с файловым хранилищем входа.")
        }
        return account
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct Transcript {
    private struct Segment {
        let revision: Int
        let text: String
        let isFinal: Bool
    }

    private var order: [String] = []
    private var segments: [String: Segment] = [:]

    var text: String {
        order.compactMap { segments[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    mutating func update(_ event: [String: Any], isFinal: Bool) throws {
        guard let id = event["utterance_id"] as? String,
              let text = event["text"] as? String,
              let revision = event["revision"] as? Int else {
            throw DictationError("Codex вернул незнакомый формат текста.")
        }
        if let current = segments[id] {
            guard !current.isFinal, revision > current.revision || (isFinal && revision == current.revision) else {
                return
            }
        } else {
            order.append(id)
        }
        segments[id] = Segment(revision: revision, text: text, isFinal: isFinal)
    }
}

@MainActor
final class CodexTranscription: Transcription {
    private enum Audio { case samples(Data), finish }

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let audio: AsyncStream<Audio>
    private let queue: AsyncStream<Audio>.Continuation
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var transcript = Transcript()
    private var finished = false
    private var stopping = false
    private let update: (String) -> Void
    private let complete: (Result<String, Error>) -> Void

    let consume: (AVAudioPCMBuffer) -> Void

    init(update: @escaping (String) -> Void, complete: @escaping (Result<String, Error>) -> Void) throws {
        self.update = update
        self.complete = complete

        let account = try CodexAccount.load()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)

        let url = URL(string: "wss://chatgpt.com/backend-api/dictation/stream?dictation_surface=composer&client_type=desktop")!
        var request = URLRequest(url: url)
        request.setValue("Bearer " + account.tokens.access_token, forHTTPHeaderField: "Authorization")
        request.setValue(account.tokens.account_id, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("chatgpt-dictation, codex-desktop", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("HoldToDictate/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                                               as? String ?? "dev"), forHTTPHeaderField: "User-Agent")
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576

        (audio, queue) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(256))
        let queue = self.queue
        let encoder = PCMEncoder()
        consume = { buffer in
            guard let bytes = encoder.encode(buffer) else { return }
            if case .dropped = queue.yield(.samples(bytes)) { queue.finish() }
        }
        socket.resume()
        work = Task { [weak self] in await self?.run() }
        armTimeout(12, message: "Codex долго не отвечает. Проверьте сеть и вход в Codex.")
    }

    func finish() {
        guard !finished, !stopping else { return }
        stopping = true
        if case .enqueued = queue.yield(.finish) {
            armTimeout(7, message: "Codex не завершил расшифровку.")
        } else {
            resolve(.failure(DictationError("Не удалось отправить всю запись.")))
        }
    }

    func cancel() {
        finished = true
        queue.finish()
        timeout?.cancel()
        work?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func run() async {
        do {
            try await send([
                "type": "session.start",
                "config": [
                    "input_audio_format": "pcm16", "sample_rate_hz": 24_000, "num_channels": 1,
                    "max_buffer_size_bytes": 4_194_304, "max_utterance_duration_ms": 30_000,
                    "session_ttl_ms": 300_000, "provider_mode": "streaming_sse",
                    "transcript_delivery_mode": "segment",
                    "vad": ["type": "server_vad", "threshold": 0.5,
                            "prefix_padding_ms": 300, "silence_duration_ms": 500]
                ]
            ])
            var event = try await receive()
            while event["type"] as? String != "session.started" {
                try handle(event)
                guard !finished else { return }
                event = try await receive()
            }
            if !stopping { timeout?.cancel() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.sendAudio() }
                group.addTask { try await self.receiveTranscript() }
                do {
                    _ = try await group.next()
                    _ = try await group.next()
                } catch {
                    group.cancelAll()
                    self.socket.cancel(with: .goingAway, reason: nil)
                    throw error
                }
            }
            resolve(.success(transcript.text))
        } catch {
            resolve(.failure(error is DictationError ? error : DictationError(
                "Соединение с диктовкой Codex недоступно. Проверьте сеть и вход в Codex."
            )))
        }
    }

    private func sendAudio() async throws {
        for await command in audio {
            switch command {
            case let .samples(bytes):
                try await append(bytes)
            case .finish:
                // Trailing silence lets VAD flush the last utterance as in Codex Desktop.
                try await append(Data(count: 12_000))
                try await send(["type": "session.close"])
                return
            }
        }
        throw DictationError("Не удалось отправить всю запись.")
    }

    private func receiveTranscript() async throws {
        while !Task.isCancelled {
            let event = try await receive()
            if event["type"] as? String == "session.updated",
               let session = event["session"] as? [String: Any], session["status"] as? String == "closed" {
                guard stopping else { throw DictationError("Codex досрочно закрыл диктовку.") }
                return
            }
            try handle(event)
        }
    }

    private func handle(_ event: [String: Any]) throws {
        let type = event["type"] as? String
        switch type {
        case "transcript.segment", "transcript.final":
            try transcript.update(event, isFinal: type == "transcript.final")
            update(transcript.text)
        case "transcript.failed":
            throw DictationError("Codex не смог распознать часть записи.")
        case "error":
            throw DictationError("Codex отклонил сеанс диктовки.")
        case "session.error":
            if event["fatal"] as? Bool != false {
                throw DictationError("Codex отклонил сеанс диктовки.")
            }
        default: break
        }
    }

    private func receive() async throws -> [String: Any] {
        guard case let .string(text) = try await socket.receive(),
              let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw DictationError("Codex вернул незнакомый формат ответа.")
        }
        return event
    }

    private func append(_ data: Data) async throws {
        try await send(["type": "audio.append", "audio": data.base64EncodedString()])
    }

    private func send(_ event: [String: Any]) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private func armTimeout(_ seconds: Int, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.resolve(.failure(DictationError(message))) }
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        guard !finished else { return }
        cancel()
        complete(result)
    }
}

@MainActor
final class DeviceTranscription: Transcription {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var finishing = false
    private var latest = ""
    private let complete: (Result<String, Error>) -> Void

    var consume: (AVAudioPCMBuffer) -> Void {
        let request = self.request
        return { request.append($0) }
    }

    init(language: String, update: @escaping (String) -> Void,
         complete: @escaping (Result<String, Error>) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw DictationError("Локальное распознавание для этого языка недоступно.")
        }
        self.recognizer = recognizer
        self.complete = complete
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            Task { @MainActor in
                guard let self, self.task != nil else { return }
                if let text {
                    self.latest = text
                    update(text)
                }
                if final || (self.finishing && error != nil && !self.latest.isEmpty) {
                    self.resolve(.success(self.latest))
                } else if error != nil {
                    self.resolve(.failure(DictationError("Локальная расшифровка прервалась.")))
                }
            }
        }
    }

    func finish() {
        finishing = true
        request.endAudio()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, let self { self.resolve(.success(self.latest)) }
        }
    }

    func cancel() {
        timeout?.cancel()
        task?.cancel()
        task = nil
    }

    private func resolve(_ result: Result<String, Error>) {
        guard task != nil else { return }
        cancel()
        complete(result)
    }
}
