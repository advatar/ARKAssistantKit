import Testing
@testable import ARKAssistantKit

struct AssistantPetMotionTests {
    @Test func posesAreDeterministicBoundedAndDistinct() {
        let phases: [AssistantVoicePhase] = [.ready, .listening, .thinking, .speaking, .unavailable]
        let poses = phases.map { ARKPetStateDescriptor(phase: $0, isMuted: false, error: nil).faderPose }
        #expect(Set(poses).count == phases.count)
        for (phase, pose) in zip(phases, poses) {
            #expect(pose.count == 3)
            #expect(pose.allSatisfy { abs($0) <= 15 })
            #expect(pose == ARKPetStateDescriptor(phase: phase, isMuted: false, error: nil).faderPose)
        }
    }
    @Test func eachQuietGateReplacesAnAlreadyActiveAnimationSubtree() {
        let active = AssistantPetMotionPolicy(reduceMotion: false, liveSession: false, quietAppearance: false)
        #expect(active.allowsMotion)
        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            let quiet = AssistantPetMotionPolicy(reduceMotion: flags.0, liveSession: flags.1, quietAppearance: flags.2)
            #expect(!quiet.allowsMotion)
            // The view uses this key as its animated subtree identity, so a
            // transition discards existing repeat-forever animation state.
            #expect(active.allowsMotion != quiet.allowsMotion)
        }
    }

    @Test func leavingLiveSessionCannotOverrideAnotherQuietPreference() {
        #expect(!AssistantPetMotionPolicy(reduceMotion: true, liveSession: false, quietAppearance: false).allowsMotion)
        #expect(!AssistantPetMotionPolicy(reduceMotion: false, liveSession: false, quietAppearance: true).allowsMotion)
    }

    @Test func muteDoesNotConcealThinkingSpeakingOrErrors() {
        for phase: AssistantVoicePhase in [.thinking, .speaking, .unavailable] {
            let muted = ARKPetStateDescriptor(phase: phase, isMuted: true, error: "Speech unavailable")
            let unmuted = ARKPetStateDescriptor(phase: phase, isMuted: false, error: "Speech unavailable")
            #expect(muted.faderPose == unmuted.faderPose)
            #expect(muted.symbol == unmuted.symbol)
        }
        let muted = ARKPetStateDescriptor(phase: .listening, isMuted: true, error: nil)
        #expect(muted.status == "Muted")
        #expect(!muted.pulses)
        let failed = ARKPetStateDescriptor(phase: .ready, isMuted: true, error: "Microphone unavailable")
        #expect(failed.accent == .orange)
        #expect(failed.status == "Microphone unavailable")
    }
}
