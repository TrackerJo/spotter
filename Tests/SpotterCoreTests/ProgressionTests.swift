import Testing
import Foundation
@testable import SpotterCore

struct ProgressionTests {
    func fixture() -> PreviousPerformance {
        let exercise = Exercise(id: "bench", name: "Bench", primary: "Chest", equipment: "Barbell", pattern: "Push")
        let workout = Workout(finished: Date(), ownerID: "alex", title: "Push")
        let entry = ExerciseEntry(workoutID: workout.id, personID: "alex", exercise: exercise, target: Target(), order: 0, status: .completed)
        let sets = (0..<3).map { slot in WorkoutSet(workoutID: workout.id, entryID: entry.id, personID: "alex", enteredBy: "jamie", modifiedBy: "jamie", order: slot, prescribedIndex: slot, weight: 50, unit: .kg, reps: 12, completed: true) }
        return PreviousPerformance(workout: workout, entry: entry, sets: sets)
    }
    @Test func estimatedMaxIncludesRecordedRIR() {
        for (rir, range, expected) in [(nil, nil, 60.0), (0, nil, 60.0), (3, nil, 65.0), (nil, RIRTarget(low: 2, high: 4), 65.0)] as [(Int?, RIRTarget?, Double)] {
            let history = fixture()
            var set = history.sets[0]
            set.reps = 6
            set.rir = rir
            set.recordedRIRRange = range
            let values: [Payload] = [.workout(history.workout), .entry(history.entry), .set(set)]
            let ledger = Ledger(revisions: values.map { Revision(entityID: $0.entityID, workoutID: $0.workoutID, parents: [], authorID: "alex", value: $0) })
            let estimate = ProgressEngine.trends(personID: "alex", exerciseID: "bench", since: .distantPast, ledger: ledger).first?.estimatedMax
            #expect(abs((estimate ?? 0) - expected) < 0.000001)
        }
    }

    @Test func increasesOnlyAfterAllPrescribedSets() {
        let p = WorkoutEngine.progression(fixture(), increment: 2.5)
        #expect(p?.nextWeight == 52.5)
        #expect(p?.explanation == "You reached 12 reps on all 3 working sets at 110.23 lb last time. Consider increasing the weight.")
    }
    @Test func rirIsNeverPartOfQualification() {
        for recorded in [nil, -3, 0, 1, 5, 10, 42] as [Int?] {
            for target in [nil, 0, 2, 10] as [Int?] {
                var history = fixture(); history.entry.target?.rir = target
                for index in history.sets.indices { history.sets[index].rir = recorded }
                #expect(WorkoutEngine.progression(history, increment: 2.5)?.nextWeight == 52.5)
                history.sets[1].reps = 11
                #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
            }
        }
    }
    @Test func missingIncrementDoesNotInventWeight() {
        #expect(WorkoutEngine.progression(fixture(), increment: nil)?.nextWeight == nil)
        #expect(WorkoutEngine.progression(fixture(), increment: 0)?.nextWeight == nil)
    }
    @Test func warmupsAndExtrasCannotPreventQualification() {
        var history = fixture()
        var warmup = history.sets[0]; warmup.id = UUID().uuidString; warmup.warmup = true; warmup.weight = 20; warmup.reps = 5
        var extra = warmup; extra.id = UUID().uuidString; extra.warmup = false; extra.prescribedIndex = nil
        history.sets += [warmup, extra]
        #expect(WorkoutEngine.progression(history, increment: 2.5) != nil)
    }
    @Test func extrasCannotReplaceMissingPrescribedSet() {
        var history = fixture(); history.sets[2].prescribedIndex = nil
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
    }
    @Test func incompleteSetsNeverQualify() {
        var history = fixture(); history.sets[1].completed = false
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
        history = fixture(); history.workout.finished = nil
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
    }
    @Test func mixedWeightsAndUnitsDoNotQualify() {
        var history = fixture(); history.sets[1].weight = 52.5
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
        history = fixture(); history.sets[1].unit = .lb
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
    }
    @Test func partnerAndOtherExerciseSetsDoNotCount() {
        var history = fixture(); history.sets[1].personID = "jamie"
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
        history = fixture(); history.sets[1].entryID = "other"
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
    }
    @Test func unsuitableTrackingNeverAddsWeight() {
        for tracking in [Tracking.bodyweight, .assisted, .timed, .distance] {
            var history = fixture(); history.entry.exercise.tracking = tracking
            #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
        }
    }
    @Test func targetsRequiredAndPreservedAcrossPlanEdits() {
        var history = fixture()
        var planned = PlannedExercise(exerciseID: history.entry.exercise.id, target: history.entry.target!)
        planned.target.high = 15; planned.target.sets = 5
        #expect(history.entry.target?.high == 12)
        #expect(WorkoutEngine.progression(history, increment: 2.5) != nil)
        history.entry.target = nil
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
    }
    @Test func duplicatePrescriptionSlotFailsSafely() {
        var history = fixture(); var duplicate = history.sets[0]; duplicate.id = "duplicate"; history.sets.append(duplicate)
        #expect(WorkoutEngine.progression(history, increment: 2.5) == nil)
    }
    @Test func aboveUpperRangeQualifies() {
        var history = fixture(); history.sets[0].reps = 15
        #expect(WorkoutEngine.progression(history, increment: 2.5) != nil)
    }
}
