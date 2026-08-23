/// Exercises A2UI encode/decode, the renderer's node budget and the visual composer.

import Foundation
import Testing
@testable import ARKAssistantKit

struct A2UIAndComposerTests {
    @Test func roundTripsFlatSurface() throws {
        let surface = A2UISurface(
            surfaceID: "s1",
            root: "root",
            components: [
                A2UIComponent(id: "root", component: .card, children: ["t", "b"]),
                A2UIComponent(id: "t", component: .text, text: .literal("Hello"), variant: "title"),
                A2UIComponent(id: "b", component: .button, label: .path("/cta"), action: A2UIAction(name: "navigate")),
            ],
            dataModel: .object(["cta": .string("Go"), "n": .number(3)])
        )
        let json = surface.encodeJSON()
        #expect(json.contains(#""component":"Text""#))
        #expect(json.contains(#""text":"Hello""#))
        #expect(json.contains(#""label":{"path":"\/cta"}"#) || json.contains(#""label":{"path":"/cta"}"#))
        let decoded = try #require(A2UISurface.decode(json: json))
        #expect(decoded == surface)
        #expect(decoded.component(id: "b")?.label?.resolved(in: decoded.dataModel) == "Go")
    }

    @Test func decodesNestedOfficialShapeAndUnknownTypes() throws {
        let json = """
        {"surfaceId":"x","root":"r","components":[
          {"id":"r","component":{"Column":{"children":["a","z"]}}},
          {"id":"a","component":{"Text":{"text":{"literal":"Nested"}}}},
          {"id":"z","component":{"Hologram":{"text":"??"}}}
        ]}
        """
        let surface = try #require(A2UISurface.decode(json: json))
        #expect(surface.rootComponent?.type == .column)
        #expect(surface.component(id: "a")?.text == .literal("Nested"))
        #expect(surface.component(id: "z")?.type == nil)
        #expect(surface.component(id: "z")?.componentName == "Hologram")
    }

    @Test func rendererBudgetExcludesCyclesAndOrphans() {
        let surface = A2UISurface(
            surfaceID: "c",
            root: "a",
            components: [
                A2UIComponent(id: "a", component: .column, children: ["b"]),
                A2UIComponent(id: "b", component: .column, children: ["a", "c"]),
                A2UIComponent(id: "c", component: .text, text: .literal("leaf")),
                A2UIComponent(id: "orphan", component: .text, text: .literal("never")),
            ]
        )
        let ids = A2UINativeRenderer.renderableIDs(in: surface)
        #expect(ids == ["a", "b", "c"])
    }

    @Test func composerBuildsBulletCard() throws {
        let outcome = AssistantActionOutcome(message: "Next steps\n- Plug in the mic\n- Press record\n- Sing")
        let action = AssistantAction(name: "x", title: "Studio", description: "", category: .session, phrases: [])
        let surface = AssistantVisualComposer.surface(for: outcome, action: action)
        #expect(surface.surfaceID == AssistantVisualComposer.surfaceID)
        #expect(surface.rootComponent?.type == .card)
        #expect(surface.component(id: "title")?.text == .literal("Studio"))
        #expect(surface.component(id: "icon")?.name == .literal("record.circle"))
        // Mixed paragraph + bullets → divider followed by lines.
        #expect(surface.rootComponent?.children?.contains("divider") == true)
        #expect(surface.component(id: "line-1")?.text == .literal("Plug in the mic"))
    }

    @Test func composerBuildsListWhenAllBullets() {
        let surface = AssistantVisualComposer.compose(title: "Items", body: "- one\n- two\n* three")
        let list = surface.component(id: "list")
        #expect(list?.type == .list)
        #expect(list?.children == ["item-0", "item-1", "item-2"])
    }

    @Test func composerBuildsKeyValueRows() {
        let surface = AssistantVisualComposer.compose(title: "Session", body: "Project: Demo Song\nState: Recording")
        #expect(surface.rootComponent?.children == ["header", "kv-0", "kv-1"])
        #expect(surface.component(id: "kv-1-value")?.text == .literal("Recording"))
    }

    @Test func composerCapsLines() {
        let body = (1...20).map { "\($0). step" }.joined(separator: "\n")
        let lines = AssistantVisualComposer.extractLines(from: body)
        #expect(lines.count == AssistantVisualComposer.maxLines)
        #expect(lines.first == .step(index: 1, text: "step"))
    }

    @Test func composerPrefersProvidedSurfaceAndFailureIcon() throws {
        let provided = A2UISurface(surfaceID: "given", root: "r", components: [A2UIComponent(id: "r", component: .text, text: .literal("hi"))])
        let outcome = AssistantActionOutcome(message: "m", a2uiSurfaceJSON: provided.encodeJSON())
        #expect(AssistantVisualComposer.surface(for: outcome, action: nil) == provided)

        let failed = AssistantVisualComposer.surface(for: .failure("Nope"), action: nil)
        #expect(failed.component(id: "icon")?.name == .literal("exclamationmark.triangle.fill"))
        #expect(failed.component(id: "title")?.text == .literal("Couldn't do that"))
    }

    @Test func shortReplyHasNoVisual() {
        #expect(AssistantVisualComposer.surface(forReply: "Hi there!") == nil)
        #expect(AssistantVisualComposer.surface(forReply: "Step one\nStep two") != nil)
    }

    @Test func canvasPayloadDecodesEnvelopeAndStream() throws {
        let inner = A2UISurface(surfaceID: "env", root: "r", components: [A2UIComponent(id: "r", component: .divider)])
        let envelope = #"{"updateComponents":\#(inner.encodeJSON()),"dataModel":{"k":"v"}}"#
        let decoded = try #require(A2UISurface.fromCanvasPayload(envelope))
        #expect(decoded.surfaceID == "env")
        #expect(decoded.dataModel.value(at: "/k")?.stringValue == "v")

        let stream = "[{\"noise\":true},\(inner.encodeJSON())]"
        #expect(A2UISurface.fromCanvasPayload(stream)?.surfaceID == "env")
        #expect(A2UISurface.fromCanvasPayload("plain text") == nil)
    }
}
