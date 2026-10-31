import Testing
@testable import SpotterCore

struct CSVExerciseMatchingTests {
    private func exercise(_ id: String, _ name: String, aliases: [String] = []) -> Exercise {
        Exercise(id: id, name: name, aliases: aliases, primary: "Chest", equipment: "Machine", pattern: "Push")
    }

    // Exercise identity must agree for plan imports and progress/history imports.
    private func importedIDs(_ labels: [String], library: [Exercise], names: [String: String] = [:]) throws -> [[String]] {
        let planCSV = "Push\nExercise,Sets,Rep range,RIR\n" + labels.map { "\($0),2,8-12,1" }.joined(separator: "\n")
        let plan = try PlanCSV.parse(planCSV, name: "Test", library: library, names: names)
        let workoutCSV = "Date,Exercise,Weight,Reps,RIR,Notes\n" + labels.map { "8-24,\($0),100,8,1," }.joined(separator: "\n")
        let workout = try WorkoutCSV.parse(workoutCSV, year: 2026, unit: .lb, profile: Profile(name: "Test"), library: library, names: names)
        return [plan.plan.days.flatMap { $0.exercises.map(\.exerciseID) }, workout.entries.flatMap { $0.map { $0.exercise.id } }]
    }

    @Test func reorderedNamesAliasesAndPersonalNamesMatch() throws {
        let library = [
            exercise("incline", "Chess Incline Press"),
            exercise("alias", "Machine Fly", aliases: ["Cable Chest Fly"]),
            exercise("renamed", "Bench Press")
        ]
        let results = try importedIDs(["  Incline CHÉSS press  ", "Chest Fly Cable", "Press Personal Flat"], library: library, names: ["renamed": "Personal Flat Press"])
        for ids in results { #expect(ids == ["incline", "alias", "renamed"]) }
    }

    @Test func exactMatchWinsOverReorderedCandidate() throws {
        let library = [exercise("exact", "Incline Chess Press"), exercise("reordered", "Chess Incline Press")]
        for ids in try importedIDs(["Incline Chess Press"], library: library) { #expect(ids == ["exact"]) }
    }

    @Test func capitalizationOnlyMatchesWithoutReview() throws {
        for ids in try importedIDs(["INCLINE CHEST PRESS"], library: [exercise("incline", "Incline Chest Press")]) {
            #expect(ids == ["incline"])
        }
    }

    @Test func pluralsMatchAutomaticallyInBothImports() throws {
        let pairs = [
            ("Cable Lateral Raises", "Cable lateral raise"),
            ("Cable Flies", "Cable fly"),
            ("Cable Fly", "Cable flies"),
            ("Chest Presses Machine", "Machine chest press"),
            ("Cable Crunches", "Cable crunch"),
            ("Dumbbells Hammer Curls", "Dumbbell hammer curl"),
            ("Weighted Pull-ups", "Weighted pull-up"),
            ("Calves Raises", "Calf raise"),
            ("Cable Triceps Pushdowns", "Cable triceps pushdown")
        ]
        for (label, existing) in pairs {
            for ids in try importedIDs([label], library: [exercise("matched", existing)]) {
                #expect(ids == ["matched"])
            }
        }
    }

    @Test func pluralMatchingUsesAliasesPersonalNamesAndCustomIdentity() throws {
        let library = [exercise("alias", "Machine fly", aliases: ["Cable chest fly"]), exercise("renamed", "Bench press")]
        for ids in try importedIDs(["Chest Flies Cable", "Personal Presses"], library: library, names: ["renamed": "Personal press"]) {
            #expect(ids == ["alias", "renamed"])
        }
        for ids in try importedIDs(["Unique Cable Fly", "Cable Flies Unique"], library: []) {
            #expect(ids[0] == ids[1])
        }
    }

    @Test func exactPluralWinsAndDifferentEquipmentStillNeedsReview() throws {
        let library = [exercise("singular", "Cable fly"), exercise("plural", "Cable flies")]
        for ids in try importedIDs(["Cable flies"], library: library) { #expect(ids == ["plural"]) }
        for ids in try importedIDs(["Dumbbell flies"], library: library) {
            #expect(!library.contains { $0.id == ids[0] })
        }
        #expect(ExerciseNameMatcher.wordKey("Triceps press") == "press triceps")
    }

    @Test func typoIsSuggestedButRequiresReviewInBothImports() throws {
        let library = [exercise("incline", "Chest Incline Press"), exercise("unrelated", "Leg Curl")]
        let label = "Incline Chess Press"
        #expect(ExerciseNameMatcher.suggestions(label, exercises: library, names: [:]).map(\.id) == ["incline"])
        for ids in try importedIDs([label], library: library) {
            #expect(!library.contains { $0.id == ids[0] })
        }
    }

    @Test func suggestionsUseAliasesPersonalNamesAndLimitResults() {
        let library = [
            exercise("alias", "Machine Fly", aliases: ["Cable Chest Fly"]),
            exercise("renamed", "Bench Press"),
            exercise("other", "Leg Curl")
        ]
        #expect(ExerciseNameMatcher.suggestions("Chest Cable Flie", exercises: library, names: [:]).first?.id == "alias")
        #expect(ExerciseNameMatcher.suggestions("Personal Flat Pres", exercises: library, names: ["renamed": "Personal Flat Press"]).first?.id == "renamed")
        #expect(ExerciseNameMatcher.suggestions("   ", exercises: library, names: [:]).isEmpty)
        #expect(ExerciseNameMatcher.suggestions("Unrelated movement", exercises: library, names: [:]).isEmpty)
        let similar = (0..<5).map { exercise("\($0)", "Incline Chest Press \($0)") }
        let suggestions = ExerciseNameMatcher.suggestions("Incline Chest Press", exercises: similar.reversed(), names: [:])
        #expect(suggestions.map(\.id) == ["0", "1", "2"])
    }

    @Test func ambiguousReorderedMatchesStillNeedReview() throws {
        let library = [exercise("one", "Chess Incline Press"), exercise("two", "Press Chess Incline")]
        for ids in try importedIDs(["Incline Chess Press"], library: library) {
            #expect(ids.count == 1)
            #expect(!library.contains { $0.id == ids[0] })
        }
    }

    @Test func reorderedCustomNamesShareIdentityAndDifferentWordsStaySeparate() throws {
        for ids in try importedIDs(["Unique Incline Press", "Press Unique Incline", "Unique Flat Press", "Unique Unique Incline Press"], library: []) {
            #expect(ids[0] == ids[1])
            #expect(ids[0] != ids[2])
            #expect(ids[0] != ids[3])
        }
    }
}
