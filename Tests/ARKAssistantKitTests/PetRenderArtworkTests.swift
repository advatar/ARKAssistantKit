#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ARKAssistantKit

/// Renders the real pet character to PNG for documentation and the landing
/// page, so marketing never shows a drawing the app does not make. Skipped
/// unless ARK_PET_RENDER_DIR points at a writable directory.
@MainActor
final class PetRenderArtworkTests: XCTestCase {
    func testRendersPetStatesToPNG() throws {
        guard let dir = ProcessInfo.processInfo.environment["ARK_PET_RENDER_DIR"] else {
            throw XCTSkip("Set ARK_PET_RENDER_DIR to render artwork")
        }
        let states: [(String, ARKPetStateDescriptor, Bool)] = [
            ("ready", .init(phase: .ready, isMuted: false, error: nil), false),
            ("listening", .init(phase: .listening, isMuted: false, error: nil), true),
            ("speaking", .init(phase: .speaking, isMuted: false, error: nil), true),
            ("muted", .init(phase: .ready, isMuted: true, error: nil), false),
        ]
        for (name, descriptor, pulse) in states {
            let view = AssistantPetCharacter(descriptor: descriptor, isPressed: false, pulse: pulse,
                                             breathing: false, isHovering: false, touchCount: 0, allowsMotion: false)
                .frame(width: 200)
                .padding(20)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            renderer.isOpaque = false
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Could not render \(name)"); continue
            }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pet-\(name).png"))
        }
    }
}
#endif
