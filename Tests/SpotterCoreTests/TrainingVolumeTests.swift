import Foundation
import Testing
@testable import SpotterCore

@MainActor struct TrainingVolumeTests {
    @Test func volumeUsesWorkingWeightAndFractionalReps() throws {
        let store = Store(file: FileManager.default.temporaryDirectory.appending(path: "VolumeTests/\(UUID().uuidString)/state.json"))
        store.start(day: nil, shared: false)
        store.selectExercise(try #require(store.library.first { $0.tracking == .weightReps }))
        let entry = try #require(store.current)
        var set = store.makeSet(entry)
        set.completed = true
        set.weight = 10
        set.unit = .kg
        set.fractionalReps = 2.5
        let expected = WeightUnit.kg.pounds(10) * 2.5
        #expect(abs(ProgressEngine.volumePounds(entries: [entry], sets: [set]) - expected) < 0.001)
        var warmup = set; warmup.warmup = true
        var bodyweight = set; bodyweight.bodyweightOnly = true
        var draft = set; draft.completed = false
        var otherPerson = set; otherPerson.personID = "other"
        #expect(ProgressEngine.volumePounds(entries: [entry], sets: [warmup, bodyweight, draft, otherPerson]) == 0)
        var assisted = entry; assisted.exercise.tracking = .assisted
        #expect(ProgressEngine.volumePounds(entries: [assisted], sets: [set]) == 0)
    }
}
