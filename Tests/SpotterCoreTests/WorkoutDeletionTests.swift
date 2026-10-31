import Foundation
import Testing
@testable import SpotterCore

@MainActor struct WorkoutDeletionTests {
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterDeletion/\(UUID().uuidString)/state.json")) }

    @Test func soloDeletionPersistsAndClearsActiveSession() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterDeletion/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        s.start(day: nil, shared: false)
        let workout = try #require(s.active)
        s.selectExercise(try #require(s.library.first))
        let entry = try #require(s.current)
        var set = s.makeSet(entry); set.weight = 20; set.reps = 10
        #expect(s.saveSet(set))
        let before = s.state.ledger.revisions
        #expect(s.deleteWorkout(workout, personID: s.me.id))
        #expect(s.active == nil)
        #expect(s.entries.isEmpty && s.sets.isEmpty && s.workouts.isEmpty)
        let reopened = Store(file: file)
        reopened.receive(before, workoutID: workout.id)
        #expect(reopened.workouts.isEmpty && reopened.sets.isEmpty)
        #expect(ProgressEngine.summary(personID: s.me.id, since: .distantPast, ledger: reopened.state.ledger).workouts == 0)
    }

    @Test func sharedDeletionPreservesFriendAndPreventsRejoining() throws {
        let a = store(); let b = store()
        a.start(day: nil, shared: true)
        let workout = try #require(a.active)
        b.receive(a.state.ledger.revisions, workoutID: workout.id); b.join(workout.id)
        a.receive(b.state.ledger.revisions, workoutID: workout.id)
        #expect(!a.deleteWorkout(workout, personID: b.me.id))
        #expect(a.deleteWorkout(workout, personID: a.me.id))
        b.receive(a.state.ledger.revisions, workoutID: workout.id)
        #expect(b.active?.id == workout.id)
        #expect(b.canLog)
        b.selectExercise(try #require(b.library.first))
        #expect(b.current != nil)
        #expect(a.state.ledger.workouts(for: a.me.id).isEmpty)
        #expect(b.state.ledger.workouts(for: b.me.id).count == 1)
        a.join(workout.id)
        #expect(a.active == nil)
    }

    @Test func failedSaveRollsBackDeletion() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterDeletion/\(UUID().uuidString)/state.json")
        let s = Store(file: file); s.start(day: nil, shared: false)
        let workout = try #require(s.active)
        let before = s.state.ledger
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(!s.deleteWorkout(workout, personID: s.me.id))
        #expect(s.state.ledger == before)
        #expect(s.active?.id == workout.id)
    }

    @Test func readOnlyDeletionDoesNotMutateLedger() throws {
        let s = store(); s.start(day: nil, shared: false)
        let workout = try #require(s.active)
        let before = s.state.ledger
        s.readOnly = true
        #expect(!s.deleteWorkout(workout, personID: s.me.id))
        #expect(s.state.ledger == before)
    }
}
