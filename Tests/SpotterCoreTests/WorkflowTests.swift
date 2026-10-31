import Testing
import Foundation
@testable import SpotterCore

@MainActor struct WorkflowTests {
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")) }
    @Test func cancellingEmptyExerciseRemovesEntryAndKeepsPlanSlotAvailable() throws {
        let s = store()
        s.start(day: s.days[0], shared: false)
        let exercise = try #require(s.exercise(s.days[0].exercises[0].exerciseID))
        s.selectExercise(exercise)
        let entry = try #require(s.current)
        #expect(s.cancelExercise(entry))
        #expect(s.current == nil)
        #expect(s.myEntries.isEmpty)
        #expect(WorkoutEngine.recommended(try #require(s.participant), ledger: s.state.ledger) == exercise.id)
        #expect(s.save())
    }

    @Test func cancellationCannotRemoveLoggedSets() throws {
        let s = store()
        s.start(day: s.days[0], shared: false)
        s.selectExercise(try #require(s.exercise(s.days[0].exercises[0].exerciseID)))
        let entry = try #require(s.current)
        var set = s.makeSet(entry)
        set.weight = 20; set.reps = 10
        #expect(s.saveSet(set))
        #expect(!s.cancelExercise(entry))
        #expect(s.sets(for: entry).count == 1)
        #expect(s.current?.id == entry.id)
    }

    @Test func relaunchRemovesDemoProfilesAndPreservesRealWorkout() throws {
        let s = store()
        s.start(day: s.days[0], shared: false)
        let realWorkout = try #require(s.active).id
        let ownID = s.me.id
        s.finish()
        s.addDemo()
        let demoIDs = Set(s.state.profiles.filter(\.isDemo).map(\.id))
        s.start(day: s.days[0], shared: true, demoPartner: true)
        #expect(s.save())
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s.state).write(to: file)
        let reopened = Store(file: file)
        #expect(reopened.me.id == ownID)
        #expect(reopened.person.id == ownID)
        #expect(reopened.state.profiles.count == 1)
        #expect(reopened.active == nil)
        #expect(reopened.workouts.map(\.id) == [realWorkout])
        #expect(!reopened.members.contains { demoIDs.contains($0.profile.id) })
        #expect(!reopened.state.ledger.revisions.contains { demoIDs.contains($0.authorID) })
        let again = Store(file: file)
        #expect(again.state.ledger == reopened.state.ledger)
        #expect(again.state.profiles == reopened.state.profiles)
    }
    @Test func finishingWhileFocusedOnFriendAllowsNewOwnWorkout() throws {
        let a = store(); let b = store()
        a.start(day: nil, shared: true)
        let workoutID = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: workoutID); b.join(workoutID)
        a.receive(b.state.ledger.revisions, workoutID: workoutID)
        b.selectPerson(a.me.id)
        #expect(b.person.id == a.me.id)
        b.finish()
        #expect(b.person.id == b.me.id)
        b.start(day: nil, shared: false)
        #expect(b.active?.ownerID == b.me.id)
        #expect(b.active?.id != workoutID)
        #expect(b.canLog)
    }
    @Test func remoteFinishAndLegacySavedFriendFocusReturnToOwnProfile() throws {
        let a = store(); let b = store()
        a.start(day: nil, shared: true)
        let workoutID = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: workoutID); b.join(workoutID)
        a.receive(b.state.ledger.revisions, workoutID: workoutID)
        b.selectPerson(a.me.id)
        a.finish()
        b.receive(a.state.ledger.revisions, workoutID: workoutID)
        #expect(b.person.id == b.me.id)
        #expect(b.active?.finished == nil)
        #expect(b.activeMembers.map(\.profile.id) == [b.me.id])
        #expect(b.canLog)
        b.finish()
        // Reproduce the persisted selection left by older versions of the app.
        b.state.activePersonID = a.me.id
        #expect(b.save(notify: false))
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/legacy-friend-focus-\(UUID().uuidString).json")
        try JSONEncoder().encode(b.state).write(to: file)
        let reopened = Store(file: file)
        #expect(reopened.person.id == reopened.me.id)
        reopened.start(day: nil, shared: false)
        #expect(reopened.active?.ownerID == reopened.me.id)
        #expect(reopened.canLog)
        #expect(reopened.workouts.contains { $0.id == workoutID && $0.finished != nil })
        #expect(reopened.members.contains { $0.workoutID == workoutID && $0.profile.id == a.me.id })
    }
    @Test func oneTimeFocusRepairIsSavedAndPreservesWorkoutAndHistory() throws {
        let host = store(); let friend = store()
        host.start(day: nil, shared: true)
        let workoutID = try #require(host.active).id
        friend.receive(host.state.ledger.revisions, workoutID: workoutID)
        friend.join(workoutID)
        friend.selectPerson(host.me.id)
        var legacy = friend.state
        legacy.workoutFocusRepairVersion = nil
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/focus-repair-\(UUID().uuidString).json")
        try JSONEncoder().encode(legacy).write(to: file)
        let repaired = Store(file: file)
        #expect(repaired.person.id == repaired.me.id)
        #expect(repaired.state.workoutFocusRepairVersion == 1)
        #expect(repaired.state.ledger == legacy.ledger)
        #expect(repaired.state.profiles == legacy.profiles)
        #expect(repaired.state.activeWorkoutID == workoutID)
        #expect(try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file)).workoutFocusRepairVersion == 1)
        // Future launches preserve intentional partner focus in an ongoing workout.
        repaired.selectPerson(host.me.id)
        let again = Store(file: file)
        #expect(again.person.id == host.me.id)
        #expect(again.state.ledger == legacy.ledger)
        again.finish()
        again.start(day: nil, shared: false)
        #expect(again.active?.ownerID == friend.me.id)
        #expect(again.canLog)
    }
    @Test func sharedFinishOnlyEndsCallerAndKeepsPersonalHistory() throws {
        let host = store(); let friend = store()
        host.start(day: host.days[0], shared: true)
        let id = try #require(host.active).id
        friend.receive(host.state.ledger.revisions, workoutID: id); friend.join(id)
        host.receive(friend.state.ledger.revisions, workoutID: id)
        let exercise = try #require(host.exercise("bench-barbell"))
        host.selectExercise(exercise)
        var ownSet = host.makeSet(try #require(host.current)); ownSet.weight = 45; ownSet.reps = 10
        #expect(host.saveSet(ownSet))
        host.selectPerson(friend.me.id)
        let friendBefore = try #require(host.participant)
        host.finish()
        #expect(host.active == nil); #expect(host.person.id == host.me.id)
        #expect(host.members.first { $0.workoutID == id && $0.profile.id == host.me.id }?.finished != nil)
        #expect(host.members.first { $0.workoutID == id && $0.profile.id == friend.me.id } == friendBefore)
        #expect(host.state.ledger.workouts.first { $0.id == id }?.finished == nil)
        #expect(ProgressEngine.summary(personID: host.me.id, since: .distantPast, ledger: host.state.ledger).workouts == 1)
        #expect(WorkoutEngine.previous(personID: host.me.id, exerciseID: exercise.id, excluding: nil, ledger: host.state.ledger) != nil)
        #expect(ProgressEngine.trends(personID: host.me.id, exerciseID: exercise.id, since: .distantPast, ledger: host.state.ledger).count == 1)
        host.join(id); #expect(host.active == nil)
        friend.selectPerson(host.me.id)
        friend.receive(host.state.ledger.revisions, workoutID: id)
        #expect(friend.active?.id == id); #expect(friend.person.id == friend.me.id)
        #expect(friend.activeMembers.map(\.profile.id) == [friend.me.id])
        #expect(friend.canLog); #expect(friend.canChooseDay)
        friend.selectPerson(host.me.id); #expect(!friend.canLog)
        friend.selectPerson(friend.me.id); friend.selectExercise(exercise)
        var lastSet = friend.makeSet(try #require(friend.current)); lastSet.weight = 35; lastSet.reps = 8
        #expect(friend.saveSet(lastSet))
        host.start(day: nil, shared: false)
        let newID = try #require(host.active).id
        friend.finish()
        host.receive(friend.state.ledger.revisions, workoutID: id)
        #expect(host.active?.id == newID)
        #expect(host.workouts.first { $0.id == id }?.finished != nil)
        #expect(host.conflicts.isEmpty)
        #expect(host.sets.contains { $0.id == ownSet.id }); #expect(host.sets.contains { $0.id == lastSet.id })
        #expect(friend.personalWorkout(try #require(friend.workouts.first { $0.id == id }), personID: friend.me.id).finished != nil)
    }
    @Test func simultaneousSharedFinishesConvergeWithoutWorkoutConflict() throws {
        let a = store(); let b = store()
        a.start(day: nil, shared: true)
        let id = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: id); b.join(id)
        a.receive(b.state.ledger.revisions, workoutID: id)
        a.finish(); b.finish()
        a.receive(b.state.ledger.revisions, workoutID: id)
        b.receive(a.state.ledger.revisions, workoutID: id)
        #expect(a.conflicts.isEmpty); #expect(b.conflicts.isEmpty)
        #expect(a.workouts.first { $0.id == id } == b.workouts.first { $0.id == id })
        #expect(a.workouts.first { $0.id == id }?.finished != nil)
        #expect(a.members.filter { $0.workoutID == id }.allSatisfy { $0.finished != nil })
        #expect(a.active == nil); #expect(b.active == nil)
        a.join(id); #expect(a.active == nil)
    }
    @Test func ownerLeavingPreparationAllowsFriendToBegin() throws {
        let a = store(); let b = store()
        a.start(day: nil, shared: true, preparing: true)
        let id = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: id); b.join(id)
        a.receive(b.state.ledger.revisions, workoutID: id)
        a.cancelPreparation()
        b.receive(a.state.ledger.revisions, workoutID: id)
        #expect(b.canManageActiveWorkout)
        b.beginWorkout()
        #expect(b.active?.isPreparing == false); #expect(b.canLog)
    }
    @Test func preparationAllowsDayChangesBeforeAndAfterInviting() {
        let s = store()
        s.start(day: s.days[0], shared: false, preparing: true)
        #expect(s.canChooseDay)
        s.setDay(s.days[1])
        #expect(s.participant?.day?.id == s.days[1].id)
        s.inviteToPreparedWorkout()
        #expect(s.canChooseDay)
        s.setDay(s.days[2])
        #expect(s.participant?.day?.id == s.days[2].id)
        #expect(!s.canLog)
    }
    @Test func preparationCanContinueSoloWithoutSharing() {
        let s = store()
        s.start(day: s.days[0], shared: false, preparing: true)
        #expect(s.active?.isPreparing == true)
        #expect(!s.canLog)
        #expect(s.activeMembers.count == 1)
        s.beginWorkout()
        #expect(s.active?.isPreparing == false)
        #expect(s.active?.shared == false)
        #expect(s.canLog)
        #expect(s.entries.isEmpty)
    }
    @Test func midWorkoutInvitationSharesExistingWorkoutWithoutResettingProgress() throws {
        let s = store()
        s.start(day: s.days[0], shared: false)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let entry = try #require(s.current)
        var set = s.makeSet(entry); set.weight = 45; set.reps = 8
        #expect(s.saveSet(set))
        let before = try #require(s.active)
        let participant = try #require(s.participant)
        s.inviteToWorkout()
        s.inviteToWorkout()
        #expect(s.active?.id == before.id)
        #expect(s.active?.started == before.started)
        #expect(s.active?.isPreparing == false)
        #expect(s.active?.shared == true)
        #expect(s.current?.id == entry.id)
        #expect(s.sets.contains { $0.id == set.id })
        #expect(s.participant == participant)
        #expect(s.activeMembers.count == 1)
        #expect(s.canLog)
    }
    @Test func invitationKeepsPreparedWorkoutAndAddsDemoFriendOnce() throws {
        let s = store(); s.addDemo()
        s.start(day: s.days[0], shared: false, preparing: true)
        let id = try #require(s.active).id
        s.inviteToPreparedWorkout()
        s.inviteToPreparedWorkout()
        #expect(s.active?.id == id)
        #expect(s.active?.shared == true)
        #expect(s.active?.isPreparing == true)
        #expect(s.activeMembers.count == 2)
        #expect(!s.canLog)
        s.beginWorkout()
        #expect(s.canLog)
        #expect(s.entries.filter { $0.workoutID == id }.isEmpty)
    }
    @Test func startsEmptyAndTargetsAreOnlySuggestions() throws {
        let s = store(); s.start(day: s.days[0], shared: false)
        #expect(s.active != nil); #expect(s.entries.isEmpty); #expect(s.sets.isEmpty)
        #expect(WorkoutEngine.recommended(try #require(s.participant), ledger: s.state.ledger) == "bench-barbell")
    }
    @Test func participantSwitchKeepsIndependentExercises() throws {
        let s = store(); s.addDemo(); s.start(day: s.days[0], shared: true, demoPartner: true)
        let first = s.person.id; let other = try #require(s.activeMembers.first { $0.profile.id != first })
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let before = s.state.ledger.revisions.count
        s.selectPerson(other.profile.id)
        #expect(s.suggestedExerciseID == "bench-barbell")
        #expect(s.myEntries.isEmpty); #expect(s.current == nil)
        #expect(s.state.ledger.revisions.count == before)
        s.selectExercise(try #require(s.exercise("squat-barbell")))
        #expect(s.current?.exercise.id == "squat-barbell")
        s.selectPerson(first)
        #expect(s.current?.exercise.id == "bench-barbell")
        #expect(s.suggestedExerciseID == "bench-barbell")
    }
    @Test func participantHistoriesNeverCross() throws {
        let s = store(); s.addDemo()
        let alex = s.person.id; let jamie = try #require(s.state.profiles.first { $0.isDemo && $0.id != alex }).id
        let a = try #require(WorkoutEngine.previous(personID: alex, exerciseID: "bench-barbell", excluding: nil, ledger: s.state.ledger))
        let b = try #require(WorkoutEngine.previous(personID: jamie, exerciseID: "bench-barbell", excluding: nil, ledger: s.state.ledger))
        #expect(a.entry.personID == alex); #expect(b.entry.personID == jamie)
        #expect(a.sets.allSatisfy { $0.personID == alex }); #expect(a.sets[0].weight != b.sets[0].weight)
    }
    @Test func historyFollowsExerciseAcrossTrainingDays() throws {
        let s = store(); let exercise = try #require(s.exercise("bench-barbell"))
        s.start(day: s.days[0], shared: false); s.selectExercise(exercise)
        var set = s.makeSet(try #require(s.current)); set.weight = 50; set.reps = 12; set.completed = true; s.saveSet(set); s.finish()
        s.start(day: s.days[2], shared: false); s.selectExercise(exercise)
        #expect(s.previous(exercise.id)?.sets.first?.weight == 50)
    }
    @Test func laterPlanChangesPreserveSessionTargets() throws {
        let s = store(); s.start(day: s.days[0], shared: false); s.selectExercise(try #require(s.exercise("bench-barbell")))
        s.state.plans[0].days[0].exercises[0].target.high = 20
        #expect(s.current?.target?.high == 12)
        #expect(s.participant?.day?.exercises[0].target.high == 12)
    }
    @Test func renamePreservesIdentityHistoryAndAliases() throws {
        let s = store(); let exercise = try #require(s.exercise("bench-barbell"))
        s.start(day: s.days[0], shared: false); s.selectExercise(exercise)
        s.rename(exercise, to: "Our chest press", increment: 1.25)
        #expect(s.search("Our chest").map(\.id).contains(exercise.id))
        #expect(s.search("Barbell bench").map(\.id).contains(exercise.id))
        #expect(s.search("Flat bench").map(\.id).contains(exercise.id))
        #expect(s.current?.exercise.id == exercise.id)
        #expect(s.participant?.day?.exercises[0].exerciseID == exercise.id)
    }
    @Test func customExerciseCanBeFoundAndHasStableSharedIdentity() throws {
        let s = store(); let custom = Exercise(id: UUID().uuidString, name: "Sled drag", aliases: ["Backward walk"], primary: "Quads", equipment: "Sled", pattern: "Walk", tracking: .distance)
        s.addExercise(custom); #expect(s.search("Backward walk").first?.id == custom.id)
        s.start(day: nil, shared: true); s.selectExercise(custom)
        let b = store(); b.receive(s.state.ledger.revisions, workoutID: try #require(s.active).id)
        #expect(b.exercise(custom.id) == custom)
    }
    @Test func connectedSharedWorkoutAllowsPartnerLoggingAndRecordsBothPeople() throws {
        let a = store(); let b = store(); a.start(day: nil, shared: true); let workout = try #require(a.active)
        b.receive(a.state.ledger.revisions, workoutID: workout.id); b.join(workout.id)
        a.receive(b.state.ledger.revisions, workoutID: workout.id); a.selectPerson(b.me.id)
        a.nearbyReadyWorkoutID = workout.id; a.nearbyPeerID = b.me.id
        #expect(a.canLog)
        // Legacy records with the removed setting off still allow partner logging.
        var member = try #require(b.participant); member.permitsPartnerLogging = false; b.write(.participant(member))
        a.receive(b.state.ledger.revisions, workoutID: workout.id); #expect(a.canLog)
        a.selectExercise(try #require(a.exercise("bench-barbell")))
        var set = a.makeSet(try #require(a.current)); set.weight = 40; set.reps = 10; set.completed = true; a.saveSet(set)
        #expect(a.sets.first?.personID == b.me.id); #expect(a.sets.first?.enteredBy == a.me.id)
    }
    @Test func unfinishedWorkoutAndUnknownRIRSurviveRelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")
        let s = Store(file: file); s.start(day: s.days[0], shared: false); s.selectExercise(try #require(s.exercise("bench-barbell")))
        var set = s.makeSet(try #require(s.current)); set.weight = 50; set.reps = 10; set.rir = nil; s.saveSet(set)
        let reloaded = Store(file: file)
        #expect(reloaded.active?.id == s.active?.id); #expect(reloaded.current?.id == s.current?.id)
        #expect(reloaded.sets.first?.rir == nil); #expect(reloaded.sets.first?.completed == true)
    }
    @Test func setTimingSurvivesEditsAndRelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterTests/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        s.start(day: nil, shared: false)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let entry = try #require(s.current)
        var first = s.makeSet(entry); first.weight = 50; first.reps = 10
        #expect(s.saveSet(first))
        let saved = try #require(s.sets.first { $0.id == first.id })
        #expect(saved.loggedAt != nil)
        #expect(saved.intervalSincePreviousSet == nil)
        var second = s.makeSet(entry); second.weight = 50; second.reps = 8
        #expect(s.saveSet(second))
        var edited = try #require(s.sets.first { $0.id == second.id })
        let timestamp = edited.loggedAt
        let interval = try #require(edited.intervalSincePreviousSet)
        #expect(interval >= 0)
        var timing = edited
        timing.intervalSincePreviousSet = 120
        #expect(timing.timeBetweenSets == 90)
        timing.intervalSincePreviousSet = 20
        #expect(timing.timeBetweenSets == 0)
        timing.intervalSincePreviousSet = nil
        #expect(timing.timeBetweenSets == nil)
        edited.reps = 9; edited.loggedAt = nil; edited.intervalSincePreviousSet = nil
        #expect(s.saveSet(edited))
        let reloaded = Store(file: file)
        let result = try #require(reloaded.sets.first { $0.id == second.id })
        #expect(result.loggedAt == timestamp)
        #expect(result.intervalSincePreviousSet == interval)
    }
    @Test func deleteUndoRestoresStableID() throws {
        let s = store(); s.start(day: nil, shared: false); s.selectExercise(try #require(s.exercise("bench-barbell")))
        var set = s.makeSet(try #require(s.current)); set.weight = 40; set.reps = 10; s.saveSet(set); s.deleteSet(set)
        #expect(s.sets.isEmpty); s.undoDelete(); #expect(s.sets.first?.id == set.id)
    }
    @Test func skippingIsPersonalAndChangingDayIsShared() throws {
        let s = store(); s.addDemo(); s.start(day: s.days[0], shared: true, demoPartner: true)
        let other = try #require(s.activeMembers.first { $0.profile.id != s.person.id })
        s.skip("bench-barbell")
        #expect(WorkoutEngine.recommended(try #require(s.participant), ledger: s.state.ledger) == "incline-dumbbell")
        s.setDay(s.days[2]); let entries = s.entries.filter { $0.workoutID == s.active?.id }; #expect(entries.isEmpty)
        #expect(s.members.first { $0.id == other.id }?.day == s.days[2])
    }
    @Test func progressExcludesWarmupsIncompleteAndOtherPeople() throws {
        let s = store(); s.start(day: nil, shared: false); s.selectExercise(try #require(s.exercise("bench-barbell")))
        let entry = try #require(s.current)
        var set = s.makeSet(entry); set.weight = 50; set.reps = 10; set.completed = true; s.saveSet(set)
        var warm = s.makeSet(entry); warm.weight = 20; warm.reps = 10; warm.warmup = true; warm.completed = true; s.saveSet(warm)
        var legacyDraft = s.makeSet(entry); legacyDraft.completed = false
        s.write(.set(legacyDraft)); s.finish()
        let summary = ProgressEngine.summary(personID: s.person.id, since: .distantPast, ledger: s.state.ledger)
        #expect(summary.workouts == 1); #expect(summary.workingSets == 1); #expect(abs(summary.volumePounds - 500) < 0.000001)
        #expect(ProgressEngine.summary(personID: "someone else", since: .distantPast, ledger: s.state.ledger).workouts == 0)
    }
    @Test func invitationLobbySharesDayBeforeStarting() throws {
        let host = store(); let friend = store()
        host.start(day: host.days[0], shared: true, preparing: true)
        let id = try #require(host.active).id
        #expect(!host.canLog); #expect(host.entries.isEmpty)
        friend.receive(host.state.ledger.revisions, workoutID: id); friend.join(id)
        #expect(friend.active?.isPreparing == true)
        #expect(friend.participant?.day == host.participant?.day)
        #expect(!friend.canLog)
        friend.beginWorkout(); #expect(friend.active?.isPreparing == true)
        host.receive(friend.state.ledger.revisions, workoutID: id)
        host.nearbyReadyWorkoutID = id; host.nearbyPeerID = friend.me.id
        host.setDay(host.days[1])
        host.beginWorkout()
        friend.receive(host.state.ledger.revisions, workoutID: id)
        #expect(friend.active?.isPreparing == false); #expect(friend.canLog)
        #expect(host.activeMembers.allSatisfy { $0.day == host.days[1] })
        #expect(friend.current == nil); #expect(host.current == nil)
    }
    @Test func logIsAtomicAndInvalidEditsPreserveRecordedSet() throws {
        let s = store(); s.start(day: s.days[0], shared: false)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let entry = try #require(s.current)
        var draft = s.makeSet(entry)
        #expect(s.sets.isEmpty)
        #expect(!s.saveSet(draft)); #expect(s.sets.isEmpty)
        draft.weight = 40; draft.reps = 10
        #expect(s.saveSet(draft)); #expect(s.sets.first?.completed == true)
        var invalidEdit = draft; invalidEdit.reps = nil
        #expect(!s.saveSet(invalidEdit)); #expect(s.sets.first?.reps == 10)
        #expect(s.finishExercise(entry)); #expect(s.current == nil)
        #expect(s.myEntries.first?.status == .completed)
        #expect(WorkoutEngine.recommended(try #require(s.participant), ledger: s.state.ledger) == "incline-dumbbell")
    }
    @Test func warmupsDoNotConsumeWorkingSlotsAndTimingIsPersonal() throws {
        let s = store(); s.addDemo(); s.start(day: s.days[0], shared: true, demoPartner: true)
        let firstID = s.person.id
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let entry = try #require(s.current)
        var warmup = s.makeSet(entry); warmup.weight = 20; warmup.reps = 10; warmup.warmup = true
        #expect(s.saveSet(warmup)); #expect(s.sets.first { $0.id == warmup.id }?.prescribedIndex == nil)
        #expect(s.makeSet(entry).prescribedIndex == 0)
        s.selectPerson(try #require(s.activeMembers.first { $0.profile.id != firstID }).profile.id)
        #expect(s.current == nil)
        let participantSets = s.sets.filter { $0.personID == s.person.id && $0.workoutID == s.active?.id }
        #expect(participantSets.isEmpty)
        s.selectPerson(firstID)
        #expect(s.sets.first { $0.id == warmup.id }?.loggedAt != nil)
    }
    @Test func cancelledInvitationCannotBeJoinedOrCountAsAWorkout() throws {
        let host = store(); let friend = store()
        host.start(day: host.days[0], shared: true, preparing: true)
        let workoutID = try #require(host.active).id
        host.cancelPreparation()
        #expect(host.active == nil)
        friend.receive(host.state.ledger.revisions, workoutID: workoutID)
        friend.join(workoutID)
        #expect(friend.active == nil); #expect(friend.members.count == 1)
        #expect(ProgressEngine.summary(personID: host.me.id, since: .distantPast, ledger: host.state.ledger).workouts == 0)
    }
    @Test func oldWorkoutsDecodeAsStartedSessions() throws {
        let workout = Workout(ownerID: "me", title: "Push")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workout)) as? [String: Any])
        json.removeValue(forKey: "isPreparing")
        let decoded = try JSONDecoder().decode(Workout.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.isPreparing); #expect(decoded.id == workout.id)
    }
    @Test func damagedStoreIsNeverOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "corrupt-\(UUID().uuidString).json")
        let original = Data("not json".utf8); try original.write(to: file)
        let s = Store(file: file); #expect(s.readOnly); #expect(!s.save()); #expect(try Data(contentsOf: file) == original)
    }
}
