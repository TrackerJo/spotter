import SwiftUI

struct WorkoutView: View {
    @Environment(Store.self) private var store
    @Environment(NearbySync.self) private var nearby
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDay = ""
    @State private var dayInitialized = false
    @State private var chooser = false
    @State private var connections = false
    @State private var connectionSymbols = false
    @State private var finishConfirm = false
    @State private var deleteConfirm = false
    @State private var changeDay = false
    @State private var addingProfiles = false
    @State private var selectedRecentWorkout: Workout?
    @State private var exerciseIDs: [String: String] = [:]

    private var selectedEntry: ExerciseEntry? {
        store.myEntries.first { $0.id == exerciseIDs[store.person.id] }
    }
    private var preparing: Bool { store.active?.isPreparing == true }
    private var friendStillTraining: Bool {
        store.active?.shared == true && store.activeMembers.contains { !store.ownsProfile($0.profile.id) }
    }
    private var hasSession: Bool { store.active != nil && store.active?.finished == nil }
    private var chosenDay: TrainingDay? {
        hasSession ? store.participant?.day : store.days.first { $0.id == selectedDay }
    }
    private var history: [Workout] {
        store.workouts.map { store.personalWorkout($0, personID: store.dataProfile.id) }.filter { workout in
            !workout.isPreparing && workout.finished != nil && store.members.contains { $0.workoutID == workout.id && $0.profile.id == store.dataProfile.id && !$0.deleted }
        }
    }

    var body: some View {
        Group {
            if hasSession && !preparing { sessionScreen }
            else if preparing { preparationScreen }
            else { startScreen }
        }
        .navigationTitle(hasSession && !preparing ? (store.participant?.day?.name ?? "Workout") : (preparing ? "Ready to start" : "Workout"))
        .navigationBarTitleDisplayMode(hasSession ? .inline : .large)
        .navigationDestination(isPresented: Binding(
            get: { selectedRecentWorkout != nil },
            set: { if !$0 { selectedRecentWorkout = nil } }
        )) {
            if let workout = selectedRecentWorkout {
                WorkoutHistoryView(workout: workout, personID: store.dataProfile.id)
            }
        }
        .toolbar {
            if hasSession, store.active?.shared == true, store.active?.demo != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.selection()
                        connectionSymbols = true
                        connections = true
                    } label: {
                        Image(systemName: nearby.connected ? "wifi" : "wifi.slash")
                            .foregroundStyle(nearby.connected ? Color.accentColor : Color.secondary)
                    }
                    .accessibilityLabel(nearby.connected ? "Nearby connected" : "Nearby disconnected")
                    .accessibilityHint("Explains the connection symbols")
                }
            }
            if preparing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { AppHaptics.selection(); store.cancelPreparation() }
                }
            }
        }
        .sheet(isPresented: $chooser) {
            NavigationStack { ExerciseChooser { exercise in
                store.selectExercise(exercise)
                chooser = false
                exerciseIDs[store.person.id] = store.current?.id
            } }
        }
        .sheet(isPresented: $connections, onDismiss: { nearby.endInviting() }) { NavigationStack { ConnectionView(showingStatus: connectionSymbols) } }
        .sheet(isPresented: $addingProfiles) { NavigationStack { ProfilesView(addingToWorkout: true) } }
        .sheet(isPresented: $changeDay) {
            NavigationStack {
                TrainingDayChooser(selectedID: chosenDay?.id) { day in
                    if hasSession { store.setDay(day) }
                    else { selectedDay = day?.id ?? "" }
                    changeDay = false
                }
            }.presentationDetents([.medium, .large])
        }
        .confirmationDialog("Delete your session?", isPresented: $deleteConfirm, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                if let workout = store.active { AppHaptics.selection(); store.deleteWorkout(workout, personID: store.actorID) }
            }
        } message: {
            Text("Your exercises and sets will be removed. Other profiles’ results will be kept. This cannot be undone.")
        }
        .onAppear {
            if !dayInitialized {
                selectedDay = (store.today ?? store.days.first)?.id ?? ""
                restoreExerciseSelection()
                dayInitialized = true
            }
        }
        .onChange(of: store.person.id) { chooser = false }
        .onChange(of: store.active?.finished) { if store.active?.finished != nil { exerciseIDs = [:] } }
        .onChange(of: store.state.activeWorkoutID) { restoreExerciseSelection() }
    }

    private var startScreen: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start a workout?").font(.title2.bold())
                    Text("Pick your day and you’re ready to go.")
                        .font(.subheadline).foregroundStyle(Color.secondary)
                }.padding(.vertical, 6)
                Button { AppHaptics.selection(); changeDay = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar").foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chosenDay?.name ?? "Open workout").font(.headline).foregroundStyle(Color.primary)
                            Text(daySubtitle).font(.caption).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        Text("Change").font(.subheadline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }.frame(minHeight: 44)
                }.disabled(hasSession && !store.canChooseDay)
            }
            Section {
                Button { AppHaptics.selection();
                    store.start(day: chosenDay, shared: false, preparing: true)
                } label: { Label("Start workout", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).disabled(!canStart)
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if !preparing {
                Section {
                    Button { AppHaptics.selection(); openConnection(host: false) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill")
                                .font(.body).foregroundStyle(Color.indigo)
                                .frame(width: 28)
                            Text("Join a friend").font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(uiColor: .secondarySystemGroupedBackground))
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    .accessibilityLabel("Join a friend’s workout")
                    .accessibilityHint("Enter their four-digit code.")
                }
                if store.dataProfiles.count > 1 || !history.isEmpty {
                    Section("Recent workouts") {
                        if store.dataProfiles.count > 1 { DataProfilePicker(title: "History for") }
                        ForEach(history.prefix(5)) { workout in
                            Button {
                                AppHaptics.selection()
                                selectedRecentWorkout = workout
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(workout.title).font(.body.weight(.medium))
                                        if let finished = workout.finished {
                                            Text(sessionDuration(finished.timeIntervalSince(workout.started)) + " total")
                                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(workout.started, format: .dateTime.month(.abbreviated).day()).font(.subheadline).foregroundStyle(Color.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                }.frame(minHeight: 32)
                            }.tint(.primary)
                            .modifier(WorkoutDeleteAction(workout: workout, personID: store.dataProfile.id))
                        }
                        if history.isEmpty { Text("No past workouts for \(store.dataProfile.name).").foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    private var preparationScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                partnerReadOnlyNotice
                VStack(alignment: .leading, spacing: 10) {
                    Text(chosenDay?.name ?? "Open workout")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(daySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Change day", systemImage: "calendar") {
                        AppHaptics.selection()
                        changeDay = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .disabled(!store.canChooseDay)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Who’s joining?")
                        .font(.title3.bold())
                        .padding(.bottom, 12)
                    VStack(spacing: 0) {
                        ForEach(store.activeMembers) { member in
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.profile.name)
                                        .font(.body.weight(.semibold))
                                    Text(member.profile.isDemo ? "Sample participant" : (member.profile.id == store.me.id ? "You" : (store.ownsProfile(member.profile.id) ? "Logging on this phone" : "Joined")))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                        }
                        if store.canAddProfiles {
                            Divider().padding(.horizontal, 16)
                            Button {
                                AppHaptics.selection()
                                addingProfiles = true
                            } label: {
                                Label("Add profiles", systemImage: "person.crop.circle.badge.plus")
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 4)
                            }
                        }
                        if store.canManageActiveWorkout && !store.activeMembers.contains(where: { !store.ownsProfile($0.profile.id) }) {
                            Divider().padding(.horizontal, 16)
                            Button {
                                AppHaptics.selection()
                                store.inviteToPreparedWorkout()
                                if !store.person.isDemo { openConnection(host: true) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.badge.plus")
                                        .font(.title3)
                                        .frame(width: 28)
                                    Text("Invite a friend").font(.body.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                                .padding(16)
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .disabled(!canStart)
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    if store.activeMembers.count > 1 {
                        Text("Switch between people to log their own exercises, sets, and time between sets.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if store.canManageActiveWorkout {
                    Button {
                        AppHaptics.selection()
                        store.beginWorkout()
                    } label: {
                        Text("Start workout")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                } else {
                    Label("Waiting for your friend to start", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var daySubtitle: String {
        guard let day = chosenDay else { return "Choose any exercise as you go" }
        let prefix = !hasSession && day.id == store.today?.id ? "Suggested today · " : ""
        return prefix + "\(day.exercises.count) exercises"
    }
    private var canStart: Bool { !store.readOnly && (!hasSession || store.canManageActiveWorkout) }

    @ViewBuilder private var partnerReadOnlyNotice: some View {
        if store.partnerEditingUnavailable != nil {
            Label("Your friend’s session is read-only while disconnected.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    private var sessionScreen: some View {
        VStack(spacing: 0) {
            partnerReadOnlyNotice
            if store.activeMembers.count > 1 {
                Group {
                    if store.activeMembers.count <= 3 && !dynamicTypeSize.isAccessibilitySize {
                        participantPicker.pickerStyle(.segmented)
                    } else {
                        participantPicker.pickerStyle(.menu)
                    }
                }.padding(.horizontal).padding(.top, 8).padding(.bottom, 10)
            }
            if let entry = selectedEntry {
                SessionExerciseView(entryID: entry.id) {
                    exerciseIDs[store.person.id] = nil
                }.id(entry.id)
            } else {
                overview
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectedEntry != nil {
                    Button("Session", systemImage: "list.bullet") { AppHaptics.selection(); exerciseIDs[store.person.id] = nil }
                        .accessibilityLabel("Session overview")
                } else {
                    Menu {
                        Button("Change day", systemImage: "calendar") { AppHaptics.selection(); changeDay = true }.disabled(!store.canChooseDay)
                        Button("Add profiles", systemImage: "person.badge.plus") { AppHaptics.selection(); addingProfiles = true }.disabled(!store.canAddProfiles)
                        Button("Invite friends", systemImage: "person.2") { AppHaptics.selection(); openConnection(host: true) }
                        Button("Delete session", systemImage: "trash", role: .destructive) { AppHaptics.selection(); deleteConfirm = true }.disabled(store.active.map { !store.canDeleteWorkout($0, personID: store.actorID) } ?? true)
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Workout options")
                }
            }
        }
    }

    private var participantPicker: some View {
        Picker("Logging for", selection: Binding(get: { store.person.id }, set: store.selectPerson).hapticSelection()) {
            ForEach(store.activeMembers) { Text($0.profile.name).tag($0.profile.id) }
        }
    }

    private var overview: some View {
        List {
            Section {
                BetweenSetsTimerRow()
                HStack {
                    let count = store.myEntries.filter { $0.status == .completed }.count
                    Text("\(count) \(count == 1 ? "exercise" : "exercises")")
                    Spacer()
                    let setCount = store.myEntries.flatMap { store.sets(for: $0) }.filter(\.completed).count
                    Text("\(setCount) \(setCount == 1 ? "set" : "sets") logged")
                }.font(.subheadline).foregroundStyle(Color.secondary)
            }
            let inProgress = store.myEntries.filter { entry in
                entry.status == .active && (entry.id == store.current?.id || store.sets(for: entry).contains(where: \.completed))
            }
            if !inProgress.isEmpty {
                Section("In progress") {
                    ForEach(inProgress) { entry in
                        Button { AppHaptics.selection(); store.selectExercise(entry.exercise); exerciseIDs[store.person.id] = entry.id } label: { entryRow(entry, resume: true) }.tint(.primary)
                    }
                }
            }
            let finished = store.myEntries.filter { $0.status == .completed }
            if !finished.isEmpty {
                Section("Finished exercises") {
                    ForEach(finished) { entry in
                        Button { AppHaptics.selection(); store.selectExercise(entry.exercise); exerciseIDs[store.person.id] = entry.id } label: { entryRow(entry) }.tint(.primary)
                    }
                }
            }
            if store.undoRevision != nil { Section { Button("Undo deleted set", systemImage: "arrow.uturn.backward") { AppHaptics.selection(); store.undoDelete() }.disabled(!store.canLog) } }
            if store.conflicts.contains(where: { $0.first?.workoutID == store.active?.id }) {
                Section { NavigationLink("Review conflicting edits") { ConflictView() }.buttonStyle(HapticNavigationButtonStyle()) }
            }
        }.listSectionSpacing(.compact)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button("Finish") { AppHaptics.selection(); finishConfirm = true }.font(.body.weight(.semibold)).frame(minWidth: 66, minHeight: 48)
                    .disabled(store.readOnly)
                    .confirmationDialog(friendStillTraining ? "Finish your session?" : "Finish workout?", isPresented: $finishConfirm, titleVisibility: .visible) {
                        Button(friendStillTraining ? "Finish my session" : "Finish workout") {
                            store.finish()
                            if store.state.activeWorkoutID == nil && store.error == nil { AppHaptics.notification(.success) }
                        }
                    } message: { Text(friendStillTraining ? "Results for you and profiles logged on this phone will be saved. Your friend can keep training." : "All logged sets will be saved to each person’s history.") }
                Button { AppHaptics.selection(); chooser = true } label: { Label("Add exercise", systemImage: "plus").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(!store.canLog)
            }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
    }

    private func entryRow(_ entry: ExerciseEntry, resume: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: resume ? "play.circle" : "checkmark.circle.fill").foregroundStyle(resume ? Color.indigo : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.name(entry.exercise)).font(.body.weight(.medium))
                let count = store.sets(for: entry).filter(\.completed).count
                Text("\(count) \(count == 1 ? "set" : "sets") logged").font(.caption).foregroundStyle(Color.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.frame(minHeight: 42)
    }
    private func restoreExerciseSelection() {
        exerciseIDs = Dictionary(uniqueKeysWithValues: store.activeMembers.compactMap { member in
            guard let entry = store.entries.first(where: { $0.id == member.currentEntryID && $0.status == .active }) else { return nil }
            return (member.profile.id, entry.id)
        })
    }
    private func openConnection(host: Bool) {
        if host && store.active?.shared != true { store.inviteToWorkout() }
        connectionSymbols = false
        connections = true
    }
}

struct TrainingDayChooser: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let selectedID: String?
    let onSelect: (TrainingDay?) -> Void
    var body: some View {
        List {
            ForEach(store.state.plans) { plan in
                Section(plan.name) {
                    ForEach(plan.days) { day in
                        Button { AppHaptics.selection(); onSelect(day) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(day.name).foregroundStyle(Color.primary)
                                    Text("\(day.exercises.count) exercises").font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                if day.id == selectedID { Image(systemName: "checkmark") }
                            }.frame(minHeight: 36)
                        }
                    }
                }
            }
            Section { Button { AppHaptics.selection(); onSelect(nil) } label: { HStack { Text("Open workout"); Spacer(); if selectedID == nil { Image(systemName: "checkmark") } } } }
        }.navigationTitle("Choose day").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { AppHaptics.selection(); dismiss() } } }
    }
}

struct BetweenSetsTimerRow: View {
    @Environment(Store.self) private var store
    var entry: ExerciseEntry? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lastSet = store.sets.filter {
                $0.workoutID == store.active?.id && $0.personID == store.person.id && $0.completed
            }.compactMap(\.loggedAt).max()
            HStack(spacing: 12) {
                Text(lastSet == nil ? "Workout time" : "Time between sets").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text((lastSet ?? store.active?.started).map { sessionDuration(max(0, context.date.timeIntervalSince($0))) } ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }
}

struct SessionExerciseView: View {
    @Environment(Store.self) private var store
    let entryID: String
    let onFinish: () -> Void
    @State private var editingSet: WorkoutSet?
    @State private var targets = false
    @State private var showingPrevious = false
    private var entry: ExerciseEntry? { store.myEntries.first { $0.id == entryID } }
    var body: some View {
        Group {
            if let entry {
                let logged = store.sets(for: entry).filter(\.completed)
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.name(entry.exercise)).font(.title2.bold())
                            Text("\(entry.exercise.equipment) · \(entry.exercise.primary)").font(.subheadline).foregroundStyle(Color.secondary)
                            Text(entry.target?.summary(for: entry.exercise.tracking) ?? guidance(entry.exercise.tracking)).font(.subheadline.weight(.medium))
                            if let notes = entry.target?.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(Color.secondary) }
                        }.padding(.vertical, 4)
                    }
                    Section("Last time") {
                        if let previous = store.previous(entry.exercise.id), let last = previous.sets.last(where: { !$0.warmup }) ?? previous.sets.last {
                            Button { AppHaptics.selection(); showingPrevious = true } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(SetSummary.performance(last, tracking: entry.exercise.tracking)).font(.body.monospacedDigit().weight(.semibold))
                                        HStack {
                                            Text("\(previous.sets.filter { !$0.warmup }.count) working sets")
                                            Spacer()
                                            Text(previous.workout.started, format: .dateTime.month(.abbreviated).day())
                                        }.font(.caption).foregroundStyle(Color.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.secondary)
                                }.frame(minHeight: 44)
                            }.tint(.primary).accessibilityHint("View previous sets and notes from all past workouts")
                            if let next = store.progression(entry.exercise)?.nextWeightPounds {
                                Text("Suggested today: \(next.formatted(.number.precision(.fractionLength(0...2)))) lb").font(.subheadline).foregroundStyle(.tint)
                            }
                        } else { Text("No previous sets recorded.").font(.subheadline).foregroundStyle(Color.secondary) }
                    }
                    Section {
                        BetweenSetsTimerRow(entry: entry)
                        Button { AppHaptics.selection(); editingSet = store.makeSet(entry) } label: {
                            Label {
                                Text("Log set").foregroundStyle(.white)
                            } icon: {
                                Image(systemName: "plus").foregroundStyle(.white)
                            }
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(!store.canLog)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                    Section("Logged sets") {
                        if logged.isEmpty { Text("No sets yet").font(.subheadline).foregroundStyle(Color.secondary) }
                        ForEach(logged) { set in
                            Button { AppHaptics.selection(); editingSet = set } label: { SetSummary(set: set, tracking: entry.exercise.tracking) }.tint(.primary).disabled(!store.canLog)
                                .swipeActions { Button("Delete", role: .destructive) { AppHaptics.selection(); store.deleteSet(set) }.disabled(!store.canLog) }
                        }
                    }
                    Section {
                        Button {
                            if logged.isEmpty {
                                if store.cancelExercise(entry) { AppHaptics.selection(); onFinish() }
                            } else if store.finishExercise(entry) {
                                AppHaptics.notification(.success); onFinish()
                            }
                        } label: {
                            Text(logged.isEmpty ? "Cancel exercise" : "Finish exercise")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(!store.canLog)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    if store.undoRevision != nil { Section { Button("Undo deleted set", systemImage: "arrow.uturn.backward") { AppHaptics.selection(); store.undoDelete() }.disabled(!store.canLog) } }
                }.listSectionSpacing(.compact)
            } else { ContentUnavailableView("Choose an exercise", systemImage: "dumbbell") }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { AppHaptics.selection(); targets = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Exercise targets").disabled(!store.canLog) } }
        .sheet(item: $editingSet) { set in NavigationStack { SetEditor(store: store, initial: set) }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $targets) { if let entry { NavigationStack { EntryTargetsView(entry: entry, parents: store.state.ledger.heads(entry.id).map(\.id)) } } }
        .sheet(isPresented: $showingPrevious) {
            if let entry, let previous = store.previous(entry.exercise.id) {
                NavigationStack {
                    List {
                        Section {
                            Text(store.name(entry.exercise)).font(.headline)
                            Text(previous.workout.started, format: .dateTime.month().day().year()).foregroundStyle(.secondary)
                        }
                        Section("Sets") {
                            ForEach(previous.sets) { set in
                                VStack(alignment: .leading, spacing: 3) {
                                    SetSummary(set: set, tracking: entry.exercise.tracking)
                                    if set.recordedRIRSummary == nil {
                                        Text("RIR not recorded").font(.caption).foregroundStyle(.secondary).padding(.leading, 36)
                                    }
                                }
                            }
                        }
                        Section("Notes from past workouts") {
                            let history = store.exerciseHistory(entry.exercise.id).filter { performance in
                                !(performance.entry.target?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                                performance.sets.contains { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            }
                            if history.isEmpty {
                                Text("No notes recorded.").foregroundStyle(.secondary)
                            }
                            ForEach(history, id: \.entry.id) { performance in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(performance.workout.started, format: .dateTime.month().day().year())
                                        .font(.subheadline.weight(.semibold))
                                    if let notes = performance.entry.target?.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(notes).font(.subheadline)
                                    }
                                    ForEach(performance.sets.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { set in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(set.warmup ? "Warm-up set \(set.order + 1)" : "Set \(set.order + 1)")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(set.notes).font(.subheadline)
                                        }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    .navigationTitle("Last time")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { AppHaptics.selection(); showingPrevious = false } } }
                }.presentationDragIndicator(.visible)
            }
        }
    }
    private func guidance(_ tracking: Tracking) -> String {
        switch tracking {
        case .weightReps, .bodyweight: return "Choose your own sets and reps"
        case .assisted: return "Choose your assistance and reps"
        case .timed: return "Choose your sets and time"
        case .distance: return "Choose your distance and time"
        }
    }
}

struct SetSummary: View {
    let set: WorkoutSet
    let tracking: Tracking
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(set.warmup ? "W" : String(set.order + 1)).font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondary).frame(minWidth: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.performance(set, tracking: tracking)).font(.body.monospacedDigit())
                if set.warmup || set.recordedRIRSummary != nil || !set.notes.isEmpty {
                    Text(([set.warmup ? "Warm-up" : nil, set.recordedRIRSummary.map { "\($0) RIR" }, set.notes.isEmpty ? nil : set.notes].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 4)
        }.frame(minHeight: 36).accessibilityElement(children: .combine)
    }
    static func performance(_ set: WorkoutSet, tracking: Tracking) -> String {
        if set.bodyweightOnly == true { return "\(set.repsSummary) reps · bodyweight" }
        switch tracking {
        case .weightReps, .assisted: return "\(set.weightPounds?.formatted(.number.precision(.fractionLength(0...2))) ?? "—") lb\(tracking == .assisted ? " assistance" : "") × \(set.repsSummary)"
        case .bodyweight: return "\(set.repsSummary) reps · bodyweight"
        case .timed: return "\(set.seconds?.formatted() ?? "—") seconds"
        case .distance: return "\(set.meters.map { USDistanceUnit.summary(meters: $0) } ?? "—") · \(set.seconds?.formatted() ?? "—") sec"
        }
    }
}
struct WorkoutHistoryView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var deleteConfirm = false
    @State private var editingSet: WorkoutSet?
    @State private var replacingEntry: ExerciseEntry?
    @State private var deletingEntry: ExerciseEntry?
    let workout: Workout
    let personID: String

    private var entries: [ExerciseEntry] {
        store.entries.filter { $0.workoutID == workout.id && $0.personID == personID }
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(workout.started, format: .dateTime.month(.abbreviated).day().year())
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        if let finished = store.personalWorkout(workout, personID: personID).finished {
                            Text(sessionDuration(finished.timeIntervalSince(workout.started)) + " total")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                    }.foregroundStyle(Color.primary)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(profileName(personID)).font(.subheadline)
                        Spacer(minLength: 4)
                        let setCount = entries.reduce(0) { $0 + store.sets(for: $1).filter(\.completed).count }
                        Text("\(entries.count) \(entries.count == 1 ? "exercise" : "exercises") · \(setCount) \(setCount == 1 ? "set" : "sets")")
                            .font(.caption)
                    }.foregroundStyle(Color.secondary)
                    LabeledContent("Training volume") {
                        Text(ProgressEngine.volumePounds(entries: entries, sets: store.sets)
                            .formatted(.number.precision(.fractionLength(0...1))) + " lb·reps")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Weight times reps across working sets. Excludes warm-ups, assisted and bodyweight sets.")
                }
                .fixedSize(horizontal: false, vertical: true)
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            }

            if entries.isEmpty {
                Section {
                    ContentUnavailableView("No exercises recorded", systemImage: "dumbbell",
                                           description: Text("This workout has no exercise history for this participant."))
                }
            }

            ForEach(entries) { entry in
                let sets = store.sets(for: entry).filter(\.completed)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(store.name(entry.exercise, personID: personID))
                                .font(.title3.weight(.bold)).foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 0)
                            if let started = entry.startedAt, let end = entry.finishedAt ?? store.personalWorkout(workout, personID: personID).finished {
                                Text(sessionDuration(end.timeIntervalSince(started)))
                                    .font(.subheadline.monospacedDigit().weight(.medium))
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize()
                                    .accessibilityLabel("Exercise time " + sessionDuration(end.timeIntervalSince(started)))
                            }
                        }
                        if let target = entry.target {
                            Text("Goal: " + target.summary(for: entry.exercise.tracking))
                                .font(.subheadline).foregroundStyle(Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    if store.canEditHistory(entry) {
                        Menu("Edit exercise", systemImage: "pencil") {
                            Button("Change exercise", systemImage: "arrow.triangle.2.circlepath") { replacingEntry = entry }
                            Button("Add set", systemImage: "plus") { editingSet = store.makeSet(entry) }
                            Button("Delete exercise", systemImage: "trash", role: .destructive) { deletingEntry = entry }
                        }
                    }
                    if sets.isEmpty {
                        Text(entry.status == .skipped ? "Exercise skipped" : "No sets logged")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(sets) { set in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                SetSummary(set: set, tracking: entry.exercise.tracking)
                                if store.canEditHistory(entry) {
                                    Button("Edit set", systemImage: "pencil") { editingSet = set }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                            }
                            if let interval = set.timeBetweenSets {
                                Text("Time between sets: " + sessionDuration(interval) + " · assumes 30-second sets")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else if set.loggedAt == nil {
                                Text("Set timing not recorded").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if store.canEditHistory(entry) { AppHaptics.selection(); editingSet = set }
                        }
                        .accessibilityAction(named: "Edit set") { if store.canEditHistory(entry) { editingSet = set } }
                        .swipeActions {
                            if store.canEditHistory(entry) {
                                Button("Delete set", role: .destructive) { store.deleteSet(set) }
                                Button("Edit set") { editingSet = set }.tint(.accentColor)
                            }
                        }
                    }

                }
            }
        }
        .sheet(item: $editingSet) { set in
            NavigationStack { SetEditor(store: store, initial: set) }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(item: $replacingEntry) { entry in
            NavigationStack {
                ExerciseChooser(onSelect: { exercise in
                    if store.replaceHistoryExercise(entry, with: exercise) { replacingEntry = nil }
                }, libraryOnly: true, requiredTracking: store.sets(for: entry).isEmpty ? nil : entry.exercise.tracking,
                   excludedExerciseID: entry.exercise.id)
            }
        }
        .confirmationDialog("Delete exercise?", isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }
        ), titleVisibility: .visible) {
            Button("Delete exercise", role: .destructive) {
                if let entry = deletingEntry { _ = store.deleteHistoryExercise(entry) }
                deletingEntry = nil
            }
        } message: { Text("This exercise and all its sets will be removed from history and progress. This cannot be undone.") }
        .listSectionSpacing(24)
        .navigationTitle(workout.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if store.canDeleteWorkout(workout, personID: personID) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete workout", systemImage: "trash", role: .destructive) { AppHaptics.selection(); deleteConfirm = true }
                }
            }
        }
        .confirmationDialog("Delete workout?", isPresented: $deleteConfirm, titleVisibility: .visible) {
            Button("Delete workout", role: .destructive) {
                AppHaptics.selection()
                if store.deleteWorkout(workout, personID: personID) { dismiss() }
            }
        } message: { Text(workoutDeletionMessage(workout)) }
    }

    private func profileName(_ id: String) -> String {
        store.state.profiles.first { $0.id == id }?.name ?? (id == personID ? "Participant" : id)
    }
}

func sessionDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
}

func workoutDeletionMessage(_ workout: Workout) -> String {
    "This profile’s exercises and sets will be removed from history and progress. Other profiles’ results will be kept. This cannot be undone."
}

struct WorkoutDeleteAction: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming = false
    let workout: Workout
    let personID: String

    func body(content: Content) -> some View {
        content
            .transition(.asymmetric(
                insertion: .opacity,
                removal: reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)
            ))
            .swipeActions(allowsFullSwipe: false) {
                if store.canDeleteWorkout(workout, personID: personID) {
                    // A destructive swipe role optimistically removes the row before confirmation.
                    // Keep it present until the confirmed action changes the stored workouts.
                    Button("Delete", systemImage: "trash") { AppHaptics.selection(); confirming = true }
                        .tint(.red)
                }
            }
            .confirmationDialog("Delete workout?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete workout", role: .destructive) {
                    AppHaptics.selection()
                    withAnimation(reduceMotion ? nil : .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.24)) {
                        _ = store.deleteWorkout(workout, personID: personID)
                    }
                }
            } message: { Text(workoutDeletionMessage(workout)) }
    }
}
