import Testing
import Foundation
@testable import SpotterCore

struct PlanCSVTests {
    @Test func samplePreservesSplitAndPrescriptions() throws {
        let csv = try String(contentsOf: #require(Bundle.module.url(forResource: "PlanImportSample", withExtension: "csv")), encoding: .utf8)
        let imported = try PlanCSV.parse(csv, name: "New Split", library: [])
        #expect(imported.plan.days.map(\.name) == ["Push", "Pull", "Legs", "Upper", "Lower"])
        #expect(imported.plan.days.map { $0.exercises.count } == [7, 8, 7, 8, 8])
        let first = try #require(imported.plan.days.first?.exercises.first)
        #expect(first.target.sets == 3)
        #expect(first.target.low == 6 && first.target.high == 10)
        #expect(first.target.perSetRIR == [RIRTarget(low: 2, high: 2), RIRTarget(low: 1, high: 1), RIRTarget(low: 1, high: 1)])
        #expect(first.target.notes.isEmpty)
        #expect(imported.plan.days[0].exercises[3].target.rirTarget(for: 2) == RIRTarget(low: 0, high: 1))
        #expect(imported.plan.days[1].exercises[1].exerciseID == imported.plan.days[3].exercises[1].exerciseID)
    }

    @Test func quotedNotesAliasesAndSingleRIR() throws {
        let exercise = Exercise(id: "bench", name: "Bench Press", aliases: ["Bench"], primary: "Chest", equipment: "Barbell", pattern: "Push")
        let csv = "\u{FEFF}Push,,,,\r\nExercise,Sets,Rep range,RIR,Notes\r\nBench,2,8-12,1,\"Pause, then \"\"press\"\"\nslowly\""
        let imported = try PlanCSV.parse(csv, name: "Test", library: [exercise])
        let planned = try #require(imported.plan.days.first?.exercises.first)
        #expect(planned.exerciseID == "bench")
        #expect(imported.exercises.isEmpty)
        #expect(planned.target.rir == 1)
        #expect(planned.target.notes == "Pause, then \"press\"\nslowly")
    }

    @Test func invalidInputIsRejected() {
        for row in ["Bench,0,8-12,1", "Bench,3,12-8,1", "Bench,3,8-12,11", "Bench,3,8-12,\"2,1\"", "Bench,3,8-12,\"2,1", "Bench,3,8-12,\"1\"oops"] {
            #expect(throws: PlanCSVError.self) { try PlanCSV.parse("Push,,,\nExercise,Sets,Rep range,RIR\n" + row, name: "Test", library: []) }
        }
        #expect(throws: PlanCSVError.self) { try PlanCSV.parse("Push,,,\nExercise,Sets,Rep range,RIR", name: "Test", library: []) }
    }

    @MainActor @Test func importedPlanPersistsAndReadOnlyDoesNotMutate() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")
        let store = Store(file: file)
        let imported = try PlanCSV.parse("Push,,,\nExercise,Sets,Rep range,RIR\nUnique exercise,2,10,1", name: "Test", library: store.library)
        #expect(store.importPlan(imported))
        let reloaded = Store(file: file)
        #expect(reloaded.state.plans.last == imported.plan)
        #expect(reloaded.exercise(imported.exercises[0].id) == imported.exercises[0])
        reloaded.readOnly = true
        let count = reloaded.state.plans.count
        #expect(!reloaded.importPlan(imported))
        #expect(reloaded.state.plans.count == count)
    }
    @MainActor @Test func reviewedCustomDetailsPersistAcrossAllPlanReferences() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")
        let store = Store(file: file)
        var imported = try PlanCSV.parse("Push,,,\nExercise,Sets,Rep range,RIR\nUnique cable press,2,8-12,1\nUpper,,,\nExercise,Sets,Rep range,RIR\nUnique cable press,3,8-12,2", name: "Reviewed", library: [])
        #expect(imported.exercises.count == 1)
        let id = imported.exercises[0].id
        imported.exercises[0].primary = "Chest"
        imported.exercises[0].secondary = ["Triceps", "Shoulders"]
        imported.exercises[0].equipment = "Cable"
        imported.exercises[0].tracking = .weightReps
        #expect(store.exercise(id) == nil)
        #expect(store.importPlan(imported))
        let reloaded = Store(file: file)
        #expect(reloaded.exercise(id) == imported.exercises[0])
        #expect(reloaded.state.plans.last?.days.flatMap { $0.exercises.map(\.exerciseID) } == [id, id])
    }

    @MainActor @Test func matchingExistingExerciseKeepsIdentityAndPersistsAliasOnImport() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")
        let store = Store(file: file)
        let existing = try #require(store.library.first)
        let csv = "Push,,,\nExercise,Sets,Rep range,RIR\nCSV alternate name,2,8-12,1\nUpper,,,\nExercise,Sets,Rep range,RIR\nCSV alternate name,3,6-10,2"
        var imported = try PlanCSV.parse(csv, name: "Matched", library: store.library)
        let customID = try #require(imported.exercises.first?.id)
        imported.exercises[0].name = "Edited draft name"
        imported.matchCustomExercise(customID, to: existing)
        #expect(imported.exercises.isEmpty)
        #expect(imported.plan.days.flatMap { $0.exercises.map(\.exerciseID) } == [existing.id, existing.id])
        #expect(imported.plan.days[0].exercises[0].target.low == 8)
        #expect(imported.plan.days[1].exercises[0].target.low == 6)
        #expect(imported.aliasAdditions[existing.id] == ["CSV alternate name"])
        #expect(store.exercise(existing.id)?.aliases.contains("CSV alternate name") == false)
        #expect(store.state.exerciseAliases == nil)
        #expect(store.importPlan(imported))
        let reloaded = Store(file: file)
        #expect(reloaded.exercise(existing.id)?.aliases.contains("CSV alternate name") == true)
        #expect(reloaded.search("CSV alternate name").contains { $0.id == existing.id })
        #expect(reloaded.state.customExercises.contains { $0.id == customID } == false)
        let next = try PlanCSV.parse(csv, name: "Next", library: reloaded.library)
        #expect(next.exercises.isEmpty)
        #expect(next.plan.days[0].exercises[0].exerciseID == existing.id)
        #expect(reloaded.importPlan(imported))
        #expect(reloaded.exercise(existing.id)?.aliases.filter { $0 == "CSV alternate name" }.count == 1)
    }

    @MainActor @Test func readOnlyImportDoesNotSaveAlias() throws {
        let store = Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json"))
        let existing = try #require(store.library.first)
        var imported = try PlanCSV.parse("Push,,,\nExercise,Sets,Rep range,RIR\nAnother CSV name,2,8-12,1", name: "Read only", library: store.library)
        imported.matchCustomExercise(try #require(imported.exercises.first?.id), to: existing)
        store.readOnly = true
        #expect(!store.importPlan(imported))
        #expect(store.state.exerciseAliases == nil)
        #expect(store.exercise(existing.id)?.aliases.contains("Another CSV name") == false)
    }

}
