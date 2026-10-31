import Foundation
struct TrendPoint: Identifiable {
    var id: String
    var date: Date
    var weight: Double?
    var reps: Double?
    var estimatedMax: Double?
    var seconds: Double?
    var meters: Double?
}
struct TrainingSummary {
    var workouts = 0
    var workingSets = 0
    var volumeKG: Double = 0
    var volumePounds: Double { WeightUnit.kg.pounds(volumeKG) }
    var exposure: [String: Int] = [:]
    var weeklyWorkouts: [Date: Int] = [:]
    var monthlyExposure: [Date: [String: Int]] = [:]
}
enum ProgressEngine {
    static func volumePounds(entries: [ExerciseEntry], sets: [WorkoutSet]) -> Double {
        let weightedEntries = Dictionary(entries.filter { $0.exercise.tracking == .weightReps }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sets.reduce(0) { total, set in
            guard let entry = weightedEntries[set.entryID],
                  entry.workoutID == set.workoutID, entry.personID == set.personID,
                  set.completed, !set.warmup, set.bodyweightOnly != true,
                  let weight = set.weightPounds, let reps = set.performedReps,
                  weight.isFinite, reps.isFinite, weight > 0, reps > 0 else { return total }
            return total + weight * reps
        }
    }

    static func trends(personID: String, exerciseID: String, since: Date, ledger: Ledger) -> [TrendPoint] {
        let allEntries = ledger.entries.filter { $0.personID == personID && $0.exercise.id == exerciseID }
        let allSets = Dictionary(grouping: ledger.sets.filter { $0.personID == personID && $0.completed && !$0.warmup }, by: \.entryID)
        return ledger.workouts(for: personID).filter { $0.finished != nil && $0.started >= since }.reversed().compactMap { workout in
            let entries = allEntries.filter { $0.workoutID == workout.id }
            let sets = entries.flatMap { allSets[$0.id] ?? [] }
            guard !sets.isEmpty else { return nil }
            let weighted = entries.first?.exercise.tracking == .weightReps
            let bestEstimate = weighted ? sets.compactMap { set -> Double? in
                guard let weight = set.weight, let reps = set.performedReps, set.bodyweightOnly != true, weight > 0, (1...12).contains(reps) else { return nil }
                let rir = set.recordedRIRRange.map { Double($0.low + $0.high) / 2 } ?? Double(set.rir ?? 0)
                return set.unit.kilograms(weight) * (1 + (Double(reps) + rir) / 30)
            }.max() : nil
            return TrendPoint(id: workout.id, date: workout.started, weight: sets.filter { $0.bodyweightOnly != true }.compactMap { $0.weight.map($0.unit.kilograms) }.max(), reps: sets.compactMap(\.performedReps).max(), estimatedMax: bestEstimate, seconds: sets.compactMap(\.seconds).max(), meters: sets.compactMap(\.meters).max())
        }
    }
    static func summary(personID: String, since: Date, ledger: Ledger) -> TrainingSummary {
        var result = TrainingSummary()
        let allEntries = Dictionary(grouping: ledger.entries.filter { $0.personID == personID }, by: \.workoutID)
        let allSets = Dictionary(grouping: ledger.sets.filter { $0.personID == personID && $0.completed }, by: \.entryID)
        for workout in ledger.workouts(for: personID) where workout.finished != nil && workout.started >= since {
            let entries = allEntries[workout.id] ?? []
            let performed = entries.filter { !(allSets[$0.id] ?? []).isEmpty }
            guard !performed.isEmpty else { continue }
            result.workouts += 1
            let week = Calendar.current.dateInterval(of: .weekOfYear, for: workout.started)!.start
            let month = Calendar.current.dateInterval(of: .month, for: workout.started)!.start
            result.weeklyWorkouts[week, default: 0] += 1
            for entry in performed {
                let sets = (allSets[entry.id] ?? []).filter { !$0.warmup }
                result.workingSets += sets.count
                result.exposure[entry.exercise.primary, default: 0] += sets.count
                result.monthlyExposure[month, default: [:]][entry.exercise.primary, default: 0] += sets.count
                if entry.exercise.tracking == .weightReps {
                    result.volumeKG += sets.filter { $0.bodyweightOnly != true }.reduce(0) { $0 + $1.unit.kilograms($1.weight ?? 0) * ($1.performedReps ?? 0) }
                }
            }
        }
        return result
    }
}
