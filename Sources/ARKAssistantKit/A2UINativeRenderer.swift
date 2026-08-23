/// Renders an `A2UISurface` with native SwiftUI views.
///
/// Read-only by default; pass `onAction` to receive button action names. Unknown component types
/// degrade to a caption naming the type, and rendering is capped by depth and node count.

import SwiftUI

public struct A2UINativeRenderer: View {
    public static let maxDepth = 12
    public static let maxNodes = 200

    private let surface: A2UISurface
    private let onAction: ((String) -> Void)?

    public init(surface: A2UISurface, onAction: ((String) -> Void)? = nil) {
        self.surface = surface
        self.onAction = onAction
    }

    public var body: some View {
        let budget = Self.renderableIDs(in: surface)
        return Group {
            if let root = surface.rootComponent {
                A2UIComponentView(component: root, surface: surface, depth: 0, budget: budget, onAction: onAction)
            } else {
                Text("Empty A2UI surface")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension A2UINativeRenderer {
    /// Breadth-first walk from the root collecting at most `maxNodes` ids within `maxDepth`.
    /// Cycles and orphans are excluded, so the view tree is always finite.
    static func renderableIDs(in surface: A2UISurface) -> Set<String> {
        var visited: Set<String> = []
        var queue: [(id: String, depth: Int)] = [(surface.root, 0)]
        while !queue.isEmpty, visited.count < maxNodes {
            let (id, depth) = queue.removeFirst()
            guard depth <= maxDepth, !visited.contains(id), let component = surface.component(id: id) else { continue }
            visited.insert(id)
            var childIDs = component.children ?? []
            if childIDs.isEmpty, let child = component.child { childIDs = [child] }
            for child in childIDs where !visited.contains(child) {
                queue.append((child, depth + 1))
            }
        }
        return visited
    }
}

struct A2UIComponentView: View {
    let component: A2UIComponent
    let surface: A2UISurface
    let depth: Int
    let budget: Set<String>
    let onAction: ((String) -> Void)?

    var body: some View {
        if depth > A2UINativeRenderer.maxDepth || !budget.contains(component.id) {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch component.type {
        case .column:
            VStack(alignment: .leading, spacing: 6) { childViews }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .row:
            HStack(alignment: .firstTextBaseline, spacing: 8) { childViews }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(childComponents, id: \.id) { child in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundColor(.secondary)
                        A2UIComponentView(component: child, surface: surface, depth: depth + 1, budget: budget, onAction: onAction)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .card:
            VStack(alignment: .leading, spacing: 8) { childViews }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .cornerRadius(10)
        case .text:
            Text(resolved(component.text))
                .font(font(for: component.variant))
                .foregroundColor(component.variant == "caption" || component.variant == "secondary" ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .markdown:
            markdownText(resolved(component.text))
                .font(font(for: component.variant))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .icon:
            Image(systemName: symbolName(resolved(component.name)))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
        case .divider:
            Divider()
        case .button:
            Button {
                if let name = component.action?.event.name {
                    onAction?(name)
                }
            } label: {
                Text(resolved(component.label).isEmpty ? "Action" : resolved(component.label))
            }
            .buttonStyle(.bordered)
            .disabled(onAction == nil || component.action == nil)
        case .none:
            Text("Unsupported A2UI component: \(component.componentName)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var childComponents: [A2UIComponent] {
        var ids = component.children ?? []
        if ids.isEmpty, let child = component.child { ids = [child] }
        return ids.compactMap { id in
            guard id != component.id, budget.contains(id) else { return nil }
            return surface.component(id: id)
        }
    }

    @ViewBuilder
    private var childViews: some View {
        ForEach(childComponents, id: \.id) { child in
            A2UIComponentView(component: child, surface: surface, depth: depth + 1, budget: budget, onAction: onAction)
        }
    }

    private func resolved(_ bound: A2UIBoundString?) -> String {
        bound?.resolved(in: surface.dataModel) ?? ""
    }

    private func symbolName(_ raw: String) -> String {
        raw.isEmpty ? "circle" : raw
    }

    private func font(for variant: String?) -> Font {
        switch variant {
        case "title": return .headline
        case "subtitle": return .subheadline.weight(.semibold)
        case "caption", "secondary": return .caption
        case "mono": return .body.monospaced()
        default: return .body
        }
    }

    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private var cardBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
