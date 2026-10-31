import Foundation
import Testing
@testable import SpotterCore

@MainActor struct ManagedProfileTests {
    @Test func historyPickerExcludesUnmanagedIdentitiesEvenWithWorkoutHistory() throws {
        let s = store()
        let leftover = Profile(name: "You")
        s.state.profiles.append(leftover)
        let workout = Workout(ownerID: leftover.id, title: "Old workout")
        let member = Participant(workoutID: workout.id, profile: leftover, day: nil)
        s.state.ledger.write(.workout(workout), entityID: workout.id, workoutID: workout.id, author: leftover.id)
        s.state.ledger.write(.participant(member), entityID: member.id, workoutID: workout.id, author: leftover.id)
        s.refresh()
        let ledger = s.state.ledger
        s.state.viewedProfileID = leftover.id
        #expect(s.managedProfiles.isEmpty)
        #expect(s.dataProfiles.map(\.id) == [s.me.id])
        #expect(s.dataProfile.id == s.me.id)

        // A real managed profile remains selectable before its first workout.
        let managed = try #require(s.createProfile(name: "Jamie"))
        #expect(s.dataProfiles.map(\.id) == [s.me.id, managed.id])
        #expect(s.state.profiles.contains { $0.id == leftover.id })
        #expect(s.state.ledger == ledger)
    }

    private func store() -> Store {
        Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterProfiles/\(UUID().uuidString)/state.json"))
    }

    @Test func removingProfilePersistsAndKeepsHistory() throws {
        let s = store()
        let jamie = try #require(s.createProfile(name: "Jamie"))
        let alex = try #require(s.createProfile(name: "Alex"))
        #expect(!s.removeProfile(s.me.id))
        #expect(!s.removeProfile("unknown"))
        s.readOnly = true
        #expect(!s.removeProfile(jamie.id))
        s.readOnly = false
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(jamie.id))
        s.selectPerson(jamie.id)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        var set = s.makeSet(try #require(s.current)); set.weight = 60; set.reps = 8
        #expect(s.saveSet(set))
        #expect(!s.canRemoveProfile(jamie.id))
        #expect(!s.removeProfile(jamie.id))
        s.finish()
        s.viewProfile(jamie.id)
        let stale = s.state
        let ledger = s.state.ledger
        #expect(s.removeProfile(jamie.id))
        #expect(s.state.ledger == ledger)
        #expect(s.dataProfile.id == s.me.id)
        #expect(!s.dataProfiles.contains { $0.id == jamie.id })
        #expect(s.managedProfiles.contains { $0.id == alex.id })
        #expect(!s.ownsProfile(jamie.id))
        #expect(!s.renameProfile(jamie.id, to: "Back"))
        #expect(try !ChatGPTTrainingData(store: s).call("list_profiles", arguments: "{}").contains(jamie.id))
        let restored = try JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(s.state))
        #expect(restored.removedProfileIDs?.contains(jamie.id) == true)
        let merged = try PersonalSync.merge(local: stale, remote: restored, base: stale)
        #expect(merged.removedProfileIDs?.contains(jamie.id) == true)
        #expect(ProgressEngine.summary(personID: jamie.id, since: .distantPast, ledger: merged.ledger).workingSets == 1)
    }

    @Test func profilesPersistWithNamesAndNeverClaimNearbyFriends() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterProfiles/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        #expect(s.createProfile(name: " \n ") == nil)
        let profile = try #require(s.createProfile(name: "  Jamie \n"))
        #expect(profile.name == "Jamie")
        let sameName = try #require(s.createProfile(name: "Jamie"))
        #expect(sameName.id != profile.id)
        let friend = store()
        friend.start(day: nil, shared: true)
        s.receive(friend.state.ledger.revisions, workoutID: try #require(friend.active).id)
        let reopened = Store(file: file)
        #expect(reopened.managedProfiles.map(\.id).contains(profile.id))
        #expect(!reopened.ownsProfile(friend.me.id))
        #expect(!reopened.dataProfiles.contains { $0.id == friend.me.id })
        #expect(!reopened.renameProfile(friend.me.id, to: "Someone else"))
        reopened.readOnly = true
        #expect(reopened.createProfile(name: "Alex") == nil)
    }

    @Test func loggingForMultipleProfilesKeepsExercisesSetsAndHistorySeparate() throws {
        let s = store()
        let jamie = try #require(s.createProfile(name: "Jamie"))
        let alex = try #require(s.createProfile(name: "Alex"))
        s.start(day: s.days.first, shared: false, preparing: true)
        #expect(s.addProfileToWorkout(jamie.id))
        #expect(s.addProfileToWorkout(alex.id))
        #expect(!s.addProfileToWorkout(jamie.id))
        #expect(!s.canLog)
        s.setDay(s.days[1])
        #expect(s.activeMembers.allSatisfy { $0.day == s.days[1] })
        s.beginWorkout()
        let workout = try #require(s.active)
        let exercise = try #require(s.exercise("bench-barbell"))
        for (id, weight) in [(s.me.id, 100.0), (jamie.id, 60.0), (alex.id, 80.0)] {
            s.selectPerson(id)
            #expect(s.canLog)
            #expect(s.current == nil)
            s.selectExercise(exercise)
            var set = s.makeSet(try #require(s.current)); set.weight = weight; set.reps = 10
            #expect(s.saveSet(set))
            #expect(s.myEntries.count == 1)
            #expect(s.sets(for: try #require(s.current)).first?.enteredBy == s.me.id)
        }
        s.selectPerson(jamie.id)
        #expect(s.sets(for: try #require(s.current)).first?.weight == 60)
        s.viewProfile(alex.id)
        #expect(s.person.id == jamie.id)
        #expect(s.dataProfile.id == alex.id)
        s.finish()
        #expect(s.active == nil)
        #expect(s.members.filter { $0.workoutID == workout.id }.allSatisfy { $0.finished != nil })
        for (id, weight) in [(s.me.id, 100.0), (jamie.id, 60.0), (alex.id, 80.0)] {
            let summary = ProgressEngine.summary(personID: id, since: .distantPast, ledger: s.state.ledger)
            #expect(summary.workouts == 1)
            #expect(summary.workingSets == 1)
            #expect(abs(summary.volumePounds - weight * 10) < 0.001)
            #expect(WorkoutEngine.previous(personID: id, exerciseID: exercise.id, excluding: nil, ledger: s.state.ledger)?.sets.first?.weight == weight)
        }
    }

    @Test func activeProfileAndIndependentExerciseFocusSurviveRelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterProfiles/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        let profile = try #require(s.createProfile(name: "Jamie"))
        s.start(day: nil, shared: false)
        s.selectExercise(try #require(s.exercise("squat-barbell")))
        let ownerEntry = try #require(s.current)
        #expect(s.addProfileToWorkout(profile.id))
        s.selectPerson(profile.id)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let profileEntry = try #require(s.current)
        s.viewProfile(profile.id)
        let reopened = Store(file: file)
        #expect(reopened.person.id == profile.id)
        #expect(reopened.dataProfile.id == profile.id)
        #expect(reopened.canLog)
        #expect(reopened.current?.id == profileEntry.id)
        reopened.selectPerson(reopened.me.id)
        #expect(reopened.current?.id == ownerEntry.id)
    }

    @Test func renamingUpdatesActiveParticipantWithoutChangingIdentityOrLogs() throws {
        let s = store()
        let profile = try #require(s.createProfile(name: "Jamie"))
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(profile.id))
        s.selectPerson(profile.id)
        s.selectExercise(try #require(s.library.first))
        let entry = try #require(s.current)
        #expect(s.renameProfile(profile.id, to: "  James  "))
        #expect(s.person.name == "James")
        #expect(s.participant?.profile.name == "James")
        #expect(s.current?.id == entry.id)
        #expect(!s.renameProfile(profile.id, to: " "))
    }

    @Test func managedProfilesCoexistWithNearbyAndFinishOnlyOnTheirOwnPhone() throws {
        let a = store(); let b = store()
        let profile = try #require(a.createProfile(name: "Jamie"))
        let second = try #require(a.createProfile(name: "Alex"))
        a.start(day: nil, shared: true)
        #expect(a.addProfileToWorkout(profile.id))
        #expect(a.addProfileToWorkout(second.id))
        let workout = try #require(a.active)
        b.receive(a.state.ledger.revisions, workoutID: workout.id); b.join(workout.id)
        #expect(b.active?.id == workout.id)
        a.receive(b.state.ledger.revisions, workoutID: workout.id)
        #expect(a.activeMembers.count == 4)
        b.selectPerson(profile.id)
        #expect(!b.canLog)
        b.nearbyReadyWorkoutID = workout.id; b.nearbyPeerID = a.me.id
        #expect(b.canLog)
        b.selectExercise(try #require(b.library.first))
        var set = b.makeSet(try #require(b.current)); set.weight = 40; set.reps = 10
        #expect(b.saveSet(set))
        b.nearbyReadyWorkoutID = nil
        #expect(!b.canLog)
        a.receive(b.state.ledger.revisions, workoutID: workout.id)
        a.selectPerson(profile.id)
        #expect(a.canLog)
        #expect(a.sets(for: try #require(a.current)).count == 1)
        a.finish()
        b.receive(a.state.ledger.revisions, workoutID: workout.id)
        #expect(b.active?.id == workout.id)
        #expect(b.person.id == b.me.id)
        #expect(b.canLog)
        #expect(b.members.filter { $0.managedByID == a.me.id }.allSatisfy { $0.finished != nil })
        b.finish()
        #expect(b.workouts.first?.finished != nil)
    }

    @Test func managedHistoryCanBeEditedAndDeletedWithoutRemovingOtherResults() throws {
        let s = store()
        let profile = try #require(s.createProfile(name: "Jamie"))
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(profile.id))
        let workout = try #require(s.active)
        for id in [s.me.id, profile.id] {
            s.selectPerson(id); s.selectExercise(try #require(s.library.first))
            var set = s.makeSet(try #require(s.current)); set.weight = 40; set.reps = 10
            #expect(s.saveSet(set))
        }
        let entry = try #require(s.current)
        s.finish()
        #expect(s.canEditHistory(entry))
        var set = try #require(s.sets(for: entry).first); set.reps = 12
        #expect(s.saveSet(set))
        #expect(s.deleteWorkout(workout, personID: profile.id))
        #expect(s.sets.allSatisfy { $0.personID == s.me.id })
        #expect(s.workouts.count == 1)
        #expect(ProgressEngine.summary(personID: s.me.id, since: .distantPast, ledger: s.state.ledger).workouts == 1)
        #expect(ProgressEngine.summary(personID: profile.id, since: .distantPast, ledger: s.state.ledger).workouts == 0)
    }

    @Test func deletingOwnerSessionPreservesManagedResultsAndCompletesThem() throws {
        let s = store()
        let profile = try #require(s.createProfile(name: "Jamie"))
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(profile.id))
        let workout = try #require(s.active)
        s.selectPerson(profile.id); s.selectExercise(try #require(s.library.first))
        var set = s.makeSet(try #require(s.current)); set.weight = 40; set.reps = 10
        #expect(s.saveSet(set))
        #expect(s.deleteWorkout(workout, personID: s.me.id))
        #expect(s.active == nil)
        #expect(s.sets.count == 1)
        #expect(ProgressEngine.summary(personID: profile.id, since: .distantPast, ledger: s.state.ledger).workouts == 1)
    }

    @Test func managedProfilesAndTheirSoloHistorySyncAcrossDevices() throws {
        let a = store(); let b = store()
        let profile = try #require(a.createProfile(name: "Jamie"))
        a.start(day: nil, shared: false)
        #expect(a.addProfileToWorkout(profile.id))
        a.selectPerson(profile.id); a.selectExercise(try #require(a.library.first))
        var set = a.makeSet(try #require(a.current)); set.weight = 40; set.reps = 10
        #expect(a.saveSet(set)); a.finish()
        let remote = try JSONDecoder().decode(LocalState.self, from: PersonalSync.snapshot(a.state))
        let merged = try PersonalSync.merge(local: b.state, remote: remote, base: nil)
        #expect(b.applyPersonalSync(merged))
        #expect(b.managedProfiles.contains { $0.id == profile.id })
        #expect(b.ownsProfile(profile.id))
        #expect(ProgressEngine.summary(personID: profile.id, since: .distantPast, ledger: b.state.ledger).workouts == 1)
        b.start(day: nil, shared: false)
        #expect(b.addProfileToWorkout(profile.id))
        b.selectPerson(profile.id)
        #expect(b.canLog)
    }

    @Test func oldSavedStateAndParticipantsDecodeWithoutManagedProfileFields() throws {
        let s = store()
        s.start(day: nil, shared: false)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s.state)) as? [String: Any])
        json.removeValue(forKey: "managedProfileIDs"); json.removeValue(forKey: "viewedProfileID")
        let decoded = try JSONDecoder().decode(LocalState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.managedProfileIDs == nil)
        let member = try #require(s.participant)
        var memberJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(member)) as? [String: Any])
        memberJSON.removeValue(forKey: "managedByID")
        let decodedMember = try JSONDecoder().decode(Participant.self, from: JSONSerialization.data(withJSONObject: memberJSON))
        #expect(decodedMember.managedByID == nil)
        #expect(decodedMember.profile.id == s.me.id)
    }

    @Test func failedSavesKeepProfilesAndFinishingGroupUnchanged() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterProfiles/\(UUID().uuidString)/state.json")
        let s = Store(file: file)
        let profile = try #require(s.createProfile(name: "Jamie"))
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(profile.id))
        let original = try JSONEncoder().encode(s.state)
        let ledger = s.state.ledger
        let workoutID = s.active?.id
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(s.createProfile(name: "Alex") == nil)
        #expect(!s.renameProfile(profile.id, to: "James"))
        s.finish()
        #expect(s.active?.id == workoutID)
        #expect(s.members.allSatisfy { $0.finished == nil })
        #expect(s.state.ledger == ledger)
        #expect(s.managedProfiles.map(\.name) == ["Jamie"])
        #expect(try JSONDecoder().decode(LocalState.self, from: original).activeWorkoutID == workoutID)
    }

    @Test func independentProfileCreationAndRenamingMergeAcrossDevices() throws {
        let a = store()
        let profile = try #require(a.createProfile(name: "Jamie"))
        let base = a.state
        var remote = base
        let alex = Profile(name: "Alex")
        remote.profiles.append(alex); remote.managedProfileIDs?.append(alex.id)
        #expect(a.renameProfile(profile.id, to: "James"))
        let merged = try PersonalSync.merge(local: a.state, remote: remote, base: base)
        #expect(merged.profiles.first { $0.id == profile.id }?.name == "James")
        #expect(Set(merged.managedProfileIDs ?? []) == Set([profile.id, alex.id]))
    }

    @Test func historyDraftUsesRecordedPersonsPreviousPerformance() throws {
        let s = store()
        let profile = try #require(s.createProfile(name: "Jamie"))
        let exercise = try #require(s.exercise("bench-barbell"))
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(profile.id))
        for (id, weight) in [(s.me.id, 100.0), (profile.id, 60.0)] {
            s.selectPerson(id); s.selectExercise(exercise)
            var set = s.makeSet(try #require(s.current)); set.weight = weight; set.reps = 10
            #expect(s.saveSet(set))
        }
        s.rename(exercise, to: "Jamie chest press", increment: 5)
        s.finish()
        #expect(s.person.id == s.me.id)
        #expect(s.search("Jamie chest").isEmpty)
        #expect(s.search("Jamie chest", personID: profile.id).first?.id == exercise.id)
        let emptyEntry = ExerciseEntry(workoutID: s.workouts[0].id, personID: profile.id, exercise: exercise, order: 1)
        #expect(s.makeSet(emptyEntry).weight == 60)
    }
}
