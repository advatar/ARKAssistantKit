/// Minimal, self-contained A2UI (v0.9.1-style) surface model used by the ARK assistant and pet.
///
/// JSON shape (flat, BrIAn-compatible):
///
/// ```json
/// {
///   "surfaceId": "ark.assistant.response",
///   "root": "root",
///   "components": [
///     {"id": "root", "component": "Card", "children": ["title", "line-0"]},
///     {"id": "title", "component": "Text", "text": "Session started", "variant": "title"},
///     {"id": "line-0", "component": "Text", "text": {"path": "/summary"}},
///     {"id": "go", "component": "Button", "label": "Open", "action": {"event": {"name": "navigate"}}}
///   ],
///   "dataModel": {"summary": "Demo Song"}
/// }
/// ```
///
/// Each component is `{"id", "component": "<Type>", ...properties}`. Bound strings are either a
/// JSON string literal or `{"path": "/data/model/path"}` resolved against `dataModel`.
///
/// For compatibility with the official A2UI v0.9 wire format the decoder *also* accepts the nested
/// form `{"id": "t", "component": {"Text": {"text": {"literal": "…"}}}}` (and `{"path": …}` bindings
/// inside it). Encoding always produces the flat form above. MIME type: `application/a2ui+json`.

import Foundation

public enum A2UIProtocolVersion {
    public static let current = "v0.9.1"
    public static let mimeType = "application/a2ui+json"
}

// MARK: - JSON value

/// A small JSON value enum used for the surface data model and opaque style bags.
public indirect enum A2UIJSONValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([A2UIJSONValue])
    case object([String: A2UIJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([A2UIJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: A2UIJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public var objectValue: [String: A2UIJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [A2UIJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Resolves a `/a/b/0`-style JSON-pointer path against this value.
    public func value(at path: String) -> A2UIJSONValue? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.reduce(Optional(self)) { current, part in
            guard let current else { return nil }
            if let object = current.objectValue { return object[part] }
            if let array = current.arrayValue, let index = Int(part), array.indices.contains(index) {
                return array[index]
            }
            return nil
        }
    }
}

// MARK: - Bound string

/// A string that is either a literal or a binding path into the surface data model.
public enum A2UIBoundString: Equatable, Sendable, Codable {
    case literal(String)
    case path(String)

    private enum CodingKeys: String, CodingKey {
        case literal
        case path
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let literal = try? single.decode(String.self) {
            self = .literal(literal)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try keyed.decodeIfPresent(String.self, forKey: .path) {
            self = .path(path)
        } else if let literal = try keyed.decodeIfPresent(String.self, forKey: .literal) {
            self = .literal(literal)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .literal,
                in: keyed,
                debugDescription: "A2UI bound string needs a literal or a path"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .literal(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .path(let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
        }
    }

    /// Resolves the string against a data model; unresolved paths yield an empty string.
    public func resolved(in dataModel: A2UIJSONValue) -> String {
        switch self {
        case .literal(let value): return value
        case .path(let path): return dataModel.value(at: path)?.stringValue ?? ""
        }
    }
}

// MARK: - Components

public enum A2UIComponentType: String, CaseIterable, Codable, Sendable {
    case column = "Column"
    case row = "Row"
    case card = "Card"
    case text = "Text"
    case markdown = "Markdown"
    case icon = "Icon"
    case divider = "Divider"
    case list = "List"
    case button = "Button"
}

public struct A2UIAction: Equatable, Sendable, Codable {
    public struct Event: Equatable, Sendable, Codable {
        public let name: String
        public init(name: String) { self.name = name }
    }

    public let event: Event

    public init(event: Event) { self.event = event }
    public init(name: String) { self.event = Event(name: name) }
}

public struct A2UIComponent: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    /// Raw component type name. Unknown types are preserved so the renderer can degrade gracefully.
    public let componentName: String
    public var children: [String]?
    public var child: String?
    public var text: A2UIBoundString?
    public var name: A2UIBoundString?
    public var label: A2UIBoundString?
    public var variant: String?
    public var action: A2UIAction?
    public var styles: [String: A2UIJSONValue]?

    public var type: A2UIComponentType? { A2UIComponentType(rawValue: componentName) }

    public init(
        id: String,
        component: A2UIComponentType,
        children: [String]? = nil,
        child: String? = nil,
        text: A2UIBoundString? = nil,
        name: A2UIBoundString? = nil,
        label: A2UIBoundString? = nil,
        variant: String? = nil,
        action: A2UIAction? = nil,
        styles: [String: A2UIJSONValue]? = nil
    ) {
        self.init(
            id: id,
            componentName: component.rawValue,
            children: children,
            child: child,
            text: text,
            name: name,
            label: label,
            variant: variant,
            action: action,
            styles: styles
        )
    }

    public init(
        id: String,
        componentName: String,
        children: [String]? = nil,
        child: String? = nil,
        text: A2UIBoundString? = nil,
        name: A2UIBoundString? = nil,
        label: A2UIBoundString? = nil,
        variant: String? = nil,
        action: A2UIAction? = nil,
        styles: [String: A2UIJSONValue]? = nil
    ) {
        self.id = id
        self.componentName = componentName
        self.children = children
        self.child = child
        self.text = text
        self.name = name
        self.label = label
        self.variant = variant
        self.action = action
        self.styles = styles
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case component
        case children
        case child
        case text
        case name
        case label
        case variant
        case action
        case styles
    }

    private struct NestedProperties: Decodable {
        var children: [String]?
        var child: String?
        var text: A2UIBoundString?
        var name: A2UIBoundString?
        var label: A2UIBoundString?
        var variant: String?
        var action: A2UIAction?
        var styles: [String: A2UIJSONValue]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let flatName = try? container.decode(String.self, forKey: .component) {
            componentName = flatName
            children = try? container.decodeIfPresent([String].self, forKey: .children)
            child = try? container.decodeIfPresent(String.self, forKey: .child)
            text = try? container.decodeIfPresent(A2UIBoundString.self, forKey: .text)
            name = try? container.decodeIfPresent(A2UIBoundString.self, forKey: .name)
            label = try? container.decodeIfPresent(A2UIBoundString.self, forKey: .label)
            variant = try? container.decodeIfPresent(String.self, forKey: .variant)
            action = try? container.decodeIfPresent(A2UIAction.self, forKey: .action)
            styles = try? container.decodeIfPresent([String: A2UIJSONValue].self, forKey: .styles)
            return
        }
        // Nested official form: "component": {"Text": {...}}
        let nested = try container.decode([String: NestedProperties].self, forKey: .component)
        guard nested.count == 1, let (typeName, props) = nested.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .component,
                in: container,
                debugDescription: "A2UI component must name exactly one type"
            )
        }
        componentName = typeName
        children = props.children
        child = props.child
        text = props.text
        name = props.name
        label = props.label
        variant = props.variant
        action = props.action
        styles = props.styles
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(componentName, forKey: .component)
        try container.encodeIfPresent(children, forKey: .children)
        try container.encodeIfPresent(child, forKey: .child)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(variant, forKey: .variant)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(styles, forKey: .styles)
    }
}

// MARK: - Surface

public struct A2UISurface: Equatable, Sendable, Codable {
    public let surfaceID: String
    public let root: String
    public let components: [A2UIComponent]
    public let dataModel: A2UIJSONValue

    public init(
        surfaceID: String,
        root: String,
        components: [A2UIComponent],
        dataModel: A2UIJSONValue = .object([:])
    ) {
        self.surfaceID = surfaceID
        self.root = root
        self.components = components
        self.dataModel = dataModel
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surfaceId"
        case root
        case components
        case dataModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID) ?? "surface"
        components = try container.decode([A2UIComponent].self, forKey: .components)
        root = try container.decodeIfPresent(String.self, forKey: .root)
            ?? components.first?.id
            ?? "root"
        dataModel = try container.decodeIfPresent(A2UIJSONValue.self, forKey: .dataModel) ?? .object([:])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(surfaceID, forKey: .surfaceID)
        try container.encode(root, forKey: .root)
        try container.encode(components, forKey: .components)
        try container.encode(dataModel, forKey: .dataModel)
    }

    public func component(id: String) -> A2UIComponent? {
        components.first { $0.id == id }
    }

    public var rootComponent: A2UIComponent? { component(id: root) }

    /// Decodes a surface from JSON text. Accepts a bare surface, or an envelope that wraps it under
    /// `surface`, `updateComponents`, or `a2ui`.
    public static func decode(json: String) -> A2UISurface? {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return decode(data: data)
    }

    public static func decode(data: Data) -> A2UISurface? {
        let decoder = JSONDecoder()
        if let surface = try? decoder.decode(A2UISurface.self, from: data) {
            return surface
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["surface", "updateComponents", "a2ui"] {
            guard let nested = object[key] as? [String: Any],
                  let nestedData = try? JSONSerialization.data(withJSONObject: nested) else { continue }
            if var surface = try? decoder.decode(A2UISurface.self, from: nestedData) {
                if let model = object["dataModel"],
                   let modelData = try? JSONSerialization.data(withJSONObject: model),
                   let modelValue = try? decoder.decode(A2UIJSONValue.self, from: modelData) {
                    surface = A2UISurface(
                        surfaceID: surface.surfaceID,
                        root: surface.root,
                        components: surface.components,
                        dataModel: modelValue
                    )
                }
                return surface
            }
        }
        return nil
    }

    public func encodeJSON(prettyPrinted: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
