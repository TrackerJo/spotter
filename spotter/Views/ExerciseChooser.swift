import SwiftUI

struct ExerciseChooser: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onSelect: (Exercise) -> Void
    var libraryOnly = false
    var requiredTracking: Tracking? = nil
    var excludedExerciseID: String? = nil
    var personID: String? = nil
    @State private var search = ""
    @State private var create = false
    private var recommendation: String? { store.participant.flatMap { WorkoutEngine.recommended($0, ledger: store.state.ledger) } }
    private var remaining: [PlannedExercise] {
        (store.participant?.day?.exercises ?? []).filter { planned in
            !planned.contains(recommendation ?? "") && !store.myEntries.contains { planned.contains($0.exercise.id) && $0.status == .completed }
        }
    }
    var body: some View {
        List {
            if !libraryOnly && search.isEmpty {
                if let id = recommendation, let planned = store.participant?.day?.exercises.first(where: { $0.contains(id) }) {
                    Section("Suggested next") {
                        plannedChoice(planned, suggested: true)
                    }
                }
                if !remaining.isEmpty {
                    Section(store.participant?.day?.name ?? "This day") {
                        ForEach(remaining) { planned in
                            plannedChoice(planned)
                        }
                    }
                }
            }
            Section(search.isEmpty ? "All exercises" : "Search results") {
                let matches = store.search(search, personID: personID).filter { $0.id != excludedExerciseID && (requiredTracking == nil || $0.tracking == requiredTracking) }
                if matches.isEmpty { ContentUnavailableView.search(text: search) }
                ForEach(matches) { exercise in choice(exercise, subtitle: "\(exercise.primary) · \(exercise.equipment)") }
                if requiredTracking == nil { Button { AppHaptics.selection(); create = true } label: { Label("Create custom exercise", systemImage: "plus.circle") }.frame(minHeight: 44) }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(libraryOnly ? "Choose exercise" : "Add exercise")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find any exercise")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { AppHaptics.selection(); dismiss() } } }
        .sheet(isPresented: $create) {
            NavigationStack { CustomExerciseView(initialName: search) { exercise in
                create = false
                onSelect(exercise)
            } }
        }
    }
    @ViewBuilder private func plannedChoice(_ planned: PlannedExercise, suggested: Bool = false) -> some View {
        let choices = planned.exerciseIDs.compactMap { store.exercise($0) }
        if choices.count > 1 {
            Menu {
                ForEach(choices) { exercise in
                    Button(store.name(exercise, personID: personID)) { AppHaptics.selection(); onSelect(exercise) }
                }
            } label: {
                HStack(spacing: 12) {
                    if suggested { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.indigo) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choices.map { store.name($0, personID: personID) }.joined(separator: " or ")).foregroundStyle(Color.primary)
                        Text(planned.target.summary(for: choices[0].tracking)).font(.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").foregroundStyle(Color.indigo)
                }.frame(minHeight: 44)
            }
        } else if let exercise = choices.first {
            choice(exercise, subtitle: planned.target.summary(for: exercise.tracking), suggested: suggested)
        }
    }

    private func choice(_ exercise: Exercise, subtitle: String, suggested: Bool = false) -> some View {
        Button { AppHaptics.selection(); onSelect(exercise) } label: {
            HStack(spacing: 12) {
                if suggested { Image(systemName: "arrow.right.circle.fill").font(.title3).foregroundStyle(Color.indigo) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.name(exercise, personID: personID)).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                    Text(subtitle).font(.caption).foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "plus").font(.body.weight(.medium)).foregroundStyle(Color.indigo)
            }.frame(minHeight: 44)
        }
    }
}
