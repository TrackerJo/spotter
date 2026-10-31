import CloudKit
import Observation

@MainActor @Observable final class CloudSync {
    static let containerID = "iCloud.com.kazoom.spotter"
    var status = "iCloud not connected"
    var enabled = false
    var busy = false
    var connecting = false
    var connectionRequested: Bool {
        UserDefaults.standard.bool(forKey: "spotter.iCloudConnectionRequested") || store?.me.cloudIdentity != nil
    }
    var lastSync: Date?
    @ObservationIgnored weak var store: Store?
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var lastPersonalFetch = Date.distantPast
    @ObservationIgnored private var lastPersonalData: Data?
    var container: CKContainer { CKContainer(identifier: Self.containerID) }

    func connect() async {
        guard !connecting else { return }
        UserDefaults.standard.set(true, forKey: "spotter.iCloudConnectionRequested")
        connecting = true
        defer { connecting = false }
        do {
            guard try await container.accountStatus() == .available else { status = "Sign in to iCloud in iPhone Settings"; return }
            let identity = try await container.userRecordID().recordName
            guard let store else { return }
            if let previous = store.me.cloudIdentity, previous != identity {
                status = "A different iCloud account is signed in. Switch back to protect your saved profile."; enabled = false; return
            }
            if let index = store.state.profiles.firstIndex(where: { $0.id == store.me.id }) { store.state.profiles[index].cloudIdentity = identity; store.save(notify: false) }
            enabled = true; status = "iCloud connected"
            await sync()
        } catch { status = "iCloud unavailable: \(error.localizedDescription)" }
    }
    private func syncPersonal(_ store: Store) async throws {
        let localData = try PersonalSync.snapshot(store.state)
        guard localData != lastPersonalData || Date().timeIntervalSince(lastPersonalFetch) >= 30 else { return }
        let db = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "PersonalData")
        _ = try await db.save(zone)
        let id = CKRecord.ID(recordName: "Library", zoneID: zone.zoneID)
        var record: CKRecord
        var merged = store.state
        do {
            record = try await db.record(for: id)
            guard let asset = record["snapshot"] as? CKAsset, let url = asset.fileURL else { throw CocoaError(.coderReadCorrupt) }
            let remote = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: url))
            guard remote.version == store.state.version,
                  remote.profiles.contains(where: { $0.id == remote.ownID && $0.cloudIdentity == store.me.cloudIdentity }) else { throw CocoaError(.coderReadCorrupt) }
            let base = try store.state.personalSyncBase.map { try JSONDecoder().decode(LocalState.self, from: $0) }
            merged = try PersonalSync.merge(local: store.state, remote: remote, base: base)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "PersonalLibrary", recordID: id)
        }
        let data = try PersonalSync.snapshot(merged)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        record["snapshot"] = CKAsset(fileURL: url)
        let results = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        _ = try results.saveResults[id]?.get()
        // Edits can occur during the upload. Rebase them instead of replacing current state.
        let current = try PersonalSync.merge(local: store.state, remote: merged,
                                            base: JSONDecoder().decode(LocalState.self, from: localData))
        var persisted = current
        persisted.personalSyncBase = data
        guard store.applyPersonalSync(persisted) else { throw CocoaError(.fileWriteUnknown) }
        lastPersonalData = try PersonalSync.snapshot(store.state)
        lastPersonalFetch = Date()
    }
    func sync() async {
        guard enabled, !busy, Date() >= retryAfter, let store, !store.readOnly else { return }
        busy = true; defer { busy = false }
        do {
            // Recheck the account before every exchange. A switched account must not receive old data.
            let identity = try await container.userRecordID().recordName
            guard identity == store.me.cloudIdentity else { enabled = false; status = "iCloud account changed. Sync paused."; return }
            try await syncPersonal(store)
            lastSync = Date(); status = "iCloud up to date"
        } catch {
            let delay = (error as? CKError)?.retryAfterSeconds ?? 5
            retryAfter = Date().addingTimeInterval(max(5, delay))
            status = "Saved on this phone. iCloud will retry: \(error.localizedDescription)"
        }
    }
}
