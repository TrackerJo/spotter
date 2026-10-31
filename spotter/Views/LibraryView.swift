import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var muscle = "All"
    @State private var equipment = "All"
    @State private var create = false
    @State private var selectedExercise: Exercise?
    var body: some View {
        List {
            Section {
                Picker("Muscle group", selection: $muscle.hapticSelection()) { Text("All muscles").tag("All"); ForEach(Set(store.library.map(\.primary)).sorted(), id: \.self) { Text($0).tag($0) } }
                Picker("Equipment", selection: $equipment.hapticSelection()) { Text("All equipment").tag("All"); ForEach(Set(store.library.map(\.equipment)).sorted(), id: \.self) { Text($0).tag($0) } }
            }
            Section {
                let matches = store.search(query).filter { (muscle == "All" || $0.primary == muscle || $0.secondary.contains(muscle)) && (equipment == "All" || $0.equipment == equipment) }
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
                ForEach(matches) { exercise in
                    Button {
                        AppHaptics.selection()
                        selectedExercise = exercise
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.name(exercise)).font(.headline)
                                Text("\(exercise.primary) · \(exercise.equipment) · \(exercise.tracking.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if store.name(exercise) != exercise.name {
                                    Text("Originally \(exercise.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }.navigationTitle("Exercise library").searchable(text: $query, prompt: "Names, aliases, muscles")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Create", systemImage: "plus") { AppHaptics.selection(); create = true } } }
        .sheet(isPresented: $create) { NavigationStack { CustomExerciseView() } }
        .navigationDestination(isPresented: Binding(
            get: { selectedExercise != nil },
            set: { if !$0 { selectedExercise = nil } }
        )) {
            if let selectedExercise { ExerciseDetail(exercise: selectedExercise) }
        }
    }
}
struct ExerciseDetail: View {
    @Environment(Store.self) private var store
    let exercise: Exercise
    @State private var name = ""
    @State private var increment = ""
    private enum PreferenceField: Hashable { case name, increment }
    @FocusState private var editingPreference: PreferenceField?
    @ScaledMetric(relativeTo: .body) private var incrementWidth = 88

    private var incrementValue: Double? {
        Double(increment.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    private var validIncrement: Bool {
        increment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        (incrementValue.map { $0.isFinite && $0 > 0 } ?? false)
    }

    var body: some View {
        Form {
            Section("Your preferences") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display name").font(.subheadline).foregroundStyle(.secondary)
                        TextField(exercise.name, text: $name)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Display name")
                            .focused($editingPreference, equals: .name)
                            .submitLabel(.done)
                            .onSubmit { editingPreference = nil }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            Text("Weight increment").foregroundStyle(.primary).fixedSize()
                            Spacer(minLength: 0)
                            incrementInput
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weight increment").foregroundStyle(.primary)
                            incrementInput
                        }
                    }
                    if !validIncrement {
                        Text("Enter a number greater than 0.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Movement") {
                LabeledContent("Original name", value: exercise.name)
                LabeledContent("Primary muscle", value: exercise.primary)
                LabeledContent("Secondary muscles", value: exercise.secondary.joined(separator: ", "))
                LabeledContent("Equipment", value: exercise.equipment)
                LabeledContent("Movement pattern", value: exercise.pattern)
                LabeledContent("Tracking", value: exercise.tracking.rawValue)
                if !exercise.aliases.isEmpty { Text("Also searchable as: \(exercise.aliases.joined(separator: ", "))").font(.footnote) }
            }
        }.navigationTitle(store.name(exercise)).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .background(PreferenceOutsideTapDismissal(isEditing: editingPreference != nil) { editingPreference = nil })
        .toolbar {
            if editingPreference != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { AppHaptics.selection(); editingPreference = nil }
                }
            }
        }
        .onChange(of: editingPreference) { old, _ in
            if let old { savePreference(old) }
        }
        .onDisappear {
            savePreference(.name)
            savePreference(.increment)
        }
        .onAppear { name = store.name(exercise); let value = store.incrementPounds(exercise); increment = value.flatMap { $0 > 0 ? $0.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) : nil } ?? "" }
    }

    private func savePreference(_ field: PreferenceField) {
        let savedIncrement = store.incrementPounds(exercise).flatMap { $0 > 0 ? $0 : nil }
        switch field {
        case .name:
            let updatedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveName = updatedName.isEmpty ? exercise.name : updatedName
            guard effectiveName != store.name(exercise) else { return }
            store.rename(exercise, to: updatedName, increment: savedIncrement)
        case .increment:
            guard validIncrement, incrementValue != savedIncrement else { return }
            store.rename(exercise, to: store.name(exercise), increment: incrementValue)
        }
    }

    private var incrementInput: some View {
        HStack(spacing: 8) {
            TextField("Optional", text: $increment)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .textFieldStyle(.plain)
                .frame(width: incrementWidth, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Weight increment in pounds")
                .accessibilityHint("Optional. Leave blank for no fixed increment.")
                .focused($editingPreference, equals: .increment)
            Text("lb").foregroundStyle(.secondary)
        }
    }
}

/// Observe outside taps without swallowing navigation, scrolling, or taps in another input.
private struct PreferenceOutsideTapDismissal: UIViewRepresentable {
    var isEditing: Bool
    var dismiss: () -> Void

    func makeUIView(context: Context) -> TapObserver { TapObserver() }
    func updateUIView(_ view: TapObserver, context: Context) {
        view.dismiss = dismiss
        view.tap.isEnabled = isEditing
    }
    static func dismantleUIView(_ view: TapObserver, coordinator: ()) {
        view.tap.view?.removeGestureRecognizer(view.tap)
    }

    final class TapObserver: UIView, UIGestureRecognizerDelegate {
        var dismiss: () -> Void = {}
        lazy var tap: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(outsideTap))
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.rootViewController?.view.addGestureRecognizer(tap)
        }

        @objc private func outsideTap() { dismiss() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is UITextField || view is UITextView { return false }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

struct CustomExerciseView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var primary = "Core"
    @State private var secondary: Set<String> = []
    @State private var equipment = "Bodyweight"
    @State private var pattern = "Other"
    @State private var aliases = ""
    @State private var tracking: Tracking = .bodyweight
    var onCreate: ((Exercise) -> Void)? = nil
    private var importedExercise: Exercise? = nil
    private var onReview: ((Exercise) -> Void)? = nil
    private var onMatch: ((Exercise) -> Void)? = nil
    private var importLabel = "plan"
    @State private var searchingLibrary = false
    @State private var matchedExercise: Exercise?
    init(initialName: String = "", onCreate: ((Exercise) -> Void)? = nil) {
        _name = State(initialValue: initialName)
        self.onCreate = onCreate
    }
    init(importedExercise: Exercise, needsClassification: Bool = true, importLabel: String = "plan", onMatch: ((Exercise) -> Void)? = nil, onReview: @escaping (Exercise) -> Void) {
        self.importedExercise = importedExercise
        self.onReview = onReview
        self.onMatch = onMatch
        self.importLabel = importLabel
        _name = State(initialValue: importedExercise.name)
        _primary = State(initialValue: needsClassification ? "" : importedExercise.primary)
        _secondary = State(initialValue: Set(importedExercise.secondary))
        _equipment = State(initialValue: needsClassification ? "" : importedExercise.equipment)
        _pattern = State(initialValue: importedExercise.pattern)
        _tracking = State(initialValue: importedExercise.tracking)
        _aliases = State(initialValue: importedExercise.aliases.joined(separator: ", "))
    }
    private var muscles: [String] {
        Set(store.library.flatMap { [$0.primary] + $0.secondary } + ["Core", "Other", primary]).filter { !$0.isEmpty }.sorted()
    }
    private var equipmentOptions: [String] {
        Set(store.library.map(\.equipment) + ["Bodyweight", "Band", "Kettlebell", "Other", equipment]).filter { !$0.isEmpty }.sorted()
    }
    private var patterns: [String] {
        Set(store.library.map(\.pattern) + ["Other"]).sorted()
    }
    private var closeMatches: [Exercise] {
        ExerciseNameMatcher.suggestions(importedExercise?.name ?? name, exercises: store.library, names: store.state.names[store.person.id] ?? [:])
    }
    var body: some View {
        Form {
            if onMatch != nil {
                Section {
                    Button("Find existing exercise", systemImage: "magnifyingglass") { AppHaptics.selection(); searchingLibrary = true }
                    if !closeMatches.isEmpty {
                        Text("Close matches").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(closeMatches) { exercise in
                            Button {
                                AppHaptics.selection()
                                onMatch?(exercise)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(store.name(exercise)).foregroundStyle(.primary)
                                        Text("\(exercise.primary) · \(exercise.equipment)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text("Use").foregroundStyle(.tint)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Use \(store.name(exercise)), \(exercise.primary), \(exercise.equipment)")
                        }
                    }
                } footer: {
                    Text("If this exercise is already in your library, select it to use its history and save the CSV name as an alias.")
                }
            }
            Section("Your exercise") {
                TextField("Exercise name", text: $name)
                Picker("Primary muscle", selection: $primary.hapticSelection()) {
                    if importedExercise != nil { Text("Choose muscle").tag("") }
                    ForEach(muscles, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                NavigationLink {
                    List {
                        ForEach(muscles.filter { $0 != primary }, id: \.self) { muscle in
                            Button { AppHaptics.selection();
                                if secondary.contains(muscle) { secondary.remove(muscle) }
                                else { secondary.insert(muscle) }
                            } label: {
                                HStack {
                                    Text(muscle).foregroundStyle(.primary)
                                    Spacer()
                                    if secondary.contains(muscle) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(secondary.contains(muscle) ? .isSelected : [])
                        }
                    }
                    .navigationTitle("Secondary muscles")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("Secondary muscles", value: secondary.isEmpty ? "None" : secondary.sorted().joined(separator: ", "))
                }.buttonStyle(HapticNavigationButtonStyle())
                Picker("Equipment", selection: $equipment.hapticSelection()) {
                    if importedExercise != nil { Text("Choose equipment").tag("") }
                    ForEach(equipmentOptions, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Picker("Movement pattern", selection: $pattern.hapticSelection()) {
                    ForEach(patterns, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Picker("Track", selection: $tracking.hapticSelection()) { ForEach(Tracking.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Aliases, comma separated", text: $aliases)
            }
            Section { Text(importedExercise == nil ? "A custom exercise keeps the same identity on both phones when used in a shared workout." : "Choose equipment and a primary muscle. Add secondary muscles if needed. This exercise is saved only when you import the \(importLabel).").font(.footnote).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $searchingLibrary, onDismiss: {
            if let matchedExercise { onMatch?(matchedExercise); dismiss() }
        }) {
            NavigationStack {
                ImportedExerciseMatcher(initialQuery: importedExercise?.name ?? name) { exercise in
                    matchedExercise = exercise
                    searchingLibrary = false
                }
            }
        }
        .onChange(of: primary) { _, muscle in secondary.remove(muscle) }
        .navigationTitle(importedExercise == nil ? "Create exercise" : "Review exercise").navigationBarTitleDisplayMode(.inline).toolbar {
            if importedExercise == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { AppHaptics.selection(); dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) { Button(importedExercise == nil ? "Create" : "Save details") { AppHaptics.selection();
                let exercise = Exercise(id: importedExercise?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces), aliases: split(aliases), primary: primary, secondary: secondary.subtracting([primary]).sorted(), equipment: equipment, pattern: pattern, tracking: tracking)
                if let onReview { onReview(exercise); dismiss() }
                else { store.addExercise(exercise); dismiss(); onCreate?(exercise) }
            }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || primary.isEmpty || equipment.isEmpty) }
        }
    }
    private func split(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

private struct ImportedExerciseMatcher: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    let onSelect: (Exercise) -> Void

    init(initialQuery: String, onSelect: @escaping (Exercise) -> Void) {
        _query = State(initialValue: initialQuery)
        self.onSelect = onSelect
    }

    var body: some View {
        List {
            let matches = store.search(query)
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(matches) { exercise in
                Button { AppHaptics.selection(); onSelect(exercise) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.name(exercise)).foregroundStyle(.primary)
                        Text("\(exercise.primary) · \(exercise.equipment)").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Find existing exercise")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Names, aliases, muscles")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { AppHaptics.selection(); dismiss() } } }
    }
}
