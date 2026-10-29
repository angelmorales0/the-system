import Foundation

extension Notification.Name {
    static let healthDataDidChange = Notification.Name("com.angelmorales.thesystem.healthDataDidChange")
    static let stepsDidChange = Notification.Name("com.angelmorales.thesystem.stepsDidChange")
}

/// Reads workouts, weight, and steps. For weight, MacroFactor is preferred when its samples are present.
/// There is no MacroFactor API. The app only sees what MacroFactor wrote into Apple Health.
enum HealthKitBridge {
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

    /// Everything the app asks to read. Steps are read but observed separately.
    private static var readTypes: [HKSampleType] {
        sampleTypes + (stepType.map { [$0] } ?? [])
    }

    private static var sampleTypes: [HKSampleType] {
        var types: [HKSampleType] = []
        if let mass = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            types.append(mass)
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
