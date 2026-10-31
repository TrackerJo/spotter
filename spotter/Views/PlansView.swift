import SwiftUI

struct PlansView: View {
    @Environment(Store.self) private var store
    @State private var newName = ""
    @State private var showingCreate = false
    @State private var showingImport = false
    @State private var showingSuggestion = false
    @State private var renamingPlanID: String?
    @State private var renameDraft = ""
    @State private var showingRename = false
    @State private var deletingPlan: Plan?
    @State private var showingDelete = false
    @State private var selectedDay: (planID: String, day: TrainingDay)?
    var body: some View {
        List {
            Section {
                Button {
                    AppHaptics.selection()
                    showingSuggestion = true
                } label: {
                    HStack {
                        Label("Suggest a split with ChatGPT", systemImage: "sparkles")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.tint(.primary).disabled(store.readOnly)
            }
            ForEach(store.state.plans) { plan in
                Section {
                    ForEach(plan.days) { day in
                        Button {
                            AppHaptics.selection()
                            selectedDay = (plan.id, day)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) { Text(day.name).font(.headline); Text("\(day.exercises.count) exercises · \(schedule(day))").font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 4)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }.tint(.primary)
                    }.onDelete { indexes in mutate(plan.id) { $0.days.remove(atOffsets: indexes) } }.onMove { from, to in mutate(plan.id) { $0.days.move(fromOffsets: from, toOffset: to) } }
                    Button("Add training day", systemImage: "plus") {
                        AppHaptics.selection()
                        let day = TrainingDay(name: "New day")
                        mutate(plan.id) { $0.days.append(day) }
                        selectedDay = (plan.id, day)
                    }
                } header: {
                    HStack {
                        Text(plan.name)
                        Spacer()
                        Menu {
                            Button("Rename", systemImage: "pencil") { AppHaptics.selection();
                                renamingPlanID = plan.id
                                renameDraft = plan.name
                                showingRename = true
                            }
                            Button("Delete plan", systemImage: "trash", role: .destructive) { AppHaptics.selection();
                                deletingPlan = plan
                                showingDelete = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Options for \(plan.name)")
                    }
                    .textCase(nil)
                }
            }
            Section { Button("Import CSV", systemImage: "square.and.arrow.down") { AppHaptics.selection(); showingImport = true }.disabled(store.readOnly) }
        }.navigationTitle("Plans").toolbar { EditButton() }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            Button {
                AppHaptics.selection()
                newName = ""
                showingCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create plan")
            .disabled(store.readOnly)
            .padding(.trailing, 20)
            .padding(.vertical, 12)
        }
        .alert("New plan", isPresented: $showingCreate) {
            TextField("Plan name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create plan") {
                AppHaptics.selection()
                guard !store.readOnly else { return }
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.state.plans.append(Plan(name: name))
                store.save(notify: false)
                newName = ""
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedDay != nil },
            set: { if !$0 { selectedDay = nil } }
        )) {
            if let selectedDay {
                DayEditor(planID: selectedDay.planID, initial: selectedDay.day)
            }
        }
        .navigationDestination(isPresented: $showingSuggestion) { ChatGPTSplitView() }
        .sheet(isPresented: $showingImport) { NavigationStack { PlanImportView() } }
        .alert("Rename plan", isPresented: $showingRename) {
            TextField("Plan name", text: $renameDraft)
            Button("Cancel", role: .cancel) { AppHaptics.selection(); renamingPlanID = nil }
            Button("Save") { AppHaptics.selection();
                if let id = renamingPlanID {
                    mutate(id) { $0.name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                renamingPlanID = nil
            }.disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete plan?", isPresented: $showingDelete, presenting: deletingPlan) { plan in
            Button("Cancel", role: .cancel) { AppHaptics.selection(); deletingPlan = nil }
            Button("Delete plan", role: .destructive) { AppHaptics.selection();
                store.state.plans.removeAll { $0.id == plan.id }
                store.save(notify: false)
                deletingPlan = nil
            }
        } message: { plan in
            Text("\(plan.name) and its training days will be removed. Existing workouts and history remain saved.")
        }
    }
    private func schedule(_ day: TrainingDay) -> String { day.weekdays.isEmpty ? "Flexible schedule" : day.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ") }
    private func mutate(_ id: String, _ action: (inout Plan) -> Void) { if let index = store.state.plans.firstIndex(where: { $0.id == id }) { action(&store.state.plans[index]); store.save(notify: false) } }
}
struct DayEditor: View {
    @Environment(Store.self) private var store
    let planID: String
    @State private var day: TrainingDay
    @State private var adding = false
    @State private var editMode: EditMode = .inactive
    @FocusState private var nameFocused: Bool
    init(planID: String, initial: TrainingDay) { self.planID = planID; _day = State(initialValue: initial) }
    var body: some View {
        Form {
            if editMode.isEditing {
                Section("Name") {
                    TextField("Day name", text: $day.name)
                        .focused($nameFocused)
                }
            }
            Section("Optional schedule") {
                ForEach(1...7, id: \.self) { weekday in
                    Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(get: { day.weekdays.contains(weekday) }, set: { enabled in if enabled { day.weekdays.append(weekday) } else { day.weekdays.removeAll { $0 == weekday } } }).hapticSelection())
                }
            }
            Section("Exercise order") {
                ForEach($day.exercises) { $planned in
                    NavigationLink { PlannedExerciseEditor(planned: $planned) } label: {
                        VStack(alignment: .leading, spacing: 5) { Text(planned.exerciseIDs.compactMap { store.exercise($0).map { store.name($0) } }.joined(separator: " or ")); Text(planned.target.summary(for: store.exercise(planned.exerciseID)?.tracking ?? .weightReps)).font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(HapticNavigationButtonStyle())
                }.onDelete { day.exercises.remove(atOffsets: $0) }.onMove { day.exercises.move(fromOffsets: $0, toOffset: $1) }
                Button("Add exercise", systemImage: "plus") { AppHaptics.selection(); adding = true }
            }
        }
        .navigationTitle(editMode.isEditing ? "Edit Plan" : day.name)
        .environment(\.editMode, $editMode)
        .toolbar {
            Button(editMode.isEditing ? "Done" : "Edit") { AppHaptics.selection();
                nameFocused = false
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { ExerciseChooser(onSelect: { exercise in day.exercises.append(PlannedExercise(exerciseID: exercise.id)); adding = false }, libraryOnly: true) } }
        .onChange(of: day) { _, updated in
            guard let p = store.state.plans.firstIndex(where: { $0.id == planID }), let d = store.state.plans[p].days.firstIndex(where: { $0.id == day.id }) else { return }
            store.state.plans[p].days[d] = updated; store.save(notify: false)
        }
    }
}

struct PlannedExerciseEditor: View {
    @Environment(Store.self) private var store
    @Binding var planned: PlannedExercise
    @State private var choosingAlternative = false
    private var tracking: Tracking { store.exercise(planned.exerciseID)?.tracking ?? .weightReps }
    var body: some View {
        Form {
            Section {
                ForEach(planned.exerciseIDs, id: \.self) { id in
                    if let exercise = store.exercise(id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.name(exercise))
                            Text(exercise.equipment).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if planned.alternativeExerciseID != nil {
                    Button("Change alternative") { AppHaptics.selection(); choosingAlternative = true }
                    Button("Remove alternative", role: .destructive) { AppHaptics.selection(); planned.alternativeExerciseID = nil }
                } else {
                    Button("Add alternative", systemImage: "plus") { AppHaptics.selection(); choosingAlternative = true }
                }
            } header: { Text("Exercise choices") } footer: {
                Text("Choose either exercise during your workout. Both use the targets below and keep separate histories.")
            }
            TargetFields(target: $planned.target, tracking: tracking)
        }
        .navigationTitle("Plan exercise")
        .sheet(isPresented: $choosingAlternative) {
            NavigationStack {
                ExerciseChooser(onSelect: { exercise in
                    planned.alternativeExerciseID = exercise.id
                    choosingAlternative = false
                }, libraryOnly: true, requiredTracking: tracking, excludedExerciseID: planned.exerciseID)
            }
        }
    }
}
