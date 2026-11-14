import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Everything this harness knows about one HealthKit type: how to name it, which unit to read it in,
/// how to form a daily value, and which group it belongs to in the developer UI.
///
/// The catalog is also used by the Apple Health XML importer, which sees the same raw identifiers
/// (e.g. `HKQuantityTypeIdentifierHeartRate`) in `<Record type="...">`.
public struct HealthTypeDescriptor: Identifiable, Hashable {
    public enum Kind: String, Codable { case quantity, category, workout }
    public enum Group: String, Codable, CaseIterable {
        case cardiovascular = "Cardiovascular"
        case sleepRecovery = "Sleep and recovery"
        case activity = "Activity"
        case mobility = "Mobility"
        case bodyNutrition = "Body and nutrition"
        case other = "Additional"
    }

    public var id: String { rawIdentifier }
    /// Raw HealthKit identifier, e.g. "HKQuantityTypeIdentifierHeartRate".
    public let rawIdentifier: String
    public let displayName: String
    public let kind: Kind
    public let group: Group
    /// Unit string accepted by `HKUnit(from:)` and written into exports. nil for categories.
    public let unitString: String?
    public let aggregation: AggregationMethod
    /// Cumulative quantities (steps, energy, distance) where several sources overlap and HealthKit's
    /// statistics engine should be used for daily totals instead of summing raw samples.
    public var isCumulative: Bool { aggregation == .sum }
}

public enum HealthTypeCatalog {

    private static func q(_ id: String, _ name: String, _ group: HealthTypeDescriptor.Group, _ unit: String,
                          _ agg: AggregationMethod) -> HealthTypeDescriptor {
        HealthTypeDescriptor(rawIdentifier: "HKQuantityTypeIdentifier" + id, displayName: name, kind: .quantity,
                             group: group, unitString: unit, aggregation: agg)
    }
    private static func c(_ id: String, _ name: String, _ group: HealthTypeDescriptor.Group,
                          _ agg: AggregationMethod) -> HealthTypeDescriptor {
        HealthTypeDescriptor(rawIdentifier: "HKCategoryTypeIdentifier" + id, displayName: name, kind: .category,
                             group: group, unitString: nil, aggregation: agg)
    }

    public static let workout = HealthTypeDescriptor(rawIdentifier: "HKWorkoutTypeIdentifier", displayName: "Workouts",
                                                     kind: .workout, group: .other, unitString: "s", aggregation: .count)

    /// Every type the harness asks permission for. Order is the display order.
    public static let all: [HealthTypeDescriptor] = [
        // Cardiovascular
        q("HeartRate", "Heart rate", .cardiovascular, "count/min", .mean),
        q("HeartRateVariabilitySDNN", "HRV (SDNN)", .cardiovascular, "ms", .mean),
        q("RestingHeartRate", "Resting heart rate", .cardiovascular, "count/min", .mean),
        q("WalkingHeartRateAverage", "Walking heart rate average", .cardiovascular, "count/min", .mean),
        q("BloodPressureSystolic", "Blood pressure systolic", .cardiovascular, "mmHg", .mean),
        q("BloodPressureDiastolic", "Blood pressure diastolic", .cardiovascular, "mmHg", .mean),
        q("OxygenSaturation", "Blood oxygen saturation", .cardiovascular, "%", .mean),
        q("VO2Max", "VO2 max", .cardiovascular, "mL/kg*min", .mean),
        q("HeartRateRecoveryOneMinute", "Heart rate recovery (1 min)", .cardiovascular, "count/min", .mean),
        c("HighHeartRateEvent", "High heart rate events", .cardiovascular, .count),
        c("LowHeartRateEvent", "Low heart rate events", .cardiovascular, .count),
        c("IrregularHeartRhythmEvent", "Irregular rhythm events", .cardiovascular, .count),
        c("LowCardioFitnessEvent", "Low cardio fitness events", .cardiovascular, .count),

        // Sleep and recovery
        c("SleepAnalysis", "Sleep analysis", .sleepRecovery, .durationHours),
        q("RespiratoryRate", "Respiratory rate", .sleepRecovery, "count/min", .mean),
        q("AppleSleepingWristTemperature", "Sleeping wrist temperature", .sleepRecovery, "degC", .mean),
        q("BodyTemperature", "Body temperature", .sleepRecovery, "degC", .mean),

        // Activity
        q("StepCount", "Steps", .activity, "count", .sum),
        q("DistanceWalkingRunning", "Walking + running distance", .activity, "m", .sum),
        q("DistanceCycling", "Cycling distance", .activity, "m", .sum),
        q("ActiveEnergyBurned", "Active energy", .activity, "kcal", .sum),
        q("BasalEnergyBurned", "Resting energy", .activity, "kcal", .sum),
        q("AppleExerciseTime", "Exercise time", .activity, "min", .sum),
        q("AppleStandTime", "Stand time", .activity, "min", .sum),
        q("AppleMoveTime", "Move time", .activity, "min", .sum),
        q("FlightsClimbed", "Flights climbed", .activity, "count", .sum),
        q("PhysicalEffort", "Physical effort", .activity, "kcal/hr*kg", .mean),
        q("TimeInDaylight", "Time in daylight", .activity, "min", .sum),
        c("AppleStandHour", "Stand hours", .activity, .count),

        // Mobility
        q("WalkingSpeed", "Walking speed", .mobility, "m/s", .mean),
        q("WalkingStepLength", "Walking step length", .mobility, "m", .mean),
        q("WalkingAsymmetryPercentage", "Walking asymmetry", .mobility, "%", .mean),
        q("WalkingDoubleSupportPercentage", "Walking double support", .mobility, "%", .mean),
        q("AppleWalkingSteadiness", "Walking steadiness", .mobility, "%", .mean),
        q("SixMinuteWalkTestDistance", "Six-minute walk distance", .mobility, "m", .mean),
        q("StairAscentSpeed", "Stair ascent speed", .mobility, "m/s", .mean),
        q("StairDescentSpeed", "Stair descent speed", .mobility, "m/s", .mean),
        q("RunningSpeed", "Running speed", .mobility, "m/s", .mean),
        q("RunningPower", "Running power", .mobility, "W", .mean),

        // Body and nutrition
        q("BodyMass", "Weight", .bodyNutrition, "kg", .latest),
        q("Height", "Height", .bodyNutrition, "m", .latest),
        q("BodyMassIndex", "BMI", .bodyNutrition, "count", .latest),
        q("BodyFatPercentage", "Body fat", .bodyNutrition, "%", .latest),
        q("LeanBodyMass", "Lean body mass", .bodyNutrition, "kg", .latest),
        q("WaistCircumference", "Waist circumference", .bodyNutrition, "cm", .latest),
        q("DietaryEnergyConsumed", "Dietary energy", .bodyNutrition, "kcal", .sum),
        q("DietaryWater", "Water", .bodyNutrition, "L", .sum),
        q("DietaryProtein", "Protein", .bodyNutrition, "g", .sum),
        q("DietaryCarbohydrates", "Carbohydrates", .bodyNutrition, "g", .sum),
        q("DietaryFatTotal", "Fat (total)", .bodyNutrition, "g", .sum),
        q("DietaryFiber", "Fiber", .bodyNutrition, "g", .sum),
        q("DietarySugar", "Sugar", .bodyNutrition, "g", .sum),
        q("DietarySodium", "Sodium", .bodyNutrition, "mg", .sum),
        q("DietaryCaffeine", "Caffeine", .bodyNutrition, "mg", .sum),
        q("BloodGlucose", "Blood glucose", .bodyNutrition, "mg/dL", .mean),

        // Additional
        c("MindfulSession", "Mindful minutes", .other, .durationHours),
        q("EnvironmentalAudioExposure", "Environmental audio exposure", .other, "dBASPL", .mean),
        q("HeadphoneAudioExposure", "Headphone audio exposure", .other, "dBASPL", .mean),
        q("NumberOfTimesFallen", "Falls", .other, "count", .sum),
        workout
    ]

    public static let byIdentifier: [String: HealthTypeDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.rawIdentifier, $0) })

    public static func descriptor(for rawIdentifier: String) -> HealthTypeDescriptor? { byIdentifier[rawIdentifier] }

    /// Human label for a category value. Mirrors HKCategoryValue* enums so the XML importer and the
    /// HealthKit path produce the same strings.
    public static func categoryLabel(typeIdentifier: String, value: Int) -> String {
        switch typeIdentifier {
        case "HKCategoryTypeIdentifierSleepAnalysis":
            switch value {
            case 0: return "inBed"
            case 1: return "asleepUnspecified"
            case 2: return "awake"
            case 3: return "asleepCore"
            case 4: return "asleepDeep"
            case 5: return "asleepREM"
            default: return "value_\(value)"
            }
        case "HKCategoryTypeIdentifierAppleStandHour":
            return value == 0 ? "stood" : "idle"
        default:
            return value == 0 ? "notApplicable" : "value_\(value)"
        }
    }

    /// Sleep analysis values that count as asleep (everything except inBed and awake).
    public static func isAsleep(categoryValue: Int) -> Bool { [1, 3, 4, 5].contains(categoryValue) }

    /// Apple Health XML uses the same string for sleep values ("HKCategoryValueSleepAnalysisAsleepCore").
    public static func categoryValue(fromXMLString s: String) -> Int? {
        if let i = Int(s) { return i }
        let map: [String: Int] = [
            "HKCategoryValueSleepAnalysisInBed": 0, "HKCategoryValueSleepAnalysisAsleepUnspecified": 1,
            "HKCategoryValueSleepAnalysisAsleep": 1, "HKCategoryValueSleepAnalysisAwake": 2,
            "HKCategoryValueSleepAnalysisAsleepCore": 3, "HKCategoryValueSleepAnalysisAsleepDeep": 4,
            "HKCategoryValueSleepAnalysisAsleepREM": 5, "HKCategoryValueAppleStandHourStood": 0,
            "HKCategoryValueAppleStandHourIdle": 1, "HKCategoryValueNotApplicable": 0
        ]
        return map[s]
    }

#if canImport(HealthKit)
    /// The HKObjectType for a descriptor, or nil when this iOS version does not have it.
    public static func objectType(for d: HealthTypeDescriptor) -> HKObjectType? {
        switch d.kind {
        case .quantity:
            return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: d.rawIdentifier))
        case .category:
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: d.rawIdentifier))
        case .workout:
            return HKObjectType.workoutType()
        }
    }

    public static func sampleType(for d: HealthTypeDescriptor) -> HKSampleType? {
        objectType(for: d) as? HKSampleType
    }

    public static func unit(for d: HealthTypeDescriptor) -> HKUnit? {
        guard let s = d.unitString else { return nil }
        switch s {
        case "mL/kg*min":
            return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case "kcal/hr*kg":
            return HKUnit.kilocalorie().unitDivided(by: HKUnit.hour().unitMultiplied(by: HKUnit.gramUnit(with: .kilo)))
        default:
            return HKUnit(from: s)
        }
    }

    public static func workoutActivityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .walking: return "walking"
        case .running: return "running"
        case .cycling: return "cycling"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .swimming: return "swimming"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .traditionalStrengthTraining: return "traditionalStrengthTraining"
        case .highIntensityIntervalTraining: return "hiit"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stairClimbing"
        case .mindAndBody: return "mindAndBody"
        case .coreTraining: return "coreTraining"
        case .dance: return "dance"
        case .pilates: return "pilates"
        case .cooldown: return "cooldown"
        case .other: return "other"
        default: return "activityType_\(t.rawValue)"
        }
    }
#endif
}
