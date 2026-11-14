import Foundation

/// System instruction and per-experiment user prompts. The payload (numbers) travels separately as
/// JSON; the prompt only says what to do with it.
public enum GeminiPrompts {

    public static let systemInstruction = """
    You are a careful data analyst reviewing summary statistics computed on a phone from two sources: \
    Apple Health (HealthKit) and an ARKit face-tracking research recorder. You receive numbers only: \
    descriptive statistics, daily aggregates, coverage and sampling reports, facial-movement features per \
    time window, and correlation coefficients. You never receive raw frames, images, audio or free text \
    written by the person.

    Rules, in order of importance:
    1. Use only numbers that appear in the input. Quote them as given (same rounding). Do not compute new \
    statistics, do not estimate values, do not fill gaps. If something cannot be judged from the input, say so \
    under "uncertainties" or "data_quality".
    2. Facial-movement features describe movement of the face, head and eyes. They are not emotions, moods, \
    personality traits, diagnoses or clinical biomarkers. Never infer happiness, sadness, depression, anxiety, \
    fatigue, stress, pain or any disorder from them. Describe movement as movement.
    3. A correlation is a descriptive association in this person's data. Never present it as a cause. Name \
    plausible confounders (time of day, lighting, phone position, tracking quality, medication, illness, \
    device changes, how few paired days there are).
    4. Mark every statement as "direct_observation" (it restates numbers in the input) or "hypothesis" (an \
    interpretation that would need more data). Each statement lists the measurements it rests on and the time \
    range.
    5. Report missing information explicitly: metrics that were unavailable or empty, days without data, \
    windows with low tracking, sparse sampling (for example HRV is a few readings per day, not a continuous signal).
    6. Historical values are this person's own history, not a healthy baseline. The history may include unwell periods.
    7. Answer with one JSON object that matches the provided schema. No markdown, no preface.
    """

    public static func userPrompt(for experiment: AnalysisExperiment) -> String {
        switch experiment {
        case .connectionTest:
            return "Connection test. Reply with the JSON object; set experiment_type to \"connection_test\", put the string \"ok\" into plain_language_explanation and leave every array empty."
        case .healthKitOnly:
            return """
            Experiment A, HealthKit only. The input holds per-metric summaries of Apple Health data for one person over the stated date range.
            Tasks:
            - Describe physiological and activity patterns (heart rate, HRV, resting heart rate, respiratory rate, steps, energy, exercise, mobility) using the statistics given.
            - Identify changes over time from the weekly aggregates and longitudinal_change entries.
            - Examine sleep and recovery: sleep duration per night, stages where present, wrist temperature, HRV.
            - Point out potential relationships between metrics only where the input provides correlation entries or clearly co-varying daily values; mark them as hypotheses.
            - Explain what is missing: unavailableTypes, emptyTypes, coverage gaps, sparse sampling.
            - In baseline_summary, restate the person's own reference ranges (median, usual range) per metric from the input.
            Put facial_behavior_observations and cross_modal_patterns as empty arrays.
            """
        case .arKitOnly:
            return """
            Experiment B, ARKit only. The input holds facial-behaviour features computed from one or more face-tracking recordings: per-session validation (frame rate, tracking, lighting), per-window features (blink count and rate, eye openness, head movement amplitude/frequency/variability, facial movement amplitude/variability/activity, left-right asymmetry, gaze direction changes), per-coefficient blend-shape statistics, and the recorder's own exported derived means kept separately.
            Tasks:
            - Describe facial movement patterns and blend-shape variability per session.
            - Compare the sessions with each other (controlled recording sessions may carry marker labels such as "Neutral face" or "Smile").
            - Examine blink patterns (rate, duration, one-sided blinks) and head and eye movement.
            - Identify temporal changes within sessions across the windows and between sessions over the dates given.
            - Account for tracking quality and lighting: say which windows or sessions are too poorly tracked to interpret.
            - State where the evidence is insufficient (few windows, short sessions, one session only).
            Put health_observations and cross_modal_patterns as empty arrays.
            """
        case .combined:
            return """
            Experiment C, combined HealthKit + ARKit. The input holds (1) the HealthKit summary, (2) facial-behaviour summaries per recording with wall-clock times, (3) dailyRows that pair each day's health values and the previous day's health values with that day's facial features, (4) locally computed correlation entries with their paired-day counts, and (5) a personal baseline profile.
            Examine possible relationships between:
            - HRV and facial movement variability.
            - Sleep duration (attributed to the wake-up day) and that day's facial movement.
            - Resting heart rate and facial movement.
            - Activity levels (steps, exercise minutes, energy) and facial movement patterns.
            - Sleep and blink statistics.
            - Changes in physiological and facial measurements over the period.
            - Self-reported wellbeing and measurements, only if such values are present in the input (otherwise say they are absent).
            For each: observed pattern, the correlation entries that support or contradict it, contradictory evidence, possible confounders, missing information, and what additional data would make the question answerable. Treat every association as descriptive. Do not infer emotions or diagnoses from facial movement.
            """
        case .baseline:
            return """
            Personal baseline. The input holds locally computed reference ranges (median, MAD, percentiles, usual range) for this person's health metrics and facial features, plus coverage and longitudinal changes.
            Interpret these ranges: which metrics have enough days to be trusted as a personal reference, which are too sparse, which show drift over the period, and how a new day should be compared against them. Do not invent target values and do not call any range healthy or unhealthy.
            """
        case .geometryFeatures:
            return """
            Optional geometry experiment. The input holds aggregate numbers derived from face-mesh geometry (inter-record displacement, bounding-box extent, a crude left-right symmetry error) next to the blend-shape based features of the same session. No vertex positions are included.
            Describe what, if anything, the geometry-derived numbers add beyond the blend-shape features, and their limitations.
            """
        case .comparison:
            return "Compare the two analyses in the input and list agreements, disagreements and statements present in only one of them."
        }
    }

    /// Terms that must not appear in observations. Checked by the validator as warnings.
    public static let forbiddenTerms: [String] = ["depress", "anxi", "happy", "happiness", "sad ", "sadness", "emotion", "diagnos",
                                                  "disorder", "mood", "fatigue", "stress", "pain"]
}
