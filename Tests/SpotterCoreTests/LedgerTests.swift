import Testing
import Foundation
@testable import SpotterCore

struct LedgerTests {
    func base() -> (Ledger, Workout) {
        let workout = Workout(ownerID: "alex", title: "Push", shared: true)
        var ledger = Ledger(); ledger.write(.workout(workout), entityID: workout.id, workoutID: workout.id, author: "alex")
        return (ledger, workout)
    }
    @Test func repeatedDeliveryAcrossTransportsIsIdempotent() {
        var (ledger, _) = base(); let incoming = ledger.revisions
        ledger.merge(incoming); ledger.merge(incoming)
        #expect(ledger.revisions.count == 1); #expect(ledger.workouts.count == 1)
    }
    @Test func simultaneousEditsPreserveBothVersions() {
        let (initial, workout) = base(); var a = initial; var b = initial
        var x = workout; x.title = "Alex edit"; a.write(.workout(x), entityID: x.id, workoutID: x.id, author: "alex")
        x.title = "Jamie edit"; b.write(.workout(x), entityID: x.id, workoutID: x.id, author: "jamie")
        a.merge(b.revisions); b.merge(a.revisions)
        #expect(a.heads(x.id).count == 2); #expect(a.workouts == b.workouts)
        #expect(a.conflicts.count == 1)
        a.write(.workout(x), entityID: x.id, workoutID: x.id, author: "alex")
        b.merge(a.revisions)
        #expect(b.conflicts.isEmpty); #expect(b.workouts.first?.title == "Jamie edit")
        #expect(b.revisions.count == 4)
    }
    @Test func offlineDeletionVersusEditRequiresResolution() {
        let (initial, workout) = base(); var a = initial; var b = initial
        a.write(nil, entityID: workout.id, workoutID: workout.id, author: "alex")
        var x = workout; x.title = "Offline edit"; b.write(.workout(x), entityID: x.id, workoutID: x.id, author: "jamie")
        a.merge(b.revisions); #expect(a.conflicts.count == 1)
        #expect(a.heads(x.id).contains { $0.value == nil })
    }
    @Test func outOfOrderRevisionsConverge() {
        var (a, workout) = base(); var x = workout
        for i in 0..<8 { x.title = String(i); a.write(.workout(x), entityID: x.id, workoutID: x.id, author: "alex") }
        var b = Ledger(); b.merge(a.revisions.reversed())
        #expect(b.conflicts.isEmpty); #expect(b.workouts == a.workouts)
    }
    @Test func twoIndependentSetsMergeWithoutConflict() {
        let (initial, workout) = base(); var a = initial; var b = initial
        for (id, author) in [("set-a", "alex"), ("set-b", "jamie")] {
            let set = WorkoutSet(id: id, workoutID: workout.id, entryID: "entry", personID: author, enteredBy: author, modifiedBy: author, order: 0, prescribedIndex: 0, weight: 50, reps: 12, completed: true)
            if author == "alex" { a.write(.set(set), entityID: id, workoutID: workout.id, author: author) } else { b.write(.set(set), entityID: id, workoutID: workout.id, author: author) }
        }
        a.merge(b.revisions); #expect(a.sets.count == 2); #expect(a.conflicts.isEmpty)
    }
    @Test func encodingRoundtripPreservesUnknownRIRAndRevisions() throws {
        let history = ProgressionTests().fixture(); var (ledger, _) = base()
        let set = history.sets[0]; ledger.write(.set(set), entityID: set.id, workoutID: set.workoutID, author: "alex")
        let copy = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        #expect(copy == ledger); #expect(copy.sets.first?.rir == nil)
    }
}
