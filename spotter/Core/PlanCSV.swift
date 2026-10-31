import Foundation

// CSV names can differ by word order or plurals. Keep exact matches first
// and leave multiple candidates for import review.
enum ExerciseNameMatcher {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func wordKey(_ text: String) -> String {
        normalized(text).split(separator: " ").map { singular(String($0)) }.sorted().joined(separator: " ")
    }

    private static func singular(_ word: String) -> String {
        // These muscle names already end in s in the singular form.
        if ["biceps", "triceps", "quadriceps", "abs"].contains(word) { return word }
        if word == "calves" { return "calf" }
        if word.count > 3 && word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if ["sses", "shes", "ches", "xes", "zes", "oes"].contains(where: { word.hasSuffix($0) }) {
            return String(word.dropLast(2))
        }
        if word.count > 3 && word.hasSuffix("s") && !["ss", "us", "is"].contains(where: { word.hasSuffix($0) }) {
            return String(word.dropLast())
        }
        return word
    }

    static func matches(_ text: String, exercises: [Exercise], names: [String: String]) -> [Exercise] {
        let key = normalized(text)
        guard !key.isEmpty else { return [] }
        func labels(_ exercise: Exercise) -> [String] {
            [exercise.name, names[exercise.id] ?? ""] + exercise.aliases
        }
        let exact = exercises.filter { labels($0).contains { normalized($0) == key } }
        if !exact.isEmpty { return exact }
        let words = wordKey(text)
        return exercises.filter { labels($0).contains { wordKey($0) == words } }
    }

    // Suggestions never resolve an import automatically. The user must select one.
    static func suggestions(_ text: String, exercises: [Exercise], names: [String: String], limit: Int = 3) -> [Exercise] {
        let query = wordKey(text)
        guard !query.isEmpty, limit > 0 else { return [] }
        let queryWords = query.split(separator: " ").map(String.init)
        func score(_ label: String) -> Double {
            let candidate = wordKey(label)
            guard !candidate.isEmpty else { return 0 }
            var remaining = candidate.split(separator: " ").map(String.init)
            let candidateCount = remaining.count
            var common = 0
            for word in queryWords {
                if let index = remaining.firstIndex(of: word) {
                    common += 1
                    remaining.remove(at: index)
                }
            }
            let overlap = 2 * Double(common) / Double(queryWords.count + candidateCount)
            let similarity = 1 - Double(editDistance(query, candidate)) / Double(max(query.count, candidate.count))
            return max(overlap, similarity >= 0.72 ? similarity : 0)
        }
        return exercises.map { exercise in
            (exercise: exercise, score: ([exercise.name, names[exercise.id] ?? ""] + exercise.aliases).map(score).max() ?? 0)
        }
        .filter { $0.score >= 0.65 }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let first = names[$0.exercise.id] ?? $0.exercise.name
            let second = names[$1.exercise.id] ?? $1.exercise.name
            if first != second { return first < second }
            return $0.exercise.id < $1.exercise.id
        }
        .prefix(limit).map(\.exercise)
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let right = Array(second)
        var previous = Array(0...right.count)
        for (index, character) in first.enumerated() {
            var current = [index + 1]
            for (column, other) in right.enumerated() {
                current.append(min(current[column] + 1, previous[column + 1] + 1,
                                   previous[column] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }
}

struct ImportedPlan {
    var plan: Plan
    var exercises: [Exercise]
    var originalNames: [String: String] = [:]
    var aliasAdditions: [String: [String]] = [:]

    mutating func matchCustomExercise(_ id: String, to existing: Exercise) {
        guard let custom = exercises.first(where: { $0.id == id }) else { return }
        let alias = originalNames[id] ?? custom.name
        if !([existing.name] + existing.aliases + (aliasAdditions[existing.id] ?? [])).contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
            aliasAdditions[existing.id, default: []].append(alias)
        }
        for dayIndex in plan.days.indices {
            for exerciseIndex in plan.days[dayIndex].exercises.indices {
                if plan.days[dayIndex].exercises[exerciseIndex].exerciseID == id {
                    plan.days[dayIndex].exercises[exerciseIndex].exerciseID = existing.id
                }
                if plan.days[dayIndex].exercises[exerciseIndex].alternativeExerciseID == id {
                    plan.days[dayIndex].exercises[exerciseIndex].alternativeExerciseID = existing.id
                }
                if plan.days[dayIndex].exercises[exerciseIndex].alternativeExerciseID == plan.days[dayIndex].exercises[exerciseIndex].exerciseID {
                    plan.days[dayIndex].exercises[exerciseIndex].alternativeExerciseID = nil
                }
            }
        }
        exercises.removeAll { $0.id == id }
    }
}

struct PlanCSVError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum PlanCSV {
    static func parse(_ text: String, name: String, library: [Exercise], names: [String: String] = [:]) throws -> ImportedPlan {
        let rows = try records(text)
        var plan = Plan(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !plan.name.isEmpty else { throw PlanCSVError(message: "Enter a plan name.") }
        var created: [Exercise] = []
        var columns: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if cells.allSatisfy({ $0.isEmpty }) { continue }
            if let exerciseColumn = cells.firstIndex(where: { $0.lowercased() == "exercise" }) {
                columns = [:]
                for (column, value) in cells.enumerated() where !value.isEmpty { columns[value.lowercased()] = column }
                guard columns["sets"] != nil, columns["rep range"] != nil else {
                    throw PlanCSVError(message: "Row \(index + 1): expected Exercise, Sets, and Rep range columns.")
                }
                columns["exercise"] = exerciseColumn
                continue
            }
            let populated = cells.filter { !$0.isEmpty }
            if let title = populated.first, populated.dropFirst().allSatisfy({ $0.lowercased() == "notes" }) {
                if let last = plan.days.last, last.exercises.isEmpty {
                    throw PlanCSVError(message: "Training day \(last.name) has no exercises.")
                }
                plan.days.append(TrainingDay(name: title))
                columns = [:]
                continue
            }
            func value(_ key: String) -> String {
                guard let column = columns[key], column < cells.count else { return "" }
                return cells[column]
            }
            guard !plan.days.isEmpty, !columns.isEmpty else {
                throw PlanCSVError(message: "Row \(index + 1): add a training day name and an Exercise, Sets, Rep range, RIR header before exercises.")
            }
            let exerciseName = value("exercise")
            let range = value("rep range").replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !exerciseName.isEmpty, let sets = Int(value("sets")), (1...20).contains(sets),
                  (1...2).contains(range.count), let low = Int(range[0]), let high = Int(range.last!), low > 0, high >= low else {
                throw PlanCSVError(message: "Row \(index + 1): use an exercise name, 1–20 sets, and a rep range such as 8–12.")
            }
            let rirText = value("rir")
            let notes = value("notes")
            var rir: Int?
            var perSetRIR: [RIRTarget?]?
            if !rirText.isEmpty {
                let items = rirText.split(separator: ",", omittingEmptySubsequences: false)
                let targets = try items.map { item -> RIRTarget in
                    let bounds = item.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard (1...2).contains(bounds.count), let first = bounds.first ?? nil, let last = bounds.last ?? nil,
                          RIRTarget(low: first, high: last).valid else {
                        throw PlanCSVError(message: "Row \(index + 1): RIR must be 0–10, a range, or one value per set.")
                    }
                    return RIRTarget(low: first, high: last)
                }
                guard targets.count == 1 || targets.count == sets else {
                    throw PlanCSVError(message: "Row \(index + 1): provide one RIR target or one target for each of the \(sets) sets.")
                }
                if targets.count == 1 && targets[0].low == targets[0].high { rir = targets[0].low }
                else { perSetRIR = (targets.count == 1 ? Array(repeating: targets[0], count: sets) : targets).map { Optional($0) } }
            }
            func resolve(_ exerciseName: String) -> Exercise {
                let matches = ExerciseNameMatcher.matches(exerciseName, exercises: library + created, names: names)
                if let existing = matches.first(where: { match in created.contains { $0.id == match.id } }) { return existing }
                if matches.count == 1 { return matches[0] }
                let exercise = Exercise(id: UUID().uuidString, name: exerciseName, primary: "Other", equipment: "Other", pattern: "Other")
                created.append(exercise)
                return exercise
            }
            let options = alternativeNames(exerciseName, library: library + created, names: names)
            guard options.count <= 2, options.allSatisfy({ !$0.isEmpty }) else {
                throw PlanCSVError(message: "Row \(index + 1): use two exercise alternatives separated by / or or.")
            }
            let exercise = resolve(options[0])
            let alternative = options.count == 2 ? resolve(options[1]) : nil
            plan.days[plan.days.count - 1].exercises.append(PlannedExercise(exerciseID: exercise.id, target: Target(sets: sets, low: low, high: high, rir: rir, perSetRIR: perSetRIR, notes: notes), alternativeExerciseID: alternative?.id == exercise.id ? nil : alternative?.id))
        }
        guard !plan.days.isEmpty, plan.days.allSatisfy({ !$0.exercises.isEmpty }) else {
            throw PlanCSVError(message: "Include at least one training day with exercises and column headers.")
        }
        return ImportedPlan(plan: plan, exercises: created, originalNames: Dictionary(uniqueKeysWithValues: created.map { ($0.id, $0.name) }))
    }

    // Expand shorthand such as Cable/Machine Fly and Incline DB/Smith Press.
    private static func alternativeNames(_ text: String, library: [Exercise], names: [String: String]) -> [String] {
        let parts = text.replacingOccurrences(of: " or ", with: "/", options: .caseInsensitive)
            .components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return parts }
        let left = parts[0].split(separator: " ").map(String.init)
        let right = parts[1].split(separator: " ").map(String.init)
        let prefix = left.dropLast().joined(separator: " ")
        let suffix = right.dropFirst().joined(separator: " ")
        let fullNames = library.flatMap { [$0.name, names[$0.id] ?? ""] + $0.aliases }
        func expand(_ part: String) -> String {
            guard !part.isEmpty else { return part }
            let candidates = [part, [part, suffix].filter { !$0.isEmpty }.joined(separator: " "),
                              [prefix, part].filter { !$0.isEmpty }.joined(separator: " "),
                              [prefix, part, suffix].filter { !$0.isEmpty }.joined(separator: " ")]
            return candidates.first { candidate in fullNames.contains { ExerciseNameMatcher.normalized($0) == ExerciseNameMatcher.normalized(candidate) } }
                ?? candidates.first { candidate in fullNames.contains { ExerciseNameMatcher.wordKey($0) == ExerciseNameMatcher.wordKey(candidate) } }
                ?? (part == parts[0] && left.count == 1 && !suffix.isEmpty ? part + " " + suffix : part)
        }
        return parts.map(expand)
    }

    // Quoted commas, escaped quotes and embedded newlines follow CSV rules.
    static func records(_ text: String) throws -> [[String]] {
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: ""))
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(character) }
            } else if character == "," || character == "\n" {
                row.append(field); field = ""; closed = false
                if character == "\n" { rows.append(row); row = [] }
            } else if character == "\"" {
                guard field.isEmpty, !closed else { throw PlanCSVError(message: "CSV contains an unexpected quote. Put quotes around the entire field.") }
                quoted = true
            } else {
                guard !closed || character == " " || character == "\t" else { throw PlanCSVError(message: "CSV contains text after a closing quote.") }
                if !closed { field.append(character) }
            }
            index += 1
        }
        guard !quoted else { throw PlanCSVError(message: "CSV has an unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
}

extension Store {
    @discardableResult func importPlan(_ imported: ImportedPlan) -> Bool {
        guard !readOnly else { return false }
        let previous = state
        state.plans.append(imported.plan)
        state.customExercises.append(contentsOf: imported.exercises)
        for (id, aliases) in imported.aliasAdditions {
            var saved = state.exerciseAliases?[id] ?? []
            for alias in aliases where !saved.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) { saved.append(alias) }
            if state.exerciseAliases == nil { state.exerciseAliases = [:] }
            state.exerciseAliases?[id] = saved
        }
        guard save(notify: false) else { state = previous; return false }
        library.append(contentsOf: imported.exercises)
        for index in library.indices {
            for alias in imported.aliasAdditions[library[index].id] ?? [] where !library[index].aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                library[index].aliases.append(alias)
            }
        }
        return true
    }
}
