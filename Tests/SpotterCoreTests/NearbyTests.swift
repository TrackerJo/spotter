import Testing
import Foundation
import Network
@testable import SpotterCore

@Suite(.serialized) @MainActor struct NearbyTests {
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterNetworkTests/\(UUID().uuidString)/state.json")) }
    func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return condition()
    }
    @Test func encryptedTransportJoinsAndTransfersRealEdits() async throws {
        let a = store(); let b = store()
        a.start(day: a.days[0], shared: true, preparing: true)
        let host = NearbySync(); host.store = a
        let client = NearbySync(); client.store = b
        a.didChange = { host.send() }; b.didChange = { client.send() }
        defer { host.stop(); client.stop() }
        host.host(try #require(a.active).id)
        #expect(await waitFor { host.listeningPort != nil })
        #expect(host.code.count == 4)
        #expect(host.code.allSatisfy { $0.isASCII && $0.isNumber })
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try #require(host.listeningPort))
        client.join(NearbyHost(id: "loopback", name: "Test host", endpoint: endpoint), code: host.code)
        #expect(await waitFor { client.connected && b.active?.id == a.active?.id && a.activeMembers.count == 2 }, "Host: \(host.status); client: \(client.status); store: \(a.error ?? "none") / \(b.error ?? "none")")
        host.endInviting()
        #expect(!host.inviting); #expect(host.connected)
        #expect(a.active?.isPreparing == true); #expect(b.active?.isPreparing == true)
        #expect(b.participant?.day == a.participant?.day); #expect(b.current == nil)
        a.beginWorkout()
        #expect(await waitFor { b.active?.isPreparing == false && b.canLog })
        a.selectExercise(try #require(a.exercise("bench-barbell")))
        var set = a.makeSet(try #require(a.current)); set.weight = 50; set.reps = 12; set.completed = true; a.saveSet(set)
        #expect(await waitFor { b.sets.contains { $0.id == set.id && $0.completed } })
        #expect(b.sets.filter { $0.id == set.id }.count == 1)
        host.send(force: true); client.send(force: true)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(b.sets.filter { $0.id == set.id }.count == 1)
        client.suspend()
        #expect(await waitFor { !host.connected })
        b.selectExercise(try #require(b.exercise("bench-barbell")))
        var offline = b.makeSet(try #require(b.current)); offline.weight = 30; offline.reps = 10; offline.completed = true
        b.saveSet(offline)
        #expect(!a.sets.contains { $0.id == offline.id })
        client.resume()
        #expect(await waitFor { a.sets.contains { $0.id == offline.id } })
        #expect(a.sets.filter { $0.id == offline.id }.count == 1)
        let sharedID = try #require(b.active).id
        a.finish()
        #expect(await waitFor { b.activeMembers.count == 1 && b.active?.id == sharedID })
        #expect(b.canLog); #expect(b.active?.finished == nil)
        host.suspend()
        #expect(await waitFor { !client.connected })
        host.resume()
        #expect(await waitFor { host.connected && client.connected })
        var afterDeparture = b.makeSet(try #require(b.current)); afterDeparture.weight = 35; afterDeparture.reps = 8
        #expect(b.saveSet(afterDeparture))
        #expect(await waitFor { a.sets.contains { $0.id == afterDeparture.id } })
        b.finish()
        #expect(await waitFor { a.workouts.first { $0.id == sharedID }?.finished != nil })
        #expect(a.conflicts.isEmpty); #expect(b.conflicts.isEmpty)
    }
    @Test func codeOnlyJoinEnablesLoggingForBothFriends() async throws {
        let a = store(); let b = store(); a.start(day: nil, shared: true)
        let host = NearbySync(); host.store = a
        let client = NearbySync(); client.store = b
        a.didChange = { host.send() }; b.didChange = { client.send() }
        defer { host.stop(); client.stop() }
        host.host(try #require(a.active).id)
        #expect(await waitFor { host.listeningPort != nil })
        client.join(code: host.code)
        #expect(await waitFor { b.active?.id == a.active?.id && !client.joining }, "\(client.status): \(client.joinError ?? "none")")
        #expect(b.activeMembers.first { $0.profile.id == b.me.id }?.permitsPartnerLogging == true)
        #expect(await waitFor { a.activeMembers.count == 2 && host.connected && client.connected })
        host.endInviting()
        a.selectExercise(try #require(a.exercise("bench-barbell")))
        #expect(await waitFor { b.entries.count == 1 })
        client.suspend()
        #expect(await waitFor { !host.connected })
        var offline = a.makeSet(try #require(a.current)); offline.weight = 50; offline.reps = 10
        #expect(a.saveSet(offline))
        client.resume()
        #expect(await waitFor { b.sets.contains { $0.id == offline.id } }, "Host: \(host.status); client: \(client.status)")
        host.suspend()
        #expect(await waitFor { !client.connected })
        b.selectExercise(try #require(b.exercise("squat-barbell")))
        var clientSet = b.makeSet(try #require(b.current)); clientSet.weight = 40; clientSet.reps = 8
        #expect(b.saveSet(clientSet))
        host.resume()
        #expect(await waitFor { a.sets.contains { $0.id == clientSet.id } }, "Host: \(host.status); client: \(client.status)")
        #expect(!host.inviting)
        a.selectPerson(b.me.id); b.selectPerson(a.me.id)
        #expect(a.canLog); #expect(b.canLog)
    }
    @Test func bothPhonesLogEitherPersonWithoutPageCoordination() async throws {
        let a = store(); let b = store(); a.start(day: nil, shared: true)
        let host = NearbySync(); host.store = a
        let client = NearbySync(); client.store = b
        a.didChange = { host.send() }; b.didChange = { client.send() }
        defer { host.stop(); client.stop() }
        let id = try #require(a.active).id
        host.host(id)
        #expect(await waitFor { host.listeningPort != nil })
        client.join(NearbyHost(id: "unlocked-host", name: "Host", endpoint: .hostPort(host: "127.0.0.1", port: try #require(host.listeningPort))), code: host.code)
        #expect(await waitFor { a.activeMembers.count == 2 && b.active?.id == id && host.connected && client.connected })
        for personID in [a.me.id, b.me.id] {
            a.selectPerson(personID); b.selectPerson(personID)
            #expect(a.canLog); #expect(b.canLog)
        }
        a.selectPerson(a.me.id); b.selectPerson(a.me.id)
        a.selectExercise(try #require(a.exercise("bench-barbell")))
        #expect(await waitFor { b.current != nil })
        var first = a.makeSet(try #require(a.current)); first.weight = 40; first.reps = 10
        var second = b.makeSet(try #require(b.current)); second.weight = 45; second.reps = 12
        #expect(a.saveSet(first, parents: [])); #expect(b.saveSet(second, parents: []))
        #expect(await waitFor { a.sets.count == 2 && b.sets.count == 2 })
        #expect(a.conflicts.isEmpty); #expect(b.conflicts.isEmpty)
        host.suspend()
        #expect(await waitFor { !client.connected })
        #expect(a.canLog); #expect(!b.canLog)
        #expect(!b.saveSet(b.makeSet(try #require(b.current))))
        b.selectPerson(b.me.id)
        b.selectExercise(try #require(b.exercise("squat-barbell")))
        #expect(b.canLog)
        var hostOffline = a.makeSet(try #require(a.current)); hostOffline.weight = 50; hostOffline.reps = 9
        #expect(a.saveSet(hostOffline))
        var offline = b.makeSet(try #require(b.current)); offline.weight = 45; offline.reps = 8
        #expect(b.saveSet(offline))
        host.resume()
        #expect(await waitFor { host.connected && client.connected && a.sets.contains { $0.id == offline.id } && b.sets.contains { $0.id == hostOffline.id } })
        b.selectPerson(a.me.id)
        #expect(a.canLog); #expect(b.canLog)
    }
    @Test func savedPairingRestoresAfterRelaunchAndReplaysMultipleChunks() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SpotterNetworkTests/\(UUID().uuidString)")
        let aFile = folder.appending(path: "host.json"); let bFile = folder.appending(path: "client.json")
        let a = Store(file: aFile); let b = Store(file: bFile)
        a.start(day: nil, shared: true)
        let id = try #require(a.active).id
        a.selectExercise(try #require(a.exercise("bench-barbell")))
        for _ in 0..<80 {
            var set = a.makeSet(try #require(a.current)); set.weight = 40; set.reps = 10
            #expect(a.saveSet(set))
        }
        let host = NearbySync(); host.store = a
        let client = NearbySync(); client.store = b
        defer { host.stop(); client.stop() }
        host.host(id)
        #expect(await waitFor { host.listeningPort != nil })
        client.join(code: host.code)
        #expect(await waitFor { host.connected && client.connected })
        #expect(b.sets.count == 80)
        #expect(a.state.nearbyPairing?.peerID == b.me.id)
        #expect(b.state.nearbyPairing?.peerID == a.me.id)
        host.endInviting()
        host.stop(clearPairing: false); client.stop(clearPairing: false)
        let reopenedA = Store(file: aFile); let reopenedB = Store(file: bFile)
        reopenedB.selectPerson(a.me.id)
        #expect(!reopenedB.canLog)
        reopenedB.selectPerson(b.me.id)
        reopenedB.selectExercise(try #require(reopenedB.exercise("squat-barbell")))
        var offline = reopenedB.makeSet(try #require(reopenedB.current)); offline.weight = 50; offline.reps = 8
        #expect(reopenedB.saveSet(offline))
        let restoredHost = NearbySync(); restoredHost.store = reopenedA
        let restoredClient = NearbySync(); restoredClient.store = reopenedB
        defer { restoredHost.stop(); restoredClient.stop() }
        reopenedA.didChange = { restoredHost.send() }; reopenedB.didChange = { restoredClient.send() }
        restoredHost.resume(); restoredClient.resume()
        #expect(await waitFor { restoredHost.connected && restoredClient.connected }, "\(restoredHost.status) / \(restoredClient.status)")
        #expect(!restoredHost.inviting)
        #expect(reopenedA.sets.count == 81); #expect(reopenedB.sets.count == 81)
        reopenedA.selectPerson(b.me.id); reopenedB.selectPerson(a.me.id)
        #expect(reopenedA.canLog); #expect(reopenedB.canLog)
    }

    @Test func existingSharedSessionCanRepairPairingWithCode() async throws {
        let a = store(); let b = store(); a.start(day: nil, shared: true)
        let id = try #require(a.active).id
        b.receive(a.state.ledger.revisions, workoutID: id); b.join(id)
        a.receive(b.state.ledger.revisions, workoutID: id)
        b.selectPerson(a.me.id); #expect(!b.canLog)
        let host = NearbySync(); host.store = a
        let client = NearbySync(); client.store = b
        defer { host.stop(); client.stop() }
        host.host(id)
        #expect(await waitFor { host.listeningPort != nil })
        client.join(code: host.code)
        #expect(await waitFor { host.connected && client.connected }, "\(host.status) / \(client.status)")
        #expect(a.active?.id == id); #expect(b.active?.id == id)
        #expect(a.activeMembers.count == 2); #expect(b.canLog)
        host.endInviting()
    }

    @Test func closingInvitationWithoutFriendStopsHostingAndDoesNotResume() async throws {
        let s = store(); s.start(day: nil, shared: true)
        let host = NearbySync(); host.store = s
        defer { host.stop() }
        let workoutID = try #require(s.active).id
        host.host(workoutID)
        #expect(await waitFor { host.listeningPort != nil })
        #expect(host.inviting)
        host.suspend()
        host.endInviting()
        host.resume()
        #expect(!host.inviting); #expect(host.listeningPort == nil)
        #expect(host.code.isEmpty); #expect(!host.connected)
        #expect(s.active?.id == workoutID)
        host.host(workoutID)
        #expect(await waitFor { host.listeningPort != nil })
        #expect(host.inviting); #expect(host.code.count == 4)
        host.endInviting()
        #expect(host.listeningPort == nil); #expect(host.code.isEmpty)
    }
    @Test func invalidCodesAndActiveWorkoutsDoNotStartDiscovery() {
        let s = store(); let client = NearbySync(); client.store = s
        for code in ["123", "12345", "abcd", "１２３４"] {
            client.join(code: code)
            #expect(!client.joining); #expect(client.joinError != nil)
        }
        s.start(day: nil, shared: false)
        client.join(code: "0123")
        #expect(!client.joining)
        #expect(client.joinError == "Finish your current workout before joining your friend.")
    }
    @Test func wrongPairingCodeCannotReadWorkout() async throws {
        let a = store(); let b = store(); a.start(day: nil, shared: true)
        let host = NearbySync(); host.store = a; let client = NearbySync(); client.store = b
        defer { host.stop(); client.stop() }
        host.host(try #require(a.active).id)
        #expect(await waitFor { host.listeningPort != nil })
        client.join(NearbyHost(id: "loopback", name: "Host", endpoint: .hostPort(host: "127.0.0.1", port: try #require(host.listeningPort))), code: host.code == "0000" ? "0001" : "0000")
        try? await Task.sleep(for: .seconds(2))
        #expect(!client.connected); #expect(b.workouts.isEmpty)
    }
}
