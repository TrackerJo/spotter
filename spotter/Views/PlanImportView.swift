import SwiftUI
import UniformTypeIdentifiers

struct PlanImportView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Imported plan"
    @State private var csv = ""
    @State private var choosingFile = false
    @State private var preview: ImportedPlan?
    @State private var error: String?
    @State private var parseFailed = false
    @State private var aiRequest: ChatGPTDraftRequest?
    let aiExplanation: String?

    init(initialCSV: String = "", initialName: String = "Imported plan", aiExplanation: String? = nil) {
        _csv = State(initialValue: initialCSV)
        _name = State(initialValue: initialName)
        self.aiExplanation = aiExplanation
    }
    @State private var reviewedExerciseIDs: Set<String> = []
    @FocusState private var editingInput: Bool

    var body: some View {
        Form {
            if let aiExplanation { Section("Suggested by ChatGPT") { Text(aiExplanation).font(.footnote); Text("Review every exercise and target before importing.").font(.footnote).foregroundStyle(.secondary) } }
            Section("Plan name") {
                TextField("Plan name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Plan name")
                    .focused($editingInput)
                    .submitLabel(.done)
                    .onSubmit { editingInput = false }
            }
            if let preview {
                Section {
                    Text("\(preview.plan.days.count) days · \(preview.plan.days.reduce(0) { $0 + $1.exercises.count }) exercises")
                    Text("\(preview.exercises.count) new custom exercises").foregroundStyle(.secondary)
                    Text("RIR targets are imported for each set. Days have a flexible schedule.").font(.footnote).foregroundStyle(.secondary)
                }
                if !preview.exercises.isEmpty {
                    Section {
                        ForEach(preview.exercises) { exercise in
                            NavigationLink {
                                CustomExerciseView(importedExercise: exercise, needsClassification: !reviewedExerciseIDs.contains(exercise.id), onMatch: { existing in
                                    self.preview?.matchCustomExercise(exercise.id, to: existing)
                                    reviewedExerciseIDs.remove(exercise.id)
                                }) { updated in
                                    guard let index = self.preview?.exercises.firstIndex(where: { $0.id == updated.id }) else { return }
                                    self.preview?.exercises[index] = updated
                                    reviewedExerciseIDs.insert(updated.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(exercise.name, systemImage: reviewedExerciseIDs.contains(exercise.id) ? "checkmark.circle" : "exclamationmark.circle")
                                    Text(reviewedExerciseIDs.contains(exercise.id) ? "\(exercise.primary) · \(exercise.equipment)" : "Choose equipment and muscle groups")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(HapticNavigationButtonStyle())
                        }
                    } header: {
                        Text("Review custom exercises · \(preview.exercises.filter { !reviewedExerciseIDs.contains($0.id) }.count) remaining")
                    } footer: {
                        Text("Review each new exercise before importing. Details apply everywhere it appears in this plan.")
                    }
                }
                ForEach(preview.plan.days) { day in
                    Section(day.name) {
                        ForEach(day.exercises) { planned in
                            let exercise = (store.library + preview.exercises).first { $0.id == planned.exerciseID }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(planned.exerciseIDs.compactMap { id in (store.library + preview.exercises).first { $0.id == id }?.name }.joined(separator: " or "))
                                if preview.exercises.contains(where: { planned.contains($0.id) }) {
                                    Text(planned.exerciseIDs.filter { id in preview.exercises.contains { $0.id == id } }.allSatisfy { reviewedExerciseIDs.contains($0) } ? "Custom exercise · Reviewed" : "Custom exercise · Needs review").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(planned.target.summary(for: exercise?.tracking ?? .weightReps)).font(.caption).foregroundStyle(.secondary)
                                if !planned.target.notes.isEmpty { Text(planned.target.notes).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    Button("Import plan") { AppHaptics.selection();
                        var imported = preview
                        imported.plan.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if store.importPlan(imported) { dismiss() }
                        else { error = store.error ?? "The plan could not be saved." }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.readOnly || preview.exercises.contains { !reviewedExerciseIDs.contains($0.id) })
                    Button("Edit CSV") { AppHaptics.selection(); self.preview = nil; reviewedExerciseIDs = [] }
                }
            } else {
                Section("Plan CSV") {
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
                                    Text("Exercise, Sets, Rep range, RIR…")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .padding(.horizontal, 13).padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Plan CSV content")
                            .focused($editingInput)
                    }
                    .padding(.vertical, 4)
                    DisclosureGroup("CSV format") {
                        Text("Use a day name followed by Exercise, Sets, Rep range, RIR, and optional Notes columns. Repeat for each day. Separate exercise alternatives with / or or, such as Cable/Machine Fly. Blank rows and a leading empty column are supported.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { AppHaptics.selection();
                        editingInput = false
                        do { reviewedExerciseIDs = []; preview = try PlanCSV.parse(csv, name: name, library: store.library, names: store.state.names[store.person.id] ?? [:]); error = nil; parseFailed = false }
                        catch { self.error = error.localizedDescription; parseFailed = true }
                    } label: {
                        Text("Preview plan").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if parseFailed && preview == nil && !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text("Want to let ChatGPT parse the CSV for you?")
                    Button("Parse with ChatGPT", systemImage: "sparkles") {
                        AppHaptics.selection()
                        editingInput = false
                        aiRequest = ChatGPTDraftRequest(title: "Parse plan CSV", prompt: "Convert this plan CSV to Spotter's plan format. Preserve all exercise prescriptions and day names. Parser error: \(error ?? "Unknown format"). CSV data follows:\n" + csv, sharesHistory: false)
                    }
                }
            }
        }
        .navigationTitle("Import plan")
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
                    let parsed = try PlanCSV.parse(repaired, name: name, library: store.library, names: store.state.names[store.person.id] ?? [:])
                    csv = repaired; preview = parsed; reviewedExerciseIDs = []; error = nil; parseFailed = false
                }
            }
        }
        .task {
            if aiExplanation != nil && preview == nil {
                do { preview = try PlanCSV.parse(csv, name: name, library: store.library, names: store.state.names[store.person.id] ?? [:]) }
                catch { self.error = error.localizedDescription; parseFailed = true }
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                    throw PlanCSVError(message: "Save the CSV with UTF-8 encoding and try again.")
                }
                csv = text
                name = url.deletingPathExtension().lastPathComponent
                preview = nil
                parseFailed = false
                reviewedExerciseIDs = []
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
