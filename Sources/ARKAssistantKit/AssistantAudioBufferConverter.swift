/// Documents the assistant Audio Buffer Converter source in ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `OneShotInputState` and `AssistantAudioBufferConverter`.

import AVFoundation

/// Implements the one Shot Input State type for ARKAssistantKit in the shared Swift packages.
private final class OneShotInputState: @unchecked Sendable {
    var didProvideInput = false
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Converts microphone buffers into the format required by SpeechAnalyzer.
final class AssistantAudioBufferConverter {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateOutputBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != outputFormat else { return buffer }

        if converter == nil || converter?.outputFormat != outputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw ConversionError.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledLength = Double(buffer.frameLength) * sampleRateRatio
        let capacity = AVAudioFrameCount(scaledLength.rounded(.up))

        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw ConversionError.failedToCreateOutputBuffer
        }

        var nsError: NSError?
        let inputState = OneShotInputState(buffer: buffer)

        let status = converter.convert(to: output, error: &nsError) { _, inputStatus in
            if inputState.didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }

            inputState.didProvideInput = true
            inputStatus.pointee = .haveData
            return inputState.buffer
        }

        if status == .error {
            throw ConversionError.conversionFailed(nsError)
        }

        return output
    }
}
