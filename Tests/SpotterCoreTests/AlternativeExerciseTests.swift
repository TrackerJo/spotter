import Testing
import Foundation
@testable import SpotterCore

@MainActor struct AlternativeExerciseTests {
    private func store() -> Store {
        Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json"))
    }

    @Test func csvShorthandResolvesEverySplitAlternative() throws {
        let s = store()
        let csv = try String(contentsOf: #require(Bundle.module.url(forResource: "PlanImportSample", withExtension: "csv")), encoding: .utf8)
        let imported = try PlanCSV.parse(csv, name: "Split", library: s.library)
        #expect(imported.exercises.isEmpty)
        #expect(imported.plan.days[0].exercises[0].exerciseIDs == ["incline-smith", "incline-barbell"])
        #expect(imported.plan.days[0].exercises[2].exerciseIDs == ["cable-fly", "machine-fly"])
        #expect(imported.plan.days[0].exercises[4].exerciseIDs == ["lateral-machine", "lateral-raise"])
        #expect(imported.plan.days[1].exercises[0].exerciseIDs == ["weighted-pullup", "lat-pulldown"])
        #expect(imported.plan.days[3].exercises[0].exerciseIDs == ["incline-dumbbell", "incline-smith"])
        #expect(imported.plan.days[4].exercises[2].exerciseIDs == ["hack-squat", "leg-press"])
        #expect(imported.plan.days[4].exercises[3].exerciseIDs == ["hip-thrust", "glute-drive"])
        #expect(s.importPlan(imported))
    }

    @Test func legacySlotDecodesAndAlternativesRoundTrip() throws {
        let legacy = Data(#"{"id":"slot","exerciseID":"cable-fly","target":{"sets":2,"low":10,"high":15,"rest":90,"notes":""}}"#.utf8)
        var slot = try JSONDecoder().decode(PlannedExercise.self, from: legacy)
        #expect(slot.alternativeExerciseID == nil)
        slot.alternativeExerciseID = "machine-fly"
        #expect(try JSONDecoder().decode(PlannedExercise.self, from: JSONEncoder().encode(slot)) == slot)
    }

    @Test func eitherChoiceUsesTargetsAndCompletesOneSlot() throws {
        for id in ["cable-fly", "machine-fly"] {
            let s = store()
            let target = Target(sets: 2, low: 10, high: 15, rir: 1)
            let day = TrainingDay(name: "Push", exercises: [
                PlannedExercise(exerciseID: "cable-fly", target: target, alternativeExerciseID: "machine-fly"),
                PlannedExercise(exerciseID: "triceps-pushdown")
            ])
            s.start(day: day, shared: false)
            s.skip("machine-fly")
            #expect(WorkoutEngine.recommended(try #require(s.participant), ledger: s.state.ledger) == "triceps-pushdown")
            s.selectExercise(try #require(s.exercise(id)))
            let entry = try #require(s.current)
            #expect(entry.target == target)
            #expect(s.participant?.skipped.isEmpty == true)
            var set = s.makeSet(entry)
            set.weight = 20; set.reps = 12
            #expect(s.saveSet(set))
            #expect(s.finishExercise(entry))
            #expect(WorkoutEngine.recommended(try #require(s.participant), ledger: s.state.ledger) == "triceps-pushdown")
            s.finish()
            #expect(s.previous(id)?.entry.exercise.id == id)
            #expect(s.previous(id == "cable-fly" ? "machine-fly" : "cable-fly") == nil)
        }
    }

    @Test func matchingCustomAlternativeUpdatesEveryReference() throws {
        let s = store()
        var imported = try PlanCSV.parse("Push\nExercise,Sets,Rep range,RIR\nCable fly or Unique fly,2,10-15,1\nCable fly / Unique fly,3,8-12,2", name: "Choices", library: s.library)
        let id = try #require(imported.exercises.first?.id)
        imported.matchCustomExercise(id, to: try #require(s.exercise("machine-fly")))
        #expect(imported.exercises.isEmpty)
        #expect(imported.plan.days[0].exercises.allSatisfy { $0.exerciseIDs == ["cable-fly", "machine-fly"] })
        #expect(s.importPlan(imported))
    }
}
