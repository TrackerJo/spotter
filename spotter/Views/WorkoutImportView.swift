import SwiftUI
import UniformTypeIdentifiers

struct WorkoutImportView: View {
    @Environment(Store.self) private var store
    var profileID: String? = nil
    @State private var selectedProfileID: String?
    private var profile: Profile {
        store.dataProfiles.first { $0.id == (selectedProfileID ?? profileID) } ?? store.dataProfile
    }
    @Environment(\.dismiss) private var dismiss
    @State private var csv = ""
    @State private var yearText = String(Calendar.current.component(.year, from: Date()))
    @State private var unit: WeightUnit = .lb
    @State private var choosingFile = false
    @State private var draft: WorkoutImportDraft?
    @State private var reviewedIDs: Set<String> = []
    @State private var warningsReviewed = false
    @State private var error: String?
    @State private var parseFailed = false
    @State private var aiRequest: ChatGPTDraftRequest?
    @FocusState private var editingInput: Bool

    private var importYear: Int? {
        guard let year = Int(yearText), (1900...2100).contains(year) else { return nil }
        return year
    }

    var body: some View {
        Form {
            Section {
                Picker("Importing for", selection: Binding(get: { profile.id }, set: { id in
                    selectedProfileID = id
                    // Draft IDs, exercise names, and ownership belong to the selected profile.
                    draft = nil
                    reviewedIDs = []
                    warningsReviewed = false
                    error = nil
                    parseFailed = false
                }).hapticSelection()) {
                    ForEach(store.dataProfiles) { profile in
                        Text(profile.id == store.me.id ? "\(profile.name) (you)" : profile.name).tag(profile.id)
                    }
                }
            }
            if let draft {
                Section {
                    Text("\(draft.workouts.count) workouts · \(draft.sets.flatMap { $0 }.count) sets")
                    Text("Dates use noon for ordering. Workout duration and set times were not recorded. Imported history has no progression targets.").font(.footnote).foregroundStyle(.secondary)
                }
                if !draft.warnings.isEmpty {
                    Section("Check original values and dates") {
                        ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.footnote) }
                        Toggle("I reviewed these values and dates", isOn: $warningsReviewed.hapticSelection())
                    }
                }
                if !draft.review.exercises.isEmpty {
                    Section {
                        ForEach(draft.review.exercises) { exercise in
                            NavigationLink {
                                CustomExerciseView(importedExercise: exercise, needsClassification: !reviewedIDs.contains(exercise.id), importLabel: "workouts", onMatch: { existing in
                                    self.draft?.review.matchCustomExercise(exercise.id, to: existing)
                                    reviewedIDs.remove(exercise.id)
                                }) { updated in
                                    guard let index = self.draft?.review.exercises.firstIndex(where: { $0.id == updated.id }) else { return }
                                    self.draft?.review.exercises[index] = updated
                                    reviewedIDs.insert(updated.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(exercise.name, systemImage: reviewedIDs.contains(exercise.id) ? "checkmark.circle" : "exclamationmark.circle")
                                    Text(reviewedIDs.contains(exercise.id) ? "\(exercise.primary) · \(exercise.equipment)" : "Choose details or find an existing exercise").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(HapticNavigationButtonStyle())
                        }
                    } header: {
                        Text("Review custom exercises · \(draft.review.exercises.filter { !reviewedIDs.contains($0.id) }.count) remaining")
                    } footer: {
                        Text("Review each new exercise. Matches use your existing exercise history and save the CSV name as an alias.")
                    }
                }
                ForEach(draft.workouts.indices, id: \.self) { index in
                    Section {
                        DatePicker("Workout date", selection: Binding(get: { self.draft?.workouts[index].started ?? draft.workouts[index].started }, set: { date in
                            self.draft?.workouts[index].started = date
                            self.draft?.workouts[index].finished = date
                        }).hapticSelection(), displayedComponents: .date)
                        DisclosureGroup("\(draft.entries[index].count) exercises · \(draft.sets[index].count) sets") {
                            ForEach(draft.entries[index].indices, id: \.self) { entryIndex in
                                let initial = draft.entries[index][entryIndex]
                                let exerciseID = draft.review.plan.days[index].exercises[entryIndex].exerciseID
                                let exercise = (store.library + draft.review.exercises).first { $0.id == exerciseID } ?? initial.exercise
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(exercise.name).font(.headline)
                                    ForEach(draft.sets[index].filter { $0.entryID == initial.id }) { set in
                                        SetSummary(set: set, tracking: exercise.tracking)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        if store.workouts.contains(where: { $0.id == draft.workouts[index].id }) {
                            Text("Already imported · will be skipped").font(.caption).foregroundStyle(.secondary)
                        }
                    } header: { Text("CSV date: \(draft.review.plan.days[index].name)") }
                }
                Section {
                    Button("Import workouts") { AppHaptics.selection();
                        if store.importWorkouts(draft) { dismiss() }
                        else { error = store.error ?? "These workouts could not be saved." }
                    }.disabled(store.readOnly || draft.review.exercises.contains { !reviewedIDs.contains($0.id) } || (!draft.warnings.isEmpty && !warningsReviewed) || draft.workouts.allSatisfy { workout in store.workouts.contains { $0.id == workout.id } })
                    Button("Edit CSV") { AppHaptics.selection(); self.draft = nil; reviewedIDs = []; warningsReviewed = false }
                }
            } else {
                Section {
                    HStack {
                        Text("Year").foregroundStyle(.primary)
                        Spacer()
                        TextField("2026", text: $yearText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .monospacedDigit()
                            .frame(width: 88, height: 44)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Year for dates without a year")
                            .focused($editingInput)
                    }
                    Picker("Weight unit", selection: $unit.hapticSelection()) { Text("Pounds").tag(WeightUnit.lb); Text("Kilograms").tag(WeightUnit.kg) }
                    if importYear == nil {
                        Text("Enter a year from 1900 to 2100.").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Import settings")
                } footer: {
                    Text("Year applies only to dates without one.")
                }
                Section("Workout CSV") {
                    VStack(alignment: .leading, spacing: 16) {
                        Button { AppHaptics.selection(); editingInput = false; choosingFile = true } label: {
                            Label("Choose CSV file", systemImage: "doc")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        Text("Or paste CSV").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $csv)
                            .scrollContentBackground(.hidden)
                            .font(.system(.subheadline, design: .monospaced))
                            .padding(8)
                            .frame(height: 140)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topLeading) {
                                if csv.isEmpty {
                                    Text("Date, Exercise, Weight, Reps…")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .padding(.horizontal, 13).padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Workout CSV content")
                            .focused($editingInput)
                    }
                    .padding(.vertical, 4)
                    DisclosureGroup("CSV format") {
                        Text("Columns: Date, Exercise, Weight, Reps, RIR, Notes. Blank dates and exercises continue the previous entry; blank weights continue within the same exercise. Fractional reps and bw are supported.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { AppHaptics.selection();
                        guard let year = importYear else { return }
                        editingInput = false
                        do {
                            draft = try WorkoutCSV.parse(csv, year: year, unit: unit, profile: profile, library: store.library, names: store.state.names[profile.id] ?? [:])
                            reviewedIDs = []; warningsReviewed = false; error = nil; parseFailed = false
                        } catch { self.error = error.localizedDescription; parseFailed = true }
                    } label: {
                        Text("Preview workouts").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importYear == nil || csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.isDemo)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if parseFailed && draft == nil && !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text("Want to let ChatGPT parse the CSV for you?")
                    Button("Parse with ChatGPT", systemImage: "sparkles") {
                        AppHaptics.selection()
                        editingInput = false
                        aiRequest = ChatGPTDraftRequest(title: "Parse workout CSV", prompt: "Convert this workout CSV to Spotter's workout format. Preserve every logged set and note. Default year for dates without a year: \(importYear ?? 2026). Weight unit: \(unit.rawValue). Parser error: \(error ?? "Unknown format"). CSV data follows:\n" + csv, sharesHistory: false)
                    }.disabled(importYear == nil || profile.isDemo)
                }
            }
        }
        .navigationTitle("Import past workouts")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { AppHaptics.selection(); dismiss() } }
            if editingInput {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { AppHaptics.selection(); editingInput = false }
                }
            }
        }
        .sheet(item: $aiRequest) { request in
            NavigationStack {
                ChatGPTDraftView(request: request) { repaired in
                    guard let year = importYear else { throw PlanCSVError(message: "Enter a valid import year.") }
                    let parsed = try WorkoutCSV.parse(repaired, year: year, unit: unit, profile: profile, library: store.library, names: store.state.names[profile.id] ?? [:])
                    csv = repaired; draft = parsed; reviewedIDs = []; warningsReviewed = false; error = nil; parseFailed = false
                }
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw PlanCSVError(message: "Save the CSV with UTF-8 encoding and try again.") }
                csv = text; draft = nil; reviewedIDs = []; warningsReviewed = false; error = nil; parseFailed = false
            } catch { self.error = error.localizedDescription }
        }
    }
}
