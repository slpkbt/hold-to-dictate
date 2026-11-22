import AppKit
import Foundation
import ImageIO

enum ClipboardPayload {
    case text(String)
    case image(Data)

    static func capture(_ board: NSPasteboard) -> ClipboardPayload? {
        // File URLs and file promises are not image content, even if Finder supplies a preview.
        let items = board.pasteboardItems ?? []
        guard !items.isEmpty, !items.contains(where: { item in
            item.types.contains(.fileURL) || item.types.contains { type in
                let name = type.rawValue.lowercased()
                return name.contains("promised-file") || name.contains("filepromise") || name == "nsfilenamespboardtype"
            }
        }) else { return nil }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")
        ]
        for type in imageTypes {
            if let data = board.data(forType: type), CGImageSourceCreateWithData(data as CFData, nil) != nil {
                return .image(data)
            }
        }
        if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        return nil
    }
}

// A short first image press latches recording; a quick second press selects edit.
struct ClipboardGesture {
    enum Action: Equatable { case none, start, edit, finish }
    private var downAt: TimeInterval?
    private var firstRelease: TimeInterval?
    private var second = false
    private var latched = false
    private let image: Bool
    init(image: Bool) { self.image = image }
    mutating func press(_ time: TimeInterval) -> Action {
        if downAt != nil { return .none }
        if let released = firstRelease, image {
            if !second && time - released <= 0.35 {
                second = true
                downAt = time
                return .edit
            }
            if latched { return .finish }
        }
        downAt = time
        return .start
    }
    mutating func release(_ time: TimeInterval) -> Action {
        guard let down = downAt else { return .none }
        downAt = nil
        guard image else { return .finish }
        if time - down >= 0.35 { return .finish }
        if !second { firstRelease = time }
        latched = true
        return .none
    }
}

enum ClipboardAgentResult { case text(String), image(Data) }

enum ClipboardAgent {
    private static let lock = NSLock()
    private static var running: [Process] = []

    static func cancelAll() {
        lock.lock()
        let processes = running
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }

    static func run(payload: ClipboardPayload, instruction: String, edit: Bool,
                    settings: Settings.ClipboardAction, resourceDirectory: URL? = nil,
                    preparedImage: ClipboardImage.Packed? = nil,
                    onProgress: @escaping (String) -> Void = { _ in },
                    onReady: @escaping (String) -> Void = { _ in },
                    bundledExecutable: URL? = nil) throws -> ClipboardAgentResult {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hold-to-dictate-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let kind: String
        var imagePath: String?
        var input: [String: String] = ["instruction": instruction]
        switch payload {
        case .text(let text): kind = "text"; input["text"] = text
        case .image(let bytes):
            kind = edit ? "edit" : "analyze"
            if edit {
                imagePath = "input.png"
                try ClipboardImage.pngForCLI(bytes).write(to: directory.appendingPathComponent("input.png"))
            } else {
                let image = try preparedImage ?? ClipboardImage.forAnalysis(bytes)
                let name = image.mime == "image/jpeg" ? "input.jpg" : "input.png"
                imagePath = name
                try image.data.write(to: directory.appendingPathComponent(name))
            }
        }
        guard let resource = (resourceDirectory ?? Bundle.main.resourceURL)?.appendingPathComponent("clipboard-agent/\(kind).txt"),
              let template = try? String(contentsOf: resource, encoding: .utf8) else {
            throw DictationError("Не найден шаблон действия с буфером обмена.")
        }
        if let preferences = settings.instructions, !preferences.isEmpty {
            input["preferences"] = preferences
        }
        let json = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let customExecutable = !(settings.executable?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let fast = kind != "edit" && !customExecutable
        let payloadJSON = String(decoding: json, as: UTF8.self)
        let prompt = fast ? payloadJSON : template + "\n" + payloadJSON
        let threadID = try invoke(prompt: prompt, imagePath: imagePath, kind: kind,
                                     settings: settings, directory: directory, bundledExecutable: bundledExecutable,
                                     instructionFile: fast ? resource : nil,
                                     onProgress: onProgress, onReady: fast ? onReady : { _ in })
        if kind == "edit" {
            return .image(try generatedImage(threadID: threadID, directory: directory,
                                             environment: ProcessInfo.processInfo.environment))
        }
        guard let reply = try? String(contentsOf: directory.appendingPathComponent("reply.txt"), encoding: .utf8),
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationError("Codex вернул пустой ответ.")
        }
        var output = reply
        if output.hasSuffix("\n") {
            output.removeLast()
            if output.hasSuffix("\r") { output.removeLast() }
        }
        return .text(output)
    }

    private static func invoke(prompt: String, imagePath: String?, kind: String,
                               settings: Settings.ClipboardAction, directory: URL, bundledExecutable: URL?, instructionFile: URL?,
                               onProgress: @escaping (String) -> Void, onReady: @escaping (String) -> Void) throws -> String? {
        let parseEvents = instructionFile != nil || kind == "edit"
        let manager = FileManager.default
        let process = Process()
        let executable = settings.executable?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundled = bundledExecutable?.path ?? [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ].first { manager.isExecutableFile(atPath: $0) }
        let path = executable?.isEmpty == false ? (executable! as NSString).expandingTildeInPath : bundled
        process.executableURL = URL(fileURLWithPath: path ?? "/usr/bin/env")
        var arguments = path == nil ? ["codex"] : []
        arguments += [
            "-a", "never", "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--skip-git-repo-check", "-c", "default_permissions=\"clipboard\"",
            "-c", "permissions.clipboard.filesystem={\":root\"=\"deny\", \":workspace_roots\"={\".\"=\"read\"}}",
            "-c", "permissions.clipboard.network.enabled=false", "-c", "project_doc_max_bytes=0",
            "-c", "mcp_servers={}", "--model", settings.model,
            "-c", "model_reasoning_effort=\"\(settings.effort)\"", "-c", "web_search=\"disabled\""
        ]
        for feature in ["shell_tool", "unified_exec", "plugins", "apps", "hooks", "multi_agent",
                        "view_image", "browser_use", "computer_use"] {
            arguments += ["--disable", feature]
        }
        if let instructionFile {
            let jsonString = try JSONSerialization.data(withJSONObject: [instructionFile.path], options: [.withoutEscapingSlashes])
            let quoted = String(decoding: jsonString, as: UTF8.self).dropFirst().dropLast()
            arguments += ["--enable", "skip_host_skill_discovery", "--disable", "tool_suggest",
                          "-c", "analytics.enabled=false", "-c", "include_apps_instructions=false",
                          "-c", "include_environment_context=false", "-c", "include_collaboration_mode_instructions=false",
                          "-c", "skills.include_instructions=false",
                          "-c", "model_instructions_file=\(quoted)"]
        }
        if kind != "edit", settings.serviceTier == "priority" {
            arguments += ["-c", "service_tier=\"priority\""]
        }
        if kind == "edit" { arguments += ["--enable", "image_generation"] }
        else { arguments += ["--disable", "image_generation"] }
        arguments += ["--json"]
        arguments += ["-o", "reply.txt"]
        if let imagePath { arguments += ["--image", imagePath] }
        arguments += ["-"]
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let home = manager.homeDirectoryForCurrentUser.path
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:" + home + "/.local/bin"
        process.environment = environment
        let promptURL = directory.appendingPathComponent("prompt.txt")
        try Data(prompt.utf8).write(to: promptURL)
        let stdin = try FileHandle(forReadingFrom: promptURL)
        defer { try? stdin.close() }
        process.standardInput = stdin
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DictationError("Не удалось запустить Codex CLI. Проверьте executable в настройках.") }
        lock.lock()
        running.append(process)
        lock.unlock()
        defer {
            lock.lock()
            running.removeAll { $0 === process }
            lock.unlock()
        }
        let timeout = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (kind == "edit" ? 300 : 120), execute: timeout)
        var events = CLIEventStream()
        var streamError: Error?
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            if !parseEvents { continue }
            do { try events.feed(data, onProgress: onProgress, onReady: onReady) }
            catch {
                streamError = error
                if process.isRunning { process.terminate() }
                break
            }
        }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        timeout.cancel()
        if let streamError { throw streamError }
        if parseEvents { try events.finish(onProgress: onProgress, onReady: onReady) }
        guard process.terminationStatus == 0, !events.failed, instructionFile == nil || events.succeeded else {
            throw DictationError("Codex CLI не выполнил действие.")
        }
        return events.threadID
    }

    static func generatedImage(threadID: String?, directory: URL, environment: [String: String]) throws -> Data {
        let manager = FileManager.default
        let validID = threadID.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let cache = codexHome.resolvingSymlinksInPath().appendingPathComponent("generated_images", isDirectory: true)
        let roots = [validID.map { cache.appendingPathComponent($0, isDirectory: true) },
                     directory.appendingPathComponent("generated_images", isDirectory: true)].compactMap { $0 }
        let candidates = roots.flatMap { root -> [URL] in
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            guard canonical == root.standardizedFileURL,
                  let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]) else { return [] }
            return urls.filter { url in
                guard url.pathExtension.lowercased() == "png", url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent() == canonical,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 8, size <= 64_000_000 else { return false }
                return true
            }
        }
        let newest = candidates.max { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ad < bd
        }
        guard let newest, let data = try? Data(contentsOf: newest),
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), NSImage(data: data) != nil else {
            throw DictationError("Codex не вернул изображение.")
        }
        return data
    }
}

// Codex exec --json emits JSONL; stdout is drained while the child is running.
struct CLIEventStream {
    private var buffer = Data()
    private var received = 0
    private(set) var threadID: String?
    private(set) var failed = false
    private(set) var succeeded = false
    private var completedMessage: String?
    private var delivered = false

    mutating func feed(_ data: Data, onProgress: (String) -> Void,
                       onReady: (String) -> Void = { _ in }) throws {
        received += data.count
        guard received <= 10_000_000 else { throw DictationError("Codex вернул слишком большой поток событий.") }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            try parse(line, onProgress: onProgress, onReady: onReady)
        }
        guard buffer.count <= 1_000_000 else { throw DictationError("Codex вернул слишком большое событие.") }
    }

    mutating func finish(onProgress: (String) -> Void, onReady: (String) -> Void = { _ in }) throws {
        if !buffer.isEmpty { try parse(buffer, onProgress: onProgress, onReady: onReady); buffer.removeAll() }
    }

    private mutating func parse(_ line: Data, onProgress: (String) -> Void, onReady: (String) -> Void) throws {
        guard !line.isEmpty else { return }
        guard line.count <= 1_000_000,
              let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else {
            throw DictationError("Codex вернул незнакомый поток событий.")
        }
        if type == "thread.started", let id = event["thread_id"] as? String, UUID(uuidString: id) != nil {
            threadID = id
        } else if type == "turn.failed" || type == "error" {
            failed = true
        } else if type == "turn.completed", !failed {
            succeeded = true
            if !delivered, let text = completedMessage,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                delivered = true
                onReady(text)
            }
        } else if type == "item.updated" || type == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, !text.isEmpty {
            if type == "item.completed" { completedMessage = text }
            onProgress(text)
        }
    }
}
