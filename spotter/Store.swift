import Foundation
import Observation

struct CloudLink: Codable, Equatable, Identifiable {
    var id: String // workout ID
    var zoneName: String
    var ownerName: String
    var isOwner: Bool
    var uploaded: Set<String> = []
}
struct NearbyPairing: Codable {
    var workoutID: String
    var code: String
    var isHost: Bool
    var peerID: String
    var serviceName: String
    var serviceType: String
    var serviceDomain: String
}
struct LocalState: Codable {
    var nearbyPairing: NearbyPairing? = nil
    var personalSyncBase: Data? = nil
    var version = 1
    var profiles: [Profile] = [Profile(name: "You")]
    var ownID: String = ""
    var managedProfileIDs: [String]? = nil
    var removedProfileIDs: [String]? = nil
    var viewedProfileID: String? = nil
    var plans = SampleData.plans()
    var customExercises: [Exercise] = []
    var exerciseAliases: [String: [String]]? = nil
    var names: [String: [String: String]] = [:]
    var increments: [String: [String: Double]] = [:]
    var incrementUnits: [String: [String: WeightUnit]]? = nil
    var ledger = Ledger()
    var activeWorkoutID: String?
    var activePersonID: String = ""
    var workoutFocusRepairVersion: Int? = nil
    var cloudLinks: [CloudLink] = []


    @discardableResult mutating func repairWorkoutFocusOnce() -> Bool {
        guard workoutFocusRepairVersion != 1, !ownID.isEmpty else { return false }
        activePersonID = ownID
        workoutFocusRepairVersion = 1
        return true
    }

    // Migrate existing development installs without touching real workout history.
    @discardableResult mutating func removeDemoData() -> Bool {
        let demoIDs = Set(profiles.filter(\.isDemo).map(\.id))
        let demoWorkouts = Set(ledger.revisions.compactMap { revision -> String? in
            if case .workout(let workout) = revision.value,
               workout.demo || demoIDs.contains(workout.ownerID) { return workout.id }
            return nil
        })
        guard !demoIDs.isEmpty || !demoWorkouts.isEmpty else { return false }
        profiles.removeAll { demoIDs.contains($0.id) }
        ledger.revisions.removeAll { demoWorkouts.contains($0.workoutID) }
        for id in demoIDs {
            names.removeValue(forKey: id)
            increments.removeValue(forKey: id)
            incrementUnits?.removeValue(forKey: id)
        }
        cloudLinks.removeAll { demoWorkouts.contains($0.id) }
        if let id = activeWorkoutID, demoWorkouts.contains(id) { activeWorkoutID = nil }
        if demoIDs.contains(activePersonID) { activePersonID = ownID }
        return true
    }
}
@MainActor @Observable final class Store {
    var state: LocalState
    var library: [Exercise] = []
    var workouts: [Workout] = []
    var members: [Participant] = []
    var entries: [ExerciseEntry] = []
    var sets: [WorkoutSet] = []
    var conflicts: [[Revision]] = []
    var error: String?
    var suggestedExerciseID: String?
    var undoRevision: Revision?
    var readOnly = false
    // A live transport alone is insufficient: both peers must replay and acknowledge state.
    var nearbyReadyWorkoutID: String?
    var nearbyPeerID: String?
    func canEditPerson(_ personID: String, workoutID: String) -> Bool {
        if ownsProfile(personID) { return true }
        if workouts.first(where: { $0.id == workoutID })?.demo == true { return true }
        let loggingOwner = members.first { $0.workoutID == workoutID && $0.profile.id == personID }?.managedByID ?? personID
        return nearbyReadyWorkoutID == workoutID && nearbyPeerID == loggingOwner
    }
    var partnerEditingUnavailable: String? {
        guard active?.shared == true, active?.demo != true,
              !canEditPerson(person.id, workoutID: active!.id) else { return nil }
        return "Your friend’s session is read-only until Nearby reconnects and syncs. You can keep editing your own session."
    }
    func canEdit(_ value: Payload) -> Bool {
        switch value {
        case .participant(let x): return canEditPerson(x.profile.id, workoutID: x.workoutID)
        case .entry(let x): return canEditPerson(x.personID, workoutID: x.workoutID)
        case .set(let x): return canEditPerson(x.personID, workoutID: x.workoutID)
        case .baseline(let x): return canEditPerson(x.personID, workoutID: x.workoutID)
        case .workout: return true
        }
    }
    func canResolve(_ revision: Revision) -> Bool {
        let value = revision.value ?? state.ledger.revisions.first { $0.entityID == revision.entityID && $0.value != nil }?.value
        return !readOnly && value.map(canEdit) == true
    }
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "Spotter/state.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: self.file))
                guard state.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            } else { state = LocalState() }
        } catch {
            state = LocalState()
            self.error = "Your saved data could not be opened. It has been preserved. Restore state.json from a backup before continuing. \(error.localizedDescription)"
            readOnly = true
        }
        if state.ownID.isEmpty { state.ownID = state.profiles[0].id; state.activePersonID = state.ownID }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let url = bundle.url(forResource: "exercises", withExtension: "json") {
            do { library = try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url)) }
            catch { self.error = "Exercise library could not be loaded: \(error.localizedDescription)" }
        }
        library += state.customExercises
        for index in library.indices {
            for alias in state.exerciseAliases?[library[index].id] ?? [] where !library[index].aliases.contains(alias) {
                library[index].aliases.append(alias)
            }
        }
        let removedDemoData = state.removeDemoData()
        let repairedWorkoutFocus = !readOnly && state.repairWorkoutFocusOnce()
        refresh()
        // Freeze the units of existing personal increments before new pounds-based logs arrive.
        if state.incrementUnits == nil {
            state.incrementUnits = state.increments.mapValues { _ in [:] }
            for (personID, increments) in state.increments {
                for exerciseID in increments.keys {
                    let previous = WorkoutEngine.previous(personID: personID, exerciseID: exerciseID, excluding: nil, ledger: state.ledger)
                    state.incrementUnits?[personID]?[exerciseID] = previous?.sets.first { !$0.warmup }?.unit ?? .kg
                }
            }
        }
        if removedDemoData || repairedWorkoutFocus { save(notify: false) }
    }
    var me: Profile { state.profiles.first { $0.id == state.ownID }! }
    var managedProfiles: [Profile] { state.profiles.filter { state.managedProfileIDs?.contains($0.id) == true && !isProfileRemoved($0.id) } }
    // Past workout participants are not profiles managed by this account.
    var dataProfiles: [Profile] { [me] + managedProfiles.filter { $0.id != me.id } }
    var dataProfile: Profile { dataProfiles.first { $0.id == state.viewedProfileID } ?? me }
    func ownsProfile(_ id: String) -> Bool { id == actorID || (state.managedProfileIDs?.contains(id) == true && !isProfileRemoved(id)) }
    func isProfileRemoved(_ id: String) -> Bool { id != state.ownID && state.removedProfileIDs?.contains(id) == true }
    func canRemoveProfile(_ id: String) -> Bool {
        !readOnly && id != me.id && managedProfiles.contains { $0.id == id } &&
        !members.contains { member in
            member.profile.id == id && !member.deleted && member.finished == nil &&
            workouts.contains { $0.id == member.workoutID && $0.finished == nil }
        }
    }
    @discardableResult func removeProfile(_ id: String) -> Bool {
        guard canRemoveProfile(id) else { return false }
        let original = state
        state.removedProfileIDs = Array(Set(state.removedProfileIDs ?? []).union([id])).sorted()
        if state.viewedProfileID == id { state.viewedProfileID = me.id }
        if state.activePersonID == id { state.activePersonID = me.id }
        guard save(notify: false) else { state = original; return false }
        refresh(); didChange?(); return true
    }
    func viewProfile(_ id: String) {
        guard dataProfiles.contains(where: { $0.id == id }) else { return }
        state.viewedProfileID = id; save(notify: false)
    }
    @discardableResult func createProfile(name: String) -> Profile? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, !name.isEmpty else { return nil }
        let original = state
        let profile = Profile(name: name)
        state.profiles.append(profile)
        state.managedProfileIDs = (state.managedProfileIDs ?? []) + [profile.id]
        guard save(notify: false) else { state = original; return nil }
        return profile
    }
    @discardableResult func renameProfile(_ id: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, ownsProfile(id), !name.isEmpty,
              let index = state.profiles.firstIndex(where: { $0.id == id }) else { return false }
        let original = state
        state.profiles[index].name = name
        for var member in members where member.profile.id == id && member.finished == nil && !member.deleted {
            guard state.ledger.heads(member.id).count == 1 else { continue }
            member.profile.name = name
            state.ledger.write(.participant(member), entityID: member.id, workoutID: member.workoutID, author: actorID)
        }
        guard save(notify: false) else { state = original; return false }
        refresh(); didChange?(); return true
    }
    var canAddProfiles: Bool { !readOnly && active != nil && active?.finished == nil && members.contains { $0.workoutID == active?.id && $0.profile.id == actorID && $0.finished == nil && !$0.deleted } }
    @discardableResult func addProfileToWorkout(_ id: String) -> Bool {
        guard canAddProfiles, state.managedProfileIDs?.contains(id) == true,
              let profile = managedProfiles.first(where: { $0.id == id }), let workout = active,
              !members.contains(where: { $0.workoutID == workout.id && $0.profile.id == id }) else { return false }
        let day = members.first { $0.workoutID == workout.id && $0.profile.id == actorID }?.day
        var member = Participant(workoutID: workout.id, profile: profile, day: day)
        member.increments = state.increments[id] ?? [:]
        member.incrementUnits = state.incrementUnits?[id]
        member.managedByID = me.id
        let original = state
        state.ledger.write(.participant(member), entityID: member.id, workoutID: workout.id, author: actorID)
        guard save(notify: false) else { state = original; return false }
        refresh()
        if workout.shared { publishBaselines(workout.id) }
        else { didChange?() }
        return true
    }
    var person: Profile { state.profiles.first { $0.id == state.activePersonID } ?? me }
    var actorID: String { active?.demo == true ? active!.ownerID : me.id }
    var active: Workout? { workouts.first { $0.id == state.activeWorkoutID } }
    var participant: Participant? { members.first { $0.workoutID == active?.id && $0.profile.id == person.id } }
    var activeMembers: [Participant] { members.filter { $0.workoutID == active?.id && $0.finished == nil }.sorted { $0.profile.name < $1.profile.name } }
    var current: ExerciseEntry? { entries.first { $0.id == participant?.currentEntryID } }
    var myEntries: [ExerciseEntry] { entries.filter { $0.workoutID == active?.id && $0.personID == person.id }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order } }
    var canLog: Bool { !readOnly && active?.finished == nil && active?.isPreparing == false && participant != nil && participant?.finished == nil && active.map { canEditPerson(person.id, workoutID: $0.id) } == true }
    var canChooseDay: Bool { (active?.shared != true || activeMembers.allSatisfy { canEditPerson($0.profile.id, workoutID: $0.workoutID) }) && !readOnly && active?.finished == nil && (active?.shared == true || active?.isPreparing == true ? canManageActiveWorkout : canLog) }
    var canManageActiveWorkout: Bool {
        active?.ownerID == actorID || (active?.shared == true && !activeMembers.contains { $0.profile.id == active?.ownerID })
    }
    func personalWorkout(_ workout: Workout, personID: String) -> Workout {
        var personal = workout
        personal.finished = members.first { $0.workoutID == workout.id && $0.profile.id == personID }?.finished ?? workout.finished
        return personal
    }
    var days: [TrainingDay] { state.plans.flatMap(\.days) }
    var today: TrainingDay? { days.first { $0.weekdays.contains(Calendar.current.component(.weekday, from: Date())) } }
    func name(_ exercise: Exercise, personID: String? = nil) -> String { state.names[personID ?? person.id]?[exercise.id] ?? exercise.name }
    func exercise(_ id: String) -> Exercise? { library.first { $0.id == id } ?? entries.first { $0.exercise.id == id }?.exercise }
    func search(_ query: String, personID: String? = nil) -> [Exercise] { WorkoutEngine.search(query, exercises: library, names: state.names[personID ?? person.id] ?? [:]) }
    func sets(for entry: ExerciseEntry) -> [WorkoutSet] { sets.filter { $0.entryID == entry.id && $0.personID == entry.personID }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order } }
    func previous(_ exerciseID: String, personID: String? = nil) -> PreviousPerformance? {
        let personID = personID ?? person.id
        let local = WorkoutEngine.previous(personID: personID, exerciseID: exerciseID, excluding: active?.id, ledger: state.ledger)
        let shared = state.ledger.values.compactMap { value -> SharedBaseline? in if case .baseline(let x) = value { return x }; return nil }.first { $0.workoutID == active?.id && $0.personID == personID && $0.previous.entry.exercise.id == exerciseID }?.previous
        return [local, shared].compactMap { $0 }.max { $0.workout.started < $1.workout.started }
    }
    func exerciseHistory(_ exerciseID: String) -> [PreviousPerformance] {
        let entries = state.ledger.entries.filter { $0.personID == person.id && $0.exercise.id == exerciseID }
        let completedSets = Dictionary(grouping: state.ledger.sets.filter { $0.personID == person.id && $0.completed }, by: \.entryID)
        var history = state.ledger.workouts(for: person.id).filter { $0.id != active?.id && $0.finished != nil }.flatMap { workout in
            entries.filter { $0.workoutID == workout.id }.compactMap { entry -> PreviousPerformance? in
                let sets = (completedSets[entry.id] ?? []).sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
                guard !sets.isEmpty else { return nil }
                return PreviousPerformance(workout: workout, entry: entry, sets: sets)
            }
        }
        if let previous = previous(exerciseID), !history.contains(where: { $0.entry.id == previous.entry.id }) {
            history.append(previous)
        }
        return history.sorted { $0.workout.started > $1.workout.started }
    }
    func progression(_ exercise: Exercise, personID: String? = nil) -> Progression? {
        guard let previous = previous(exercise.id, personID: personID) else { return nil }
        let unit = previous.sets.first { !$0.warmup }?.unit ?? .lb
        return WorkoutEngine.progression(previous, increment: incrementPounds(exercise, personID: personID).map(unit.value(fromPounds:)))
    }
    func incrementPounds(_ exercise: Exercise, personID: String? = nil) -> Double? {
        let personID = personID ?? person.id
        let member = members.first { $0.workoutID == active?.id && $0.profile.id == personID }
        let legacyUnit = previous(exercise.id, personID: personID)?.sets.first { !$0.warmup }?.unit ?? .kg
        if let value = member?.increments[exercise.id] {
            return (member?.incrementUnits?[exercise.id] ?? legacyUnit).pounds(value)
        }
        if let value = state.increments[personID]?[exercise.id] {
            return (state.incrementUnits?[personID]?[exercise.id] ?? legacyUnit).pounds(value)
        }
        return exercise.increment.map(WeightUnit.kg.pounds)
    }
    func refresh() {
        let values = state.ledger.values
        members = values.compactMap { if case .participant(let x) = $0 { return x }; return nil }
        workouts = values.compactMap { value -> Workout? in
            guard case .workout(var workout) = value else { return nil }
            let joined = members.filter { $0.workoutID == workout.id }
            if workout.shared, workout.finished == nil, !joined.isEmpty, joined.allSatisfy({ $0.finished != nil }) {
                workout.finished = joined.compactMap(\.finished).max()
            }
            return workout
        }.sorted { $0.started > $1.started }
        entries = values.compactMap { if case .entry(let x) = $0 { return x }; return nil }
        sets = values.compactMap { if case .set(let x) = $0 { return x }; return nil }
        let grouped = Dictionary(grouping: state.ledger.revisions, by: \.entityID)
        conflicts = grouped.values.compactMap { history in
            let superseded = Set(history.flatMap(\.parents))
            let heads = history.filter { !superseded.contains($0.id) }
            return heads.count > 1 ? heads : nil
        }
        for member in members where !state.profiles.contains(where: { $0.id == member.profile.id }) { state.profiles.append(member.profile) }
        if let workout = active,
           members.first(where: { $0.workoutID == workout.id && $0.profile.id == actorID })?.finished != nil {
            state.activeWorkoutID = nil; state.activePersonID = me.id
        }
        // A departed partner disappears from live focus while their history stays saved.
        if active == nil || active?.finished != nil || participant?.finished != nil, person.id != me.id, !person.isDemo {
            state.activePersonID = me.id
        }
        for entry in entries where !library.contains(where: { $0.id == entry.exercise.id }) {
            library.append(entry.exercise); state.customExercises.append(entry.exercise)
        }
    }
    func applyPersonalSync(_ incoming: LocalState) -> Bool {
        let original = state
        state = incoming
        guard save(notify: false) else { state = original; return false }
        library.removeAll()
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let url = bundle.url(forResource: "exercises", withExtension: "json"),
           let data = try? Data(contentsOf: url), let exercises = try? JSONDecoder().decode([Exercise].self, from: data) { library = exercises }
        library += state.customExercises
        for index in library.indices {
            for alias in state.exerciseAliases?[library[index].id] ?? [] where !library[index].aliases.contains(alias) { library[index].aliases.append(alias) }
        }
        refresh()
        return save(notify: false)
    }
    @discardableResult func save(notify: Bool = true) -> Bool {
        guard !readOnly else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            if notify { didChange?() }
            return true
        } catch { self.error = "Could not save your workout. Keep the app open and free some storage. \(error.localizedDescription)"; return false }
    }
    @discardableResult func write(_ value: Payload, parents: [String]? = nil) -> Bool {
        guard !readOnly else { return false }
        guard canEdit(value) else { error = partnerEditingUnavailable ?? "Reconnect Nearby before editing your friend’s session."; return false }
        if let parents, Set(parents) != Set(state.ledger.heads(value.entityID).map(\.id)) {
            error = "This item changed on the other phone. Reopen it before saving."; return false
        }
        guard state.ledger.heads(value.entityID).count <= 1 else { error = "Review the conflicting versions before editing this item."; return false }
        state.ledger.write(value, entityID: value.entityID, workoutID: value.workoutID, author: actorID)
        refresh(); return save()
    }
    @discardableResult func receive(_ revisions: [Revision], workoutID: String) -> Bool {
        guard !readOnly else { return false }
        let filtered = revisions.filter { $0.workoutID == workoutID && ($0.value == nil || ($0.value?.workoutID == workoutID && $0.value?.entityID == $0.entityID)) }
        state.ledger.merge(filtered)
        refresh(); return save(notify: false)
    }
    func selectPerson(_ id: String) {
        let old = person.id
        if let workout = active { suggestedExerciseID = WorkoutEngine.defaultExercise(personID: id, previousPersonID: old, workoutID: workout.id, ledger: state.ledger) }
        state.activePersonID = id; save(notify: false)
    }
    func start(day: TrainingDay?, shared: Bool, demoPartner: Bool = false, preparing: Bool = false) {
        guard !readOnly else { return }
        guard active == nil || active?.finished != nil else { error = "Finish your current workout first."; return }
        if !person.isDemo { state.activePersonID = me.id }
        let workout = Workout(ownerID: person.id, title: day?.name ?? "Open workout", shared: shared, demo: person.isDemo, isPreparing: preparing)
        state.activeWorkoutID = workout.id
        write(.workout(workout))
        var member = Participant(workoutID: workout.id, profile: person, day: day, permitsPartnerLogging: shared)
        member.increments = state.increments[person.id] ?? [:]
        member.incrementUnits = state.incrementUnits?[person.id]
        write(.participant(member))
        if demoPartner, let partner = state.profiles.first(where: { $0.isDemo && $0.id != person.id }) {
            write(.participant(Participant(workoutID: workout.id, profile: partner, day: day, permitsPartnerLogging: true)))
            var own = participant!; own.permitsPartnerLogging = true; write(.participant(own))
        }
        if shared { publishBaselines(workout.id) }
        suggestedExerciseID = nil
    }
    func inviteToPreparedWorkout() {
        guard active?.isPreparing == true else { return }
        inviteToWorkout()
    }
    func inviteToWorkout() {
        guard !readOnly, var workout = active, workout.finished == nil, workout.ownerID == actorID else { return }
        workout.shared = true
        write(.workout(workout))
        if workout.demo, activeMembers.count < 2,
           let partner = state.profiles.first(where: { $0.isDemo && $0.id != workout.ownerID }) {
            write(.participant(Participant(workoutID: workout.id, profile: partner, day: participant?.day, permitsPartnerLogging: true)))
            if var own = participant {
                own.permitsPartnerLogging = true
                write(.participant(own))
            }
        }
        publishBaselines(workout.id)
    }
    func beginWorkout() {
        guard !readOnly, var workout = active, workout.isPreparing, canManageActiveWorkout else { return }
        workout.isPreparing = false; workout.started = Date(); write(.workout(workout))
    }
    func cancelPreparation() {
        guard !readOnly, var workout = active, workout.isPreparing else { return }
        if workout.shared { finish(); return }
        guard workout.ownerID == actorID else { return }
        // Keep the invitation's cancellation in the shared ledger; omit it from workout history.
        workout.finished = Date(); write(.workout(workout))
        state.activeWorkoutID = nil; save()
    }
    func join(_ workoutID: String) {
        guard let workout = workouts.first(where: { $0.id == workoutID }), workout.shared, workout.finished == nil else { return }
        if let active, active.finished == nil, active.id != workoutID { error = "Finish the current workout before joining another."; return }
        if members.contains(where: { $0.workoutID == workoutID && $0.profile.id == me.id && $0.finished != nil }) { error = "You’ve already finished this workout. Start a new workout instead."; return }
        let phoneOwners = Set(members.filter { $0.workoutID == workoutID && $0.finished == nil }.map { $0.managedByID ?? $0.profile.id })
        if !phoneOwners.contains(me.id) && phoneOwners.count >= 2 { error = "This workout already has two connected phones."; return }
        state.activeWorkoutID = workoutID; state.activePersonID = me.id
        if !members.contains(where: { $0.workoutID == workoutID && $0.profile.id == me.id }) {
            let day = members.first { $0.workoutID == workoutID && $0.profile.id == workout.ownerID }?.day
            var member = Participant(workoutID: workoutID, profile: me, day: day, permitsPartnerLogging: true)
            member.increments = state.increments[me.id] ?? [:]
            member.incrementUnits = state.incrementUnits?[me.id]
            write(.participant(member))
        }
        publishBaselines(workoutID); save()
    }
    func publishBaselines(_ workoutID: String) {
        // Explicit sharing includes the latest performance of each exercise, never the full private diary.
        for member in members where member.workoutID == workoutID && ownsProfile(member.profile.id) && !member.deleted {
            let personID = member.profile.id
            let exerciseIDs = Set(entries.filter { $0.personID == personID && $0.workoutID != workoutID }.map { $0.exercise.id })
            for exerciseID in exerciseIDs {
                guard let previous = WorkoutEngine.previous(personID: personID, exerciseID: exerciseID, excluding: workoutID, ledger: state.ledger) else { continue }
                let baseline = SharedBaseline(id: "\(workoutID):\(personID):\(exerciseID):baseline", workoutID: workoutID, personID: personID, previous: previous)
                state.ledger.write(.baseline(baseline), entityID: baseline.id, workoutID: workoutID, author: me.id)
            }
        }
        refresh(); save()
    }
    func selectExercise(_ exercise: Exercise, repeatExercise: Bool = false) {
        guard canLog, var member = participant, let workout = active else { return }
        let existing = repeatExercise ? nil : myEntries.last { $0.exercise.id == exercise.id }
        var entry = existing ?? ExerciseEntry(workoutID: workout.id, personID: person.id, exercise: exercise, target: member.day?.exercises.first { $0.contains(exercise.id) }?.target, order: (myEntries.map(\.order).max() ?? -1) + 1)
        if entry.startedAt == nil && entry.status == .active { entry.startedAt = Date(); write(.entry(entry)) }
        else if existing == nil { write(.entry(entry)) }
        member.currentEntryID = entry.id
        let selectedIDs = member.day?.exercises.first { $0.contains(exercise.id) }?.exerciseIDs ?? [exercise.id]
        member.skipped.removeAll { selectedIDs.contains($0) }
        write(.participant(member)); suggestedExerciseID = nil
    }
    func setDay(_ day: TrainingDay?) {
        guard canChooseDay, let workout = active else { return }
        let affected = workout.shared || canManageActiveWorkout ? activeMembers : [participant].compactMap { $0 }
        for var member in affected {
            member.day = day; member.skipped = []; write(.participant(member))
        }
        var updated = workout; updated.title = day?.name ?? "Open workout"; write(.workout(updated))
    }
    func skip(_ exerciseID: String) {
        guard canLog, var member = participant else { return }
        if member.skipped.contains(exerciseID) { member.skipped.removeAll { $0 == exerciseID } }
        else { member.skipped.append(exerciseID) }
        write(.participant(member))
    }
    func makeSet(_ entry: ExerciseEntry) -> WorkoutSet {
        let existing = sets(for: entry)
        let logged = existing.filter(\.completed)
        let previousSet = logged.last(where: { !$0.warmup }) ?? previous(entry.exercise.id, personID: entry.personID)?.sets.first { !$0.warmup }
        let used = Set(logged.filter { !$0.warmup }.compactMap(\.prescribedIndex))
        let slot = (0..<(entry.target?.sets ?? 0)).first { !used.contains($0) }
        return WorkoutSet(workoutID: entry.workoutID, entryID: entry.id, personID: entry.personID, enteredBy: actorID, modifiedBy: actorID, order: (existing.map(\.order).max() ?? -1) + 1, prescribedIndex: slot,
                          weight: previousSet?.weightPounds, unit: .lb, reps: previousSet?.reps ?? (entry.exercise.tracking == .timed || entry.exercise.tracking == .distance ? nil : entry.target?.low),
                          fractionalReps: previousSet?.fractionalReps, rir: nil, seconds: previousSet?.seconds ?? entry.target?.seconds, meters: previousSet?.meters ?? entry.target?.meters)
    }
    @discardableResult func saveSet(_ incoming: WorkoutSet, parents: [String]? = nil) -> Bool {
        if let parents, Set(parents) != Set(state.ledger.heads(incoming.id).map(\.id)) {
            error = "This set changed on the other phone. Reopen it before saving."; return false
        }
        guard canSaveSet(incoming),
              let entry = entries.first(where: { $0.id == incoming.entryID }),
              incoming.isComplete(for: entry.exercise.tracking) else { return false }
        guard state.ledger.heads(incoming.id).count <= 1 else { error = "Review this set’s conflicting edits before saving."; return false }
        let originalState = state
        var set = incoming
        if let original = sets.first(where: { $0.id == incoming.id && $0.completed }) {
            set.loggedAt = original.loggedAt
            set.intervalSincePreviousSet = original.intervalSincePreviousSet
        } else {
            // Drafts may have been opened before the other phone added a set.
            let others = sets(for: entry).filter { $0.id != incoming.id }
            set.order = (others.map(\.order).max() ?? -1) + 1
            let used = Set(others.filter { $0.completed && !$0.warmup }.compactMap(\.prescribedIndex))
            set.prescribedIndex = set.warmup ? nil : (0..<(entry.target?.sets ?? 0)).first { !used.contains($0) }
            let now = Date()
            let previous = sets.filter { $0.workoutID == set.workoutID && $0.personID == set.personID && $0.completed }
                .compactMap(\.loggedAt).max()
            set.loggedAt = canEditHistory(entry) ? nil : now
            set.intervalSincePreviousSet = canEditHistory(entry) ? nil : previous.map { max(0, now.timeIntervalSince($0)) }
        }
        set.completed = true; set.modifiedBy = actorID
        if set.warmup { set.prescribedIndex = nil }
        let revision = Revision(entityID: set.id, workoutID: set.workoutID, parents: parents ?? state.ledger.heads(set.id).map(\.id), authorID: actorID, value: .set(set))
        state.ledger.merge([revision]); refresh()
        guard save() else { state = originalState; refresh(); return false }
        return true
    }
    @discardableResult func cancelExercise(_ entry: ExerciseEntry) -> Bool {
        guard canLog, entry.personID == person.id, entry.workoutID == active?.id,
              entry.status == .active, sets(for: entry).isEmpty,
              state.ledger.heads(entry.id).count == 1,
              var member = participant, state.ledger.heads(member.id).count == 1 else { return false }
        state.ledger.write(nil, entityID: entry.id, workoutID: entry.workoutID, author: actorID)
        if member.currentEntryID == entry.id { member.currentEntryID = nil }
        write(.participant(member))
        return true
    }
    @discardableResult func finishExercise(_ entry: ExerciseEntry) -> Bool {
        guard canLog, entry.personID == person.id, entry.workoutID == active?.id,
              !sets(for: entry).filter(\.completed).isEmpty,
              state.ledger.heads(entry.id).count == 1,
              var member = participant, state.ledger.heads(member.id).count == 1 else { return false }
        var updated = entry; updated.status = .completed; updated.finishedAt = Date()
        write(.entry(updated))
        member.currentEntryID = nil; write(.participant(member))
        return true
    }
    func canEditHistory(_ entry: ExerciseEntry) -> Bool {
        !readOnly && ownsProfile(entry.personID) && entries.contains(where: { $0 == entry }) &&
        members.contains { $0.workoutID == entry.workoutID && $0.profile.id == entry.personID && !$0.deleted && $0.finished != nil } &&
        !conflicts.contains { $0.first?.workoutID == entry.workoutID }
    }

    func canSaveSet(_ set: WorkoutSet) -> Bool {
        guard let entry = entries.first(where: { $0.id == set.entryID && $0.workoutID == set.workoutID && $0.personID == set.personID }) else { return false }
        let heads = state.ledger.heads(set.id)
        guard !heads.contains(where: { $0.value == nil }) else { return false }
        if let stored = sets.first(where: { $0.id == set.id }),
           stored.entryID != set.entryID || stored.workoutID != set.workoutID || stored.personID != set.personID { return false }
        return (canLog && set.personID == person.id && set.workoutID == active?.id) || canEditHistory(entry)
    }

    @discardableResult func replaceHistoryExercise(_ entry: ExerciseEntry, with exercise: Exercise) -> Bool {
        guard canEditHistory(entry), sets(for: entry).isEmpty || exercise.tracking == entry.exercise.tracking else { return false }
        var updated = entry
        updated.exercise = exercise
        return write(.entry(updated), parents: state.ledger.heads(entry.id).map(\.id))
    }

    @discardableResult func deleteHistoryExercise(_ entry: ExerciseEntry) -> Bool {
        guard canEditHistory(entry) else { return false }
        let original = state
        for set in sets(for: entry) {
            state.ledger.write(nil, entityID: set.id, workoutID: entry.workoutID, author: actorID)
        }
        state.ledger.write(nil, entityID: entry.id, workoutID: entry.workoutID, author: actorID)
        guard save(notify: false) else { state = original; refresh(); return false }
        refresh(); didChange?()
        return true
    }

    func canDeleteWorkout(_ workout: Workout, personID: String) -> Bool {
        !readOnly && ownsProfile(personID) && members.contains {
            $0.workoutID == workout.id && $0.profile.id == personID && !$0.deleted
        }
    }

    @discardableResult func deleteWorkout(_ workout: Workout, personID: String) -> Bool {
        guard let stored = workouts.first(where: { $0.id == workout.id }),
              canDeleteWorkout(stored, personID: personID) else { return false }
        guard !conflicts.contains(where: { $0.first?.workoutID == stored.id }) else {
            error = "Resolve workout conflicts before deleting."
            return false
        }
        let original = state
        let hasOthers = members.contains { $0.workoutID == stored.id && $0.profile.id != personID && !$0.deleted }
        let preserveWorkout = stored.shared || hasOthers
        let values = state.ledger.values.filter { $0.workoutID == stored.id }
        for value in values {
            let remove: Bool
            switch value {
            case .workout: remove = !preserveWorkout
            case .participant(var member):
                if preserveWorkout && member.profile.id == personID {
                    member.deleted = true; member.finished = member.finished ?? Date()
                    member.currentEntryID = nil; member.permitsPartnerLogging = false
                    state.ledger.write(.participant(member), entityID: member.id, workoutID: stored.id, author: actorID)
                }
                remove = !preserveWorkout
            case .entry(let entry): remove = !preserveWorkout || entry.personID == personID
            case .set(let set): remove = !preserveWorkout || set.personID == personID
            case .baseline(let baseline): remove = !preserveWorkout || baseline.personID == personID
            }
            if remove { state.ledger.write(nil, entityID: value.entityID, workoutID: stored.id, author: actorID) }
        }
        if state.activeWorkoutID == stored.id && personID == actorID {
            // Keep locally logged companions' results when the phone owner leaves.
            for var member in members where member.workoutID == stored.id && member.profile.id != actorID && ownsProfile(member.profile.id) && member.finished == nil {
                member.finished = Date(); member.currentEntryID = nil
                state.ledger.write(.participant(member), entityID: member.id, workoutID: stored.id, author: actorID)
            }
            state.activeWorkoutID = nil; state.activePersonID = me.id
        } else if state.activeWorkoutID == stored.id && state.activePersonID == personID {
            state.activePersonID = me.id
        }
        guard save(notify: false) else { state = original; refresh(); return false }
        if undoRevision?.workoutID == stored.id { undoRevision = nil }
        refresh(); didChange?()
        return true
    }

    func deleteSet(_ set: WorkoutSet) {
        guard canSaveSet(set), state.ledger.heads(set.id).count == 1 else { return }
        undoRevision = state.ledger.heads(set.id).first
        state.ledger.write(nil, entityID: set.id, workoutID: set.workoutID, author: actorID)
        refresh(); save()
    }
    func undoDelete() {
        guard let revision = undoRevision, let value = revision.value else { return }
        if write(value) { undoRevision = nil }
    }
    func finish() {
        guard !readOnly, var workout = active else { return }
        guard conflicts.filter({ $0.first?.workoutID == workout.id }).isEmpty else { error = "Resolve workout conflicts before finishing."; return }
        let finishingID = actorID
        guard let own = members.first(where: { $0.workoutID == workout.id && $0.profile.id == finishingID }), own.finished == nil else { return }
        let original = state
        let date = Date()
        for var member in members where member.workoutID == workout.id && ownsProfile(member.profile.id) && member.finished == nil {
            member.finished = date; member.currentEntryID = nil; member.permitsPartnerLogging = false
            state.ledger.write(.participant(member), entityID: member.id, workoutID: workout.id, author: finishingID)
        }
        if !workout.shared {
            workout.finished = date
            state.ledger.write(.workout(workout), entityID: workout.id, workoutID: workout.id, author: finishingID)
        }
        state.activeWorkoutID = nil; state.activePersonID = me.id
        guard save(notify: false) else { state = original; refresh(); return }
        refresh(); didChange?()
    }
    func resolve(_ revision: Revision) {
        guard canResolve(revision) else { error = "Reconnect Nearby before resolving your friend’s edits."; return }
        state.ledger.write(revision.value, entityID: revision.entityID, workoutID: revision.workoutID, author: actorID)
        refresh(); save()
    }
    #if SWIFT_PACKAGE
    func addDemo() {
        guard !state.profiles.contains(where: \.isDemo) else { return }
        let people = [Profile(name: "Alex", isDemo: true), Profile(name: "Jamie", isDemo: true)]
        state.profiles += people
        state.ledger.merge(SampleData.history(profiles: people, exercises: library).revisions)
        state.activePersonID = people[0].id; refresh(); save()
    }
    #endif
    func rename(_ exercise: Exercise, to name: String, increment: Double?) {
        let personID = person.id
        state.names[personID, default: [:]][exercise.id] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        state.increments[personID, default: [:]][exercise.id] = increment ?? 0
        if state.incrementUnits == nil { state.incrementUnits = [:] }
        var units = state.incrementUnits?[personID] ?? [:]; units[exercise.id] = .lb
        state.incrementUnits?[personID] = units
        if var member = participant, ownsProfile(person.id) {
            member.increments = state.increments[person.id] ?? [:]
            member.incrementUnits = state.incrementUnits?[person.id]; write(.participant(member))
        }
        save(notify: false)
    }
    func addExercise(_ exercise: Exercise) {
        library.append(exercise); state.customExercises.append(exercise); save(notify: false)
    }
}
