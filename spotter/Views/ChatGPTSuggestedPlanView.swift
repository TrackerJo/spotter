import SwiftUI

struct ChatGPTSuggestedPlanView: View {
    @Environment(Store.self) private var store
    @Environment(ChatGPTConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    let request: ChatGPTDraftRequest
    @State private var chat = ChatGPTConversation()
    @State private var suggestion: ImportedPlan?
    @State private var explanation = ""
    @State private var reviewedIDs: Set<String> = []
    @State private var preparing = false
    @State private var started = Date()
    @State private var saved = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Group {
            if preparing {
                loading
            } else if saved {
                ContentUnavailableView {
                    Label("Plan added", systemImage: "checkmark.circle")
                } description: {
                    Text(suggestion?.plan.name ?? "Your new split is ready in Plans.")
                } actions: {
                    Button("Done") { AppHaptics.selection(); dismiss() }.buttonStyle(.borderedProminent)
                }
            } else if let suggestion {
                preview(suggestion)
            } else {
                setup
            }
        }
        .navigationTitle(preparing ? "Creating your split" : "Suggested split")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .modifier(ChatGPTWelcomeModifier())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !preparing && !saved, let suggestion {
                VStack(spacing: 8) {
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    Button { addPlan() } label: {
                        Text("Add plan").frame(maxWidth: .infinity, minHeight: 32)
                    }.buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(store.readOnly || suggestion.plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || suggestion.exercises.contains { !reviewedIDs.contains($0.id) })
                    ChatGPTPlanNotice()
                }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
        .task(id: connection.usesPlan) {
            guard connection.usesPlan, suggestion == nil, !preparing, !saved else { return }
            generate()
        }
        .onDisappear { task?.cancel(); chat.cancel() }
    }

    private var loading: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 14) {
                    ProgressView().padding(.top, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loadingTitle).font(.title3.weight(.semibold))
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                            Text("\(elapsed / 60):\(String(format: "%02d", elapsed % 60)) elapsed")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityElement(children: .combine)
                ForEach(0..<2) { _ in
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Training day").font(.headline)
                        ForEach(0..<3) { _ in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Exercise name").font(.body)
                                Text("Sets and rep targets").font(.subheadline).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .redacted(reason: .placeholder).accessibilityHidden(true)
                }
                Button("Stop", role: .cancel) { AppHaptics.selection(); task?.cancel(); chat.cancel() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                ChatGPTPlanNotice()
            }.padding(24)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
    private var loadingTitle: String {
        if chat.activity == "Reading your training data…" { return "Reviewing your workouts…" }
        if chat.busy { return "Building your split…" }
        return "Getting ChatGPT ready…"
    }

    private var setup: some View {
        Form {
            if !connection.usesPlan {
                Section("Connect ChatGPT") { ChatGPTConnectionControls() }
            } else {
                Section {
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        Text("Create a split from your goal and past training.")
                    }
                    ChatGPTModelPicker(chat: chat)
                    Button("Suggest split") { AppHaptics.selection(); generate() }.disabled(preparing || chat.error?.isUsageLimit == true)
                    if chat.error?.isUsageLimit == true {
                        HapticLink("Manage usage", destination: ChatGPTConnection.usageURL)
                    }
                }
            }
        }
    }

    private func preview(_ suggestion: ImportedPlan) -> some View {
        Form {
            if !explanation.isEmpty {
                Section("What changed") {
                    Text(explanation).font(.subheadline).textSelection(.enabled)
                }
            }
            Section {
                TextField("Plan name", text: Binding(
                    get: { self.suggestion?.plan.name ?? "Suggested split" },
                    set: { self.suggestion?.plan.name = $0 }
                ))
                Text("\(suggestion.plan.days.count) days · \(suggestion.plan.days.reduce(0) { $0 + $1.exercises.count }) exercises")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !suggestion.exercises.isEmpty {
                Section("Check exercise details") {
                    ForEach(suggestion.exercises) { exercise in
                        NavigationLink {
                            CustomExerciseView(importedExercise: exercise, needsClassification: !reviewedIDs.contains(exercise.id), importLabel: "plan", onMatch: { existing in
                                self.suggestion?.matchCustomExercise(exercise.id, to: existing)
                                reviewedIDs.remove(exercise.id)
                            }) { updated in
                                guard let index = self.suggestion?.exercises.firstIndex(where: { $0.id == updated.id }) else { return }
                                self.suggestion?.exercises[index] = updated
                                reviewedIDs.insert(updated.id)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(exercise.name, systemImage: reviewedIDs.contains(exercise.id) ? "checkmark.circle" : "exclamationmark.circle")
                                Text(reviewedIDs.contains(exercise.id) ? "\(exercise.primary) · \(exercise.equipment)" : "Choose muscle groups and equipment")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(HapticNavigationButtonStyle())
                    }
                }
            }
            ForEach(suggestion.plan.days) { day in
                Section(day.name) {
                    ForEach(day.exercises) { planned in
                        let library = store.library + suggestion.exercises
                        let exercise = library.first { $0.id == planned.exerciseID }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(planned.exerciseIDs.compactMap { id in library.first { $0.id == id }.map { store.name($0, personID: store.me.id) } }.joined(separator: " or "))
                            Text(planned.target.summary(for: exercise?.tracking ?? .weightReps))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
            Section {
                Button("Suggest another split", systemImage: "arrow.clockwise") { AppHaptics.selection(); generate() }
                    .disabled(store.readOnly)
            }
        }
    }

    private func generate() {
        guard !preparing else { return }
        preparing = true; started = Date(); error = nil
        suggestion = nil; explanation = ""; reviewedIDs = []
        task = Task {
            defer { preparing = false }
            do {
                if chat.models.isEmpty { await chat.loadModels(connection: connection) }
                try Task.checkCancellation()
                let instructions = ChatGPTDraftRequest.csvInstructions + "\nFor this suggested split, explanation must be at most two short sentences and 45 words. Focus on the specific changes from the current plan and how they serve the goal. If there is no current plan or not enough history, say that briefly. Prefer exercises from the exercise_library tool and keep per-exercise notes short."
                let response = try await chat.send(request.prompt, connection: connection, store: store, instructions: instructions)
                try Task.checkCancellation()
                let draft = try ChatGPTDraft.parse(response)
                do {
                    suggestion = try PlanCSV.parse(draft.csv, name: "Suggested split", library: store.library, names: store.state.names[store.me.id] ?? [:])
                } catch {
                    throw ChatGPTError(message: "The suggested split wasn’t ready to save. Try another suggestion.")
                }
                explanation = draft.explanation
            } catch is CancellationError {
                // Stopping returns to the retry action without exposing a partial plan.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    private func addPlan() {
        guard let suggestion, !saved else { return }
        guard !suggestion.exercises.contains(where: { !reviewedIDs.contains($0.id) }) else { return }
        var plan = suggestion
        plan.plan.name = plan.plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        AppHaptics.selection()
        if store.importPlan(plan) { self.suggestion = plan; saved = true; error = nil }
        else { error = store.error ?? "The plan couldn’t be saved. Try again." }
    }
}
