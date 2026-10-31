import Foundation

struct WorkoutActivitySnapshot: Equatable {
    let workoutID: String
    let entryID: String?
    let exerciseName: String
    let timerStart: Date
    let recommendations: String
}

extension Store {
    var workoutActivitySnapshot: WorkoutActivitySnapshot? {
        guard let workout = active, !workout.isPreparing, workout.finished == nil, !workout.demo,
              let own = members.first(where: { $0.workoutID == workout.id && $0.profile.id == me.id && !$0.deleted }),
              own.finished == nil else { return nil }
        let entry = entries.first { $0.id == own.currentEntryID && $0.personID == me.id && $0.status == .active }
        let timerStart = sets.filter { $0.workoutID == workout.id && $0.personID == me.id && $0.completed }
            .compactMap(\.loggedAt).max() ?? workout.started
        var recommendations = "Choose an exercise"
        if let entry {
            if let target = entry.target {
                let used = Set(sets(for: entry).filter { $0.completed && !$0.warmup }.compactMap(\.prescribedIndex))
                let next = (0..<target.sets).first { !used.contains($0) }
                let reps = target.low == target.high ? "\(target.low) reps" : "\(target.low)–\(target.high) reps"
                let effort = target.rirTarget(for: next)?.summary ?? "—"
                let dose: String
                switch entry.exercise.tracking {
                case .timed: dose = target.seconds.map { "\($0.formatted()) sec" } ?? "Time —"
                case .distance: dose = target.meters.map { USDistanceUnit.summary(meters: $0) } ?? "Distance —"
                default: dose = reps
                }
                recommendations = "\(dose) · \(effort) RIR · \(target.sets) sets"
            } else { recommendations = "Reps — · RIR — · Sets —" }
        }
        return WorkoutActivitySnapshot(workoutID: workout.id, entryID: entry?.id,
            exerciseName: entry.map { name($0.exercise, personID: me.id) } ?? "Choose an exercise",
            timerStart: timerStart, recommendations: recommendations)
    }
}
