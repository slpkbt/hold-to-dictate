import AppKit
import AVFoundation
import Carbon
import Foundation
import ImageIO

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
        printf 'custom output is not JSON\\n'
        printf '  unchanged leading spaces\\n' > reply.txt
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let config = Settings.ClipboardAction(shortcut: "cmd+shift+l", model: "test", effort: "low", executable: cli.path)
        guard case .text("  unchanged leading spaces") = try ClipboardAgent.run(payload: .text("source"), instruction: "edit", edit: false, settings: config, resourceDirectory: fixture) else { fatalError("CLI text result") }

        let fastCLI = fixture.appendingPathComponent("fake-fast-codex")
        let fastScript = #"""
        #!/bin/sh
        case "$*" in *service_tier*priority*) ;; *) exit 41 ;; esac
        case "$*" in *model_instructions_file=*) ;; *) exit 45 ;; esac
        case "$*" in *--json*) ;; *) exit 46 ;; esac
        case "$*" in *skills.include_instructions=false*) ;; *) exit 42 ;; esac
        payload=$(cat)
        case "$payload" in \{*\}) ;; *) exit 43 ;; esac
        case "$payload" in *preferences*) ;; *) exit 44 ;; esac
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fast answer"}}'
        printf '%s\n' '{"type":"turn.completed"}'
        sleep 1
        printf 'fast answer\n' > reply.txt
        """#
        try fastScript.write(to: fastCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fastCLI.path)
        let fastConfig = Settings.ClipboardAction(shortcut: "cmd+shift+l", model: "test", effort: "low",
                                                   executable: nil, instructions: "brief", serviceTier: "priority")
        let started = Date()
        var readyAt: TimeInterval?
        let fastResult = try ClipboardAgent.run(payload: .text("source"), instruction: "edit", edit: false,
                                                settings: fastConfig, resourceDirectory: fixture,
                                                onReady: { text in
                                                    precondition(text == "fast answer")
                                                    readyAt = Date().timeIntervalSince(started)
                                                }, bundledExecutable: fastCLI)
        guard case .text("fast answer") = fastResult, let readyAt else { fatalError("CLI fast result") }
        precondition(Date().timeIntervalSince(started) - readyAt > 0.5)
        let incompleteCLI = fixture.appendingPathComponent("fake-incomplete-codex")
        let incompleteScript = #"""
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}'
        printf 'partial' > reply.txt
        """#
        try incompleteScript.write(to: incompleteCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: incompleteCLI.path)
        let incompleteConfig = Settings.ClipboardAction(shortcut: "cmd+shift+l", model: "test", effort: "low", executable: nil)
        var incompleteReady = false
        let incomplete = try? ClipboardAgent.run(payload: .text("source"), instruction: "edit", edit: false,
                                                 settings: incompleteConfig, resourceDirectory: fixture,
                                                 onReady: { _ in incompleteReady = true }, bundledExecutable: incompleteCLI)
        if case nil = incomplete {} else { fatalError("Incomplete CLI result accepted") }
        precondition(!incompleteReady)

        var eventStream = CLIEventStream()
        var progress: [String] = []
        var ready: [String] = []
        let first = "{\"type\":\"item.updated\",\"item\":{\"type\":\"agent_message\",\"text\":\"partial\"}}\n"
        let final = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"  answer\"}}\n"
        let done = "{\"type\":\"turn.completed\"}\n"
        let firstBytes = Data(first.utf8)
        try eventStream.feed(Data(firstBytes.prefix(8)), onProgress: { progress.append($0) }, onReady: { ready.append($0) })
        try eventStream.feed(Data(firstBytes.dropFirst(8)), onProgress: { progress.append($0) }, onReady: { ready.append($0) })
        precondition(progress == ["partial"] && ready.isEmpty)
        try eventStream.feed(Data(final.utf8), onProgress: { progress.append($0) }, onReady: { ready.append($0) })
        precondition(ready.isEmpty)
        try eventStream.feed(Data(done.utf8), onProgress: { progress.append($0) }, onReady: { ready.append($0) })
        try eventStream.feed(Data(done.utf8), onProgress: { progress.append($0) }, onReady: { ready.append($0) })
        precondition(ready == ["  answer"])
        var failed = CLIEventStream()
        var failedReady: [String] = []
        try failed.feed(Data(final.utf8), onProgress: { _ in }, onReady: { failedReady.append($0) })
        try failed.feed(Data("{\"type\":\"turn.failed\"}\n".utf8), onProgress: { _ in }, onReady: { failedReady.append($0) })
        try failed.feed(Data(done.utf8), onProgress: { _ in }, onReady: { failedReady.append($0) })
        precondition(failed.failed && failedReady.isEmpty)

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
        let unchanged = try ClipboardImage.forAnalysis(png)
        precondition(unchanged.mime == "image/png" && unchanged.data == png)
        let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
        let unchangedJPEG = try ClipboardImage.forAnalysis(jpeg)
        precondition(unchangedJPEG.mime == "image/jpeg" && unchangedJPEG.data == jpeg)
        let asPNG = try ClipboardImage.pngForCLI(jpeg)
        precondition(asPNG.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        let large = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 1000,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        let largePNG = large.representation(using: .png, properties: [:])!
        let packed = try ClipboardImage.forAnalysis(largePNG)
        let source = CGImageSourceCreateWithData(packed.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        precondition(properties[kCGImagePropertyPixelWidth] as? Int == 3072)
        precondition(properties[kCGImagePropertyPixelHeight] as? Int == 768)
        precondition(ClipboardImage.instructionNeedsTextDetail("Прочитай надпись"))
        let preservedLarge = try ClipboardImage.forAnalysis(largePNG, preserveText: true)
        precondition(preservedLarge.data == largePNG)
        let photo = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                                     bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        var random: UInt32 = 42
        for y in 0..<photo.pixelsHigh {
            for x in 0..<photo.pixelsWide {
                let offset = y * photo.bytesPerRow + x * 3
                for channel in 0..<3 {
                    random = random &* 1664525 &+ 1013904223
                    photo.bitmapData![offset + channel] = UInt8(truncatingIfNeeded: random >> 24)
                }
            }
        }
        let noisyPNG = photo.representation(using: .png, properties: [:])!
        let photoPacked = try ClipboardImage.forAnalysis(noisyPNG)
        precondition(photoPacked.mime == "image/jpeg" && photoPacked.data.count * 2 < noisyPNG.count)
        let photoText = try ClipboardImage.forAnalysis(noisyPNG, preserveText: true)
        precondition(photoText.data == noisyPNG && photoText.mime == "image/png")
        let wrong = wrongRoot.appendingPathComponent("image.png")
        try png.write(to: wrong)
        let environment = ["CODEX_HOME": fixture.appendingPathComponent("codex").path]
        precondition((try? ClipboardAgent.generatedImage(threadID: thread, directory: fixture, environment: environment)) == nil)
        let image = rightRoot.appendingPathComponent("image.png")
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: wrong)
        precondition((try? ClipboardAgent.generatedImage(threadID: thread, directory: fixture, environment: environment)) == nil)
        try FileManager.default.removeItem(at: image)
        try Data("not a png".utf8).write(to: image)
        precondition((try? ClipboardAgent.generatedImage(threadID: thread, directory: fixture, environment: environment)) == nil)
        try png.write(to: image)
        let selectedImage = try ClipboardAgent.generatedImage(threadID: thread, directory: fixture, environment: environment)
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
