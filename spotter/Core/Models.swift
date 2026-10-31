import Foundation

enum Tracking: String, Codable, CaseIterable, Identifiable {
    case weightReps = "Weight & reps", bodyweight = "Bodyweight", assisted = "Assisted", timed = "Time", distance = "Distance & time"
    var id: String { rawValue }
}
enum WeightUnit: String, Codable, CaseIterable { case kg, lb
    func kilograms(_ value: Double) -> Double { self == .kg ? value : value * 0.45359237 }
    func pounds(_ value: Double) -> Double { self == .lb ? value : value / 0.45359237 }
    func value(fromPounds value: Double) -> Double { self == .lb ? value : value * 0.45359237 }
}
enum USDistanceUnit: String, CaseIterable, Identifiable {
    case feet = "ft", miles = "mi"
    var id: String { rawValue }
    var name: String { self == .feet ? "Feet" : "Miles" }
    var metersPerUnit: Double { self == .feet ? 0.3048 : 1609.344 }
    func value(meters: Double) -> Double { meters / metersPerUnit }
    func meters(_ value: Double) -> Double { value * metersPerUnit }
    static func preferred(for meters: Double) -> Self { meters >= 1609.344 ? .miles : .feet }
    static func summary(meters: Double) -> String {
        let unit = preferred(for: meters)
        return "\(unit.value(meters: meters).formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue)"
    }
}
struct Exercise: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var aliases: [String] = []
    var primary: String
    var secondary: [String] = []
    var equipment: String
    var pattern: String
    var tracking: Tracking = .weightReps
    var increment: Double? = nil
}
struct Profile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var cloudIdentity: String? = nil
    var isDemo: Bool = false
}
struct RIRTarget: Codable, Equatable {
    var low: Int
    var high: Int
    var valid: Bool { (0...10).contains(low) && (low...10).contains(high) }
    var summary: String { low == high ? "\(low)" : "\(low)–\(high)" }
}
struct Target: Codable, Equatable {
    var sets: Int = 3
    var low: Int = 8
    var high: Int = 12
    var rir: Int? = nil
    var rirRange: RIRTarget? = nil
    var perSetRIR: [RIRTarget?]? = nil
    var rest: Int? = 90
    var notes: String = ""
    var seconds: Double? = nil
    var meters: Double? = nil
    var valid: Bool {
        sets > 0 && sets <= 20 && low > 0 && high >= low
        && (rirRange?.valid ?? true)
        && (perSetRIR == nil || (perSetRIR?.count == sets && perSetRIR!.allSatisfy { $0?.valid ?? true }))
    }
    func rirTarget(for prescribedIndex: Int?) -> RIRTarget? {
        guard let index = prescribedIndex, (0..<sets).contains(index) else { return nil }
        if let perSetRIR { return perSetRIR.indices.contains(index) ? perSetRIR[index] : nil }
        return rirRange ?? rir.map { RIRTarget(low: $0, high: $0) }
    }
    var rirSummary: String? {
        if let perSetRIR { return "RIR by set: " + perSetRIR.map { $0?.summary ?? "—" }.joined(separator: ", ") }
        if let rirRange { return "\(rirRange.summary) RIR" }
        return rir.map { "\($0) RIR" }
    }
    mutating func resizeRIRTargets() {
        guard let values = perSetRIR else { return }
        perSetRIR = Array(values.prefix(sets)) + Array(repeating: nil, count: max(0, sets - values.count))
    }
}
struct PlannedExercise: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var exerciseID: String
    var target: Target = Target()
    var alternativeExerciseID: String? = nil
    var exerciseIDs: [String] { [exerciseID] + (alternativeExerciseID.map { $0 == exerciseID ? [] : [$0] } ?? []) }
    func contains(_ id: String) -> Bool { exerciseIDs.contains(id) }
}
struct TrainingDay: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var weekdays: [Int] = []
    var exercises: [PlannedExercise] = []
}
struct Plan: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var days: [TrainingDay] = []
}
struct Workout: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var started: Date = Date()
    var finished: Date? = nil
    var ownerID: String
    var title: String
    var shared: Bool = false
    var demo: Bool = false
    var isPreparing: Bool = false
}
struct Participant: Codable, Identifiable, Equatable {
    var id: String { "\(workoutID):\(profile.id)" }
    var workoutID: String
    var profile: Profile
    var day: TrainingDay?
    var skipped: [String] = []
    var currentEntryID: String? = nil
    var permitsPartnerLogging: Bool = false
    var finished: Date? = nil
    var deleted = false
    var increments: [String: Double] = [:]
    var incrementUnits: [String: WeightUnit]? = nil
    // The phone owner responsible for a locally managed profile.
    var managedByID: String? = nil
}
enum EntryStatus: String, Codable { case active, completed, skipped }
struct ExerciseEntry: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var workoutID: String
    var personID: String
    var exercise: Exercise
    var target: Target?
    var order: Int
    var status: EntryStatus = .active
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
}
struct WorkoutSet: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var workoutID: String
    var entryID: String
    var personID: String
    var enteredBy: String
    var modifiedBy: String
    var order: Int
    // A stable slot in the original prescription. nil means an extra set or warm-up.
    var prescribedIndex: Int?
    var weight: Double? = nil
    var unit: WeightUnit = .lb
    var reps: Int? = nil
    var fractionalReps: Double? = nil
    var rir: Int? = nil
    var recordedRIRRange: RIRTarget? = nil
    var bodyweightOnly: Bool? = nil
    var seconds: Double? = nil
    var meters: Double? = nil
    var warmup: Bool = false
    // Retained for decoding old records. New records are saved only when logged.
    var completed: Bool = false
    var notes: String = ""
    var loggedAt: Date? = nil
    var intervalSincePreviousSet: Double? = nil
    // Set timestamps mark completion; exclude the next set’s assumed duration.
    var timeBetweenSets: Double? { intervalSincePreviousSet.map { max(0, $0 - 30) } }
    var weightPounds: Double? { weight.map(unit.pounds) }
    var performedReps: Double? { fractionalReps ?? reps.map(Double.init) }
    var repsSummary: String { performedReps?.formatted(.number.grouping(.never)) ?? "—" }
    var recordedRIRSummary: String? { recordedRIRRange?.summary ?? rir.map(String.init) }
    var validNumbers: Bool {
        [weight, seconds, meters].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
        && (performedReps == nil || (performedReps!.isFinite && performedReps! > 0))
        && (recordedRIRRange?.valid ?? true) && (rir == nil || (0...10).contains(rir!))
    }
    func isComplete(for tracking: Tracking) -> Bool {
        guard validNumbers else { return false }
        switch tracking {
        case .weightReps, .assisted: return (weight != nil || bodyweightOnly == true) && performedReps != nil
        case .bodyweight: return performedReps != nil
        case .timed: return (seconds ?? 0) > 0
        case .distance: return (meters ?? 0) > 0 && (seconds ?? 0) > 0
        }
    }
}
enum Payload: Codable, Equatable {
    case workout(Workout), participant(Participant), entry(ExerciseEntry), set(WorkoutSet), baseline(SharedBaseline)
    var entityID: String {
        switch self { case .workout(let x): return x.id; case .participant(let x): return x.id; case .entry(let x): return x.id; case .set(let x): return x.id; case .baseline(let x): return x.id }
    }
    var workoutID: String {
        switch self { case .workout(let x): return x.id; case .participant(let x): return x.workoutID; case .entry(let x): return x.workoutID; case .set(let x): return x.workoutID; case .baseline(let x): return x.workoutID }
    }
}
// Immutable revisions are shared by both transports. No wall-clock last-writer-wins.
struct Revision: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var entityID: String
    var workoutID: String
    var parents: [String]
    var authorID: String
    var date: Date = Date()
    var value: Payload? // tombstone; retained so an offline edit cannot resurrect silently
}
struct Ledger: Codable, Equatable {
    var revisions: [Revision] = []
    mutating func merge(_ incoming: [Revision]) {
        var known = Set(revisions.map(\.id))
        for revision in incoming where known.insert(revision.id).inserted { revisions.append(revision) }
    }
    func heads(_ entityID: String) -> [Revision] {
        let history = revisions.filter { $0.entityID == entityID }
        let replaced = Set(history.flatMap(\.parents))
        return history.filter { !replaced.contains($0.id) }.sorted { $0.id < $1.id }
    }
    var conflicts: [[Revision]] {
        Set(revisions.map(\.entityID)).sorted().map(heads).filter { $0.count > 1 }
    }
    var values: [Payload] {
        Dictionary(grouping: revisions, by: \.entityID).values.compactMap { history in
            let replaced = Set(history.flatMap(\.parents))
            return history.filter { !replaced.contains($0.id) }.min { $0.id < $1.id }?.value
        }
    }
    mutating func write(_ value: Payload?, entityID: String, workoutID: String, author: String) {
        revisions.append(Revision(entityID: entityID, workoutID: workoutID, parents: heads(entityID).map(\.id), authorID: author, value: value))
    }
    var workouts: [Workout] { values.compactMap { if case .workout(let x) = $0 { return x }; return nil }.sorted { $0.started > $1.started } }
    func workouts(for personID: String) -> [Workout] {
        let ownMembers = Dictionary(uniqueKeysWithValues: participants.filter { $0.profile.id == personID }.map { ($0.workoutID, $0) })
        return workouts.filter { ownMembers[$0.id]?.deleted != true }.map { workout in
            var personal = workout
            personal.finished = ownMembers[workout.id]?.finished ?? workout.finished
            return personal
        }
    }
    var participants: [Participant] { values.compactMap { if case .participant(let x) = $0 { return x }; return nil } }
    var entries: [ExerciseEntry] { values.compactMap { if case .entry(let x) = $0 { return x }; return nil }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order } }
    var sets: [WorkoutSet] { values.compactMap { if case .set(let x) = $0 { return x }; return nil }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order } }
    func sets(for entry: ExerciseEntry) -> [WorkoutSet] { sets.filter { $0.entryID == entry.id && $0.personID == entry.personID } }
}
struct SharedBaseline: Codable, Equatable {
    var id: String
    var workoutID: String
    var personID: String
    var previous: PreviousPerformance
}
struct PreviousPerformance: Codable, Equatable {
    var workout: Workout
    var entry: ExerciseEntry
    var sets: [WorkoutSet]
}
struct Progression: Equatable {
    var weight: Double
    var unit: WeightUnit
    var sets: Int
    var reps: Int
    var nextWeight: Double?
    var weightPounds: Double { unit.pounds(weight) }
    var nextWeightPounds: Double? { nextWeight.map(unit.pounds) }
    var explanation: String {
        "You reached \(reps) reps on all \(sets) working sets at \(weightPounds.formatted(.number.precision(.fractionLength(0...2)))) lb last time. Consider increasing the weight."
    }
}
enum WorkoutEngine {
    static func previous(personID: String, exerciseID: String, excluding: String?, ledger: Ledger) -> PreviousPerformance? {
        let entries = ledger.entries.filter { $0.personID == personID && $0.exercise.id == exerciseID }
        let sets = Dictionary(grouping: ledger.sets.filter { $0.personID == personID && $0.completed }, by: \.entryID)
        for workout in ledger.workouts(for: personID) where workout.id != excluding && workout.finished != nil {
            if let entry = entries.last(where: { $0.workoutID == workout.id && !(sets[$0.id] ?? []).isEmpty }) {
                return PreviousPerformance(workout: workout, entry: entry, sets: sets[entry.id] ?? [])
            }
        }
        return nil
    }
    static func progression(_ previous: PreviousPerformance, increment: Double?) -> Progression? {
        guard previous.workout.finished != nil, previous.entry.exercise.tracking == .weightReps,
              let target = previous.entry.target, target.valid else { return nil }
        let working = previous.sets.filter { !$0.warmup && $0.personID == previous.entry.personID && $0.entryID == previous.entry.id && $0.prescribedIndex != nil }
        var prescribed: [WorkoutSet] = []
        for slot in 0..<target.sets {
            let matching = working.filter { $0.prescribedIndex == slot }
            guard matching.count == 1, let set = matching.first, set.completed, (set.reps ?? 0) >= target.high, set.weight?.isFinite == true else { return nil }
            prescribed.append(set)
        }
        guard let first = prescribed.first, let weight = first.weight, weight > 0,
              prescribed.allSatisfy({ abs($0.unit.pounds($0.weight ?? 0) - first.unit.pounds(weight)) < 0.000001 }) else { return nil }
        return Progression(weight: weight, unit: first.unit, sets: target.sets, reps: target.high,
                           nextWeight: increment.flatMap { $0 > 0 ? weight + $0 : nil })
    }
    static func recommended(_ member: Participant, ledger: Ledger) -> String? {
        member.day?.exercises.first { planned in
            !planned.exerciseIDs.contains(where: { member.skipped.contains($0) }) && !ledger.entries.contains { $0.workoutID == member.workoutID && $0.personID == member.profile.id && planned.contains($0.exercise.id) && $0.status == .completed }
        }?.exerciseID
    }
    // Each person follows their own exercise order. Switching never copies a friend's exercise.
    static func defaultExercise(personID: String, previousPersonID: String, workoutID: String, ledger: Ledger) -> String? {
        let members = ledger.participants.filter { $0.workoutID == workoutID }
        return members.first(where: { $0.profile.id == personID }).flatMap { recommended($0, ledger: ledger) }
    }
    static func search(_ query: String, exercises: [Exercise], names: [String: String]) -> [Exercise] {
        exercises.filter { exercise in
            query.isEmpty || ([names[exercise.id] ?? "", exercise.name, exercise.primary, exercise.equipment, exercise.pattern, exercise.tracking.rawValue] + exercise.aliases + exercise.secondary).contains { $0.localizedStandardContains(query) }
        }.sorted { (names[$0.id] ?? $0.name).localizedStandardCompare(names[$1.id] ?? $1.name) == .orderedAscending }
    }
}

extension Workout {
    enum CodingKeys: String, CodingKey { case id, started, finished, ownerID, title, shared, demo, isPreparing }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        started = try values.decode(Date.self, forKey: .started)
        finished = try values.decodeIfPresent(Date.self, forKey: .finished)
        ownerID = try values.decode(String.self, forKey: .ownerID)
        title = try values.decode(String.self, forKey: .title)
        shared = try values.decode(Bool.self, forKey: .shared)
        demo = try values.decode(Bool.self, forKey: .demo)
        isPreparing = try values.decodeIfPresent(Bool.self, forKey: .isPreparing) ?? false
    }
}

extension Participant {
    enum CodingKeys: String, CodingKey { case workoutID, profile, day, skipped, currentEntryID, permitsPartnerLogging, finished, deleted, increments, incrementUnits, managedByID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workoutID = try values.decode(String.self, forKey: .workoutID)
        profile = try values.decode(Profile.self, forKey: .profile)
        day = try values.decodeIfPresent(TrainingDay.self, forKey: .day)
        skipped = try values.decodeIfPresent([String].self, forKey: .skipped) ?? []
        currentEntryID = try values.decodeIfPresent(String.self, forKey: .currentEntryID)
        permitsPartnerLogging = try values.decodeIfPresent(Bool.self, forKey: .permitsPartnerLogging) ?? false
        finished = try values.decodeIfPresent(Date.self, forKey: .finished)
        deleted = try values.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        increments = try values.decodeIfPresent([String: Double].self, forKey: .increments) ?? [:]
        incrementUnits = try values.decodeIfPresent([String: WeightUnit].self, forKey: .incrementUnits)
        managedByID = try values.decodeIfPresent(String.self, forKey: .managedByID)
    }
}

extension Target {
    func summary(for tracking: Tracking) -> String {
        let prefix = "\(sets) working sets"
        let rirSuffix = rirSummary.map { " · " + $0 } ?? ""
        switch tracking {
        case .timed, .distance:
            let values = [seconds.map { "\($0.formatted()) sec" }, tracking == .distance ? meters.map { USDistanceUnit.summary(meters: $0) } : nil].compactMap { $0 }
            return ([prefix] + values).joined(separator: " · ") + rirSuffix
        default: return "\(prefix) · \(low)–\(high) reps" + rirSuffix
        }
    }
}
