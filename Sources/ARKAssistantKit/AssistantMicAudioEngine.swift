import AVFoundation

private final class SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Captures microphone audio and yields buffers on the main actor.
final class AssistantMicAudioEngine {
    private let audioEngine = AVAudioEngine()
    private var isTapInstalled = false

    @MainActor
    func start(onBuffer: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        installTap(on: inputNode, format: inputFormat, onBuffer: onBuffer)

        audioEngine.prepare()
        try audioEngine.start()
    }

    @MainActor
    func stop() {
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine.stop()
    }

    private func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        onBuffer: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) {
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let copied = self.copy(buffer) else { return }
            let sendable = SendablePCMBuffer(copied)
            DispatchQueue.main.async {
                onBuffer(sendable.buffer)
            }
        }
        isTapInstalled = true
    }

    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            let bytesPerChannel = frameCount * MemoryLayout<Float>.stride
            for index in 0..<channelCount {
                memcpy(destination[index], source[index], bytesPerChannel)
            }
            return copy
        }

        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            let bytesPerChannel = frameCount * MemoryLayout<Int16>.stride
            for index in 0..<channelCount {
                memcpy(destination[index], source[index], bytesPerChannel)
            }
            return copy
        }

        if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            let bytesPerChannel = frameCount * MemoryLayout<Int32>.stride
            for index in 0..<channelCount {
                memcpy(destination[index], source[index], bytesPerChannel)
            }
            return copy
        }

        return nil
    }
}
