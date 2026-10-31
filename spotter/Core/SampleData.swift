import Foundation

enum SampleData {
    static func plans() -> [Plan] {
        [Plan(name: "Push / Pull / Legs", days: [
            TrainingDay(id: "push", name: "Push", weekdays: [2, 5], exercises: ["bench-barbell", "incline-dumbbell", "shoulder-dumbbell", "lateral-raise", "triceps-pushdown"].map { PlannedExercise(exerciseID: $0) }),
            TrainingDay(id: "pull", name: "Pull", weekdays: [3, 6], exercises: ["lat-pulldown", "cable-row", "face-pull", "dumbbell-curl"].map { PlannedExercise(exerciseID: $0) }),
            TrainingDay(id: "legs", name: "Legs", weekdays: [4, 7], exercises: ["squat-barbell", "romanian-deadlift", "leg-press", "leg-curl", "calf-raise"].map { PlannedExercise(exerciseID: $0) })])]
    }
    #if SWIFT_PACKAGE
    static func history(profiles: [Profile], exercises: [Exercise], now: Date = Date()) -> Ledger {
        var ledger = Ledger()
        let days = plans()[0].days
        for week in 1...24 {
            for dayIndex in 0..<3 {
                let date = Calendar.current.date(byAdding: .day, value: -(week * 7 + dayIndex), to: now)!
                let day = days[dayIndex]
                let workout = Workout(started: date, finished: date.addingTimeInterval(3600), ownerID: profiles[0].id, title: day.name, shared: true, demo: true)
                ledger.write(.workout(workout), entityID: workout.id, workoutID: workout.id, author: profiles[0].id)
                for (personIndex, profile) in profiles.enumerated() {
                    let member = Participant(workoutID: workout.id, profile: profile, day: day, permitsPartnerLogging: true, finished: workout.finished)
                    ledger.write(.participant(member), entityID: member.id, workoutID: workout.id, author: profile.id)
                    for (order, planned) in day.exercises.prefix(3).enumerated() {
                        guard let exercise = exercises.first(where: { $0.id == planned.exerciseID }) else { continue }
                        let entry = ExerciseEntry(workoutID: workout.id, personID: profile.id, exercise: exercise, target: planned.target, order: order, status: .completed)
                        ledger.write(.entry(entry), entityID: entry.id, workoutID: workout.id, author: profile.id)
                        for slot in 0..<3 {
                            let base = dayIndex == 2 ? 60.0 : 25.0
                            let weight = base + Double((24 - week) / 4) * 2.5 + Double(personIndex * 10 + order * 5)
                            let set = WorkoutSet(workoutID: workout.id, entryID: entry.id, personID: profile.id, enteredBy: profile.id, modifiedBy: profile.id, order: slot, prescribedIndex: slot, weight: WeightUnit.kg.pounds(weight), unit: .lb, reps: 10 + ((24 - week) % 3), rir: slot == 2 ? nil : 2, completed: true)
                            ledger.write(.set(set), entityID: set.id, workoutID: workout.id, author: profile.id)
                        }
                    }
                }
            }
        }
        return ledger
    }
    #endif
}
