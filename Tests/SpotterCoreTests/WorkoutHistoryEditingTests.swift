import Foundation
import Testing
@testable import SpotterCore

@MainActor struct WorkoutHistoryEditingTests {
    @Test func editAndDeleteFinishedExercisePersists() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterHistory/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        s.start(day: nil, shared: false)
        let exercise = try #require(s.library.first { $0.tracking == .weightReps })
        s.selectExercise(exercise)
        let entry = try #require(s.current)
        var set = s.makeSet(entry); set.weight = 20; set.reps = 10
        #expect(s.saveSet(set))
        s.finish()
        #expect(!s.canLog)
        #expect(s.canEditHistory(entry))
        set = try #require(s.sets.first)
        let loggedAt = set.loggedAt
        set.weight = 30
        #expect(s.saveSet(set))
        #expect(s.sets.first?.loggedAt == loggedAt)
        let replacement = try #require(s.library.first { $0.tracking == .weightReps && $0.id != exercise.id })
        #expect(s.replaceHistoryExercise(entry, with: replacement))
        let updated = try #require(s.entries.first)
        #expect(updated.exercise.id == replacement.id)
        let added = s.makeSet(updated)
        #expect(s.saveSet(added))
        #expect(s.sets.first { $0.id == added.id }?.loggedAt == nil)
        s.readOnly = true
        #expect(!s.deleteHistoryExercise(updated))
        s.readOnly = false
        #expect(s.deleteHistoryExercise(updated))
        let reopened = Store(file: file)
        #expect(reopened.entries.isEmpty && reopened.sets.isEmpty)
        #expect(reopened.workouts.count == 1)
    }

    @Test func historyEditingRejectsUnfinishedAndOtherParticipants() throws {
        let s = Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterHistory/\(UUID().uuidString)/state.json"))
        s.start(day: nil, shared: false)
        s.selectExercise(try #require(s.library.first))
        let entry = try #require(s.current)
        #expect(!s.canEditHistory(entry))
        s.finish()
        var other = entry; other.personID = "someone-else"
        #expect(!s.canEditHistory(other))
        #expect(!s.deleteHistoryExercise(other))
    }
}
