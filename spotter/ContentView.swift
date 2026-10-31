import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(NearbySync.self) private var nearby
    @Environment(CloudSync.self) private var cloud
    @Environment(\.scenePhase) private var phase
    @State private var liveActivity = WorkoutLiveActivity()
    @State private var activitySet: WorkoutSet?
    @State private var tab = 0
    @State private var showSettings = false
    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Workout", systemImage: "dumbbell", value: 0) { NavigationStack { WorkoutView().toolbar { accountButton } } }
            Tab("Plans", systemImage: "list.bullet.rectangle", value: 1) { NavigationStack { PlansView().toolbar { accountButton } } }
            Tab("Progress", systemImage: "chart.xyaxis.line", value: 2) { NavigationStack { ProgressViewScreen().toolbar { accountButton } } }
            Tab("Library", systemImage: "books.vertical", value: 3) { NavigationStack { LibraryView().toolbar { accountButton } } }
        }
        .onAppear { liveActivity.update(store.workoutActivitySnapshot) }
        .onChange(of: store.workoutActivitySnapshot) { _, snapshot in liveActivity.update(snapshot) }
        .onChange(of: phase) { _, phase in
            if phase == .active { liveActivity.update(store.workoutActivitySnapshot) }
        }
        .onOpenURL { url in
            guard url.scheme == "spotter", url.host == "log-set",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let workoutID = components.queryItems?.first(where: { $0.name == "workout" })?.value,
                  let snapshot = store.workoutActivitySnapshot, snapshot.workoutID == workoutID else { return }
            tab = 0
            store.selectPerson(store.me.id)
            guard let entryID = components.queryItems?.first(where: { $0.name == "entry" })?.value,
                  snapshot.entryID == entryID, store.canLog,
                  let entry = store.myEntries.first(where: { $0.id == entryID }) else { return }
            showSettings = false
            activitySet = store.makeSet(entry)
        }
        .sheet(item: $activitySet) { set in
            NavigationStack { SetEditor(store: store, initial: set) }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .background(NativeControlHaptics().allowsHitTesting(false))
        .onChange(of: tab) { _, _ in AppHaptics.selection() }
        .onChange(of: store.person.id) { _, _ in AppHaptics.selection() }
        .onChange(of: store.error) { _, error in
            if error != nil { AppHaptics.notification(.error) }
        }
        .onChange(of: store.active?.isPreparing) { old, new in
            if old == true && new == false { AppHaptics.impact() }
        }
        .onChange(of: store.state.activeWorkoutID) { old, new in
            if old == nil && new != nil { AppHaptics.impact() }
        }
        .onChange(of: store.undoRevision?.id) { old, new in
            if new != nil { AppHaptics.impact() }
            else if old != nil && store.error == nil { AppHaptics.selection() }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .alert("Needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { AppHaptics.selection(); store.error = nil } } message: { Text(store.error ?? "") }
        .onChange(of: store.state.activeWorkoutID) { _, id in
            if let id, let nearbyID = nearby.workoutID, id != nearbyID { nearby.stop() }
        }
        .task(id: phase) {
            guard phase == .active else { _ = store.save(notify: false); if phase == .background { nearby.suspend() }; return }
            nearby.resume()
            if !cloud.enabled { await cloud.connect() }
            while !Task.isCancelled {
                await cloud.sync()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    private var accountButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { Button { AppHaptics.selection(); showSettings = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Profile and settings") }
    }
}
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var connecting = false
    @AppStorage(AppHaptics.preferenceKey) private var hapticsEnabled = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Your name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityLabel("Your name")
                        .disabled(store.readOnly)
                        .onChange(of: name) { _, value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, trimmed != store.me.name else { return }
                            _ = store.renameProfile(store.me.id, to: trimmed)
                        }
                }
            } header: {
                Text("About you")
            }

            Section {
                NavigationLink { ProfilesView() } label: {
                    Label("Manage profiles", systemImage: "person.2")
                }.buttonStyle(HapticNavigationButtonStyle())
            }

            Section {
                AccountConnectionHeader(
                    title: "iCloud",
                    systemImage: "icloud",
                    status: connecting ? "Connecting…" : cloud.status
                )
                if let lastSync = cloud.lastSync {
                    LabeledContent("Last synced") {
                        Text(lastSync, style: .relative).foregroundStyle(.secondary)
                    }
                }
                if !cloud.enabled {
                    Button { AppHaptics.selection();
                        connecting = true
                        Task {
                            await cloud.connect()
                            connecting = false
                        }
                    } label: {
                        HStack {
                            Text(connecting ? "Connecting…" : "Connect to iCloud")
                            Spacer()
                            if connecting { ProgressView() }
                        }
                    }
                    .disabled(connecting || store.readOnly)
                }
            } footer: {
                Text("Sync plans, workout history, exercises, and settings privately across your devices.")
            }

            ChatGPTAccountSection()

            Section("Feedback") {
                Toggle("Haptic feedback", isOn: $hapticsEnabled.hapticSelection())
            }

            Section {
                Label(store.readOnly ? "Saved data needs attention" : "Workout storage and iCloud sync", systemImage: store.readOnly ? "exclamationmark.triangle" : "externaldrive.badge.icloud")
                if !store.conflicts.isEmpty {
                    NavigationLink("Review \(store.conflicts.count) conflicts") { ConflictView() }.buttonStyle(HapticNavigationButtonStyle())
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Workouts are saved on this iPhone and sync privately to iCloud when connected. Shared sessions sync only through Nearby with both apps open.")
            }
        }
        .navigationTitle("Profile")
        .modifier(ChatGPTWelcomeModifier())
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { AppHaptics.selection(); dismiss() }
            }
        }
        .onAppear { name = store.me.name }
    }
}

/// Semantic, foreground-only feedback. UIKit quietly ignores unsupported hardware.
@MainActor
enum AppHaptics {
    static let preferenceKey = "hapticsEnabled"
    private static var lastSelection = Date.distantPast
    private static var enabled: Bool {
        (UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true)
            && UIApplication.shared.applicationState == .active
    }
    static func selection() {
        guard enabled else { return }
        // A native control and its SwiftUI wrapper can observe the same tap.
        let now = Date()
        guard now.timeIntervalSince(lastSelection) > 0.08 else { return }
        lastSelection = now
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func impact() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

/// Run feedback and the link's original activation in one button action.
/// No extra tap recognizer or destination lifecycle callback is involved.
struct HapticNavigationButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            AppHaptics.selection()
            configuration.trigger()
        } label: {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.automatic)
    }
}

/// Open an external destination through the same user-initiated feedback path
/// as buttons, including VoiceOver activation.
struct HapticLink: View {
    @Environment(\.openURL) private var openURL
    let title: String
    let destination: URL
    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }
    var body: some View {
        Button {
            AppHaptics.selection()
            openURL(destination)
        } label: { Text(title) }
        .accessibilityAddTraits(.isLink)
    }
}

extension Binding {
    /// Feedback for user-driven changes, including picker menus and accessibility.
    func hapticSelection() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { value in
            wrappedValue = value
            AppHaptics.selection()
        })
    }
}

/// Covers native controls and all text inputs, including system back/search buttons
/// and inputs presented in sheets. Observe completed taps without consuming them.
private struct NativeControlHaptics: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) {}
    static func dismantleUIView(_ view: Observer, coordinator: ()) {
        view.tap.view?.removeGestureRecognizer(view.tap)
    }

    final class Observer: UIView, UIGestureRecognizerDelegate {
        lazy var tap: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(feedback))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            return gesture
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.addGestureRecognizer(tap)
        }

        @objc private func feedback() { AppHaptics.selection() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var candidate = touch.view
            var isControl = false
            while let view = candidate {
                if let control = view as? UIControl, !control.isEnabled { return false }
                if let field = view as? UITextField { return field.isEnabled }
                if let editor = view as? UITextView { return editor.isEditable }
                if view is UIControl || view.accessibilityTraits.contains(.button) { isControl = true }
                if view is UINavigationBar { return isControl }
                candidate = view.superview
            }
            return isControl
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
