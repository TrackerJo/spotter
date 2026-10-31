import Foundation

/// Three-way snapshot merge. Workout revisions retain their causal history and tombstones.
enum PersonalSync {
    static func sharedWorkoutIDs(_ state: LocalState) -> Set<String> {
        Set(state.ledger.revisions.compactMap {
            if case .workout(let workout) = $0.value, workout.shared { return workout.id }
            return nil
        })
    }
    static func snapshot(_ state: LocalState) throws -> Data {
        var copy = state
        let shared = sharedWorkoutIDs(state)
        copy.ledger.revisions.removeAll { shared.contains($0.workoutID) }
        copy.cloudLinks = []
        copy.nearbyPairing = nil
        copy.personalSyncBase = nil
        copy.activeWorkoutID = nil
        copy.activePersonID = copy.ownID
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }

    private static func isStarterPlans(_ plans: [Plan]) -> Bool {
        func stripIDs(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(stripIDs) }
            if let dict = value as? [String: Any] { return dict.filter { $0.key != "id" }.mapValues(stripIDs) }
            return value
        }
        func data(_ plans: [Plan]) throws -> Data {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plans))
            return try JSONSerialization.data(withJSONObject: stripIDs(object), options: .sortedKeys)
        }
        return (try? data(plans)) == (try? data(SampleData.plans()))
    }

    static func merge(local: LocalState, remote: LocalState, base: LocalState?) throws -> LocalState {
        var local = local
        // The same iCloud account uses one performer identity across installations.
        if local.ownID != remote.ownID {
            let oldID = local.ownID
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local))
            func rekey(_ value: Any) -> Any {
                if let text = value as? String { return text.replacingOccurrences(of: oldID, with: remote.ownID) }
                if let array = value as? [Any] { return array.map(rekey) }
                if let dict = value as? [String: Any] {
                    return Dictionary(uniqueKeysWithValues: dict.map { ($0.key.replacingOccurrences(of: oldID, with: remote.ownID), rekey($0.value)) })
                }
                return value
            }
            local = try JSONDecoder().decode(LocalState.self, from: JSONSerialization.data(withJSONObject: rekey(object)))
        }
        if base == nil, let index = local.profiles.firstIndex(where: { $0.id == remote.ownID }),
           local.profiles[index].name == "You", let profile = remote.profiles.first(where: { $0.id == remote.ownID }) {
            local.profiles[index] = profile
        }
        var result = local
        func choose<T: Equatable>(_ local: T, _ remote: T, _ base: T?) -> T {
            if let base, local == base { return remote }
            return local
        }
        func items<T: Identifiable & Equatable>(_ local: [T], _ remote: [T], _ base: [T]?) -> [T] where T.ID == String {
            let l = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
            let r = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
            let b = Dictionary(uniqueKeysWithValues: (base ?? []).map { ($0.id, $0) })
            var seen = Set<String>()
            let ids = (local.map(\.id) + remote.map(\.id) + (base ?? []).map(\.id)).filter { seen.insert($0).inserted }
            return ids.compactMap { id in
                if base == nil { return l[id] ?? r[id] }
                return choose(l[id], r[id], .some(b[id]))
            }
        }
        result.profiles = items(local.profiles, remote.profiles, base?.profiles)
        result.removedProfileIDs = Array(Set(local.removedProfileIDs ?? []).union(remote.removedProfileIDs ?? [])).sorted()
        result.managedProfileIDs = Array(Set(local.managedProfileIDs ?? []).union(remote.managedProfileIDs ?? [])).sorted()
        if base == nil, local.ledger.revisions.isEmpty, isStarterPlans(local.plans) {
            result.plans = remote.plans
        } else { result.plans = items(local.plans, remote.plans, base?.plans) }
        result.customExercises = items(local.customExercises, remote.customExercises, base?.customExercises)
        func dictionary<T: Equatable>(_ local: [String: T], _ remote: [String: T], _ base: [String: T]?) -> [String: T] {
            var result: [String: T] = [:]
            for key in Set(local.keys).union(remote.keys).union(base?.keys.map { $0 } ?? []) {
                result[key] = base == nil ? (local[key] ?? remote[key]) : choose(local[key], remote[key], .some(base?[key]))
            }
            return result
        }
        result.names = dictionary(local.names, remote.names, base?.names)
        result.increments = dictionary(local.increments, remote.increments, base?.increments)
        result.incrementUnits = dictionary(local.incrementUnits ?? [:], remote.incrementUnits ?? [:], base.map { $0.incrementUnits ?? [:] })
        result.exerciseAliases = dictionary(local.exerciseAliases ?? [:], remote.exerciseAliases ?? [:], base.map { $0.exerciseAliases ?? [:] })
        // Ignore legacy cloud copies of shared sessions, including tombstones.
        let shared = sharedWorkoutIDs(local).union(sharedWorkoutIDs(remote))
        result.ledger.merge(remote.ledger.revisions.filter { !shared.contains($0.workoutID) })
        result.cloudLinks = []
        result.activeWorkoutID = local.activeWorkoutID
        result.activePersonID = local.activePersonID
        return result
    }
}
