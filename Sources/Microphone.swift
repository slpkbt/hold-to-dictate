import AVFoundation
import Accelerate

@MainActor
final class Microphone {
    private let engine = AVAudioEngine()
    private var tapped = false

    func start(consume: @escaping (AVAudioPCMBuffer) -> Void, level: @escaping (Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError("Микрофон недоступен.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var rms: Float = 0
                vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
                level(min(1, pow(rms * 10, 0.62)))
            }
            consume(buffer)
        }
        tapped = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw DictationError("Не удалось запустить микрофон.")
        }
    }

    func stop() {
        guard tapped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapped = false
    }
}

final class PCMEncoder {
    private var converter: AVAudioConverter?
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                       channels: 1, interleaved: true)!

    func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let frames = ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 16
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        var pending: AVAudioPCMBuffer? = buffer
        var error: NSError?
        let result = converter.convert(to: pcm, error: &error) { _, status in
            if let input = pending {
                pending = nil
                status.pointee = .haveData
                return input
            }
            status.pointee = .noDataNow
            return nil
        }
        let samples = pcm.audioBufferList.pointee.mBuffers
        guard result != .error, error == nil, samples.mDataByteSize > 0, let ptr = samples.mData else {
            return nil
        }
        return Data(bytes: ptr, count: Int(samples.mDataByteSize))
    }
}
