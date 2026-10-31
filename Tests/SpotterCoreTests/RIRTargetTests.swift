import Testing
import Foundation
@testable import SpotterCore

struct RIRTargetTests {
    @Test func sharedRangePersistsAndAppliesWhenSetCountChanges() throws {
        var target = Target(sets: 3, rirRange: RIRTarget(low: 1, high: 3))
        #expect(target.valid)
        #expect(target.rirSummary == "1–3 RIR")
        #expect(try JSONDecoder().decode(Target.self, from: JSONEncoder().encode(target)) == target)
        target.sets = 4
        target.resizeRIRTargets()
        for index in 0..<4 {
            #expect(target.rirTarget(for: index) == RIRTarget(low: 1, high: 3))
        }
        target.rirRange = RIRTarget(low: 3, high: 1)
        #expect(!target.valid)
    }

    @Test func oldTargetsDecodeAndApplyToEveryWorkingSet() throws {
        let data = Data(#"{"sets":3,"low":8,"high":12,"rir":2,"rest":90,"notes":""}"#.utf8)
        let target = try JSONDecoder().decode(Target.self, from: data)
        #expect(target.perSetRIR == nil)
        for index in 0..<3 { #expect(target.rirTarget(for: index) == RIRTarget(low: 2, high: 2)) }
        #expect(target.rirTarget(for: nil) == nil)
        #expect(target.rirTarget(for: 3) == nil)
    }

    @Test func perSetRangesPersistAndResizeWithoutRepeatingLastTarget() throws {
        var target = Target(sets: 3, perSetRIR: [RIRTarget(low: 2, high: 2), nil, RIRTarget(low: 0, high: 1)])
        #expect(target.valid)
        #expect(target.rirTarget(for: 1) == nil)
        #expect(target.rirTarget(for: 2)?.summary == "0–1")
        #expect(target.summary(for: .weightReps).contains("RIR by set: 2, —, 0–1"))
        #expect(try JSONDecoder().decode(Target.self, from: JSONEncoder().encode(target)) == target)
        target.sets = 4
        target.resizeRIRTargets()
        #expect(target.perSetRIR?.count == 4)
        #expect(target.rirTarget(for: 3) == nil)
        target.sets = 2
        target.resizeRIRTargets()
        #expect(target.perSetRIR?.count == 2)
        #expect(target.valid)
        #expect(!RIRTarget(low: 11, high: 11).valid)
        #expect(!RIRTarget(low: 2, high: 1).valid)
    }

    @MainActor @Test func targetsFollowPrescribedSlotsAndNeverFillActualRIR() throws {
        let store = Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json"))
        let exercise = try #require(store.library.first { $0.tracking == .weightReps })
        let target = Target(sets: 3, perSetRIR: [RIRTarget(low: 2, high: 2), RIRTarget(low: 1, high: 1), RIRTarget(low: 0, high: 1)])
        let day = TrainingDay(name: "RIR", exercises: [PlannedExercise(exerciseID: exercise.id, target: target)])
        store.start(day: day, shared: false)
        store.selectExercise(exercise)
        let entry = try #require(store.current)
        var warmup = store.makeSet(entry)
        warmup.warmup = true
        warmup.weight = 10; warmup.reps = 8
        #expect(store.saveSet(warmup))
        for slot in 0..<3 {
            var set = store.makeSet(entry)
            #expect(set.prescribedIndex == slot)
            #expect(set.rir == nil)
            #expect(entry.target?.rirTarget(for: set.prescribedIndex) == target.perSetRIR?[slot])
            set.weight = 20; set.reps = 8
            #expect(store.saveSet(set))
        }
        let extra = store.makeSet(entry)
        #expect(extra.prescribedIndex == nil)
        #expect(entry.target?.rirTarget(for: extra.prescribedIndex) == nil)
        #expect(extra.rir == nil)
    }
}
