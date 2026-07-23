/// Prevents an asynchronous push-to-talk startup from outliving the user's
/// press. A token is valid only for the latest requested capture.
struct AssistantVoiceCaptureGate: Sendable {
    private(set) var isRequested = false
    private var generation: UInt = 0

    mutating func request() -> UInt {
        generation &+= 1
        isRequested = true
        return generation
    }

    func permits(_ token: UInt) -> Bool {
        isRequested && token == generation
    }

    mutating func cancel() {
        isRequested = false
        generation &+= 1
    }

    mutating func finish(_ token: UInt) {
        guard token == generation else { return }
        cancel()
    }
}
