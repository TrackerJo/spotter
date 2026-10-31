import SwiftUI

struct SetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: Store
    @State private var set: WorkoutSet
    @State private var weight: String
    @State private var reps: String
    @State private var rir: String
    @State private var seconds: String
    @State private var distance: String
    @State private var distanceUnit: USDistanceUnit
    @State private var invalid = false
    @State private var moreOptions = false
    @State private var saveError: String?
    private enum InputField: Hashable { case weight, reps, rir, seconds, distance }
    @FocusState private var focused: InputField?
    @State private var visitedFields: Set<InputField> = []
    @State private var parents: [String]
    private let isEditing: Bool
    private let original: WorkoutSet

    init(store: Store, initial: WorkoutSet) {
        self.store = store
        original = initial
        var poundsSet = initial; poundsSet.weight = initial.weightPounds; poundsSet.unit = .lb
        _set = State(initialValue: poundsSet)
        _weight = State(initialValue: Self.editable(initial.weightPounds))
        _reps = State(initialValue: initial.performedReps?.formatted(.number.grouping(.never)) ?? "")
        _rir = State(initialValue: initial.rir.map(String.init) ?? "")
        _seconds = State(initialValue: initial.seconds.map { $0.formatted(.number.grouping(.never)) } ?? "")
        let unit = USDistanceUnit.preferred(for: initial.meters ?? 0)
        _distanceUnit = State(initialValue: unit)
        _distance = State(initialValue: Self.editableDistance(initial.meters.map { unit.value(meters: $0) }, unit: unit))
        _parents = State(initialValue: store.state.ledger.heads(initial.id).map(\.id))
        isEditing = !store.state.ledger.heads(initial.id).isEmpty
    }
    private var entry: ExerciseEntry? { store.entries.first { $0.id == set.entryID } }
    private var tracking: Tracking { entry?.exercise.tracking ?? .weightReps }
    private var targetSlot: Int? {
        guard !set.warmup, let entry else { return nil }
        if let slot = set.prescribedIndex { return slot }
        if isEditing && !original.warmup { return nil }
        let used = Set(store.sets(for: entry).filter { $0.id != set.id && !$0.warmup && $0.completed }.compactMap(\.prescribedIndex))
        return (0..<(entry.target?.sets ?? 0)).first { !used.contains($0) }
    }
    var body: some View {
        Form {
            if let explanation = store.partnerEditingUnavailable {
                Section { Label(explanation, systemImage: "lock.fill").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Picker("Set type", selection: $set.warmup.hapticSelection()) {
                    Text("Working set").tag(false)
                    Text("Warm-up").tag(true)
                }.pickerStyle(.segmented).listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if tracking == .weightReps || tracking == .assisted {
                    HStack {
                        Text(tracking == .assisted ? "Assistance" : "Weight")
                        Spacer()
                        TextField("0", text: $weight).accessibilityLabel("Weight").keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focused, equals: .weight)
                        Text("lb").foregroundStyle(.secondary)
                    }
                }
                if tracking == .weightReps || tracking == .assisted || tracking == .bodyweight { numberField("Reps", text: $reps, field: .reps, decimal: true) }
                if tracking == .timed || tracking == .distance { numberField("Seconds", text: $seconds, field: .seconds, decimal: true) }
                if tracking == .distance {
                    HStack {
                        Text("Distance")
                        Spacer()
                        TextField("0", text: $distance).accessibilityLabel("Distance in \(distanceUnit.name.lowercased())").keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focused, equals: .distance)
                        Picker("Distance unit", selection: $distanceUnit.hapticSelection()) { ForEach(USDistanceUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RIR")
                        if let target = entry?.target?.rirTarget(for: targetSlot) {
                            Text("Target: \(target.summary)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    TextField("Optional", text: $rir)
                        .accessibilityLabel("Actual reps in reserve")
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focused, equals: .rir)
                        .frame(minWidth: 60)
                }
                if invalid { Text("Enter valid numbers. Reps, time and distance must be positive; weight may be zero.").font(.footnote).foregroundStyle(.red) }
                if let saveError { Text(saveError).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text(entry.map { store.name($0.exercise, personID: set.personID) } ?? "Exercise")
                    .textCase(nil)
            }
            Section {
                DisclosureGroup("More options", isExpanded: $moreOptions) {
                    TextField("Notes", text: $set.notes, axis: .vertical)
                    if let exercise = entry?.exercise, let next = store.progression(exercise, personID: set.personID)?.nextWeightPounds {
                        Button("Use suggested \(next.formatted(.number.precision(.fractionLength(0...2)))) lb") { weight = Self.editable(next); visitedFields.insert(.weight); AppHaptics.selection() }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .safeAreaInset(edge: .bottom) {
            Button { AppHaptics.selection(); log() } label: { Text(isEditing ? "Save changes" : "Log set").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).padding(.horizontal).padding(.vertical, 10)
                .disabled(!store.canSaveSet(set) || store.state.ledger.heads(set.id).count > 1)
        }
        .onChange(of: focused) { _, field in
            guard !isEditing, let field, visitedFields.insert(field).inserted else { return }
            switch field {
            case .weight: weight = ""
            case .reps: reps = ""
            case .rir: rir = ""
            case .seconds: seconds = ""
            case .distance: distance = ""
            }
        }
        .onChange(of: set.warmup) { _, _ in AppHaptics.selection() }
        .onChange(of: distanceUnit) { old, new in
            AppHaptics.selection()
            if let value = Double(distance.replacingOccurrences(of: ",", with: ".")) {
                let originalValue = original.meters.map { old.value(meters: $0) }
                let meters = distance == Self.editableDistance(originalValue, unit: old) ? (original.meters ?? old.meters(value)) : old.meters(value)
                distance = Self.editableDistance(new.value(meters: meters), unit: new)
            }
        }
        .navigationTitle(isEditing ? "Edit set" : "Log set").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { AppHaptics.selection(); dismiss() } }
        }
    }
    private static func editable(_ value: Double?) -> String {
        value?.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) ?? ""
    }
    private static func editableDistance(_ value: Double?, unit: USDistanceUnit) -> String {
        value?.formatted(.number.grouping(.never).precision(.fractionLength(unit == .miles ? 0...6 : 0...2))) ?? ""
    }
    private func numberField(_ title: String, text: Binding<String>, field: InputField, decimal: Bool, placeholder: String = "0") -> some View {
        HStack { Text(title); Spacer(); TextField(placeholder, text: text).accessibilityLabel(title).keyboardType(decimal ? .decimalPad : .numberPad).multilineTextAlignment(.trailing).focused($focused, equals: field).frame(minWidth: 60) }
    }
    private func log() {
        let decimals = [weight, seconds, distance]
        guard decimals.allSatisfy({ $0.isEmpty || Double($0.replacingOccurrences(of: ",", with: ".")) != nil }),
              (reps.isEmpty || Double(reps.replacingOccurrences(of: ",", with: ".")) != nil), (rir.isEmpty || Int(rir) != nil) else { invalid = true; AppHaptics.notification(.error); return }
        set.weight = weight == Self.editable(original.weightPounds) ? original.weightPounds : Double(weight.replacingOccurrences(of: ",", with: "."))
        set.unit = .lb
        let performed = Double(reps.replacingOccurrences(of: ",", with: "."))
        set.reps = performed.flatMap { $0.isFinite && $0 > 0 && $0 <= Double(Int.max / 2) && $0.rounded(.towardZero) == $0 ? Int($0) : nil }
        set.fractionalReps = set.reps == nil ? performed : nil
        set.rir = Int(rir)
        if rir != (original.rir.map(String.init) ?? "") { set.recordedRIRRange = nil }
        set.seconds = Double(seconds.replacingOccurrences(of: ",", with: "."))
        let originalDistance = original.meters.map { distanceUnit.value(meters: $0) }
        set.meters = distance == Self.editableDistance(originalDistance, unit: distanceUnit) ? original.meters : Double(distance.replacingOccurrences(of: ",", with: ".")).map(distanceUnit.meters)
        guard set.isComplete(for: tracking) else { invalid = true; AppHaptics.notification(.error); return }
        invalid = false
        if set.warmup { set.prescribedIndex = nil }
        else if let entry, !isEditing || original.warmup {
            let used = Set(store.sets(for: entry).filter { $0.id != set.id && !$0.warmup && $0.completed }.compactMap(\.prescribedIndex))
            set.prescribedIndex = (0..<(entry.target?.sets ?? 0)).first { !used.contains($0) }
        }
        guard store.saveSet(set, parents: parents) else { saveError = store.error ?? "This set could not be saved. Try again."; return }
        AppHaptics.notification(.success)
        dismiss()
    }
}
struct EntryTargetsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: ExerciseEntry
    @State private var target: Target
    @State private var parents: [String]
    init(entry: ExerciseEntry, parents: [String]) {
        self.entry = entry; _target = State(initialValue: entry.target ?? Target())
        _parents = State(initialValue: parents)
    }
    private var locked: Bool { !store.sets(for: entry).isEmpty }
    var body: some View {
        Form {
            if let explanation = store.partnerEditingUnavailable {
                Section { Label(explanation, systemImage: "lock.fill").font(.footnote).foregroundStyle(.secondary) }
            }
            TargetFields(target: $target, tracking: entry.exercise.tracking).disabled(locked || !store.canLog)
        }.navigationTitle("Exercise targets").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { AppHaptics.selection(); if store.canLog && !locked && target.valid { var updated = entry; updated.target = target; guard store.write(.entry(updated), parents: parents) else { return } }; dismiss() }.disabled(!target.valid) } }
    }
}
struct TargetFields: View {
    @Binding var target: Target
    var tracking: Tracking = .weightReps
    @State private var distanceUnit: USDistanceUnit = .miles
    var body: some View {
        Section("Goal") {
            TargetNumberField(title: "Working sets", accessibilityTitle: "Working sets", value: $target.sets, range: 1...20)
            if tracking == .timed || tracking == .distance {
                Toggle("Time target", isOn: Binding(get: { target.seconds != nil }, set: { target.seconds = $0 ? 60 : nil }).hapticSelection())
                if target.seconds != nil { TargetDecimalField(title: "Seconds", value: Binding(get: { target.seconds ?? 60 }, set: { target.seconds = $0 }), range: 5...7200) }
                if tracking == .distance {
                    Toggle("Distance target", isOn: Binding(get: { target.meters != nil }, set: { target.meters = $0 ? distanceUnit.meters(distanceUnit == .miles ? 1 : 100) : nil }).hapticSelection())
                    if target.meters != nil {
                        Picker("Distance unit", selection: $distanceUnit.hapticSelection()) { ForEach(USDistanceUnit.allCases) { Text($0.name).tag($0) } }
                        TargetDecimalField(title: distanceUnit.name, value: Binding(get: { distanceUnit.value(meters: target.meters ?? 0) }, set: { target.meters = distanceUnit.meters($0) }), range: distanceUnit == .feet ? 1...1_000_000 : 0.01...200)
                    }
                }
            } else {
                TargetNumberField(title: "Minimum reps", accessibilityTitle: "Minimum reps", value: Binding(get: { target.low }, set: { low in
                    target.low = low
                    target.high = max(low, target.high)
                }), range: 1...100)
                TargetNumberField(title: "Maximum reps", accessibilityTitle: "Maximum reps", value: Binding(get: { target.high }, set: { high in
                    target.high = high
                    target.low = min(high, target.low)
                }), range: 1...100)
            }
        }
        Section {
            Toggle("Target RIR", isOn: Binding(get: { target.rir != nil || target.rirRange != nil || target.perSetRIR != nil }, set: { enabled in
                target.rir = enabled ? 2 : nil
                target.rirRange = nil
                target.perSetRIR = nil
            }).hapticSelection())
            if target.rir != nil || target.rirRange != nil || target.perSetRIR != nil {
                Picker("Apply target", selection: Binding(get: { target.perSetRIR != nil }, set: { enabled in
                    if enabled {
                        target.perSetRIR = Array(repeating: target.rirRange ?? RIRTarget(low: target.rir ?? 2, high: target.rir ?? 2), count: target.sets)
                        target.rir = nil
                        target.rirRange = nil
                    } else {
                        let shared = target.perSetRIR?.compactMap { $0 }.first ?? RIRTarget(low: 2, high: 2)
                        target.rir = shared.low == shared.high ? shared.low : nil
                        target.rirRange = shared.low == shared.high ? nil : shared
                        target.perSetRIR = nil
                    }
                }).hapticSelection()) {
                    Text("All sets").tag(false)
                    Text("Per set").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Apply RIR target to all sets or per set")
                if target.perSetRIR != nil {
                    ForEach(0..<target.sets, id: \.self) { index in
                        RIRTargetFields(number: index + 1, value: Binding(get: {
                            guard let values = target.perSetRIR, values.indices.contains(index) else { return nil }
                            return values[index]
                        }, set: { value in
                            target.resizeRIRTargets()
                            target.perSetRIR?[index] = value
                        }))
                    }
                } else {
                    RIRTargetFields(number: nil, value: Binding(get: {
                        target.rirRange ?? target.rir.map { RIRTarget(low: $0, high: $0) }
                    }, set: { shared in
                        target.rir = shared.flatMap { $0.low == $0.high ? $0.low : nil }
                        target.rirRange = shared.flatMap { $0.low == $0.high ? nil : $0 }
                    }))
                }
            }
        } header: {
            Text("Effort target")
        }
        Section("Notes") {
            TextField("Notes", text: $target.notes, axis: .vertical)
        }.onChange(of: target.sets) { target.resizeRIRTargets() }
        .onAppear { if let meters = target.meters { distanceUnit = USDistanceUnit.preferred(for: meters) } }
    }
}

private struct RIRTargetFields: View {
    private enum Mode: String, CaseIterable {
        case none = "No target", exact = "Exact", range = "Range"
    }

    let number: Int?
    private var title: String { number.map { "Set \($0)" } ?? "All sets" }
    private var modes: [Mode] { number == nil ? [.exact, .range] : Mode.allCases }
    @Binding var value: RIRTarget?
    @State private var editingRange = false

    private var mode: Mode {
        guard let value else { return .none }
        return editingRange || value.low != value.high ? .range : .exact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
                Picker("\(title) target type", selection: Binding(get: { mode }, set: { selected in
                    editingRange = selected == .range
                    switch selected {
                    case .none: value = nil
                    case .exact:
                        let rir = value?.low ?? 2
                        value = RIRTarget(low: rir, high: rir)
                    case .range:
                        let low = value?.low ?? 2
                        value = RIRTarget(low: low, high: value?.high ?? min(low + 1, 10))
                    }
                }).hapticSelection()) {
                    ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
            }

            if value != nil {
                if mode == .range {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { minimumField; maximumField }
                        VStack(spacing: 4) { minimumField; maximumField }
                    }
                } else {
                    TargetNumberField(title: "RIR", accessibilityTitle: "\(title) RIR", value: Binding(
                        get: { value?.low ?? 2 },
                        set: { value = RIRTarget(low: $0, high: $0) }
                    ))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var minimumField: some View {
        TargetNumberField(title: "Min", accessibilityTitle: "\(title) minimum RIR", value: Binding(
            get: { value?.low ?? 2 },
            set: { low in value = RIRTarget(low: low, high: max(low, value?.high ?? low)) }
        ))
    }

    private var maximumField: some View {
        TargetNumberField(title: "Max", accessibilityTitle: "\(title) maximum RIR", value: Binding(
            get: { value?.high ?? 2 },
            set: { high in value = RIRTarget(low: min(high, value?.low ?? high), high: high) }
        ))
    }
}

private struct TargetNumberField: View {
    let title: String
    let accessibilityTitle: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...10
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            TextField("0", text: $draft)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 56, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .focused($focused)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityHint("Enter a number from \(range.lowerBound) to \(range.upperBound)")
                .onChange(of: draft) { _, text in
                    guard !text.isEmpty else { return }
                    guard let number = Int(text), number >= 0, number <= range.upperBound else {
                        draft = String(value)
                        return
                    }
                    if range.contains(number) { value = number }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { draft = String(value) }
                }
                .onChange(of: value) { _, updated in
                    if !focused { draft = String(updated) }
                }
                .onAppear { draft = String(value) }
                .toolbar {
                    if focused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { AppHaptics.selection(); focused = false }
                        }
                    }
                }
        }
    }
}

private struct TargetDecimalField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var formattedValue: String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            TextField("0", text: $draft)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(minWidth: 80, maxWidth: 140, minHeight: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .focused($focused)
                .accessibilityLabel(title)
                .onChange(of: draft) { _, text in
                    guard !text.isEmpty else { return }
                    let normalized = text.replacingOccurrences(of: ",", with: ".")
                    if normalized == "." { return }
                    guard let number = Double(normalized), number.isFinite,
                          number >= 0, number <= range.upperBound else {
                        draft = formattedValue
                        return
                    }
                    if range.contains(number) { value = number }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { draft = formattedValue }
                }
                .onChange(of: value) { _, _ in
                    if !focused { draft = formattedValue }
                }
                .onAppear { draft = formattedValue }
                .toolbar {
                    if focused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { AppHaptics.selection(); focused = false }
                        }
                    }
                }
        }
    }
}
