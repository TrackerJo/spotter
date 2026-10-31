import Foundation
import Testing
@testable import SpotterCore

@MainActor struct MeasurementTests {
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterUnits/\(UUID().uuidString)/state.json")) }

    @Test func exactUSConversionsAndDistanceTargets() {
        #expect(abs(WeightUnit.kg.pounds(45.359237) - 100) < 0.000001)
        #expect(WeightUnit.lb.pounds(100) == 100)
        #expect(abs(USDistanceUnit.feet.value(meters: 30.48) - 100) < 0.000001)
        #expect(USDistanceUnit.miles.value(meters: 1609.344) == 1)
        #expect(USDistanceUnit.feet.meters(100) == 30.48)
        #expect(USDistanceUnit.miles.meters(1) == 1609.344)
        #expect(USDistanceUnit.summary(meters: 30.48) == "100 ft")
        #expect(USDistanceUnit.summary(meters: 1609.344) == "1 mi")
        #expect(Target(meters: 1609.344).summary(for: .distance).contains("1 mi"))
    }

    @Test func metricHistoryPrefillsPoundsWithoutRewritingHistory() throws {
        let s = store(); let exercise = try #require(s.exercise("bench-barbell"))
        s.start(day: s.days[0], shared: false); s.selectExercise(exercise)
        var legacy = s.makeSet(try #require(s.current)); legacy.weight = 45.359237; legacy.unit = .kg; legacy.reps = 12
        s.saveSet(legacy); s.finish()
        s.start(day: s.days[0], shared: false); s.selectExercise(exercise)
        let next = s.makeSet(try #require(s.current))
        #expect(next.unit == .lb); #expect(abs(try #require(next.weight) - 100) < 0.000001)
        #expect(s.previous(exercise.id)?.sets.first?.unit == .kg)
        #expect(s.previous(exercise.id)?.sets.first?.weight == 45.359237)
        let progress = ProgressEngine.summary(personID: s.person.id, since: .distantPast, ledger: s.state.ledger)
        #expect(abs(progress.volumePounds - 1200) < 0.000001)
    }

    @Test func mixedLegacyAndUSSetsAtEquivalentWeightStillQualify() {
        var previous = ProgressionTests().fixture()
        previous.sets[1].weight = WeightUnit.kg.pounds(50); previous.sets[1].unit = .lb
        let progression = WorkoutEngine.progression(previous, increment: 2.5)
        #expect(progression != nil)
        #expect(abs((progression?.nextWeightPounds ?? 0) - WeightUnit.kg.pounds(52.5)) < 0.000001)
    }

    @Test func savedPoundIncrementWorksWithOldMetricHistoryAndSharing() throws {
        let s = store(); let exercise = try #require(s.exercise("bench-barbell"))
        s.start(day: s.days[0], shared: false); s.selectExercise(exercise)
        for _ in 0..<3 {
            var set = s.makeSet(try #require(s.current)); set.weight = 50; set.unit = .kg; set.reps = 12; s.saveSet(set)
        }
        s.finish(); s.rename(exercise, to: exercise.name, increment: 5)
        #expect(s.incrementPounds(exercise) == 5)
        #expect(abs(try #require(s.progression(exercise)?.nextWeightPounds) - (WeightUnit.kg.pounds(50) + 5)) < 0.000001)
        s.start(day: s.days[0], shared: true)
        #expect(s.participant?.incrementUnits?[exercise.id] == .lb)
        #expect(s.participant?.increments[exercise.id] == 5)
    }

    @Test func legacyPersonalIncrementKeepsItsOriginalUnitAfterUSLogging() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SpotterUnits/\(UUID().uuidString)/state.json")
        let original = Store(file: file); let exercise = try #require(original.exercise("bench-barbell"))
        original.start(day: original.days[0], shared: false); original.selectExercise(exercise)
        var legacy = original.makeSet(try #require(original.current)); legacy.weight = 50; legacy.unit = .kg; legacy.reps = 12
        original.saveSet(legacy); original.finish()
        original.state.increments[original.person.id] = [exercise.id: 2.5]
        original.state.incrementUnits = nil; original.save()
        let s = Store(file: file)
        #expect(s.state.incrementUnits?[s.person.id]?[exercise.id] == .kg)
        #expect(abs(try #require(s.incrementPounds(exercise)) - WeightUnit.kg.pounds(2.5)) < 0.000001)
        s.start(day: s.days[0], shared: false); s.selectExercise(exercise)
        var pounds = s.makeSet(try #require(s.current)); pounds.weight = 110; pounds.reps = 12
        s.saveSet(pounds); s.finish()
        #expect(abs(try #require(s.incrementPounds(exercise)) - WeightUnit.kg.pounds(2.5)) < 0.000001)
    }
}
