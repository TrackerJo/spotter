import SwiftUI
import Charts

struct ProgressViewScreen: View {
    @Environment(Store.self) private var store
    var profileID: String? = nil
    private var profile: Profile { store.state.profiles.first { $0.id == profileID } ?? store.dataProfile }
    @State private var period = "This year"
    @State private var exerciseID = "bench-barbell"
    @State private var metric = "Weight"
    @State private var choose = false
    @State private var importHistory = false
    @State private var showingChatGPT = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var since: Date {
        switch period {
        case "30 days": Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        case "90 days": Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        case "This year": Calendar.current.dateInterval(of: .year, for: Date())!.start
        default: .distantPast
        }
    }
    private var points: [TrendPoint] { ProgressEngine.trends(personID: profile.id, exerciseID: exerciseID, since: since, ledger: store.state.ledger) }
    private var summary: TrainingSummary { ProgressEngine.summary(personID: profile.id, since: since, ledger: store.state.ledger) }
    private struct WorkoutVolumePoint: Identifiable {
        let id: String
        let title: String
        let date: Date
        let volume: Double
    }
    private var volumePoints: [WorkoutVolumePoint] {
        store.state.ledger.workouts(for: profile.id)
            .filter { $0.finished != nil && $0.started >= since }
            .sorted { $0.started < $1.started }
            .map { workout in
                let entries = store.entries.filter { $0.workoutID == workout.id && $0.personID == profile.id }
                return WorkoutVolumePoint(id: workout.id, title: workout.title, date: workout.started,
                                          volume: ProgressEngine.volumePounds(entries: entries, sets: store.sets))
            }
    }
    private var exercise: Exercise? { store.exercise(exerciseID) }
    private var metrics: [String] {
        switch exercise?.tracking {
        case .timed: ["Seconds"]
        case .distance: ["Distance", "Seconds"]
        case .bodyweight: ["Reps"]
        case .assisted: ["Assistance", "Reps"]
        default: ["Weight", "Reps", "Est. 1RM"]
        }
    }
    var body: some View {
        List {
            Section {
                if profileID == nil { DataProfilePicker() }
                else { LabeledContent("Viewing data for", value: profile.name) }
                if profile.isDemo { Label("Sample history", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                Picker("Time period", selection: $period.hapticSelection()) { ForEach(["30 days", "90 days", "This year", "All time"], id: \.self) { Text($0).tag($0) } }
                    .simultaneousGesture(TapGesture().onEnded { AppHaptics.selection() })
                NavigationLink { WorkoutHistoryListView(personID: profile.id) } label: {
                    Label("Past workouts", systemImage: "clock.arrow.circlepath")
                }.buttonStyle(HapticNavigationButtonStyle())
            }
            if store.ownsProfile(profile.id) && !profile.isDemo { Section {
                Button {
                    AppHaptics.selection()
                    showingChatGPT = true
                } label: {
                    HStack {
                        Label(profile.id == store.me.id ? "Ask ChatGPT about your progress" : "Ask ChatGPT about \(profile.name)’s progress", systemImage: "bubble.left.and.bubble.right")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.tint(.primary)
            } }
            Section("Training summary") {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) { summaryTotals }
                    } else {
                        HStack(alignment: .top, spacing: 16) { summaryTotals }
                    }
                }.padding(.vertical, 4)
                if summary.workouts > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Workouts per week").font(.caption).foregroundStyle(.secondary)
                        Chart(weeks, id: \.date) { point in
                            BarMark(x: .value("Week", point.date, unit: .weekOfYear), y: .value("Workouts", point.count))
                                .foregroundStyle(.indigo)
                        }
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                        .frame(height: 100)
                        .accessibilityLabel("Completed workouts by week, including weeks with no workouts")
                    }.padding(.vertical, 4)
                }
                DisclosureGroup("About training volume") {
                    Text("Weight × reps across working sets, in lb·reps. Warm-ups, assisted, bodyweight and timed exercises are excluded. Volume measures workload, not strength.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.font(.subheadline)
            }
            Section("Exercise performance") {
                Button { AppHaptics.selection(); choose = true } label: { HStack { Text(exercise.map { store.name($0, personID: profile.id) } ?? "Choose exercise").font(.headline); Spacer(); Image(systemName: "chevron.up.chevron.down") } }
                Picker("Measure", selection: $metric.hapticSelection()) { ForEach(metrics, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                if points.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No workouts in this period").font(.headline)
                        Text("Log \(exercise.map { store.name($0, personID: profile.id) } ?? "this exercise") in a workout, or choose a different time period to see earlier sessions.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                } else {
                    Text(metric == "Est. 1RM" ? "Estimated one-rep max · lb" : "Best \(metric.lowercased()) each workout · \(metricUnit)").font(.subheadline).foregroundStyle(.secondary)
                    Chart(points) { point in
                        if let value = value(point) {
                            LineMark(x: .value("Workout", point.date), y: .value("\(metric) (\(metricUnit))", value)).foregroundStyle(.indigo)
                            PointMark(x: .value("Workout", point.date), y: .value("\(metric) (\(metricUnit))", value)).foregroundStyle(.indigo)
                        }
                    }.frame(height: 160).chartYScale(domain: .automatic(includesZero: false)).accessibilityLabel("\(metric) in \(metricUnit) per workout for \(exercise?.name ?? "exercise")")
                    if let best = points.compactMap({ value($0) }).max() { LabeledContent(metric == "Assistance" ? "Highest assistance in period" : "Best in selected period", value: best.formatted(.number.precision(.fractionLength(0...2))) + " " + metricUnit) }
                    if points.count > 1, let last = points.last.flatMap(value), let previous = points.dropLast().last.flatMap(value) {
                        LabeledContent("Change from previous workout", value: (last - previous).formatted(.number.sign(strategy: .always()).precision(.fractionLength(0...2))) + " " + metricUnit)
                    }
                    if metric == "Assistance" { Text("Less assistance can indicate improvement. Assistance is not external lifted weight.").font(.caption).foregroundStyle(.secondary) }
                    if exercise?.tracking == .weightReps && metric == "Est. 1RM" {
                        if metric == "Est. 1RM", points.allSatisfy({ $0.estimatedMax == nil }) { Text("No estimate available. Log an external-weight set of 1–12 reps to show this trend.").font(.subheadline).foregroundStyle(.secondary) }
                        DisclosureGroup("About estimated 1RM") {
                            Text("Uses weight × (1 + (reps + RIR) ÷ 30), for working sets of 1–12 performed reps. Uses recorded RIR, or 0 if missing; recorded RIR ranges use their midpoint. This is an estimate, not a tested maximum.").font(.footnote).foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }
                }
            }
            Section("Training volume per workout") {
                if volumePoints.isEmpty {
                    Text("Log a workout or choose a different time period to see training volume.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Working-set weight × reps · lb·reps")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Chart(volumePoints) { point in
                        BarMark(x: .value("Workout", point.date), y: .value("Volume (lb·reps)", point.volume))
                            .foregroundStyle(.indigo)
                    }
                    .frame(height: 160)
                    .accessibilityLabel("Training volume in pound reps per workout")
                    ForEach(volumePoints.reversed()) { point in
                        LabeledContent {
                            Text(point.volume.formatted(.number.precision(.fractionLength(0...1))) + " lb·reps")
                                .monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.title)
                                Text(point.date, format: .dateTime.month(.abbreviated).day().year())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Muscle-group exposure") {
                if summary.exposure.isEmpty {
                    Text("Log working sets to see which muscle groups you train.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Working sets by primary muscle group").font(.subheadline).foregroundStyle(.secondary)
                    Chart(summary.exposure.keys.sorted(), id: \.self) { muscle in BarMark(x: .value("Working sets", summary.exposure[muscle] ?? 0), y: .value("Muscle", muscle)).foregroundStyle(.indigo) }.frame(height: CGFloat(max(140, summary.exposure.count * 32)))
                    if !summary.monthlyExposure.isEmpty {
                        Chart(exposurePoints, id: \.id) { point in BarMark(x: .value("Month", point.date, unit: .month), y: .value("Sets", point.count)).foregroundStyle(by: .value("Muscle", point.muscle)) }.frame(height: 200)
                    }
                    DisclosureGroup("About muscle groups") {
                        Text("Sets count toward the primary muscle only. Secondary muscles are listed in the library. This describes training exposure, not muscle growth.").font(.footnote).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
            }
            if !points.isEmpty {
                Section("Recorded sessions") {
                    ForEach(points.reversed()) { point in
                        if let workout = store.workouts.first(where: { $0.id == point.id }) {
                            NavigationLink { WorkoutHistoryView(workout: workout, personID: profile.id) } label: { HStack { Text(point.date, format: .dateTime.month(.abbreviated).day()); Spacer(); Text(value(point).map { $0.formatted(.number.precision(.fractionLength(0...2))) + " " + metricUnit } ?? "—").monospacedDigit() } }.buttonStyle(HapticNavigationButtonStyle())
                        .modifier(WorkoutDeleteAction(workout: workout, personID: profile.id))
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Import history", systemImage: "square.and.arrow.down") { AppHaptics.selection(); importHistory = true }.disabled(store.readOnly || profile.isDemo || !store.ownsProfile(profile.id)) } }
        .navigationDestination(isPresented: $showingChatGPT) { ChatGPTChatView(profileID: profile.id) }
        .sheet(isPresented: $importHistory) { NavigationStack { WorkoutImportView(profileID: profile.id) } }
        .sheet(isPresented: $choose) { NavigationStack { ExerciseChooser(onSelect: { exerciseID = $0.id; choose = false; metric = metrics.first ?? "Weight" }, libraryOnly: true, personID: profile.id) } }
    }
    @ViewBuilder private var summaryTotals: some View {
        summaryTotal("Workouts", value: String(summary.workouts))
        summaryTotal("Working sets", value: String(summary.workingSets))
        summaryTotal("Volume · lb·reps", value: summary.volumePounds.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
    }

    private func summaryTotal(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var distanceUnit: USDistanceUnit { USDistanceUnit.preferred(for: points.compactMap(\.meters).max() ?? 0) }
    private var metricUnit: String {
        switch metric { case "Reps": "reps"; case "Seconds": "sec"; case "Distance": distanceUnit.rawValue; default: "lb" }
    }
    private func value(_ point: TrendPoint) -> Double? {
        switch metric {
        case "Reps": point.reps
        case "Est. 1RM": point.estimatedMax.map(WeightUnit.kg.pounds)
        case "Seconds": point.seconds
        case "Distance": point.meters.map { distanceUnit.value(meters: $0) }
        default: point.weight.map(WeightUnit.kg.pounds)
        }
    }
    private var weeks: [(date: Date, count: Int)] {
        let first = period == "All time" ? (summary.weeklyWorkouts.keys.min() ?? Date()) : since
        var date = Calendar.current.dateInterval(of: .weekOfYear, for: first)!.start
        var result: [(Date, Int)] = []
        while date <= Date(), result.count < 520 { result.append((date, summary.weeklyWorkouts[date] ?? 0)); date = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: date)! }
        return result
    }
    private var exposurePoints: [ExposurePoint] { summary.monthlyExposure.flatMap { date, groups in groups.map { ExposurePoint(date: date, muscle: $0.key, count: $0.value) } }.sorted { $0.date < $1.date } }
}
private struct ExposurePoint { var date: Date; var muscle: String; var count: Int; var id: String { "\(date)-\(muscle)" } }


private struct WorkoutHistoryListView: View {
    @Environment(Store.self) private var store
    let personID: String
    @State private var query = ""
    @State private var sort = HistorySort.newest

    private enum HistorySort: String, CaseIterable {
        case newest = "Newest first"
        case oldest = "Oldest first"
        case title = "Name A–Z"
        case longest = "Longest first"
    }

    private struct HistoryRow: Identifiable {
        var workout: Workout
        var exercises: String
        var setCount: Int
        var searchText: String
        var id: String { workout.id }
        var duration: TimeInterval { max(0, (workout.finished ?? workout.started).timeIntervalSince(workout.started)) }
    }

    private var history: [HistoryRow] {
        let memberIDs = Set(store.members.filter { $0.profile.id == personID && !$0.deleted }.map(\.workoutID))
        let entries = Dictionary(grouping: store.entries.filter { $0.personID == personID }, by: \.workoutID)
        let setCounts = Dictionary(grouping: store.sets.filter { $0.personID == personID && $0.completed }, by: \.workoutID).mapValues(\.count)
        return store.workouts.map { store.personalWorkout($0, personID: personID) }
            .filter { !$0.isPreparing && $0.finished != nil && memberIDs.contains($0.id) }
            .map { workout in
                let names = (entries[workout.id] ?? []).sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
                    .map { store.name($0.exercise, personID: personID) }
                let originalNames = (entries[workout.id] ?? []).map { $0.exercise.name }
                let date = workout.started.formatted(date: .complete, time: .omitted)
                return HistoryRow(workout: workout, exercises: names.joined(separator: ", "), setCount: setCounts[workout.id] ?? 0,
                                  searchText: ([workout.title, date] + names + originalNames).joined(separator: " "))
            }
    }

    private func results(from history: [HistoryRow]) -> [HistoryRow] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return history.filter { row in terms.allSatisfy { row.searchText.localizedStandardContains($0) } }
            .sorted { lhs, rhs in
                switch sort {
                case .newest:
                    if lhs.workout.started != rhs.workout.started { return lhs.workout.started > rhs.workout.started }
                case .oldest:
                    if lhs.workout.started != rhs.workout.started { return lhs.workout.started < rhs.workout.started }
                case .title:
                    let order = lhs.workout.title.localizedStandardCompare(rhs.workout.title)
                    if order != .orderedSame { return order == .orderedAscending }
                    if lhs.workout.started != rhs.workout.started { return lhs.workout.started > rhs.workout.started }
                case .longest:
                    if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
                    if lhs.workout.started != rhs.workout.started { return lhs.workout.started > rhs.workout.started }
                }
                return lhs.id < rhs.id
            }
    }

    var body: some View {
        let history = history
        let results = results(from: history)
        List {
            Section {
                Picker("Sort by", selection: $sort.hapticSelection()) {
                    ForEach(HistorySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                ForEach(results) { row in
                    NavigationLink { WorkoutHistoryView(workout: row.workout, personID: personID) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.workout.title).font(.body.weight(.semibold))
                            Text(row.workout.started, format: .dateTime.month(.abbreviated).day().year())
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("\(sessionDuration(row.duration)) total · \(row.setCount) sets")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if !row.exercises.isEmpty {
                                Text(row.exercises).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.padding(.vertical, 4)
                    }.buttonStyle(HapticNavigationButtonStyle())
                        .modifier(WorkoutDeleteAction(workout: row.workout, personID: personID))
                }
            } header: {
                Text("\(results.count) \(results.count == 1 ? "workout" : "workouts")")
            }
            if results.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(history.isEmpty ? "No past workouts" : "No matching workouts", systemImage: history.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                    } description: {
                        Text(history.isEmpty ? "Finish a workout or import your history to see it here." : "Try a different workout name, exercise, or date.")
                    }
                }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Past workouts")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search workouts, exercises, or dates")
    }
}
