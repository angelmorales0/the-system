import Foundation

extension Notification.Name {
    static let healthDataDidChange = Notification.Name("com.angelmorales.thesystem.healthDataDidChange")
}

/// Reads workouts, nutrition, weight, and sleep. MacroFactor is preferred when its samples are present.
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

    static func startObservers() {
        #if canImport(HealthKit)
        HealthKitStore.shared.startObservers()
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
            try await store.requestAuthorization(toShare: [], read: Set(Self.sampleTypes))
        } catch {
            return .unavailable
        }
        let interval = QuestDay.calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        async let protein = quantitySum(.dietaryProtein, unit: .gram(), predicate: predicate)
        async let energy = quantitySum(.dietaryEnergyConsumed, unit: .kilocalorie(), predicate: predicate)
        async let mass = latestQuantity(.bodyMass, unit: .gram(), predicate: predicate)
        async let sleep = sleepHours(predicate: predicate)
        async let workouts = workoutEvents(predicate: predicate)
        let proteinResult = await protein
        let massResult = await mass
        return HealthDaySummary(
            access: .requested,
            proteinGrams: proteinResult.total,
            proteinPrefersMacroFactor: proteinResult.prefersMacroFactor,
            energyKcal: await energy.total,
            bodyMassKg: massResult.total.map { $0 / 1000 },
            bodyMassPrefersMacroFactor: massResult.prefersMacroFactor,
            sleepAsleepHours: await sleep,
            workouts: await workouts
        )
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
    }

    private func quantitySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async -> MacroFactorTotal {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return .empty }
        let samples: [HKQuantitySample] = await samples(type: type, predicate: predicate)
        let chosen = MacroFactorSamples.prefer(samples)
        let total = chosen.reduce(0) { $0 + $1.quantity.doubleValue(for: unit) }
        return MacroFactorTotal(total: total, prefersMacroFactor: MacroFactorSamples.containsMacroFactor(samples))
    }

    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async -> MacroFactorOptional {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return .empty }
        let samples: [HKQuantitySample] = await samples(type: type, predicate: predicate)
        let chosen = MacroFactorSamples.prefer(samples)
        guard let latest = chosen.max(by: { $0.startDate < $1.startDate }) else { return .empty }
        return MacroFactorOptional(
            total: latest.quantity.doubleValue(for: unit),
            prefersMacroFactor: MacroFactorSamples.isMacroFactor(latest)
        )
    }

    private func sleepHours(predicate: NSPredicate) async -> Double {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return 0 }
        let samples: [HKCategorySample] = await samples(type: type, predicate: predicate)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let seconds = samples.reduce(0.0) { total, sample in
            guard asleep.contains(sample.value) else { return total }
            return total + sample.endDate.timeIntervalSince(sample.startDate)
        }
        return seconds / 3600
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

    private static var sampleTypes: [HKSampleType] {
        var types: [HKSampleType] = []
        for identifier in [HKQuantityTypeIdentifier.dietaryProtein, .dietaryEnergyConsumed, .bodyMass] {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.append(type)
            }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            types.append(sleep)
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
        default: "other"
        }
    }
}

private struct MacroFactorTotal {
    var total: Double
    var prefersMacroFactor: Bool
    static let empty = MacroFactorTotal(total: 0, prefersMacroFactor: false)
}

private struct MacroFactorOptional {
    var total: Double?
    var prefersMacroFactor: Bool
    static let empty = MacroFactorOptional(total: nil, prefersMacroFactor: false)
}

/// MacroFactor writes Apple Health under a source whose name or bundle id contains "macrofactor".
enum MacroFactorSamples {
    static func isMacroFactor(_ sample: HKQuantitySample) -> Bool {
        let source = sample.sourceRevision.source
        let name = source.name.lowercased()
        let bundle = source.bundleIdentifier.lowercased()
        return name.contains("macrofactor") || bundle.contains("macrofactor")
    }

    static func containsMacroFactor(_ samples: [HKQuantitySample]) -> Bool {
        samples.contains(where: isMacroFactor)
    }

    static func prefer(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        let preferred = samples.filter(isMacroFactor)
        return preferred.isEmpty ? samples : preferred
    }
}
#endif
