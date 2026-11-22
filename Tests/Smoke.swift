import AppKit
import AVFoundation
import Carbon
import Foundation

@main
struct Smoke {
    static func main() throws {
        let shortcut = try Shortcut("cmd+shift+k")
        precondition(shortcut.keyCode == UInt32(kVK_ANSI_K))
        precondition(shortcut.carbonModifiers == UInt32(cmdKey | shiftKey))
        precondition((try? Shortcut("super+k")) == nil)

        var textGesture = ClipboardGesture(image: false)
        precondition(textGesture.press(0) == .start)
        precondition(textGesture.release(0.1) == .finish)
        var hold = ClipboardGesture(image: true)
        precondition(hold.press(0) == .start)
        precondition(hold.release(0.5) == .finish)
        var single = ClipboardGesture(image: true)
        precondition(single.press(0) == .start)
        precondition(single.release(0.1) == .none)
        precondition(single.press(0.6) == .finish)
        var double = ClipboardGesture(image: true)
        precondition(double.press(0) == .start)
        precondition(double.release(0.1) == .none)
        precondition(double.press(0.2) == .edit)
        precondition(double.release(0.25) == .none)
        precondition(double.press(0.7) == .finish)
        var doubleHold = ClipboardGesture(image: true)
        precondition(doubleHold.press(0) == .start)
        precondition(doubleHold.release(0.1) == .none)
        precondition(doubleHold.press(0.2) == .edit)
        precondition(doubleHold.release(0.6) == .finish)
        let board = NSPasteboard(name: NSPasteboard.Name("smoke-" + UUID().uuidString))
        board.clearContents()
        if board.setString("hello", forType: .string) {
            guard case .text("hello") = ClipboardPayload.capture(board) else { fatalError("text clipboard") }
            board.clearContents()
            if board.setString("file:///tmp/example.png", forType: .fileURL) {
                if case nil = ClipboardPayload.capture(board) {} else { fatalError("file clipboard") }
            }
        } else { print("Pasteboard service unavailable; clipboard integration skipped") }
        board.releaseGlobally()

        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("clipboard-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("clipboard-agent"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "template".write(to: fixture.appendingPathComponent("clipboard-agent/text.txt"), atomically: true, encoding: .utf8)
        try "template".write(to: fixture.appendingPathComponent("clipboard-agent/edit.txt"), atomically: true, encoding: .utf8)
        let cli = fixture.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        cat >/dev/null
        printf '  unchanged leading spaces\\n' > reply.txt
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let config = Settings.ClipboardAction(shortcut: "cmd+shift+l", model: "test", effort: "low", executable: cli.path)
        guard case .text("  unchanged leading spaces") = try ClipboardAgent.run(payload: .text("source"), instruction: "edit", edit: false, settings: config, resourceDirectory: fixture) else { fatalError("CLI text result") }

        let thread = UUID().uuidString
        let otherThread = UUID().uuidString
        let imageRoot = fixture.appendingPathComponent("codex/generated_images", isDirectory: true)
        let wrongRoot = imageRoot.appendingPathComponent(otherThread, isDirectory: true)
        let rightRoot = imageRoot.appendingPathComponent(thread, isDirectory: true)
        try FileManager.default.createDirectory(at: wrongRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightRoot, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let wrong = wrongRoot.appendingPathComponent("image.png")
        try png.write(to: wrong)
        let events = fixture.appendingPathComponent("events.jsonl")
        try "{\"type\":\"thread.started\",\"thread_id\":\"\(thread)\"}\n".write(to: events, atomically: true, encoding: .utf8)
        let environment = ["CODEX_HOME": fixture.appendingPathComponent("codex").path]
        precondition((try? ClipboardAgent.generatedImage(eventsURL: events, directory: fixture, environment: environment)) == nil)
        let image = rightRoot.appendingPathComponent("image.png")
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: wrong)
        precondition((try? ClipboardAgent.generatedImage(eventsURL: events, directory: fixture, environment: environment)) == nil)
        try FileManager.default.removeItem(at: image)
        try Data("not a png".utf8).write(to: image)
        precondition((try? ClipboardAgent.generatedImage(eventsURL: events, directory: fixture, environment: environment)) == nil)
        try png.write(to: image)
        let selectedImage = try ClipboardAgent.generatedImage(eventsURL: events, directory: fixture, environment: environment)
        precondition(selectedImage == png)

        var transcript = Transcript()
        try transcript.update(["utterance_id": "one", "revision": 1, "text": "Раз"], isFinal: false)
        try transcript.update(["utterance_id": "two", "revision": 1, "text": "Три."], isFinal: false)
        try transcript.update(["utterance_id": "one", "revision": 2, "text": "Раз, два."], isFinal: true)
        try transcript.update(["utterance_id": "one", "revision": 1, "text": "Раз"], isFinal: false)
        precondition(transcript.text == "Раз, два. Три.")

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        input.frameLength = 4_800
        for index in 0..<4_800 {
            input.floatChannelData![0][index] = 0.1 * sin(Float(index) * 0.05)
        }

        let encoder = PCMEncoder()
        guard let first = encoder.encode(input), let second = encoder.encode(input) else {
            throw DictationError("PCM conversion failed.")
        }
        precondition((4_000...4_900).contains(first.count))
        precondition((4_700...4_900).contains(second.count))
        precondition(first.contains { $0 != 0 })
        print("Shortcut, transcript revisions and 24 kHz PCM: OK")
    }
}
