import Foundation
import CryptoKit

struct WorkoutImportDraft {
    var workouts: [Workout]
    var entries: [[ExerciseEntry]]
    var sets: [[WorkoutSet]]
    var review: ImportedPlan
    var warnings: [String]
    var profile: Profile
}

enum WorkoutCSV {
    static func parse(_ text: String, year: Int, unit: WeightUnit, profile: Profile, library: [Exercise], names: [String: String] = [:]) throws -> WorkoutImportDraft {
        guard (1900...2100).contains(year) else { throw PlanCSVError(message: "Choose a year between 1900 and 2100.") }
        let rows = try PlanCSV.records(text)
        guard let header = rows.firstIndex(where: { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.prefix(6).elementsEqual(["date", "exercise", "weight", "reps", "rir", "notes"]) }) else {
            throw PlanCSVError(message: "Use Date, Exercise, Weight, Reps, RIR, Notes columns.")
        }
        let fingerprint = SHA256.hash(data: Data("\(profile.id)|\(year)|\(unit.rawValue)|\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
        var result = WorkoutImportDraft(workouts: [], entries: [], sets: [], review: ImportedPlan(plan: Plan(name: "History"), exercises: []), warnings: [], profile: profile)
        var currentEntry = -1
        var carriedWeight = ""
        for (index, row) in rows.enumerated() where index > header {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if cells.allSatisfy({ $0.isEmpty }) { continue }
            guard cells.count >= 6, cells.dropFirst(6).allSatisfy({ $0.isEmpty }) else { throw PlanCSVError(message: "Row \(index + 1): expected six CSV columns.") }
            var notes = cells[5]
            func preserve(_ message: String) { notes = [notes, message].filter { !$0.isEmpty }.joined(separator: "\n") }
            if !cells[0].isEmpty {
                if cells[0].contains("-") || cells[0].contains("/") {
                    let date = try date(cells[0], defaultYear: year)
                    if let previous = result.workouts.last?.started, date < previous {
                        result.warnings.append("Row \(index + 1): \(cells[0]) is earlier than the preceding workout. Check its year in the preview.")
                    }
                    let id = "csv-\(fingerprint)-\(result.workouts.count)"
                    result.workouts.append(Workout(id: id, started: date, finished: date, ownerID: profile.id, title: "Imported workout"))
                    result.entries.append([]); result.sets.append([])
                    result.review.plan.days.append(TrainingDay(name: cells[0]))
                    currentEntry = -1; carriedWeight = ""
                } else {
                    guard !result.workouts.isEmpty else { throw PlanCSVError(message: "Row \(index + 1): enter a date such as 8-24 or 9-1-26.") }
                    preserve("Date-column annotation: \(cells[0])")
                    result.warnings.append("Row \(index + 1): date-column value ‘\(cells[0])’ is preserved in notes under the preceding date.")
                }
            }
            guard let workout = result.workouts.last else { throw PlanCSVError(message: "Row \(index + 1): the first set needs a date.") }
            let day = result.workouts.count - 1
            if !cells[1].isEmpty {
                let matches = ExerciseNameMatcher.matches(cells[1], exercises: library + result.review.exercises, names: names)
                let custom = matches.first { match in result.review.exercises.contains { $0.id == match.id } }
                let exercise: Exercise
                if let custom { exercise = custom }
                else if matches.count == 1 { exercise = matches[0] }
                else {
                    exercise = Exercise(id: UUID().uuidString, name: cells[1], primary: "Other", equipment: "Other", pattern: "Other", tracking: cells[2].lowercased() == "bw" ? .bodyweight : .weightReps)
                    result.review.exercises.append(exercise)
                    result.review.originalNames[exercise.id] = cells[1]
                }
                currentEntry = result.entries[day].count
                let entry = ExerciseEntry(workoutID: workout.id, personID: profile.id, exercise: exercise, order: currentEntry, status: .completed)
                result.entries[day].append(entry)
                result.review.plan.days[day].exercises.append(PlannedExercise(id: entry.id, exerciseID: exercise.id))
                carriedWeight = ""
            }
            guard currentEntry >= 0 else { throw PlanCSVError(message: "Row \(index + 1): the first set on each date needs an exercise name.") }
            guard let reps = Double(cells[3]), reps.isFinite, reps > 0, reps <= 10000 else { throw PlanCSVError(message: "Row \(index + 1): reps must be a positive number, including fractions such as 2.5.") }
            if !cells[2].isEmpty { carriedWeight = cells[2] }
            let bodyweight = ["bw", "bodyweight"].contains(carriedWeight.lowercased())
            let weight = Double(carriedWeight)
            if let weight, !weight.isFinite || weight < 0 { throw PlanCSVError(message: "Row \(index + 1): weight must be positive or zero.") }
            if !bodyweight && weight == nil {
                preserve(carriedWeight.isEmpty ? "Weight not recorded" : "Original weight: \(carriedWeight)")
                result.warnings.append("Row \(index + 1): \(carriedWeight.isEmpty ? "missing weight" : "weight ‘\(carriedWeight)’") is preserved in notes and excluded from weight calculations.")
            }
            var rir: Int?
            var rirRange: RIRTarget?
            if !cells[4].isEmpty {
                let bounds = cells[4].replacingOccurrences(of: "–", with: "-").split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if (1...2).contains(bounds.count), let low = bounds.first ?? nil, let high = bounds.last ?? nil, RIRTarget(low: low, high: high).valid {
                    if low == high { rir = low } else { rirRange = RIRTarget(low: low, high: high) }
                } else {
                    preserve("Original RIR: \(cells[4])")
                    result.warnings.append("Row \(index + 1): RIR ‘\(cells[4])’ is preserved in notes.")
                }
            }
            let entry = result.entries[day][currentEntry]
            let order = result.sets[day].filter { $0.entryID == entry.id }.count
            result.sets[day].append(WorkoutSet(workoutID: workout.id, entryID: entry.id, personID: profile.id, enteredBy: profile.id, modifiedBy: profile.id, order: order, prescribedIndex: nil, weight: bodyweight ? nil : weight, unit: unit, reps: reps.rounded(.towardZero) == reps ? Int(reps) : nil, fractionalReps: reps.rounded(.towardZero) == reps ? nil : reps, rir: rir, recordedRIRRange: rirRange, bodyweightOnly: bodyweight ? true : nil, completed: true, notes: notes))
        }
        guard !result.workouts.isEmpty, result.sets.allSatisfy({ !$0.isEmpty }) else { throw PlanCSVError(message: "Include at least one dated workout with sets.") }
        return result
    }

    static func date(_ value: String, defaultYear: Int) throws -> Date {
        let fields = value.replacingOccurrences(of: "/", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }
        guard parts.count == fields.count else { throw PlanCSVError(message: "Invalid date ‘\(value)’.") }
        guard parts.count == 2 || parts.count == 3 else { throw PlanCSVError(message: "Could not read date ‘\(value)’. Use month-day-year.") }
        let year = parts.count == 3 ? (parts[2] < 100 ? 2000 + parts[2] : parts[2]) : defaultYear
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: year, month: parts[0], day: parts[1], hour: 12)
        guard let date = calendar.date(from: components), calendar.component(.month, from: date) == parts[0], calendar.component(.day, from: date) == parts[1], calendar.component(.year, from: date) == year else { throw PlanCSVError(message: "Invalid date ‘\(value)’.") }
        return date
    }
}

extension Store {
    @discardableResult func importWorkouts(_ draft: WorkoutImportDraft) -> Bool {
        guard !readOnly, !draft.profile.isDemo, ownsProfile(draft.profile.id), state.profiles.contains(where: { $0.id == draft.profile.id }) else { return false }
        let pending = draft.workouts.indices.filter { index in !state.ledger.workouts.contains { $0.id == draft.workouts[index].id } }
        guard !pending.isEmpty else { error = "These workouts have already been imported."; return false }
        let previous = state
        let previousLibrary = library
        let newExercises = draft.review.exercises.filter { candidate in !library.contains { $0.id == candidate.id } }
        state.customExercises.append(contentsOf: newExercises)
        library.append(contentsOf: newExercises)
        for (id, aliases) in draft.review.aliasAdditions {
            if state.exerciseAliases == nil { state.exerciseAliases = [:] }
            var saved = state.exerciseAliases?[id] ?? []
            for alias in aliases where !saved.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) { saved.append(alias) }
            state.exerciseAliases?[id] = saved
            if let index = library.firstIndex(where: { $0.id == id }) {
                for alias in aliases where !library[index].aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) { library[index].aliases.append(alias) }
            }
        }
        for index in pending {
            let workout = draft.workouts[index]
            state.ledger.write(.workout(workout), entityID: workout.id, workoutID: workout.id, author: me.id)
            var member = Participant(workoutID: workout.id, profile: draft.profile, finished: workout.finished)
            if draft.profile.id != me.id { member.managedByID = me.id }
            state.ledger.write(.participant(member), entityID: member.id, workoutID: workout.id, author: me.id)
            for (entryIndex, initial) in draft.entries[index].enumerated() {
                var entry = initial
                let exerciseID = draft.review.plan.days[index].exercises[entryIndex].exerciseID
                guard let exercise = library.first(where: { $0.id == exerciseID }) else { state = previous; library = previousLibrary; return false }
                entry.exercise = exercise
                state.ledger.write(.entry(entry), entityID: entry.id, workoutID: workout.id, author: me.id)
            }
            for set in draft.sets[index] { state.ledger.write(.set(set), entityID: set.id, workoutID: workout.id, author: me.id) }
        }
        guard save(notify: false) else { state = previous; library = previousLibrary; return false }
        refresh()
        return true
    }
}
