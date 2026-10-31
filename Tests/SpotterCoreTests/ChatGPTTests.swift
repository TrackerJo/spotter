import Foundation
import Testing
import CryptoKit
import Security
@testable import SpotterCore

struct ChatGPTProtocolTests {
    @Test func pkceAndFormEncodingFollowOAuthContract() throws {
        #expect(ChatGPTOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let form = String(decoding: ChatGPTOAuth.form(["code": "a+b&c= d", "redirect_uri": "http://127.0.0.1:1234/auth/callback"]), as: UTF8.self)
        #expect(form.contains("code=a%2Bb%26c%3D%20d"))
        #expect(try ChatGPTOAuth.random().count == 43)
    }
    @Test func callbacksRejectMissingStateChangedClientAndDeclinedConsent() throws {
        func callback(_ query: String, client: String? = nil) throws -> String {
            try ChatGPTOAuth.callback(URL(string: "http://127.0.0.1:1/auth/callback?" + query)!, state: "expected", clientID: client).clientID
        }
        #expect(try callback("code=abc&state=expected&client_id=oaiapp_new") == "oaiapp_new")
        #expect(try callback("code=abc&state=expected", client: "oaiapp_saved") == "oaiapp_saved")
        #expect(throws: ChatGPTError.self) { try callback("code=abc&state=wrong&client_id=oaiapp_new") }
        #expect(throws: ChatGPTError.self) { try callback("code=abc&state=expected&state=wrong&client_id=oaiapp_new") }
        #expect(throws: ChatGPTError.self) { try callback("code=abc&state=expected&client_id=oaiapp_other", client: "oaiapp_saved") }
        #expect(throws: ChatGPTError.self) { try callback("code=abc&state=expected&client_id=dynamic_agent_client") }
        #expect(throws: ChatGPTError.self) { try callback("state=expected&error=access_denied") }
    }
    @Test func signedIdentityRequiresValidSignatureIssuerAudienceExpiryAndNonce() throws {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        let jwk: [String: Any] = ["kid": "test", "kty": "EC", "crv": "P-256", "x": ChatGPTOAuth.base64URL(point.subdata(in: 1..<33)), "y": ChatGPTOAuth.base64URL(point.subdata(in: 33..<65))]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func token(_ changes: [String: Any] = [:], signer: P256.Signing.PrivateKey? = nil) throws -> String {
            let header = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "test"]))
            var claims: [String: Any] = ["iss": ChatGPTOAuth.issuer, "sub": "owner", "aud": "oaiapp_test", "exp": now.timeIntervalSince1970 + 3600, "nonce": "expected"]
            claims.merge(changes) { _, value in value }
            let body = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims))
            let data = Data("\(header).\(body)".utf8)
            return "\(header).\(body)." + ChatGPTOAuth.base64URL(try (signer ?? key).signature(for: data).rawRepresentation)
        }
        #expect(try ChatGPTOAuth.verifyIDToken(token(), jwks: [jwk], clientID: "oaiapp_test", nonce: "expected", now: now)["sub"] as? String == "owner")
        for changes: [String: Any] in [["iss": "https://example.com"], ["aud": "other"], ["exp": now.timeIntervalSince1970 - 1], ["nonce": "other"], ["aud": ["oaiapp_test", "other"]], ["azp": "other"], ["nbf": now.timeIntervalSince1970 + 100]] {
            #expect(throws: ChatGPTError.self) { try ChatGPTOAuth.verifyIDToken(token(changes), jwks: [jwk], clientID: "oaiapp_test", nonce: "expected", now: now) }
        }
        #expect(throws: ChatGPTError.self) { try ChatGPTOAuth.verifyIDToken(token(signer: P256.Signing.PrivateKey()), jwks: [jwk], clientID: "oaiapp_test", nonce: "expected", now: now) }
    }
    @Test func rsaIdentitySignatureIsVerifiedAgainstPublishedKey() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 0
        func read() -> Data {
            offset += 1
            var count = Int(der[offset]); offset += 1
            if count >= 128 {
                let length = count & 127; count = 0
                for _ in 0..<length { count = count * 256 + Int(der[offset]); offset += 1 }
            }
            let bytes = der.subdata(in: offset..<(offset + count)); offset += count
            return bytes
        }
        _ = der[offset]; offset += 1
        let first = Int(der[offset]); offset += 1
        if first >= 128 { offset += first & 127 }
        let n = Data(read().drop(while: { $0 == 0 })), e = read()
        let jwk: [String: Any] = ["kid": "rsa", "kty": "RSA", "n": ChatGPTOAuth.base64URL(n), "e": ChatGPTOAuth.base64URL(e)]
        let header = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "rsa"]))
        let body = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["iss": ChatGPTOAuth.issuer, "sub": "owner", "aud": "client", "nonce": "nonce", "exp": Date().timeIntervalSince1970 + 3600] as [String: Any]))
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(header).\(body)".utf8) as CFData, nil)) as Data
        let token = "\(header).\(body)." + ChatGPTOAuth.base64URL(signature)
        #expect(try ChatGPTOAuth.verifyIDToken(token, jwks: [jwk], clientID: "client", nonce: "nonce")["sub"] as? String == "owner")
    }
    @Test func streamRequiresCompletedEventAndRejectsLateUsageFailure() throws {
        var stream = ChatGPTStream()
        try stream.consume(#"{"type":"response.output_text.delta","delta":"partial"}"#)
        #expect(throws: ChatGPTError.self) { try stream.finish() }
        do {
            try stream.consume(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"#)
            Issue.record("Late stream failure was accepted")
        } catch let error as ChatGPTError { #expect(error.isUsageLimit) }
        try stream.consume(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"complete"}]}]}}"#)
        try stream.finish()
        #expect(stream.text == "complete")
        var incomplete = ChatGPTStream()
        #expect(throws: ChatGPTError.self) { try incomplete.consume(#"{"type":"response.incomplete"}"#) }
    }
    @Test func metadataOnlyCompletionPreservesStreamedTextAndToolCalls() throws {
        var stream = ChatGPTStream()
        try stream.consume(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Your bench "}"#)
        try stream.consume(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"is improving."}"#)
        try stream.consume(#"{"type":"response.output_text.done","output_index":0,"content_index":0,"text":"Your bench is improving."}"#)
        try stream.consume(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        try stream.finish()
        #expect(stream.text == "Your bench is improving.")
        #expect(stream.output.last?["role"] as? String == "assistant")

        var tool = ChatGPTStream()
        try tool.consume(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_history","name":"exercise_history","arguments":"{\"exercise_id\":\"bench-barbell\"}"}}"#)
        try tool.consume(#"{"type":"response.completed","response":{"status":"completed"}}"#)
        try tool.finish()
        #expect(tool.output.first?["name"] as? String == "exercise_history")
        #expect(tool.output.first?["call_id"] as? String == "call_history")
    }
    @Test func sparseFinalItemsDoNotEraseCompletedContentOrReasoning() throws {
        var stream = ChatGPTStream()
        try stream.consume(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","encrypted_content":"opaque","summary":[]}}"#)
        try stream.consume(#"{"type":"response.output_item.done","output_index":1,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}}"#)
        try stream.consume(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":null},{"type":"message","role":"assistant","content":[]}]}}"#)
        try stream.finish()
        #expect(stream.text == "Answer")
        #expect(stream.output.first?["encrypted_content"] as? String == "opaque")
    }
    @Test func multipleTextPartsAndRefusalsAreHandledWithoutDuplicateText() throws {
        var stream = ChatGPTStream()
        try stream.consume(#"{"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"Second"}"#)
        try stream.consume(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"First "}"#)
        try stream.consume(#"{"type":"response.output_text.done","output_index":0,"content_index":0,"text":"First "}"#)
        try stream.consume(#"{"type":"response.completed","response":{"status":"completed"}}"#)
        #expect(stream.text == "First Second")
        var refusal = ChatGPTStream()
        try refusal.consume(#"{"type":"response.refusal.done","refusal":"I can’t help with that request."}"#)
        try refusal.consume(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        #expect(refusal.text == "I can’t help with that request.")
    }
    @Test func draftsMustBeStructuredAndPassExistingParser() throws {
        let draft = try ChatGPTDraft.parse(#"{"csv":"Upper\nExercise,Sets,Rep range,RIR,Notes\nBench press,3,8-12,2,","explanation":"Preserved targets"}"#)
        let parsed = try PlanCSV.parse(draft.csv, name: "Draft", library: [])
        #expect(parsed.plan.days.count == 1)
        #expect(throws: ChatGPTError.self) { try ChatGPTDraft.parse("Here is your plan") }
        #expect(throws: ChatGPTError.self) { try ChatGPTDraft.parse(#"{"csv":"","explanation":"Unable to parse"}"#) }
    }
}

@MainActor struct ChatGPTPrivacyTests {
    func store() -> Store { Store(file: FileManager.default.temporaryDirectory.appending(path: "SpotterChatGPTTests/\(UUID().uuidString)/state.json")) }
    @Test func toolsOnlyExposeOwnerEvenWhenViewingFriendAndFriendKeepsTraining() throws {
        let owner = store(), friend = store()
        owner.start(day: nil, shared: true)
        let workoutID = try #require(owner.active).id
        friend.receive(owner.state.ledger.revisions, workoutID: workoutID); friend.join(workoutID)
        owner.receive(friend.state.ledger.revisions, workoutID: workoutID)
        owner.selectExercise(try #require(owner.exercise("bench-barbell")))
        var set = owner.makeSet(try #require(owner.current)); set.weight = 100; set.reps = 8; set.notes = "owner-note"
        #expect(owner.saveSet(set))
        friend.selectExercise(try #require(friend.exercise("bench-barbell")))
        var foreign = friend.makeSet(try #require(friend.current)); foreign.weight = 777; foreign.reps = 10; foreign.notes = "private-friend-note"
        #expect(friend.saveSet(foreign))
        owner.receive(friend.state.ledger.revisions, workoutID: workoutID)
        owner.selectPerson(friend.me.id)
        owner.finish()
        owner.selectPerson(friend.me.id)
        let snapshot = ChatGPTTrainingData(store: owner)
        #expect(snapshot.workouts.count == 1)
        let output = try snapshot.call("get_workout", arguments: "{\"workout_id\":\"\(workoutID)\"}")
        #expect(output.contains("owner-note"))
        #expect(!output.contains("private-friend-note"))
        #expect(!output.contains(friend.me.id))
        #expect(!output.contains("777"))
        #expect(try snapshot.call("list_workouts", arguments: "{\"profile_id\":\"\(friend.me.id)\"}").contains("unavailable"))
        #expect(try !snapshot.call("list_profiles", arguments: "{}").contains(friend.me.id))
        #expect(try snapshot.call("training_summary", arguments: "{\"days\":90}").contains("800"))
        #expect(try snapshot.call("get_workout", arguments: "{\"workout_id\":\"foreign\"}").contains("not found"))
    }
    @Test func managedProfileProgressStaysSeparate() throws {
        let s = store()
        let jamie = try #require(s.createProfile(name: "Jamie"))
        s.start(day: nil, shared: false)
        #expect(s.addProfileToWorkout(jamie.id))
        s.selectPerson(jamie.id)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        var set = s.makeSet(try #require(s.current))
        set.weight = 135; set.reps = 8; set.notes = "Jamie-only"
        #expect(s.saveSet(set))
        s.finish()
        let snapshot = ChatGPTTrainingData(store: s)
        let profiles = try snapshot.call("list_profiles", arguments: "{}")
        #expect(profiles.contains(jamie.id))
        #expect(profiles.contains("Jamie"))
        let args = "{\"profile_id\":\"\(jamie.id)\",\"exercise_id\":\"bench-barbell\"}"
        #expect(try snapshot.call("exercise_history", arguments: args).contains("Jamie-only"))
        #expect(try !snapshot.call("exercise_history", arguments: "{\"exercise_id\":\"bench-barbell\"}").contains("Jamie-only"))
        #expect(try snapshot.call("training_summary", arguments: args).contains("1080"))
        #expect(try snapshot.call("list_plans", arguments: args) == "[]")
        #expect(try snapshot.call("list_workouts", arguments: "{\"profile_id\":\"unknown\"}").contains("unavailable"))
    }
    @Test func trainingToolsUseSupportedNamespaceAndRejectForeignCalls() throws {
        let namespace = try #require(ChatGPTTrainingData.requestTools.first)
        #expect(namespace["type"] as? String == "namespace")
        #expect(namespace["name"] as? String == "spotter")
        let tools = try #require(namespace["tools"] as? [[String: Any]])
        #expect(tools.count == 7)
        #expect(tools.allSatisfy { $0["type"] as? String == "function" })
        _ = try JSONSerialization.data(withJSONObject: ChatGPTTrainingData.requestTools)
        let data = ChatGPTTrainingData(store: store())
        #expect(try data.call("list_workouts", arguments: "{}", namespace: "spotter").contains("total"))
        #expect(throws: ChatGPTError.self) { try data.call("list_workouts", arguments: "{}", namespace: "other") }
    }
    @Test func toolsDoNotWriteAndSkipActiveWorkouts() throws {
        let s = store()
        s.start(day: nil, shared: false)
        s.selectExercise(try #require(s.exercise("bench-barbell")))
        let before = s.state.ledger
        let snapshot = ChatGPTTrainingData(store: s)
        #expect(snapshot.workouts.isEmpty)
        #expect(try snapshot.call("delete_workout", arguments: "{}").contains("read-only"))
        #expect(try snapshot.call("list_workouts", arguments: "{\"limit\":100000,\"offset\":-1}").contains("\"total\":0"))
        #expect(s.state.ledger == before)
    }
}
