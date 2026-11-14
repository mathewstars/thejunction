import Foundation

/// Strict checks on a Gemini reply:
/// 1. It must decode as `StructuredAnalysis` (section 9 shape).
/// 2. `experiment_type` must match the request.
/// 3. Every observation needs non-empty text, a valid `kind`, and (for direct observations) at least one supporting measurement.
/// 4. Every number mentioned anywhere in the reply must exist in the request payload (allowing for rounding and % scaling).
///    Small integers (|n| ≤ 31) that are missing are warnings, because they are usually counts or dates.
/// 5. Emotion/diagnosis vocabulary in observations is flagged.
public enum GeminiResponseValidator {

    public struct Options {
        public var relativeTolerance: Double = 0.005
        public var smallIntegerLimit: Double = 31
        public var failOnUnsupportedNumbers = true
        public var failOnForbiddenTerms = false
        public init() {}
    }

    public static func validate(rawText: String, request: GeminiAnalysisRequest,
                                options: Options = Options()) -> (StructuredAnalysis?, ResponseValidationReport) {
        var schemaErrors: [ResponseValidationReport.Problem] = []
        var unsupported: [ResponseValidationReport.Problem] = []
        var forbidden: [ResponseValidationReport.Problem] = []

        let cleaned = stripCodeFences(rawText)
        guard let data = cleaned.data(using: .utf8) else {
            return (nil, ResponseValidationReport(isValid: false, schemaErrors: [.init(severity: "error", location: "$", message: "Reply is not UTF-8 text.")],
                                                  unsupportedNumbers: [], forbiddenTerms: [], observationCount: 0, checkedNumbers: 0))
        }
        let analysis: StructuredAnalysis
        do {
            analysis = try JSONValue.decoder().decode(StructuredAnalysis.self, from: data)
        } catch {
            return (nil, ResponseValidationReport(isValid: false, schemaErrors: [.init(severity: "error", location: "$", message: "Does not match the schema: \(describe(error))")],
                                                  unsupportedNumbers: [], forbiddenTerms: [], observationCount: 0, checkedNumbers: 0))
        }

        if analysis.experimentType != request.experiment.rawValue {
            schemaErrors.append(.init(severity: "error", location: "$.experiment_type", message: "Expected \(request.experiment.rawValue), got \(analysis.experimentType)."))
        }

        let groups: [(String, [AnalysisObservation])] = [
            ("health_observations", analysis.healthObservations), ("facial_behavior_observations", analysis.facialBehaviorObservations),
            ("cross_modal_patterns", analysis.crossModalPatterns), ("longitudinal_changes", analysis.longitudinalChanges),
            ("potential_confounders", analysis.potentialConfounders)
        ]
        for (name, obs) in groups {
            for (i, o) in obs.enumerated() {
                let loc = "$.\(name)[\(i)]"
                if o.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { schemaErrors.append(.init(severity: "error", location: loc, message: "Empty observation.")) }
                if o.kind != "direct_observation" && o.kind != "hypothesis" { schemaErrors.append(.init(severity: "error", location: loc + ".kind", message: "kind must be direct_observation or hypothesis, got '\(o.kind)'.")) }
                if o.kind == "direct_observation" && o.supportingMeasurements.isEmpty { schemaErrors.append(.init(severity: "error", location: loc, message: "Direct observation without supporting measurements.")) }
                if o.dataQuality.isEmpty { schemaErrors.append(.init(severity: "warning", location: loc + ".data_quality", message: "Empty data_quality.")) }
                let lower = (o.observation + " " + o.limitations).lowercased()
                for term in GeminiPrompts.forbiddenTerms where lower.contains(term) {
                    // Allow explicit disclaimers ("not a diagnosis", "no emotion is inferred").
                    if lower.contains("not a \(term)") || lower.contains("no \(term)") || lower.contains("not \(term)") || lower.contains("cannot") { continue }
                    forbidden.append(.init(severity: "warning", location: loc, message: "Contains '\(term.trimmingCharacters(in: .whitespaces))'."))
                }
            }
        }

        // Numbers.
        let allowed = request.payload.allNumbers()
        var allowedAbs = Set<Double>()
        for n in allowed { allowedAbs.insert(abs(n)) }
        let sortedAllowed = allowedAbs.sorted()
        var checked = 0
        func check(_ text: String, _ loc: String) {
            for n in NumberScanner.numbers(in: text) {
                checked += 1
                if isSupported(n, sortedAllowed: sortedAllowed, tolerance: options.relativeTolerance) { continue }
                let small = n == n.rounded() && abs(n) <= options.smallIntegerLimit
                unsupported.append(.init(severity: small ? "warning" : "error", location: loc, message: "Number \(formatNumber(n)) not found in the request payload."))
            }
        }
        for (name, obs) in groups {
            for (i, o) in obs.enumerated() {
                check(o.observation, "$.\(name)[\(i)].observation")
                for (j, s) in o.supportingMeasurements.enumerated() { check(s, "$.\(name)[\(i)].supporting_measurements[\(j)]") }
                check(o.limitations, "$.\(name)[\(i)].limitations")
                check(o.dataQuality, "$.\(name)[\(i)].data_quality")
            }
        }
        check(analysis.plainLanguageExplanation, "$.plain_language_explanation")
        check(analysis.baselineSummary.description, "$.baseline_summary")
        check(analysis.dataQuality.description, "$.data_quality")
        for (i, u) in analysis.uncertainties.enumerated() { check(u, "$.uncertainties[\(i)]") }

        let hardErrors = schemaErrors.filter { $0.severity == "error" }.count
            + (options.failOnUnsupportedNumbers ? unsupported.filter { $0.severity == "error" }.count : 0)
            + (options.failOnForbiddenTerms ? forbidden.count : 0)
        let report = ResponseValidationReport(isValid: hardErrors == 0, schemaErrors: schemaErrors, unsupportedNumbers: unsupported,
                                              forbiddenTerms: forbidden, observationCount: groups.reduce(0) { $0 + $1.1.count },
                                              checkedNumbers: checked)
        return (analysis, report)
    }

    /// A number is supported when some payload number equals it after rounding to the reply's precision,
    /// within a relative tolerance, or when it is that number scaled by 100 (fraction shown as percent).
    static func isSupported(_ n: Double, sortedAllowed: [Double], tolerance: Double) -> Bool {
        let x = abs(n)
        let decimals = decimalPlaces(n)
        for candidate in [x, x / 100, x * 100] {
            if contains(sortedAllowed, candidate, tolerance: tolerance) { return true }
            // The model may have rounded a longer payload value to `decimals` places.
            let scale = pow(10.0, Double(decimals))
            let lo = (candidate - 0.5 / scale), hi = (candidate + 0.5 / scale)
            if let i = lowerBound(sortedAllowed, lo), i < sortedAllowed.count, sortedAllowed[i] <= hi + 1e-12 { return true }
        }
        return false
    }

    static func contains(_ sorted: [Double], _ v: Double, tolerance: Double) -> Bool {
        let tol = max(abs(v) * tolerance, 1e-9)
        guard let i = lowerBound(sorted, v - tol) else { return false }
        return i < sorted.count && sorted[i] <= v + tol
    }

    static func lowerBound(_ a: [Double], _ v: Double) -> Int? {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < v { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    static func decimalPlaces(_ n: Double) -> Int {
        let s = formatNumber(n)
        guard let dot = s.firstIndex(of: ".") else { return 0 }
        return s.distance(from: dot, to: s.endIndex) - 1
    }

    static func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.6f", n)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public static func stripCodeFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .keyNotFound(let k, let c): return "missing key '\(k.stringValue)' at \(path(c))"
            case .typeMismatch(let t, let c): return "wrong type at \(path(c)), expected \(t)"
            case .valueNotFound(let t, let c): return "null at \(path(c)), expected \(t)"
            case .dataCorrupted(let c): return "corrupted at \(path(c)): \(c.debugDescription)"
            @unknown default: return String(describing: d)
            }
        }
        return error.localizedDescription
    }

    private static func path(_ c: DecodingError.Context) -> String {
        "$" + c.codingPath.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined()
    }
}
