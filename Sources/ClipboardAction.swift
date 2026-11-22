import AppKit
import Foundation

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
        if let data = board.data(forType: .png), NSImage(data: data) != nil { return .image(data) }
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
        for type in imageTypes {
            if let data = board.data(forType: type), let image = NSImage(data: data),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) { return .image(png) }
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
                    settings: Settings.ClipboardAction, resourceDirectory: URL? = nil) throws -> ClipboardAgentResult {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hold-to-dictate-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let kind: String
        var input: [String: String] = ["instruction": instruction]
        switch payload {
        case .text(let text): kind = "text"; input["text"] = text
        case .image(let bytes):
            kind = edit ? "edit" : "analyze"
            try bytes.write(to: directory.appendingPathComponent("input.png"))
        }
        guard let resource = (resourceDirectory ?? Bundle.main.resourceURL)?.appendingPathComponent("clipboard-agent/\(kind).txt"),
              let template = try? String(contentsOf: resource, encoding: .utf8) else {
            throw DictationError("Не найден шаблон действия с буфером обмена.")
        }
        let json = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let prompt = template + "\n" + String(decoding: json, as: UTF8.self)
        let environment = try invoke(prompt: prompt, payload: payload, kind: kind, settings: settings, directory: directory)
        if kind == "edit" {
            return .image(try generatedImage(eventsURL: directory.appendingPathComponent("events.jsonl"),
                                             directory: directory, environment: environment))
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

    private static func invoke(prompt: String, payload: ClipboardPayload, kind: String,
                               settings: Settings.ClipboardAction, directory: URL) throws -> [String: String] {
        let manager = FileManager.default
        let process = Process()
        let executable = settings.executable?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundled = [
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
        if kind == "edit" { arguments += ["--enable", "image_generation", "--json"] }
        else { arguments += ["--disable", "image_generation"] }
        arguments += ["-o", "reply.txt"]
        if case .image = payload { arguments += ["--image", "input.png"] }
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
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        manager.createFile(atPath: eventsURL.path, contents: nil)
        let events = try FileHandle(forWritingTo: eventsURL)
        defer { try? events.close() }
        process.standardOutput = kind == "edit" ? events : FileHandle.nullDevice
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        try? events.synchronize()
        guard process.terminationStatus == 0 else { throw DictationError("Codex CLI не выполнил действие.") }
        return environment
    }

    static func generatedImage(eventsURL: URL, directory: URL, environment: [String: String]) throws -> Data {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: eventsURL.path)[.size]) as? NSNumber,
              size.intValue <= 10_000_000,
              let log = try? String(contentsOf: eventsURL, encoding: .utf8) else {
            throw DictationError("Codex не вернул сведения об изображении.")
        }
        let threadID = log.split(separator: "\n").compactMap { line -> String? in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["type"] as? String == "thread.started",
                  let id = object["thread_id"] as? String, UUID(uuidString: id) != nil else { return nil }
            return id
        }.first
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let cache = codexHome.resolvingSymlinksInPath().appendingPathComponent("generated_images", isDirectory: true)
        let roots = [threadID.map { cache.appendingPathComponent($0, isDirectory: true) },
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
