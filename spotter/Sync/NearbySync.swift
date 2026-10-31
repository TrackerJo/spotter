import Foundation
import Network
import Security
import CryptoKit
import Observation

struct NearbyPacket: Codable {
    var version = 2
    var workoutID: String?
    var profile: Profile
    var revisions: [Revision]
    var snapshotID: String? = nil
    var acknowledgedSnapshotID: String? = nil

}
struct NearbyHost: Identifiable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
}
@MainActor @Observable final class NearbySync {
    var status = "Not connected"
    var hosts: [NearbyHost] = []
    var code = ""
    private(set) var connected = false
    private var transportReady = false
    private var receivedSnapshot = false
    private var pendingSnapshotID: String?
    private var snapshotAcknowledged = false
    private func clearReadiness() {
        connected = false; transportReady = false; receivedSnapshot = false
        pendingSnapshotID = nil; snapshotAcknowledged = false
        store?.nearbyReadyWorkoutID = nil; store?.nearbyPeerID = nil
    }
    private func updateReadiness() {
        guard transportReady, receivedSnapshot, snapshotAcknowledged,
              let workoutID, let remoteProfileID else { return }
        connected = true; status = "Nearby connected · Synced"
        store?.nearbyReadyWorkoutID = workoutID; store?.nearbyPeerID = remoteProfileID
        joining = false; joinTimeout?.cancel(); joinTimeout = nil
        persistPairing()
    }
    private(set) var inviting = false
    var joining = false
    var joinError: String?
    private var suspended = false
    var lastReceived: Date?
    var workoutID: String?
    @ObservationIgnored weak var store: Store?
    @ObservationIgnored private var resumePort: NWEndpoint.Port?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var isHost = false
    @ObservationIgnored private var remoteProfileID: String?
    @ObservationIgnored private var retryEndpoint: NWEndpoint?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCode: String?
    @ObservationIgnored private var joinTimeout: Task<Void, Never>?
    @ObservationIgnored private var sent: Set<String> = []
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    var listeningPort: NWEndpoint.Port? {
        guard let listener, case .ready = listener.state else { return nil }
        return listener.port
    }
    private static let service = "_spotter-gym._tcp"

    private func parameters(_ passcode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let normalized = passcode.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let key = Data(SHA256.hash(data: Data(("spotter-nearby-v1:" + normalized).utf8)))
        let identity = Data("spotter-nearby-v1".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, DispatchData(bytes: keyBytes) as __DispatchData, DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        sec_protocol_options_add_tls_ciphersuite(tls.securityProtocolOptions, SSLCipherSuite(TLS_PSK_WITH_AES_128_GCM_SHA256))
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
    func host(_ workoutID: String) {
        startHosting(workoutID, existingCode: nil)
    }
    private func startHosting(_ workoutID: String, existingCode: String?, inviting: Bool = true, port: NWEndpoint.Port? = nil) {
        stop(clearPairing: false)
        guard let store, let workout = store.workouts.first(where: { $0.id == workoutID }), !workout.demo, workout.shared, store.active == nil || store.active?.id == workoutID else { return }
        isHost = true; self.inviting = inviting; self.workoutID = workoutID
        remoteProfileID = store.state.nearbyPairing.flatMap { $0.workoutID == workoutID ? $0.peerID : nil }
            ?? store.members.first { $0.workoutID == workoutID && !store.ownsProfile($0.profile.id) && $0.managedByID == nil && !$0.deleted }?.profile.id
        code = existingCode ?? String(format: "%04d", Int.random(in: 0...9999))
        do {
            let listener = try NWListener(using: parameters(code), on: port ?? .any)
            self.listener = listener
            // Bonjour is also the paired client's reconnect address. Keep it alive
            // after the invitation closes, including across host suspension.
            let name = store.state.nearbyPairing.flatMap { $0.workoutID == workoutID && $0.code == code ? $0.serviceName : nil }
                ?? "\(store.me.name.prefix(24)) · \(Self.discoveryID(code))"
            listener.service = NWListener.Service(name: name, type: Self.service)
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener,
                          self.connection == nil, self.inviting || self.remoteProfileID != nil else { connection.cancel(); return }
                    self.configure(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    if case .failed(let error) = state { self?.status = "Nearby unavailable: \(error.localizedDescription)" }
                }
            }
            listener.start(queue: .main); status = "Waiting for your friend"
        } catch { status = error.localizedDescription }
    }
    func endInviting() {
        guard isHost, inviting else { return }
        inviting = false
        // Removing the service strands service-endpoint reconnects and can tear
        // down the peer-to-peer route. The pinned profile still rejects new peers.
        // Keep the existing friend's transport and reconnect address alive.
        // An unfinished handshake does not count as a joined friend.
        if remoteProfileID == nil { stop() }
    }
    func browse() {
        stop(); status = "Looking for nearby workouts"
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.hosts = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return NearbyHost(id: String(describing: result.endpoint), name: name, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
                self?.joinDiscoveredHost()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed(let error) = state {
                    if self?.joining == true { self?.failJoin("Couldn’t find nearby workouts. Allow Local Network access for Spotter in Settings, then try again.") }
                    else { self?.status = "Discovery failed: \(error.localizedDescription)" }
                }
            }
        }
        browser.start(queue: .main)
    }
    static func discoveryID(_ code: String) -> String {
        SHA256.hash(data: Data(("spotter-code:" + code).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    func join(code: String) {
        guard code.count == 4, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            joinError = "Enter your friend’s four-digit code."; return
        }
        let existingWorkout = store?.active.flatMap { $0.shared && !$0.demo ? $0.id : nil }
        let existingPeer = store?.members.first { $0.workoutID == existingWorkout && $0.profile.id != store?.me.id && $0.managedByID == nil && !$0.deleted }?.profile.id
        guard store?.active == nil || store?.active?.finished != nil || (existingWorkout != nil && existingPeer != nil) else {
            joinError = "Finish your current workout before joining your friend."; return
        }
        browse()
        workoutID = existingWorkout; remoteProfileID = existingPeer
        pendingCode = code; joining = true; joinError = nil
        joinTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.joining else { return }
            self.failJoin("Couldn’t join. Check the code and keep both phones nearby with Wi-Fi on and Spotter open.")
        }
        joinDiscoveredHost()
    }
    private func joinDiscoveredHost() {
        guard let pendingCode else { return }
        let matches = hosts.filter { $0.name.hasSuffix(" · " + Self.discoveryID(pendingCode)) }
        guard matches.count <= 1 else {
            failJoin("Two workouts have this code. Ask your friend to close the invitation sheet and open it again for a new code."); return
        }
        guard let host = matches.first else { return }
        self.pendingCode = nil
        join(host, code: pendingCode)
    }
    private func failJoin(_ message: String) {
        stop(); joinError = message
    }
    func join(_ host: NearbyHost, code: String) {
        self.code = code; retryEndpoint = host.endpoint
        connection?.cancel(); connection = nil
        configure(NWConnection(to: host.endpoint, using: parameters(code)))
    }
    private func configure(_ connection: NWConnection) {
        clearReadiness()
        self.connection = connection; lastReceived = Date(); sent = []; status = "Connecting securely…"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.transportReady = true; self.status = "Nearby connected · Syncing…"; self.send(force: true); self.receiveHeader(connection)
                    self.reconciliationTask?.cancel()
                    self.reconciliationTask = Task { [weak self, weak connection] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled, let self, let connection,
                                  self.connection === connection else { return }
                            if let lastReceived = self.lastReceived, Date().timeIntervalSince(lastReceived) > 15 {
                                self.disconnected(connection); return
                            }
                            self.send(force: true)
                        }
                    }
                case .failed(let error):
                    if self.joining { self.failJoin("Couldn’t connect. Check your friend’s code and try again."); return }
                    self.status = "Disconnected. Check the pairing code. \(error.localizedDescription)"
                    self.disconnected(connection)
                case .cancelled: self.disconnected(connection)
                case .waiting:
                    self.status = "Nearby disconnected · Reconnecting…"
                    self.disconnected(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    private func disconnected(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        reconciliationTask?.cancel(); reconciliationTask = nil
        self.connection = nil; clearReadiness(); sent = []
        status = "Nearby disconnected · Reconnecting…"
        connection.cancel()
        guard !suspended, let endpoint = retryEndpoint else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.connection == nil else { return }
            self.configure(NWConnection(to: endpoint, using: self.parameters(self.code)))
        }
    }
    func send(force: Bool = false) {
        guard transportReady, let connection, let store else { return }
        let events = workoutID.map { id in store.state.ledger.revisions.filter { $0.workoutID == id && (force || !sent.contains($0.id)) } } ?? []
        let chunks = events.isEmpty ? [[]] : stride(from: 0, to: events.count, by: 75).map { Array(events[$0..<min($0 + 75, events.count)]) }
        let snapshotID = force && workoutID != nil ? UUID().uuidString : nil
        if !connected, let snapshotID { pendingSnapshotID = snapshotID; snapshotAcknowledged = false }
        for (index, chunk) in chunks.enumerated() {
            let packet = NearbyPacket(workoutID: workoutID, profile: store.me, revisions: chunk,
                                      snapshotID: index == chunks.count - 1 ? snapshotID : nil)
            guard let data = try? JSONEncoder().encode(packet), data.count <= 4_000_000 else { status = "Nearby packet is too large"; return }
            var length = UInt32(data.count).bigEndian
            var frame = Data(bytes: &length, count: 4); frame.append(data)
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection else { return }
                    if let error {
                        self.status = "Nearby send failed: \(error.localizedDescription)"
                        self.disconnected(connection)
                    }
                }
            })
            sent.formUnion(chunk.map(\.id))
        }
    }
    private func receiveHeader(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                guard error == nil, !complete, let data, data.count == 4 else { self.disconnected(connection); return }
                let length = data.reduce(0) { ($0 << 8) | Int($1) }
                guard (1...4_000_000).contains(length) else { self.disconnected(connection); return }
                self.receiveBody(connection, length: length)
            }
        }
    }
    private func receiveBody(_ connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                guard error == nil, !complete, let data, data.count == length,
                      let packet = try? JSONDecoder().decode(NearbyPacket.self, from: data), packet.version == 2 else { self.disconnected(connection); return }
                self.handle(packet); self.receiveHeader(connection)
            }
        }
    }
    private func handle(_ packet: NearbyPacket) {
        guard let store, !packet.profile.isDemo else { return }
        if let remoteProfileID, remoteProfileID != packet.profile.id { connection?.cancel(); status = "A different participant tried to connect"; return }
        remoteProfileID = packet.profile.id
        if !isHost, workoutID == nil { workoutID = packet.workoutID }
        guard let workoutID else { return }
        guard packet.workoutID == nil || packet.workoutID == workoutID else { connection?.cancel(); return }
        lastReceived = Date()
        if let acknowledgment = packet.acknowledgedSnapshotID {
            if acknowledgment == pendingSnapshotID { snapshotAcknowledged = true; updateReadiness() }
            return
        }
        let needsInitialSnapshot = !isHost && pendingSnapshotID == nil
        let before = store.state.ledger.revisions.count
        guard packet.profile.id != store.me.id, store.receive(packet.revisions, workoutID: workoutID) else {
            if let connection { disconnected(connection) }; return
        }
        lastReceived = Date()
        if !isHost, store.workouts.contains(where: { $0.id == workoutID }), !store.members.contains(where: { $0.workoutID == workoutID && $0.profile.id == store.me.id }) {
            store.join(workoutID)
            if store.active?.id == workoutID, store.members.contains(where: { $0.workoutID == workoutID && $0.profile.id == store.me.id }) {
                joining = false; joinTimeout?.cancel(); joinTimeout = nil
            } else if joining { failJoin(store.error ?? "This workout is no longer available."); return }
        }
        if needsInitialSnapshot { send(force: true) }
        else if store.state.ledger.revisions.count != before || packet.workoutID == nil { send() }
        if let snapshotID = packet.snapshotID, packet.workoutID == workoutID {
            receivedSnapshot = true
            sendAcknowledgment(snapshotID)
            updateReadiness()
        }
    }
    private func sendAcknowledgment(_ snapshotID: String) {
        guard transportReady, let connection, let store else { return }
        let packet = NearbyPacket(workoutID: workoutID, profile: store.me, revisions: [], acknowledgedSnapshotID: snapshotID)
        guard let data = try? JSONEncoder().encode(packet) else { return }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4); frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            Task { @MainActor in
                guard error != nil, let self, let connection, self.connection === connection else { return }
                self.disconnected(connection)
            }
        })
    }
    func suspend() {
        reconciliationTask?.cancel(); reconciliationTask = nil
        suspended = true
        retryTask?.cancel(); retryTask = nil
        resumePort = listeningPort
        listener?.cancel(); browser?.cancel()
        let old = connection; connection = nil; old?.cancel()
        clearReadiness(); sent = []; status = "Paused while app is in the background"
    }
    private func persistPairing() {
        guard let store, let workoutID, let remoteProfileID else { return }
        let endpoint: NWEndpoint?
        if isHost, let service = listener?.service, let name = service.name {
            endpoint = .service(name: name, type: service.type, domain: service.domain ?? "local.", interface: nil)
        } else { endpoint = retryEndpoint }
        guard case .service(let name, let type, let domain, _) = endpoint else { return }
        store.state.nearbyPairing = NearbyPairing(workoutID: workoutID, code: code, isHost: isHost,
            peerID: remoteProfileID, serviceName: name, serviceType: type, serviceDomain: domain)
        store.save(notify: false)
    }
    func reconnect() {
        if suspended { resume(); return }
        if transportReady { send(force: true); return }
        if let endpoint = retryEndpoint {
            retryTask?.cancel()
            configure(NWConnection(to: endpoint, using: parameters(code)))
        } else if let workoutID, isHost {
            startHosting(workoutID, existingCode: code, inviting: false, port: resumePort)
        } else { restorePairing() }
    }
    private func restorePairing() {
        guard let store, let pairing = store.state.nearbyPairing,
              store.workouts.contains(where: { $0.id == pairing.workoutID && $0.shared && !$0.demo }),
              store.active == nil || store.active?.id == pairing.workoutID else { return }
        if pairing.isHost {
            startHosting(pairing.workoutID, existingCode: pairing.code, inviting: false)
        } else {
            workoutID = pairing.workoutID; code = pairing.code; remoteProfileID = pairing.peerID
            let endpoint = NWEndpoint.service(name: pairing.serviceName, type: pairing.serviceType,
                                              domain: pairing.serviceDomain, interface: nil)
            retryEndpoint = endpoint
            configure(NWConnection(to: endpoint, using: parameters(code)))
        }
    }
    func resume() {
        guard suspended else { if workoutID == nil { restorePairing() }; return }
        suspended = false
        if isHost, let workoutID {
            let previousPeer = remoteProfileID
            let wasInviting = inviting
            startHosting(workoutID, existingCode: code, inviting: wasInviting, port: resumePort)
            remoteProfileID = previousPeer
        } else if let endpoint = retryEndpoint {
            configure(NWConnection(to: endpoint, using: parameters(code)))
        }
    }
    func stop(clearPairing: Bool = true) {
        if clearPairing, let store { store.state.nearbyPairing = nil; store.save(notify: false) }
        reconciliationTask?.cancel(); reconciliationTask = nil
        joinTimeout?.cancel(); joinTimeout = nil; pendingCode = nil; joining = false; joinError = nil
        suspended = false
        retryTask?.cancel(); retryTask = nil; retryEndpoint = nil
        listener?.cancel(); browser?.cancel(); let old = connection; connection = nil; old?.cancel()
        resumePort = nil; listener = nil; browser = nil; hosts = []; clearReadiness(); lastReceived = nil; isHost = false; inviting = false
        workoutID = nil; remoteProfileID = nil; code = ""; sent = []; status = "Not connected"
    }
}
