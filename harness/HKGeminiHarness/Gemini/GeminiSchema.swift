import Foundation

/// The JSON Schema Gemini is asked to follow (sent as `response_schema` through the proxy) and the
/// same shape the local validator enforces. Section 9 of the brief.
public enum GeminiSchema {

    public static let observationSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "observation": .object(["type": .string("string"), "description": .string("One statement about the data, in plain words.")]),
            "supporting_measurements": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Names of the measurements or statistics in the input that this statement rests on, quoting their values as given.")
            ]),
            "time_range": .object([
                "type": .string("object"),
                "properties": .object(["start": .object(["type": .string("string")]), "end": .object(["type": .string("string")])]),
                "description": .string("ISO 8601 dates or day keys from the input that the statement covers.")
            ]),
            "kind": .object(["type": .string("string"), "enum": .array([.string("direct_observation"), .string("hypothesis")])]),
            "data_quality": .object(["type": .string("string"), "description": .string("Coverage, sampling and tracking quality of the measurements used.")]),
            "limitations": .object(["type": .string("string")])
        ]),
        "required": .array(["observation", "supporting_measurements", "kind", "data_quality", "limitations"].map { .string($0) })
    ])

    public static func responseSchema(experiment: AnalysisExperiment) -> JSONValue {
        func arr(_ items: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": items]) }
        let strings = arr(.object(["type": .string("string")]))
        return .object([
            "type": .string("object"),
            "properties": .object([
                "experiment_type": .object(["type": .string("string"), "enum": .array([.string(experiment.rawValue)])]),
                "baseline_summary": .object(["type": .string("object"), "description": .string("Short per-metric notes on the person's own reference ranges, using only numbers from the input."), "additionalProperties": .object(["type": .string("string")])]),
                "health_observations": arr(observationSchema),
                "facial_behavior_observations": arr(observationSchema),
                "cross_modal_patterns": arr(observationSchema),
                "longitudinal_changes": arr(observationSchema),
                "potential_confounders": arr(observationSchema),
                "data_quality": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")])]),
                "uncertainties": strings,
                "recommended_tracking": strings,
                "plain_language_explanation": .object(["type": .string("string")])
            ]),
            "required": .array(["experiment_type", "baseline_summary", "health_observations", "facial_behavior_observations",
                                "cross_modal_patterns", "longitudinal_changes", "potential_confounders", "data_quality",
                                "uncertainties", "recommended_tracking", "plain_language_explanation"].map { .string($0) })
        ])
    }
}
