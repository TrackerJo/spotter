# Spotter

A native iPhone workout log for you and the people you train with. SwiftUI, Swift Charts, local persistence, real encrypted nearby networking, and private CloudKit backup for local workouts and personal settings. Requires iOS 18 or later. No third-party dependencies.

## Run

1. Open `spotter.xcodeproj` in Xcode 16 or later (verified with Xcode 26.6).
2. Select the `spotter` scheme and an iPhone simulator, then Run. Simulator builds do not require an iCloud account for local workouts.
3. For a physical iPhone, select your development team under Signing & Capabilities. The current bundle identifier is `com.kazoom.spotter`.
4. Open the profile button to name your profile. Use **Manage profiles** to create named profiles for other people whose workouts you log on this phone.

## Log for multiple people on one phone

Create profiles under **Profile → Manage profiles**, or create one while adding participants. Tap **Add profiles** on the Ready to start screen, or open the workout’s options menu and choose **Add profiles** during training. Add any saved profiles, then use **Logging for** to switch people. Exercises, set values, timers, previous performances, and progress stay separate for each person.

Finish saves results for you and all profiles managed on this phone. A friend connected through Nearby can keep training independently. In **Progress**, choose **Viewing data for** to see a person’s summary, charts, and past workouts; changing this selection does not change workout logging focus. You can rename a managed profile and open its progress from **Manage profiles**. History imports use the profile selected in Progress. Deleting one profile’s workout preserves the other participants’ results. Profiles and workouts without Nearby sync through the same private iCloud account.

To build without signing:

```sh
xcodebuild -project spotter.xcodeproj -scheme spotter \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/spotter-build CODE_SIGNING_ALLOWED=NO build
```

## Import a training plan

Open **Plans → Import CSV** and choose a file or paste CSV text. Name the plan, preview its days and exercises, then tap **Import plan**. Each day has a title row followed by `Exercise,Sets,Rep range,RIR,Notes` headers and exercise rows. A leading blank column, blank rows, quoted commas, and en-dash rep ranges are supported, including the Workout Journal split format.

RIR can be blank, a single target for all sets, or a quoted list with one target per set, such as `"2, 1, 0–1"`. Ranges are preserved as editable per-set targets. Notes remain separate. Exact library names and aliases are reused; unmatched names are flagged as custom exercises. Review each one to choose equipment, a primary muscle, and optional secondary muscles before importing. If it already exists under another name, use **Find existing exercise** to search the local library and select a match. Every occurrence uses the existing exercise and its history; the CSV name is saved as an alias at import and recognized in future imports. The plan and reviewed exercises are saved together; canceling saves neither. Alternative names such as “Cable/Machine Fly” or “Incline DB/Smith Press” create one plan slot with two exercise choices. The slot displays both names joined by “or”; select the movement in the workout chooser. Either choice uses the shared targets, completing either satisfies the slot, and histories remain separate. In a training day, open an exercise and tap **Add alternative** to choose another exercise with the same tracking type; you can change or remove it later. Imported days use a flexible schedule until you assign weekdays.

In an exercise’s targets, enable **Target RIR → Different RIR for each set** to edit individual targets and ranges. During logging, the current working set’s target appears next to optional actual RIR. Warm-ups and extra sets have no prescribed RIR, and targets never prefill actual RIR.

## Import past workouts

Open **Progress → Import history** and choose a CSV file or paste your journal. Use `Date,Exercise,Weight,Reps,RIR,Notes`; title rows above the header are allowed. Select the weight unit and year for dates without a year (2026 by default). Explicit years are preserved. Check the dates in the preview, especially entries that run backward in time.

Blank date and exercise cells continue the preceding workout/exercise. Blank weights inherit the last weight within that exercise; a new exercise starts fresh. Fractional reps (including 0.5), bodyweight (`bw`), numeric RIR, RIR ranges, and quoted notes are preserved. Weight expressions such as `55-45` or `85? 25 + bar` remain in notes with no numeric weight, and are excluded from weight calculations. Non-numeric RIR and unexpected date-column annotations are kept in notes and flagged for review.

Review new custom exercises or match them to existing library entries, just as with plan imports. Confirm flagged values before importing. All history, custom exercise details, and aliases save together; canceling saves nothing. Reimporting the same CSV for the same profile/year/unit skips already imported workouts. Dates use noon for ordering; set timestamps and workout durations are unknown. Imported workouts have no prescribed targets and do not qualify for target-based progression suggestions. Your active workout and reusable plans remain intact.

## At the gym: nearby connection

Nearby transfer uses Apple's Network framework, Bonjour discovery, `includePeerToPeer`, and TLS 1.2 with an authenticated pre-shared key. It works over direct peer-to-peer Wi-Fi or an available local network. **Joining gym Wi-Fi and internet access are not required. This is not a Bluetooth-only implementation.** Keep Wi-Fi enabled on both iPhones.

1. On the first phone, choose the suggested day or tap **Change**, then tap **Invite a friend**.
2. Nearby hosting opens automatically. Show the private four-digit code to your friend.
3. On the second phone, choose **Join a friend**, enter the code, and tap **Join**. The host taps **Start workout** when ready.
4. Joining closes the sheet automatically. Both friends can log sets for either person immediately.
5. Both phones can select either participant; each sees that participant's own entries, targets, and previous performance.

Both phones can view either person. Partner editing requires Nearby to be connected and both phones to finish exchanging saved state. While disconnected, you can edit only your own session. Connection and syncing status stay visible on the workout screen, with an explanation when the friend’s session is read-only. Stale set or target editors refuse to overwrite an update already received from the other phone and ask you to reopen the item. Truly simultaneous edits preserve both versions for review; independent new sets merge without overwriting each other. New set drafts choose their order and working-set slot using the latest local data when saved. Stable ID tie-breakers keep the display order consistent when concurrent additions have the same order.

Changes transmit immediately after a successful local save. A five-second exchange repairs missed delivery. Reconnects replay the full session in ordered chunks and acknowledge receipt in both directions before enabling partner editing. Saved pairing details restore the connection after relaunch. Repeated delivery uses the same revision IDs and does not create new sets. Backgrounding closes the live connection; foregrounding resumes it. Keep both apps open for the best workout experience. A new host invitation creates a new private code. Only give the code to the intended friend.

Joining also shares the latest completed performance for each exercise, explicitly disclosed in the join screen, so a partner can see personal starting values. Full private solo workout diaries and personal exercise-name overrides are not transmitted.

The Network implementation and encryption have been tested over real local sockets. Actual peer-to-peer radio discovery, iOS local-network permission behavior, range and latency must still be verified on two physical iPhones. The sub-second local test is not a promise about radio conditions.

## Personal iCloud backup

CloudKit privately syncs plans, solo workout history, custom exercises, and personal settings across the same account. Shared-session revisions and pairing secrets are excluded from uploads. Legacy iCloud copies of shared sessions are ignored on download. There are no shared-workout cloud invitations or cloud fallback.

Enable the `iCloud.com.kazoom.spotter` container in your provisioning profile and deploy the `PersonalLibrary` record type with a `snapshot` Asset field before distribution. Open **Profile → Connect to iCloud** to check personal sync status. Live CloudKit backup still requires verification with a provisioned account.

## Workout flow

- Plans contain ordered training days, optional weekdays, and per-exercise sets, rep range, optional RIR, rest and notes. Day order and exercise order can be edited; missed days do not block anything.
- The start screen suggests today’s training day, offers a compact day chooser, and lets a friend join a waiting room before the host starts. Solo workouts start directly.
- The session overview shows finished exercises, a personal timer between sets, Finish, and a raised Add exercise button. An unfinished selected exercise can be resumed.
- Add exercise shows the suggested next movement, the remaining movements in the selected day, and a searchable library. Custom exercises can be created and selected from that sheet.
- Friends share the host’s day while choosing exercises independently. Switching people preserves each person’s own selection, history, logged sets, and timer between sets. Day changes apply to both people; existing exercise targets stay frozen.
- The selected exercise replaces the session overview beneath the persistent participant switcher. It shows the name, previous weight and performance, suggested sets/reps, Log set, logged sets, and Finish exercise. Switching people restores their own selected exercise or overview. Finishing returns to the session overview.
- Set entry supports weight/reps, bodyweight, assistance, seconds, distance, warm-ups, optional RIR and notes. Log set saves a finished record and starts rest. Cancel creates no set; edits save only on Save changes. Sets can be deleted with undo.
- Historical values prefill the set form; a suggested weight increase requires an explicit tap. Blank RIR stays nil. Warm-ups do not consume prescribed working-set slots.
- Targets are copied into the session and frozen after the first logged set. Changes to reusable plans never rewrite recorded history.
- Finish my session ends participation for the phone owner and profiles managed on that phone in a shared session. The connected friend stays active; completed participant records remain available for each person’s history and progress. Legacy unlogged drafts remain preserved in storage and are excluded from displayed sets and progress.

Weight, assistance, and increments use pounds. Distances use feet or miles in set entry, targets, history, and charts. Existing metric records are converted for display without rewriting history; saved personal increments retain their original measurement units.

## Progression and progress

Double progression checks one completed workout and one exercise occurrence. Every original prescribed slot must have exactly one completed working set at or above the upper rep target, at the same positive physical weight, converting legacy kg/lb records before comparison. Warm-ups, extras, incomplete sets and other people cannot satisfy it. Missing targets, mixed weights/units, and non-external-weight tracking never produce an automatic increase. RIR is deliberately absent from qualification, including target, missing or out-of-range historical RIR. Increments are optional; no precise weight is invented without one.

Progress provides periods including the current year, weekly training frequency (including zero-workout weeks), working-set counts, normalized external volume in lb·reps, exercise weight/repetition trends, estimates, best performances in the period, previous-workout comparisons, and primary-muscle exposure by month. Epley's estimate is labelled and limited to sets of 1–12 reps: `weight × (1 + reps / 30)`. This is not a tested maximum. Volume is not an overall strength score, and muscle exposure is not muscle growth. Distinct exercise/equipment variants keep separate IDs and trends.

## Storage and conflict behavior

`Core/` contains the data types and independently testable progression, selection and progress calculations. `Store.swift` owns local state and persistence. `Views/` contains the native interface. `Sync/` contains the two actual transports.

Local state is Codable JSON in Application Support at `Spotter/state.json`, written atomically with iOS file protection. Read failures preserve the original file and disable writes rather than silently resetting data. Save failures are shown explicitly. This initial implementation rewrites the local snapshot on edits; very large multi-year archives may warrant migrating storage to SQLite.

Both transports replicate the same append-only revision graph. Records have stable entity and revision identities, causal parent revisions, author and performer identities, and deletion tombstones. Separate records merge independently. Concurrent changes to one entity remain as multiple heads; **Review edits** presents each version, including delete-versus-edit. Choosing a version adds a resolving revision; losing variants remain in the audit history. An open set editor retains the causal base it opened, so a remote edit arriving while typing becomes a conflict. Charts show a deterministic provisional version until the conflict is resolved, and a workout with unresolved conflicts cannot be finished.

The Nearby pairing secret authenticates the connection, and reconnects pin the paired participant identity. Previously exchanged data remains on each phone. This is intended for two trusted friends, not adversarial/public collaboration.

Plans, all workout revisions (including solo history and deletions), custom exercises, profiles, aliases and personal exercise settings sync to the private `PersonalData` zone. The app connects when active and checks for personal changes every 30 seconds, uploading changed local data sooner. A new installation recovers the account’s performer identity and saved data. Local edits made during uploads are preserved. Plans merge independently by ID; concurrent edits to the same plan prefer the current device. Workout conflicts keep the existing revision review flow. The append-only audit log currently has no compaction.

## Verification

Run the UI-free tests, including real encrypted transport tests on macOS:

```sh
swift test
```

The test target includes the production engine, local store and nearby transport. It covers:

- Progression success/failure, every RIR condition, warm-ups, extra/incomplete/duplicate slots, mixed units/weights, missing targets and unsupported tracking.
- Empty starts, participant switching without mutation, participant history isolation, cross-day history, shared day changes and independent exercise choices, automatic partner logging, target snapshots, renaming/aliases/custom identity, delete/undo and relaunch restoration.
- Volume/working-set exclusions, corrupt-file preservation, repeated/out-of-order delivery, simultaneous edits, delete/edit conflicts and explicit resolution.
- A real TLS connection that joins two independent stores in the waiting room, shares the day and start event, transfers a logged set, deduplicates repeated delivery, and sends offline edits after reconnection; a wrong pairing code receives no workout.

See `VERIFICATION.md` for the current run results and remaining device/cloud checks.

## Platform references

- [Apple: CloudKit zone sharing sample](https://github.com/apple/sample-cloudkit-zonesharing)
- [Apple: CKShare](https://developer.apple.com/documentation/cloudkit/ckshare)
- [Apple: Moving from Multipeer Connectivity to Network framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
- [Apple: secure nearby networking with pre-shared keys](https://developer.apple.com/videos/play/wwdc2019/713/)

## ChatGPT integration

Spotter uses the [open-source Sign in with ChatGPT flow](https://developers.openai.com/siwc/token-sharing-open-source) directly on the iPhone. No developer API key or client secret is required. This distribution must remain eligible for the OSS program; a private/commercial distribution requires OpenAI approval. Account connection adds AI capabilities to the local Spotter profile, rather than replacing its iCloud identity.

- **Profile → ChatGPT:** Continue with ChatGPT, explicitly allow ChatGPT plan usage, reconnect, manage usage, or disconnect. Access requires an eligible account/workspace. Model choices come from that account's `/v1/models` catalog.
- **Failed CSV preview:** Parse with ChatGPT appears after a parser failure for both workouts and plans. The user explicitly sends the selected CSV. ChatGPT returns an editable draft and explanation; Review import runs the normal parser, exercise classification and import confirmation. Repair requests do not send existing workout history.
- **Progress → Ask ChatGPT:** A temporary conversation can call `list_workouts`, `get_workout`, `training_summary`, `exercise_history`, `list_plans`, and `exercise_library`. These tools expose a snapshot of the phone owner's completed sessions and their own sets, including their finished portion of a shared session. They never expose the friend's sets, profiles or private history, and cannot write data. The snapshot stays stable while this screen is open; reopen it after logging new training.
- **Plans → Suggest a split:** Enter a goal, days per week, session length, equipment and constraints. ChatGPT can inspect the same personal tools, then show a native plan preview with training days, exercises, targets and a brief What changed summary. A dedicated loading screen shows the current activity and elapsed time. Add plan saves a new plan after review; generated CSV is never displayed in this flow. Existing plans and recorded results are not replaced.

Authentication uses fresh state, nonce and PKCE; a loopback-only `127.0.0.1` listener starts before the system authentication browser. The issued dynamic client ID is used for exchange and returning sign-in. ID tokens are verified against OpenAI JWKS (RS256/ES256), issuer, audience, authorized party, expiry and nonce. Credentials and the stable host identifier are stored in device-only Keychain items, excluded from iCloud workout sync. Refreshes are serialized and rotated credentials saved together. Disconnect attempts refresh-token revocation from OIDC discovery and always reports when remote revocation could not be confirmed.

Inference uses only `https://api.openai.com/v1/responses`, with `store: false`, `stream: true`, full local conversation context, and read-only function outputs. No partial response is accepted without `response.completed`; interrupted, incomplete and late usage-limit failures are surfaced. Usage-limit errors link to ChatGPT usage settings and stop further requests in that conversation. Start a new chat after adjusting limits. Nothing silently switches to developer-paid API billing.

Live validation still requires an eligible person's consent: connect on an iPhone, confirm first-use notice, discover models, send a progress question, recover an unsupported CSV, review a suggested split, then reconnect and disconnect. In particular, verify the system authentication browser can reach the loopback listener on a physical device with the supported iOS release. Automated tests do not prove OAuth service eligibility or a live account's model entitlement.
