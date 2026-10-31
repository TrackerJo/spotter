import Foundation

// Snapshots include only the owner and locally managed profiles. Connected friends
// remain excluded, including their entries in shared workouts.
struct ChatGPTTrainingData {
    private var profiles: [[String: Any]] = []
    private var managedData: [String: ChatGPTTrainingData] = [:]
    private var profileID = ""
    var workouts: [[String: Any]]
    var plans: [[String: Any]]
    var exercises: [[String: Any]]

    @MainActor init(store: Store) {
        self.init(store: store, personID: store.me.id)
        profiles = ([store.me] + store.managedProfiles).filter { !$0.isDemo }.map {
            ["id": $0.id, "name": $0.name, "is_you": $0.id == store.me.id]
        }
        for profile in store.managedProfiles where !profile.isDemo {
            managedData[profile.id] = ChatGPTTrainingData(store: store, personID: profile.id)
        }
    }

    @MainActor private init(store: Store, personID owner: String) {
        profileID = owner
        workouts = store.workouts.map { store.personalWorkout($0, personID: owner) }
            .filter { workout in !workout.demo && !workout.isPreparing && workout.finished != nil && store.members.contains(where: { $0.workoutID == workout.id && $0.profile.id == owner && !$0.deleted }) }
            .sorted { $0.started > $1.started }.map { workout in
                let entries = store.entries.filter { $0.workoutID == workout.id && $0.personID == owner }.sorted { $0.order < $1.order }
                return ["id": workout.id, "title": workout.title, "date": workout.started.ISO8601Format(), "exercises": entries.map { entry -> [String: Any] in
                    ["exercise_id": entry.exercise.id, "name": store.name(entry.exercise, personID: owner), "primary_muscle": entry.exercise.primary,
                     "secondary_muscles": entry.exercise.secondary, "tracking": entry.exercise.tracking.rawValue,
                     "sets": store.sets(for: entry).filter { $0.completed }.map { set -> [String: Any] in
                         var row: [String: Any] = ["warmup": set.warmup, "notes": set.notes]
                         if let value = set.weightPounds { row["weight_lb"] = value }
                         if let value = set.performedReps { row["reps"] = value }
                         if let value = set.recordedRIRSummary { row["rir"] = value }
                         if let value = set.seconds { row["seconds"] = value }
                         if let value = set.meters { row["meters"] = value }
                         row["bodyweight_only"] = set.bodyweightOnly == true
                         return row
                     }]
                }]
            }
        plans = (owner == store.me.id ? store.state.plans : []).map { plan in
            ["name": plan.name, "days": plan.days.map { day in
                ["name": day.name, "weekdays": day.weekdays, "exercises": day.exercises.map { planned -> [String: Any] in
                    ["exercise_ids": planned.exerciseIDs, "names": planned.exerciseIDs.compactMap { store.exercise($0).map { store.name($0, personID: owner) } }, "sets": planned.target.sets, "reps_low": planned.target.low, "reps_high": planned.target.high, "rir": planned.target.rirSummary ?? "unspecified", "notes": planned.target.notes]
                }] as [String: Any]
            }]
        }
        exercises = store.library.map { ["id": $0.id, "name": store.name($0, personID: owner), "primary_muscle": $0.primary, "equipment": $0.equipment, "tracking": $0.tracking.rawValue] }
    }

    static let namespace = "spotter"
    static var requestTools: [[String: Any]] {
        [["type": "namespace", "name": namespace,
          "description": "Read-only training data for you and profiles you manage. Connected friends are excluded.",
          "tools": tools]]
    }
    static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
            var properties = properties
            if name != "list_profiles" {
                properties["profile_id"] = ["type": "string", "description": "Optional profile ID from list_profiles. Omit for the phone owner. Never use a name as an ID."]
            }
            return ["type": "function", "name": name, "description": description, "strict": false, "parameters": ["type": "object", "properties": properties, "additionalProperties": false]]
        }
        let number: [String: Any] = ["type": "integer"]
        let string: [String: Any] = ["type": "string"]
        return [
            tool("list_profiles", "List you and profiles you manage. Resolve names here before querying another profile; ask if names are ambiguous.", [:]),
            tool("list_workouts", "List the selected profile’s completed workouts, newest first. Paginate with offset; limit is capped at 20.", ["offset": number, "limit": number]),
            tool("get_workout", "Read the selected profile’s exercises and recorded sets for one completed workout.", ["workout_id": string]),
            tool("training_summary", "Summarize primary muscle working-set exposure, workload and frequency for the last days. Exposure is not growth; volume is not strength.", ["days": number]),
            tool("exercise_history", "Read up to 20 completed workouts for one exercise ID, newest first.", ["exercise_id": string, "limit": number]),
            tool("list_plans", "Read the phone owner's training plans. Managed profiles have no separate saved plans and return an empty list.", [:]),
            tool("exercise_library", "Search the exercise library for available exercises. Query by name, muscle or equipment. Capped at 50.", ["query": string])
        ]
    }

    func call(_ name: String, arguments: String, namespace: String? = nil, now: Date = Date()) throws -> String {
        guard namespace == nil || namespace == Self.namespace else {
            throw ChatGPTError(message: "ChatGPT requested an unavailable training tool.")
        }
        guard let data = arguments.data(using: .utf8), let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTError(message: "ChatGPT requested invalid tool arguments.") }
        if name != "list_profiles", let requested = args["profile_id"] {
            guard let id = requested as? String else { return "{\"error\":\"Invalid profile ID. Use list_profiles.\"}" }
            if id != profileID {
                guard let selected = managedData[id] else { return "{\"error\":\"Profile unavailable. Only you and profiles you manage can be queried. Use list_profiles.\"}" }
                var forwarded = args
                forwarded.removeValue(forKey: "profile_id")
                let bytes = try JSONSerialization.data(withJSONObject: forwarded)
                return try selected.call(name, arguments: String(decoding: bytes, as: UTF8.self), namespace: namespace, now: now)
            }
        }
        var result: Any
        switch name {
        case "list_profiles": result = profiles
        case "list_workouts":
            let offset = max(0, args["offset"] as? Int ?? 0), limit = min(20, max(1, args["limit"] as? Int ?? 10))
            let rows = workouts.dropFirst(offset).prefix(limit).map { ["id": $0["id"]!, "title": $0["title"]!, "date": $0["date"]!] }
            result = ["workouts": rows, "total": workouts.count, "next_offset": offset + rows.count < workouts.count ? offset + rows.count : NSNull()] as [String: Any]
        case "get_workout": result = workouts.first { $0["id"] as? String == args["workout_id"] as? String } ?? ["error": "Workout not found in your history."]
        case "exercise_history":
            let id = args["exercise_id"] as? String ?? ""
            result = workouts.compactMap { workout -> [String: Any]? in
                let entries = (workout["exercises"] as? [[String: Any]] ?? []).filter { $0["exercise_id"] as? String == id }
                guard !entries.isEmpty else { return nil }
                return ["id": workout["id"]!, "date": workout["date"]!, "exercises": entries]
            }.prefix(min(20, max(1, args["limit"] as? Int ?? 10))).map { $0 }
        case "training_summary":
            let days = min(3650, max(1, args["days"] as? Int ?? 90))
            let since = now.addingTimeInterval(-Double(days) * 86400)
            let rows = workouts.filter { (try? Date($0["date"] as? String ?? "", strategy: .iso8601)) ?? .distantPast >= since }
            var exposure: [String: Int] = [:], count = 0, volume = 0.0
            for entry in rows.flatMap({ $0["exercises"] as? [[String: Any]] ?? [] }) {
                let sets = (entry["sets"] as? [[String: Any]] ?? []).filter { $0["warmup"] as? Bool != true }
                count += sets.count
                exposure[entry["primary_muscle"] as? String ?? "Other", default: 0] += sets.count
                if entry["tracking"] as? String == Tracking.weightReps.rawValue {
                    volume += sets.filter { $0["bodyweight_only"] as? Bool != true }.reduce(0) { $0 + ($1["weight_lb"] as? Double ?? 0) * ($1["reps"] as? Double ?? 0) }
                }
            }
            result = ["days": days, "workouts": rows.count, "working_sets": count, "primary_muscle_working_sets": exposure, "volume_lb_reps": volume, "caveat": "Primary muscle exposure only. Secondary involvement is not counted. Missing logs are not evidence of no training."]
        case "list_plans": result = plans
        case "exercise_library":
            let query = args["query"] as? String ?? ""
            result = exercises.filter { query.isEmpty || [$0["name"], $0["primary_muscle"], $0["equipment"]].compactMap { $0 as? String }.joined(separator: " ").localizedCaseInsensitiveContains(query) }.prefix(50).map { $0 }
        default: result = ["error": "Unknown tool. Tools are read-only."]
        }
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard bytes.count <= 300_000 else { return "{\"error\":\"Result too large. Request fewer workouts.\"}" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
