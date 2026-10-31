import SwiftUI

struct ConnectionView: View {
    var showingStatus = false
    @Environment(Store.self) private var store
    @Environment(NearbySync.self) private var nearby
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var code = ""
    @State private var step = Step.join
    @State private var joiningAttempt = false
    @State private var sheetDetent: PresentationDetent = .height(310)
    @FocusState private var codeFocused: Bool

    private enum Step: Equatable { case join, status }
    private var myMember: Participant? {
        store.members.first { $0.workoutID == store.active?.id && $0.profile.id == store.me.id }
    }
    private var hosting: Bool { (hasUnfinishedWorkout && !joiningAttempt) || nearby.inviting }
    private var hasUnfinishedWorkout: Bool { store.active != nil && store.active?.finished == nil }
    private var recoveringSession: Bool { store.active?.shared == true && store.activeMembers.contains { !store.ownsProfile($0.profile.id) } }
    private var canJoin: Bool { code.count == 4 && !nearby.joining && (!hasUnfinishedWorkout || recoveringSession) }
    private var preferredDetent: PresentationDetent {
        if dynamicTypeSize.isAccessibilitySize { return .large }
        if step == .status { return .height(360) }
        if step != .join || hosting || nearby.joining || nearby.joinError != nil || hasUnfinishedWorkout { return .medium }
        return .height(310)
    }

    private var content: some View {
        Group {
            if step == .join && !hosting {
                ScrollView {
                    joinForm
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            } else if step == .status {
                ScrollView {
                    connectionSymbols
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            } else {
                Form { invitation }
            }
        }
    }

    private var sheetContent: some View {
        content
        .presentationDetents([.height(310), .height(360), .medium, .large], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .navigationTitle(step == .status ? "Nearby connection" : "Train together")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { AppHaptics.selection(); nearby.endInviting(); if step == .join && nearby.joining { nearby.stop() }; dismiss() } }
        }
        .onAppear {
            if showingStatus || nearby.connected || recoveringSession { step = .status }
            sheetDetent = preferredDetent
            if step == .join, hosting, let workout = store.active, workout.shared, !workout.demo, !nearby.connected, nearby.code.isEmpty, !recoveringSession {
                nearby.host(workout.id)
            }
        }
        .onDisappear { nearby.endInviting(); if joiningAttempt && nearby.joining { nearby.stop() } }
        .onChange(of: preferredDetent) { _, value in
            sheetDetent = value
        }
    }

    var body: some View {
        sheetContent
        .onChange(of: code) { _, value in
            code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4))
        }
        .onChange(of: store.activeMembers.count) { _, _ in advanceAfterJoin() }
        .onChange(of: nearby.joining) { _, joining in if !joining { advanceAfterJoin() } }
        .onChange(of: nearby.connected) { _, connected in if connected { advanceAfterJoin() } }

    }

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Join your friend").font(.title2.bold())
                Text("Enter the four-digit code from your friend.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 16) {
                TextField("0000", text: $code)
                    .font(.largeTitle.monospaced().bold()).tracking(8)
                    .multilineTextAlignment(.center).keyboardType(.numberPad)
                    .textContentType(.oneTimeCode).autocorrectionDisabled()
                    .focused($codeFocused).disabled(nearby.joining)
                    .padding(.horizontal, 16).padding(.vertical, 20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Friend’s four-digit code")
                Button(action: { AppHaptics.selection(); join() }) {
                    HStack(spacing: 10) {
                        if nearby.joining { ProgressView().tint(.white) }
                        Text(nearby.joining ? "Joining…" : "Join").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(canJoin || nearby.joining ? Color.white : Color.secondary)
                    .background(canJoin || nearby.joining ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canJoin)
            }
            if nearby.joining {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finding your friend’s workout nearby…").font(.subheadline).foregroundStyle(.secondary)
                    Button("Cancel joining", role: .cancel) { AppHaptics.selection(); nearby.stop(); joiningAttempt = false }
                        .frame(minHeight: 44)
                }
            }
            if let error = nearby.joinError {
                Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red)
            }
            if hasUnfinishedWorkout && !recoveringSession {
                Text("Finish your current workout before joining another.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var invitation: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Invite your friend").font(.title2.bold())
                    Text("Have them open Train together, enter this code, and tap Join.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                Text(nearby.code).font(.largeTitle.monospaced().bold()).tracking(8)
                    .frame(maxWidth: .infinity).padding(.vertical, 16).textSelection(.enabled)
                    .accessibilityLabel("Pairing code " + nearby.code.map(String.init).joined(separator: " "))
                Label(nearby.status, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline).foregroundStyle(.secondary)
            } footer: { Text("Share this code only with your friend. Keep Wi-Fi on and both apps open.") }
        }
    }

    private var connectionSymbols: some View {
        VStack(alignment: .leading, spacing: 24) {
            connectionSymbol("wifi", title: "Connected", detail: "Sessions are synced. You can log sets for each other.", current: nearby.connected)
            connectionSymbol("wifi.slash", title: "Disconnected", detail: "Your sets save on this phone and sync when you reconnect.", current: !nearby.connected)
            if !nearby.connected {
                if !nearby.code.isEmpty || store.state.nearbyPairing != nil {
                    Button("Reconnect Nearby") { AppHaptics.selection(); nearby.reconnect() }
                        .frame(minHeight: 44)
                } else if let workout = store.active {
                    Menu("Reconnect Nearby") {
                        Button("Show a reconnect code") {
                            AppHaptics.selection(); nearby.host(workout.id); joiningAttempt = false; step = .join
                        }
                        Button("Enter friend’s reconnect code") {
                            AppHaptics.selection(); joiningAttempt = true; step = .join
                        }
                    }.frame(minHeight: 44)
                }
            }
        }
    }

    private func connectionSymbol(_ symbol: String, title: String, detail: String, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if current {
                        Text("Current").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func join() {
        codeFocused = false
        joiningAttempt = true
        nearby.join(code: code)
    }
    private func advanceAfterJoin() {
        guard step == .join, nearby.connected, myMember != nil, store.activeMembers.contains(where: { !store.ownsProfile($0.profile.id) }),
              joiningAttempt || nearby.inviting || store.active?.ownerID == store.me.id else { return }
        nearby.endInviting()
        dismiss()
    }

}
struct ConflictView: View {
    @Environment(Store.self) private var store
    var body: some View {
        List {
            Section { Text("Both edits are preserved. Choose the version to use; the other remains in the revision history. Until resolved, summaries show a provisional version.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(store.conflicts, id: \.first!.entityID) { versions in
                Section("\(versions.count) conflicting versions") {
                    ForEach(versions) { revision in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(description(revision)).font(.headline)
                            Text("\(store.state.profiles.first { $0.id == revision.authorID }?.name ?? "Participant") · \(revision.date.formatted())").font(.caption).foregroundStyle(.secondary)
                            Button("Use this version") { AppHaptics.selection(); store.resolve(revision) }.disabled(!store.canResolve(revision))
                        }.padding(.vertical, 5)
                    }
                }
            }
            if store.conflicts.isEmpty { ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("No conflicting edits to review.")) }
        }.navigationTitle("Review edits")
    }
    private func description(_ revision: Revision) -> String {
        guard let value = revision.value else { return "Deleted item" }
        switch value {
        case .set(let set):
            let tracking = store.entries.first { $0.id == set.entryID }?.exercise.tracking ?? .weightReps
            return "Set \(set.order + 1): " + SetSummary.performance(set, tracking: tracking) + (set.warmup ? " · warm-up" : "") + (set.recordedRIRSummary.map { " · \($0) RIR" } ?? "") + (set.notes.isEmpty ? "" : " · " + set.notes)
        case .entry(let entry): return "\(entry.exercise.name) · \(entry.status.rawValue)"
        case .participant(let participant): return "\(participant.profile.name) · \(participant.day?.name ?? "Unplanned")"
        case .workout(let workout): return "\(workout.title) · \(workout.finished == nil ? "active" : "finished")"
        case .baseline(let baseline): return "Previous performance: \(baseline.previous.entry.exercise.name)"
        }
    }
}
