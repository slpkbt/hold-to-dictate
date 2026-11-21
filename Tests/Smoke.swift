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
