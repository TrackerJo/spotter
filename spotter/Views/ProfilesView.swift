import SwiftUI

struct DataProfilePicker: View {
    @Environment(Store.self) private var store
    var title = "Viewing data for"

    var body: some View {
        if store.dataProfiles.count > 1 {
            Picker(title, selection: Binding(get: { store.dataProfile.id }, set: store.viewProfile).hapticSelection()) {
                ForEach(store.dataProfiles) { profile in
                    Text(profile.id == store.me.id ? "\(profile.name) (you)" : profile.name).tag(profile.id)
                }
            }
        }
    }
}

struct ProfilesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var addingToWorkout = false
    @State private var name = ""
    @FocusState private var editingName: Bool

    private var canCreate: Bool { !store.readOnly && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!addingToWorkout || store.canAddProfiles) }

    var body: some View {
        Form {
            if !store.managedProfiles.isEmpty {
                Section {
                    ForEach(store.managedProfiles) { profile in
                        if addingToWorkout {
                            let member = store.members.first { $0.workoutID == store.active?.id && $0.profile.id == profile.id }
                            Button {
                                AppHaptics.selection()
                                _ = store.addProfileToWorkout(profile.id)
                            } label: {
                                HStack {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Spacer()
                                    if let member {
                                        Label(member.deleted ? "Removed" : (member.finished == nil ? "Added" : "Finished"), systemImage: "checkmark")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    } else {
                                        Label("Add", systemImage: "plus")
                                    }
                                }.frame(minHeight: 44)
                            }
                            .disabled(member != nil || !store.canAddProfiles)
                            .accessibilityLabel("\(profile.name), \(member == nil ? "add to workout" : "already in workout")")
                        } else {
                            NavigationLink { ProfileDetailsView(profileID: profile.id) } label: {
                                Label(profile.name, systemImage: "person.crop.circle")
                            }.buttonStyle(HapticNavigationButtonStyle())
                        }
                    }
                } header: { Text(addingToWorkout ? "Add to this workout" : "Profiles you manage") } footer: {
                    Text(addingToWorkout ? "Switch between people in the workout to log their exercises and sets." : "Each profile has its own workout history and progress. You can log for them on this phone.")
                }
            }
            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($editingName)
                    .disabled(store.readOnly)
                    .onSubmit { createProfile() }
                Button(addingToWorkout ? "Create and add to workout" : "Create profile", systemImage: "person.badge.plus") {
                    createProfile()
                }.disabled(!canCreate)
            } header: { Text("New profile") }
        }
        .navigationTitle(addingToWorkout ? "Add profiles" : "Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if addingToWorkout {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { AppHaptics.selection(); dismiss() }
                }
            }
        }
    }

    private func createProfile() {
        guard canCreate else { return }
        AppHaptics.selection()
        guard let profile = store.createProfile(name: name) else { return }
        name = ""; editingName = false
        if addingToWorkout { _ = store.addProfileToWorkout(profile.id) }
    }
}

private struct ProfileDetailsView: View {
    @Environment(Store.self) private var store
    let profileID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var name = ""
    private var profile: Profile? { store.managedProfiles.first { $0.id == profileID } }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .disabled(store.readOnly)
                Button("Save name") {
                    AppHaptics.selection()
                    if store.renameProfile(profileID, to: name) { name = profile?.name ?? name }
                }.disabled(store.readOnly || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == profile?.name)
            }
            Section {
                NavigationLink { ProgressViewScreen(profileID: profileID) } label: {
                    Label("View progress and workouts", systemImage: "chart.xyaxis.line")
                }.buttonStyle(HapticNavigationButtonStyle())
                if store.canAddProfiles && !store.members.contains(where: { $0.workoutID == store.active?.id && $0.profile.id == profileID }) {
                    Button("Add to current workout", systemImage: "person.badge.plus") {
                        AppHaptics.selection()
                        _ = store.addProfileToWorkout(profileID)
                    }
                }
            }
            Section {
                Button("Remove profile", role: .destructive) { confirmingRemoval = true }
                    .disabled(!store.canRemoveProfile(profileID))
            } footer: {
                if !store.readOnly && !store.canRemoveProfile(profileID) {
                    Text("Finish this profile’s active workout before removing it.")
                }
            }
        }
        .confirmationDialog("Remove \(profile?.name ?? "profile")?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove profile", role: .destructive) {
                AppHaptics.selection()
                if store.removeProfile(profileID) { dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This profile will be hidden. Saved workout records will be kept.")
        }
        .navigationTitle(profile?.name ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = profile?.name ?? "" }
    }
}
