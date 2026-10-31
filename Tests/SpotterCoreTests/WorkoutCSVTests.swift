import Foundation
import Testing
@testable import SpotterCore

@MainActor struct WorkoutCSVTests {
    func sample() throws -> String {
        try String(contentsOf: #require(Bundle.module.url(forResource: "WorkoutImportSample", withExtension: "csv")), encoding: .utf8)
    }
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterHistoryTests/\(UUID().uuidString)/state.json")) }

    @Test func wholeJournalPreservesDatesFractionsRangesAndAnnotations() throws {
        let s = store()
        let draft = try WorkoutCSV.parse(sample(), year: 2026, unit: .lb, profile: s.me, library: s.library)
        #expect(draft.workouts.count == 12)
        #expect(draft.sets.map(\.count) == [17, 12, 5, 15, 15, 10, 17, 28, 20, 15, 19, 19])
        #expect(Calendar.current.component(.year, from: draft.workouts[0].started) == 2026)
        #expect(Calendar.current.component(.year, from: draft.workouts[7].started) == 2025)
        #expect(draft.sets[0][1].performedReps == 2.5)
        #expect(draft.sets[0][4].performedReps == 0.5)
        #expect(draft.sets[0][4].notes == "spam")
        #expect(draft.sets[7][1].notes.contains("160.8"))
        #expect(draft.sets[7][15].recordedRIRRange == RIRTarget(low: 3, high: 4))
        #expect(draft.sets[7][25].notes == "8 right, slight imbalance")
        #expect(draft.sets[8][0].bodyweightOnly == true)
        #expect(draft.sets[8][2].weight == 20)
        #expect(draft.sets[8][5].weight == 45)
        #expect(draft.sets[11][0].weight == nil)
        #expect(draft.sets[11][2].notes.contains("85? 25 + bar"))
        #expect(draft.warnings.count == 8)
        #expect(draft.sets.flatMap { $0 }.allSatisfy { $0.completed && $0.prescribedIndex == nil && $0.loggedAt == nil })
    }

    @Test func reviewedAndMatchedHistoryPersistsWithoutPlansOrActiveSessionChanges() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterHistoryTests/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        let existing = try #require(s.exercise("bench-barbell"))
        let csv = "Date,Exercise,Weight,Reps,RIR,Notes\n8-24,My bench,100,2.5,1-2,\"pause, then press\"\n,,,3,0,\n8-25,My bench,105,4,1,"
        var draft = try WorkoutCSV.parse(csv, year: 2026, unit: .lb, profile: s.me, library: s.library)
        let custom = try #require(draft.review.exercises.first)
        draft.review.matchCustomExercise(custom.id, to: existing)
        s.start(day: s.days[0], shared: false)
        let activeID = s.state.activeWorkoutID
        let planCount = s.state.plans.count
        #expect(s.importWorkouts(draft))
        #expect(s.state.activeWorkoutID == activeID)
        #expect(s.state.plans.count == planCount)
        let imported = s.entries.filter { draft.workouts.map(\.id).contains($0.workoutID) }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.exercise.id == existing.id && $0.target == nil && $0.status == .completed })
        #expect(s.exercise(existing.id)?.aliases.contains("My bench") == true)
        let points = ProgressEngine.trends(personID: s.me.id, exerciseID: existing.id, since: .distantPast, ledger: s.state.ledger)
        #expect(points.count == 2)
        #expect(points.first?.reps == 3)
        let volume = ProgressEngine.summary(personID: s.me.id, since: .distantPast, ledger: s.state.ledger).volumePounds
        #expect(abs(volume - 970) < 0.000001)
        #expect(s.previous(existing.id)?.sets.first?.notes == "")
        let count = s.workouts.count
        let replay = try WorkoutCSV.parse(csv, year: 2026, unit: .lb, profile: s.me, library: s.library)
        #expect(!s.importWorkouts(replay))
        #expect(s.workouts.count == count)
        #expect(s.sets.contains { $0.fractionalReps == 2.5 && $0.recordedRIRRange == RIRTarget(low: 1, high: 2) })
        let reloaded = Store(file: file)
        #expect(reloaded.sets.sorted { $0.id < $1.id } == s.sets.sorted { $0.id < $1.id })
        #expect(reloaded.exercise(existing.id)?.aliases.contains("My bench") == true)
        #expect(reloaded.state.activeWorkoutID == activeID)
    }

    @Test func bodyweightAndUnknownWeightsDoNotInflateVolume() throws {
        let s = store()
        let csv = "Date,Exercise,Weight,Reps,RIR,Notes\n8-24,Test lift,bw,2.5,,\n,,55-45,5,,drop\n,,20,4.5,,"
        var draft = try WorkoutCSV.parse(csv, year: 2026, unit: .lb, profile: s.me, library: [])
        draft.review.exercises[0].primary = "Chest"
        draft.review.exercises[0].equipment = "Barbell"
        draft.review.exercises[0].tracking = .weightReps
        #expect(s.importWorkouts(draft))
        let summary = ProgressEngine.summary(personID: s.me.id, since: .distantPast, ledger: s.state.ledger)
        #expect(summary.workouts == 1 && summary.workingSets == 3)
        #expect(summary.volumePounds == 90)
        #expect(s.sets.first { $0.notes.contains("55-45") }?.weight == nil)
    }

    @Test func invalidDatesAndDanglingContinuationAreRejected() throws {
        let profile = Profile(name: "Test")
        for row in ["2-30,Lift,20,5,,", "8--24,Lift,20,5,,", ",Lift,20,5,,", "8-24,,20,5,,", "8-24,Lift,-20,5,,", "8-24,Lift,20,0,,"] {
            #expect(throws: PlanCSVError.self) { try WorkoutCSV.parse("Date,Exercise,Weight,Reps,RIR,Notes\n" + row, year: 2026, unit: .lb, profile: profile, library: []) }
        }
    }

    @Test func blankWeightNeverCarriesAcrossExerciseBoundariesAndMetricConversionWorks() throws {
        let s = store()
        let draft = try WorkoutCSV.parse("Date,Exercise,Weight,Reps,RIR,Notes\n8-24,First,10,5,,\n,,,6,,\n,Second,,5,,", year: 2026, unit: .kg, profile: s.me, library: [])
        #expect(draft.sets[0][1].weight == 10)
        #expect(draft.sets[0][2].weight == nil)
        #expect(draft.sets[0][1].weightPounds == WeightUnit.kg.pounds(10))
        #expect(draft.warnings.count == 1)
    }

    @Test func failedSaveRollsBackHistoryExercisesAndAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SpotterHistoryTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "blocker")
        try Data().write(to: blocker)
        let s = Store(file: blocker.appending(path: "state.json"))
        let existing = try #require(s.library.first)
        var draft = try WorkoutCSV.parse("Date,Exercise,Weight,Reps,RIR,Notes\n8-24,Alternate,10,5,,\n,Another,20,6,,", year: 2026, unit: .lb, profile: s.me, library: s.library)
        draft.review.matchCustomExercise(draft.review.exercises[0].id, to: existing)
        let library = s.library
        let revisions = s.state.ledger.revisions
        #expect(!s.importWorkouts(draft))
        #expect(s.library == library)
        #expect(s.state.ledger.revisions == revisions)
        #expect(s.state.customExercises.isEmpty)
        #expect(s.state.exerciseAliases == nil)
    }
}
