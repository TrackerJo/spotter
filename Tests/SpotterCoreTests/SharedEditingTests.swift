import Testing
import Foundation
@testable import SpotterCore

@MainActor struct SharedEditingTests {
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterEditingTests/\(UUID().uuidString)/state.json")) }
    func pair() throws -> (Store, Store, ExerciseEntry) {
        let a = store(); let b = store(); a.start(day: nil, shared: true)
        let id = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: id); b.join(id)
        a.receive(b.state.ledger.revisions, workoutID: id)
        a.selectExercise(try #require(a.exercise("bench-barbell")))
        var entry = try #require(a.current); entry.target = Target(sets: 3, low: 8, high: 12)
        a.write(.entry(entry))
        b.receive(a.state.ledger.revisions, workoutID: id); b.selectPerson(a.me.id)
        a.nearbyReadyWorkoutID = id; a.nearbyPeerID = b.me.id
        b.nearbyReadyWorkoutID = id; b.nearbyPeerID = a.me.id
        return (a, b, entry)
    }
    func synchronize(_ a: Store, _ b: Store, _ id: String) {
        a.receive(b.state.ledger.revisions, workoutID: id)
        b.receive(a.state.ledger.revisions, workoutID: id)
    }
    func draft(_ s: Store, _ entry: ExerciseEntry, reps: Int = 10) -> WorkoutSet {
        var set = s.makeSet(entry); set.weight = 40; set.reps = reps
        return set
    }

    @Test func bothPhonesCanLogSamePersonAndConcurrentSetsArePreserved() throws {
        let (a, b, entry) = try pair()
        #expect(a.canLog); #expect(b.canLog)
        let first = draft(a, entry); let second = draft(b, entry, reps: 12)
        #expect(a.saveSet(first, parents: [])); #expect(b.saveSet(second, parents: []))
        synchronize(a, b, entry.workoutID)
        #expect(a.sets(for: entry).map(\.id) == b.sets(for: entry).map(\.id))
        #expect(Set(a.sets(for: entry).map(\.id)) == [first.id, second.id])
        #expect(a.conflicts.isEmpty); #expect(b.conflicts.isEmpty)
        b.receive(a.state.ledger.revisions.reversed(), workoutID: entry.workoutID)
        b.receive(a.state.ledger.revisions, workoutID: entry.workoutID)
        #expect(b.sets(for: entry).count == 2)
        a.selectPerson(b.me.id); b.selectPerson(b.me.id)
        #expect(a.canLog); #expect(b.canLog)
    }

    @Test func staleDraftUsesCurrentOrderAndWorkingSlot() throws {
        let (a, b, entry) = try pair()
        let earlierDraft = draft(b, entry)
        let first = draft(a, entry)
        #expect(a.saveSet(first))
        b.receive(a.state.ledger.revisions, workoutID: entry.workoutID)
        #expect(b.saveSet(earlierDraft, parents: []))
        let saved = try #require(b.sets.first { $0.id == earlierDraft.id })
        #expect(saved.order == 1); #expect(saved.prescribedIndex == 1)
    }

    @Test func staleEditAndDeletedSetCannotOverwriteOrResurrect() throws {
        let (a, b, entry) = try pair()
        let original = draft(a, entry); #expect(a.saveSet(original))
        synchronize(a, b, entry.workoutID)
        let parents = b.state.ledger.heads(original.id).map(\.id)
        var updated = try #require(a.sets.first); updated.reps = 12
        #expect(a.saveSet(updated))
        b.receive(a.state.ledger.revisions, workoutID: entry.workoutID)
        var stale = original; stale.reps = 11
        #expect(!b.saveSet(stale, parents: parents))
        #expect(b.sets.first?.reps == 12); #expect(b.conflicts.isEmpty)
        let beforeDelete = b.state.ledger.heads(original.id).map(\.id)
        a.deleteSet(updated); b.receive(a.state.ledger.revisions, workoutID: entry.workoutID)
        #expect(!b.saveSet(stale, parents: beforeDelete))
        #expect(b.sets.isEmpty); #expect(b.conflicts.isEmpty)
    }

    @Test func trueSimultaneousEditsKeepBothVersionsForResolution() throws {
        let (a, b, entry) = try pair()
        let original = draft(a, entry); #expect(a.saveSet(original))
        synchronize(a, b, entry.workoutID)
        let parents = a.state.ledger.heads(original.id).map(\.id)
        var first = try #require(a.sets.first); first.reps = 11
        var second = first; second.reps = 12
        #expect(a.saveSet(first, parents: parents)); #expect(b.saveSet(second, parents: parents))
        synchronize(a, b, entry.workoutID)
        let heads = a.state.ledger.heads(original.id)
        #expect(heads.count == 2)
        #expect(Set(heads.compactMap { if case .set(let set) = $0.value { return set.reps }; return nil }) == [11, 12])
        #expect(a.sets == b.sets)
        a.resolve(try #require(heads.first { if case .set(let set) = $0.value { return set.reps == 11 }; return false }))
        synchronize(a, b, entry.workoutID)
        #expect(b.sets.first?.reps == 11); #expect(a.conflicts.isEmpty); #expect(b.conflicts.isEmpty)
    }

    @Test func staleTargetsAreRejectedWithoutChangingLatestEntry() throws {
        let (a, b, entry) = try pair()
        let parents = b.state.ledger.heads(entry.id).map(\.id)
        var updated = entry; updated.target?.sets = 5
        #expect(a.write(.entry(updated)))
        b.receive(a.state.ledger.revisions, workoutID: entry.workoutID)
        var stale = entry; stale.target?.sets = 4
        #expect(!b.write(.entry(stale), parents: parents))
        #expect(b.entries.first { $0.id == entry.id }?.target?.sets == 5)
        #expect(b.conflicts.isEmpty)
    }

    @Test func disconnectedPartnerIsReadOnlyIncludingOpenDraftsAndTargets() throws {
        let (a, b, entry) = try pair()
        let pending = draft(b, entry)
        b.nearbyReadyWorkoutID = nil; b.nearbyPeerID = nil
        #expect(!b.canLog); #expect(b.partnerEditingUnavailable != nil)
        #expect(!b.saveSet(pending))
        var changed = entry; changed.target?.sets = 7
        #expect(!b.write(.entry(changed)))
        #expect(!b.canChooseDay)
        b.selectPerson(b.me.id)
        #expect(b.canLog); #expect(b.partnerEditingUnavailable == nil)
        b.selectExercise(try #require(b.exercise("squat-barbell")))
        #expect(b.saveSet(draft(b, try #require(b.current))))
        b.nearbyReadyWorkoutID = entry.workoutID; b.nearbyPeerID = a.me.id
        b.selectPerson(a.me.id)
        #expect(b.canLog)
        b.nearbyReadyWorkoutID = "another-session"
        #expect(!b.canLog)
    }

    @Test func oldLockMetadataDoesNotBlockRelaunchedSession() throws {
        let (a, _, _) = try pair()
        let data = try JSONEncoder().encode(a.state)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pageAuthorities"] = [try #require(a.active).id: "old-coordinator"]
        object["cloudPageLockWorkouts"] = [try #require(a.active).id]
        let url = FileManager.default.temporaryDirectory.appending(path: "SpotterEditingTests/\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let reopened = Store(file: url)
        #expect(reopened.active?.id == a.active?.id); #expect(reopened.canLog)
    }
}
