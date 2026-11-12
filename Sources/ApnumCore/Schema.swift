/// A small JSON Schema builder for describing tool inputs to agents.
///
///     .object([
///         "label": .string("Shown when the alarm rings"),
///         "hour": .integer("0-23", minimum: 0, maximum: 23),
///     ], required: ["hour"])
public indirect enum Schema: Sendable, Equatable {
    case object([String: Schema], required: [String] = [], description: String? = nil)
    case string(_ description: String? = nil, enumValues: [String]? = nil, format: String? = nil)
    case integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil)
    case number(_ description: String? = nil)
    case boolean(_ description: String? = nil)
    case array(of: Schema, description: String? = nil)

    /// An object schema with no properties, for tools that take no input.
    public static let empty: Schema = .object([:])

    /// The JSON Schema document.
    public var json: JSONValue {
        var out: [String: JSONValue] = [:]
        func describe(_ d: String?) { if let d { out["description"] = .string(d) } }
        switch self {
        case .object(let props, let required, let d):
            out["type"] = "object"
            out["properties"] = .object(props.mapValues(\.json))
            if !required.isEmpty { out["required"] = .array(required.sorted().map(JSONValue.string)) }
            out["additionalProperties"] = false
            describe(d)
        case .string(let d, let enumValues, let format):
            out["type"] = "string"
            if let enumValues { out["enum"] = .array(enumValues.map(JSONValue.string)) }
            if let format { out["format"] = .string(format) }
            describe(d)
        case .integer(let d, let min, let max):
            out["type"] = "integer"
            if let min { out["minimum"] = .number(Double(min)) }
            if let max { out["maximum"] = .number(Double(max)) }
            describe(d)
        case .number(let d):
            out["type"] = "number"
            describe(d)
        case .boolean(let d):
            out["type"] = "boolean"
            describe(d)
        case .array(let item, let d):
            out["type"] = "array"
            out["items"] = item.json
            describe(d)
        }
        return .object(out)
    }
}
