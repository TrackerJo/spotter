import Foundation
import Testing
@testable import SpotterCore

struct PersonalSyncTests {
    func state() -> LocalState {
        var state = LocalState()
        state.ownID = state.profiles[0].id
        state.activePersonID = state.ownID
        return state
    }

    @Test func sharedSessionsNeverUploadOrMergeFromLegacyCloudCopies() throws {
        var local = state()
        let shared = Workout(ownerID: local.ownID, title: "Together", shared: true)
        let solo = Workout(ownerID: local.ownID, title: "Solo")
        local.ledger.write(.workout(shared), entityID: shared.id, workoutID: shared.id, author: local.ownID)
        local.ledger.write(.workout(solo), entityID: solo.id, workoutID: solo.id, author: local.ownID)
        let snapshot = try JSONDecoder().decode(LocalState.self, from: PersonalSync.snapshot(local))
        #expect(snapshot.ledger.revisions.allSatisfy { $0.workoutID != shared.id })
        #expect(snapshot.ledger.revisions.contains { $0.workoutID == solo.id })
        var remote = local
        var changed = shared; changed.title = "Stale cloud edit"
        remote.ledger.write(.workout(changed), entityID: shared.id, workoutID: shared.id, author: local.ownID)
        let remoteShared = Workout(ownerID: local.ownID, title: "Old shared", shared: true)
        remote.ledger.write(.workout(remoteShared), entityID: remoteShared.id, workoutID: remoteShared.id, author: local.ownID)
        let merged = try PersonalSync.merge(local: local, remote: remote, base: nil)
        #expect(merged.ledger == local.ledger)
        #expect(merged.cloudLinks.isEmpty)
    }

    @Test func independentPlansAndDeletionMerge() throws {
        let base = state()
        var local = base; var remote = base
        local.plans.removeAll()
        let added = Plan(name: "Remote plan")
        remote.plans.append(added)
        let merged = try PersonalSync.merge(local: local, remote: remote, base: base)
        #expect(merged.plans == [added])
    }

    @Test func newDeviceRecoversIdentityAndHistory() throws {
        var remote = state()
        remote.plans = [Plan(name: "My split")]
        remote.names = [remote.ownID: ["bench": "My bench"]]
        let workout = Workout(ownerID: remote.ownID, title: "Yesterday")
        remote.ledger.write(.workout(workout), entityID: workout.id, workoutID: workout.id, author: remote.ownID)
        let merged = try PersonalSync.merge(local: state(), remote: remote, base: nil)
        #expect(merged.ownID == remote.ownID)
        #expect(merged.plans == remote.plans)
        #expect(merged.ledger == remote.ledger)
        #expect(merged.names == remote.names)
    }

    @Test func uploadRebasePreservesNewEditsAndActiveWorkout() throws {
        let base = state()
        var local = base; var remote = base
        local.activeWorkoutID = "active"
        local.plans.append(Plan(name: "During upload"))
        remote.customExercises = [Exercise(id: "custom", name: "Custom", primary: "chest", equipment: "other", pattern: "push")]
        let merged = try PersonalSync.merge(local: local, remote: remote, base: base)
        #expect(merged.activeWorkoutID == "active")
        #expect(merged.plans == local.plans)
        #expect(merged.customExercises == remote.customExercises)
    }
}
