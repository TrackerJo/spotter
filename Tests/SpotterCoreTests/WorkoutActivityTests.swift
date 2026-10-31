import Testing
import Foundation
@testable import SpotterCore

@MainActor struct WorkoutActivityTests {
    func store() -> Store {
        Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json"))
    }
    @Test func timerFollowsOwnSetsAcrossExercises() throws {
        let s = store()
        s.start(day: s.days[0], shared: false, preparing: true)
        #expect(s.workoutActivitySnapshot == nil)
        s.beginWorkout()
        #expect(s.workoutActivitySnapshot?.timerStart == s.active?.started)
        let exercise = try #require(s.exercise(s.days[0].exercises[0].exerciseID))
        s.selectExercise(exercise)
        let entry = try #require(s.current)
        #expect(s.workoutActivitySnapshot?.entryID == entry.id)
        #expect(s.workoutActivitySnapshot?.recommendations.contains("sets") == true)
        var set = s.makeSet(entry)
        set.weight = 20; set.reps = 10
        #expect(s.saveSet(set))
        let loggedAt = try #require(s.sets(for: entry).first?.loggedAt)
        #expect(s.workoutActivitySnapshot?.timerStart == loggedAt)
        #expect(s.finishExercise(entry))
        s.selectExercise(exercise)
        #expect(s.workoutActivitySnapshot?.timerStart == loggedAt)
        s.finish()
        #expect(s.workoutActivitySnapshot == nil)
    }
    @Test func sharedActivityIgnoresFriendFocusAndSets() throws {
        let a = store(); let b = store()
        a.start(day: nil, shared: true)
        let id = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: id); b.join(id)
        a.receive(b.state.ledger.revisions, workoutID: id)
        let exercise = try #require(a.library.first { $0.tracking == .weightReps })
        a.selectExercise(exercise)
        let original = try #require(a.workoutActivitySnapshot)
        b.selectExercise(exercise)
        var set = b.makeSet(try #require(b.current))
        set.weight = 20; set.reps = 10
        #expect(b.saveSet(set))
        a.receive(b.state.ledger.revisions, workoutID: id)
        a.selectPerson(b.me.id)
        #expect(a.workoutActivitySnapshot == original)
        a.finish()
        #expect(a.workoutActivitySnapshot == nil)
    }
}
