import Foundation

extension Notification.Name {
    static let healthDataDidChange = Notification.Name("com.angelmorales.thesystem.healthDataDidChange")
    static let stepsDidChange = Notification.Name("com.angelmorales.thesystem.stepsDidChange")
}

/// Stat inputs from Apple Health: 90 days of nutrition and weight by local day (MacroFactor first), VO₂ max readings,
/// 180 days of workouts, and the max heart rate (220 minus the age from the Health date of birth) for zone 2.
struct HealthStatInputs: Equatable {
    /// False when Health is unavailable or access was refused.
    var available = false
    /// Rows with only the nutrition and weight fields set.
    var nutritionDays: [RecoveryDay] = []
    var vo2: [VO2MaxReading] = []
    var workouts: [WorkoutEvent] = []
    var maxHeartRate: Double?
}

/// Reads workouts, weight, steps, nutrition, VO₂ max, and heart rate. For weight and nutrition, MacroFactor is
/// preferred when its samples are present. There is no MacroFactor API. The app only sees what it wrote into Apple Health.
enum HealthKitBridge {
    /// The stat histories. Empty when Health is unavailable.
    static func statInputs(now: Date) async -> HealthStatInputs {
        #if canImport(HealthKit)
        return await HealthKitStore.shared.statInputs(now: now)
        #else
        _ = now
        return HealthStatInputs()
        #endif
    }

    /// Heart rate samples between `start` and `end`, oldest first, for the zone 2 target.
    static func heartRate(from start: Date, to end: Date) async -> [HeartRateSample] {
        #if canImport(HealthKit)
        return await HealthKitStore.shared.heartRate(from: start, to: end)
        #else
        _ = (start, end)
        return []
        #endif
    }

    static func summary(on day: Date) async -> HealthDaySummary {
        #if canImport(HealthKit)
        return await HealthKitStore.shared.summary(on: day)
        #else
        _ = day
        return .unavailable
        #endif
    }

    /// The newest weigh-in from `days` before `now` up to `now`, MacroFactor's trend weight first. Nil without one.
    static func latestBodyMass(days: Int, now: Date) async -> BodyMassReading? {
        #if canImport(HealthKit)
        return await HealthKitStore.shared.latestBodyMass(since: now.addingTimeInterval(-Double(days) * 86_400), until: now)
        #else
        _ = (days, now)
        return nil
        #endif
    }

    static func startObservers() {
        #if canImport(HealthKit)
        HealthKitStore.shared.startObservers()
        #endif
    }

    /// Steps from `start` to `end`, de-duplicated across iPhone and Watch. Nil when Health is unavailable or locked.
    static func steps(from start: Date, to end: Date) async -> Int? {
        #if canImport(HealthKit)
        return await HealthKitStore.shared.steps(from: start, to: end)
        #else
        _ = (start, end)
        return nil
        #endif
    }
}

#if canImport(HealthKit)
import HealthKit

final class HealthKitStore {
    static let shared = HealthKitStore()

    private let store = HKHealthStore()
    private var observing = false

    private init() {}

    func summary(on day: Date) async -> HealthDaySummary {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        do {
            try await store.requestAuthorization(toShare: [], read: Set(Self.readTypes))
        } catch {
            return .unavailable
        }
        let interval = QuestDay.interval(for: day)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        return HealthDaySummary(access: .requested, workouts: await workoutEvents(predicate: predicate))
    }

    func startObservers() {
        guard HKHealthStore.isHealthDataAvailable(), !observing else { return }
        observing = true
        for type in Self.sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if error == nil {
                    NotificationCenter.default.post(name: .healthDataDidChange, object: nil)
                }
                completion()
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
        // Steps get their own signal, so a step sample does not reload every integration.
        // Hourly is the most often iOS delivers steps in the background.
        if let steps = Self.stepType {
            let query = HKObserverQuery(sampleType: steps, predicate: nil) { _, completion, error in
                if error == nil {
                    NotificationCenter.default.post(name: .stepsDidChange, object: nil)
                }
                completion()
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: steps, frequency: .hourly) { _, _ in }
        }
    }

    func steps(from start: Date, to end: Date) async -> Int? {
        guard HKHealthStore.isHealthDataAvailable(), let type = Self.stepType, end > start else { return nil }
        do {
            try await store.requestAuthorization(toShare: [], read: Set(Self.readTypes))
        } catch {
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let sum = stats?.sumQuantity() {
                    continuation.resume(returning: Int(sum.doubleValue(for: .count()).rounded(.down)))
                } else if let error = error as? HKError, error.code == .errorNoData {
                    continuation.resume(returning: 0)
                } else {
                    continuation.resume(returning: error == nil ? 0 : nil)
                }
            }
            store.execute(query)
        }
    }

    func latestBodyMass(since start: Date, until end: Date) async -> BodyMassReading? {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKQuantitySample] = await samples(type: type, predicate: predicate)
        guard let latest = MacroFactorSamples.prefer(samples).max(by: { $0.startDate < $1.startDate }) else { return nil }
        return BodyMassReading(
            kg: latest.quantity.doubleValue(for: .gramUnit(with: .kilo)),
            date: latest.startDate,
            source: MacroFactorSamples.isMacroFactor(latest) ? "MacroFactor" : "Apple Health"
        )
    }

    /// See `HealthStatInputs`. Days are local calendar days, so they line up with MacroFactor's log and WHOOP's cycles.
    func statInputs(now: Date) async -> HealthStatInputs {
        guard HKHealthStore.isHealthDataAvailable() else { return HealthStatInputs() }
        do {
            try await store.requestAuthorization(toShare: [], read: Set(Self.readTypes))
        } catch {
            return HealthStatInputs()
        }
        var inputs = HealthStatInputs(available: true)
        let zone = QuestDay.timeZone
        let recoveryStart = now.addingTimeInterval(-Double(RecoveryLevel.baselineDays) * 86_400)
        let recoveryPredicate = HKQuery.predicateForSamples(withStart: recoveryStart, end: now, options: [])
        var days: [String: RecoveryDay] = [:]

        for (identifier, unit, keyPath) in Self.dietaryTypes {
            for (key, total) in await dailySums(identifier, unit: unit, predicate: recoveryPredicate, zone: zone, preferMacroFactor: true) {
                days[key, default: RecoveryDay(dayKey: key)][keyPath: keyPath] = Optional(total)
            }
        }
        // Expenditure: active plus basal energy, on days that have both (an Apple Watch). Health has no MacroFactor estimate.
        let active = await dailySums(.activeEnergyBurned, unit: .kilocalorie(), predicate: recoveryPredicate, zone: zone, preferMacroFactor: false)
        let basal = await dailySums(.basalEnergyBurned, unit: .kilocalorie(), predicate: recoveryPredicate, zone: zone, preferMacroFactor: false)
        for (key, moving) in active {
            guard let resting = basal[key], moving > 0, resting > 0 else { continue }
            days[key, default: RecoveryDay(dayKey: key)].maintenanceKcal = moving + resting
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            let samples: [HKQuantitySample] = await samples(type: type, predicate: recoveryPredicate)
            for (key, group) in Dictionary(grouping: samples, by: { OnDeviceTime.dayKey($0.startDate, zone: zone) }) {
                guard let latest = MacroFactorSamples.prefer(group).max(by: { $0.startDate < $1.startDate }) else { continue }
                days[key, default: RecoveryDay(dayKey: key)].bodyMassKg = latest.quantity.doubleValue(for: .gramUnit(with: .kilo))
            }
        }
        inputs.nutritionDays = days.keys.sorted().compactMap { days[$0] }

        if let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) {
            let start = now.addingTimeInterval(-Double(EnduranceLevel.vo2WindowDays) * 86_400)
            let samples: [HKQuantitySample] = await samples(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: now, options: []))
            inputs.vo2 = samples.map { VO2MaxReading(value: $0.quantity.doubleValue(for: Self.vo2Unit), date: $0.startDate, source: "Apple Health") }
        }
        let effortStart = now.addingTimeInterval(-Double(EnduranceLevel.effortWindowDays) * 86_400)
        inputs.workouts = await workoutEvents(predicate: HKQuery.predicateForSamples(withStart: effortStart, end: now, options: []))
        if let birth = try? store.dateOfBirthComponents(), let born = Calendar.current.date(from: birth) {
            let age = Calendar.current.dateComponents([.year], from: born, to: now).year ?? 0
            if age > 0 { inputs.maxHeartRate = ZoneTwo.maxHeartRate(age: age) }
        }
        return inputs
    }

    func heartRate(from start: Date, to end: Date) async -> [HeartRateSample] {
        guard HKHealthStore.isHealthDataAvailable(), end > start,
              let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let samples: [HKQuantitySample] = await samples(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []))
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.map { HeartRateSample(time: $0.startDate, bpm: $0.quantity.doubleValue(for: unit)) }.sorted { $0.time < $1.time }
    }

    /// Local day → the sum of one quantity. With `preferMacroFactor`, a day with MacroFactor samples sums only those.
    private func dailySums(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate, zone: TimeZone, preferMacroFactor: Bool) async -> [String: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [:] }
        let samples: [HKQuantitySample] = await samples(type: type, predicate: predicate)
        var sums: [String: Double] = [:]
        for (key, group) in Dictionary(grouping: samples, by: { OnDeviceTime.dayKey($0.startDate, zone: zone) }) {
            let counted = preferMacroFactor ? MacroFactorSamples.prefer(group) : group
            sums[key] = counted.reduce(0) { $0 + $1.quantity.doubleValue(for: unit) }
        }
        return sums
    }

    private func workoutEvents(predicate: NSPredicate) async -> [WorkoutEvent] {
        let samples: [HKWorkout] = await samples(type: HKWorkoutType.workoutType(), predicate: predicate)
        return samples.map { workout in
            WorkoutEvent(
                source: "healthkit",
                externalId: workout.uuid.uuidString,
                sport: Self.sportName(workout.workoutActivityType),
                start: workout.startDate,
                end: workout.endDate,
                movingTimeSec: workout.duration,
                distanceMeters: workout.totalDistance?.doubleValue(for: .meter())
            )
        }
    }

    private func samples<T: HKSample>(type: HKSampleType, predicate: NSPredicate) async -> [T] {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [T]) ?? [])
            }
            store.execute(query)
        }
    }

    private static var stepType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: .stepCount) }

    /// The nutrition the REC stat reads, with its unit and the `RecoveryDay` field it fills.
    private static let dietaryTypes: [(HKQuantityTypeIdentifier, HKUnit, WritableKeyPath<RecoveryDay, Double?>)] = [
        (.dietaryProtein, .gram(), \.proteinG),
        (.dietaryFatTotal, .gram(), \.fatG),
        (.dietaryCarbohydrates, .gram(), \.carbsG),
        (.dietaryEnergyConsumed, .kilocalorie(), \.caloriesKcal),
        (.dietaryCaffeine, .gramUnit(with: .milli), \.caffeineMg),
    ]

    /// mL/kg/min.
    private static let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    /// Everything the app asks to read. Steps are read but observed separately.
    private static var readTypes: [HKObjectType] {
        var types: [HKObjectType] = sampleTypes + (stepType.map { [$0] } ?? [])
        let quantities: [HKQuantityTypeIdentifier] = dietaryTypes.map(\.0) + [.activeEnergyBurned, .basalEnergyBurned, .vo2Max, .heartRate]
        types += quantities.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
        if let birth = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            types.append(birth)
        }
        return types
    }

    /// Observed for changes: a new weigh-in, workout, or food log reloads the integrations.
    private static var sampleTypes: [HKSampleType] {
        var types: [HKSampleType] = []
        if let mass = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            types.append(mass)
        }
        if let food = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) {
            types.append(food)
        }
        types.append(HKWorkoutType.workoutType())
        return types
    }

    private static func sportName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "running"
        case .cycling: "cycling"
        case .walking: "walking"
        case .hiking: "hiking"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "traditionalStrengthTraining"
        case .swimming: "swimming"
        case .flexibility, .yoga, .cooldown, .mindAndBody: "flexibility"
        default: "other"
        }
    }
}

/// MacroFactor writes Apple Health under a source whose name or bundle id contains "macrofactor".
nonisolated enum MacroFactorSamples {
    static func isMacroFactor(_ sample: HKQuantitySample) -> Bool {
        let source = sample.sourceRevision.source
        let name = source.name.lowercased()
        let bundle = source.bundleIdentifier.lowercased()
        return name.contains("macrofactor") || bundle.contains("macrofactor")
    }

    static func prefer(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        let preferred = samples.filter(isMacroFactor)
        return preferred.isEmpty ? samples : preferred
    }
}
#endif
