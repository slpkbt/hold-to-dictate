import AppKit
import Carbon

struct Settings: Decodable {
    let shortcut: String
    let language: String?
    let pasteAutomatically: Bool
    let playSound: Bool
    let startSound: String?
    let appearance: Appearance
    let engine: Engine
    let clipboardAction: ClipboardAction

    struct ClipboardAction: Decodable {
        let shortcut: String
        let model: String
        let effort: String
        let executable: String?
        var instructions: String? = nil
        var serviceTier: String? = nil
    }

    enum Engine: String, Decodable { case codex, onDevice }

    struct Appearance: Decodable {
        let textColor: String
        let backgroundOpacity: Double
        let width: Double
        let textSize: Double
        let maxLines: Int
        let verticalOffset: Double
        let horizontalOffset: Double
        let reduceMotion: Bool

        var color: NSColor {
            guard textColor.count == 7, textColor.hasPrefix("#"),
                  let value = UInt32(textColor.dropFirst(), radix: 16) else {
                return NSColor(srgbRed: 0.66, green: 0.85, blue: 1, alpha: 1)
            }
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hold to Dictate", isDirectory: true)
    static let file = directory.appendingPathComponent("settings.json")

    static func load() throws -> Settings {
        let defaultsURL = Bundle.main.url(forResource: "settings", withExtension: "json")!
        let defaults = try JSONSerialization.jsonObject(with: Data(contentsOf: defaultsURL)) as! [String: Any]
        var merged = defaults
        if FileManager.default.fileExists(atPath: file.path) {
            let local = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            guard let local else { throw DictationError("В settings.json ожидается JSON-объект.") }
            for (key, value) in local {
                if (key == "appearance" || key == "clipboardAction"), let appearance = value as? [String: Any],
                   let fallback = defaults[key] as? [String: Any] {
                    merged[key] = fallback.merging(appearance) { _, new in new }
                } else {
                    merged[key] = value
                }
            }
        }
        return try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    static func openFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(
                at: Bundle.main.url(forResource: "settings", withExtension: "json")!, to: file
            )
        }
        NSWorkspace.shared.open(file)
    }
}

struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Shortcut {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let flags: CGEventFlags

    init(_ value: String) throws {
        let parts = value.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = Self.keys[key], parts.count > 1 else {
            throw DictationError("Укажите сочетание клавиш, например cmd+shift+k.")
        }
        keyCode = code
        var carbon: UInt32 = 0
        var flags: CGEventFlags = []
        for modifier in Set(parts.dropLast()) {
            switch modifier {
            case "cmd": carbon |= UInt32(cmdKey); flags.insert(.maskCommand)
            case "shift": carbon |= UInt32(shiftKey); flags.insert(.maskShift)
            case "opt": carbon |= UInt32(optionKey); flags.insert(.maskAlternate)
            case "ctrl": carbon |= UInt32(controlKey); flags.insert(.maskControl)
            default: throw DictationError("Неизвестный модификатор сочетания клавиш.")
            }
        }
        carbonModifiers = carbon
        self.flags = flags
    }

    private static let keys: [String: UInt32] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "space": 49, "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111
    ]
}
