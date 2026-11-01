# Long-poll Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A change saved on one device reaches another device that has the app open within 10 seconds (NFR 05), using a long-polled change feed and a prompt push after each save.

**Architecture:** `GET /v1/sync/changes` gains an optional `wait` (seconds, at most 25). The server holds the request outside any transaction until a change record exists after the cursor. It is woken by an after-commit signal and re-checks every 2 s, which covers other server instances and the worker. The client keeps one waiting request open outside `SyncClient`'s serial lock, applies the page only if the stored cursor has not moved, and syncs about 1 s after any save.

**Tech Stack:** Java 25 / Spring Boot 4.1 (virtual threads, JdbcClient, TransactionTemplate), Dart `finance_store`, Flutter `finance_app`.

**Spec:** `docs/superpowers/specs/2026-11-02-long-poll-sync-design.md`

## Global Constraints

- `wait` is whole seconds, default 0 (behaviour unchanged), clamped to at most 25 by the server.
- Re-check of the newest change record every 2 s while waiting.
- Response has `"waited": true` whenever the request had `wait > 0` and the server supports it; the field is absent otherwise.
- The wait check uses `max(sequence)` from `sync_change` only, never `EntityStore.headSequence`.
- A waiting request holds no database connection or transaction; `ChangeFeedService.changes` behaviour is unchanged.
- Client: push about 1 s after the unsynced count goes up (debounced); at most one queued follow-up sync; the post-save sync uses `uploadAssets: false`, then uploads separately.
- Client back-off after a failed wait: 5 s, doubling, at most 2 minutes. The 2-minute periodic sync stays.
- Use `gradle25w`, never `./gradlew`. Write `flutter test`/`dart test` output to a file and check the exit code. British spelling. Author Paul Snow, `@since 0.0.0`. Antora edits go through the asciidoc-antora-writer agent; check with `gradle25w antora`.

## Review Focus

1. A workspace whose newest change records were purged: a wait must last its full time, not answer at once (Task 1 test `waitIgnoresPurgedRecordsBeyondTheLastChange`).
2. A wait that returns while this device's own sync moved the cursor: the page must be dropped, never applied over newer state (Task 2 test `a waited page is dropped when a pull moved the cursor`).
3. An older server that ignores `wait` and answers at once: the client must stop long-polling, not spin (Task 2 and Task 3 tests on `supportsWait = false`).
4. A save during a long receipt upload or a running sync: the change must still go out promptly (Task 4 test `a save during a running sync is sent when it ends`).
5. A sync that leaves changes pending (offline or conflict): it must not retrigger itself every second (Task 4 test `a failed sync does not retrigger itself`).

---

### Task 1: Server long-poll on the change feed

**Files:**
- Create: `server/app/src/main/java/com/paulsnow/finance/server/sync/ChangeWaiter.java`
- Modify: `server/app/src/main/java/com/paulsnow/finance/server/sync/SyncProperties.java`
- Modify: `server/app/src/main/java/com/paulsnow/finance/server/sync/EntityStore.java` (new query next to `headSequence`, lines 169–177)
- Modify: `server/app/src/main/java/com/paulsnow/finance/server/sync/ChangeFeedService.java` (extract cursor validation from `changes`; `ChangePage` gains `waited`)
- Modify: `server/app/src/main/java/com/paulsnow/finance/server/sync/CommandProcessor.java:106-134` (after-commit signal)
- Modify: `server/app/src/main/java/com/paulsnow/finance/server/sync/SyncController.java` (`wait` parameter)
- Modify: `server/app/src/main/resources/application.yml` (`finance.sync` block, lines 54–58)
- Test: `server/app/src/test/java/com/paulsnow/finance/server/sync/LongPollIntegrationTest.java` (extends `IntegrationTestSupport`, same helpers as `ChangeFeedIntegrationTest`)
- Test: `server/app/src/test/java/com/paulsnow/finance/server/sync/ChangeWaiterTest.java` (plain unit test)

**Interfaces:**
- Produces (HTTP): `GET /v1/sync/changes?cursor&limit&wait` → `{changes, cursor, hasMore, waited?}`
- Produces (Java):
  - `SyncProperties(Duration tombstoneHorizon, int maxCommandsPerBatch, int maxPageSize, Duration maxWait, Duration waitRecheck)`, with defaults 25 s and 2 s; yml keys `max-wait: 25s`, `wait-recheck: 2s`.
  - `long EntityStore.latestChangeSequence(UUID workspaceId)`, which is `coalesce(max(sequence), 0)` from `sync_change` for the workspace.
  - `static Duration ChangeWaiter.effectiveWait(Integer requestedSeconds, Duration max)`: null or ≤ 0 gives `Duration.ZERO`; otherwise the smaller of the requested seconds and `max`.
  - `void ChangeWaiter.changed(UUID workspaceId)`: wakes the waiters for that workspace.
  - `void ChangeWaiter.awaitChangeAfter(UUID workspaceId, long sequence, Duration wait)`: returns when `latestChangeSequence > sequence` or `wait` elapses. It measures wall time with `System.nanoTime()`, not the injectable `Clock`, which tests freeze. It re-checks every `waitRecheck` and registers for wake-ups before reading the database, so no wake-up is lost. On interrupt it returns.
  - `long ChangeFeedService.validatedSequence(CurrentDevice device, String cursorText)`: today's decode and expiry checks from `changes`, throwing the same `INVALID_CURSOR` / `CURSOR_EXPIRED`. `changes` calls it.
  - `record ChangePage(List<ChangeView> changes, String cursor, boolean hasMore, @JsonInclude(NON_NULL) Boolean waited)`: `changes` returns `waited = null`; the controller sets `TRUE` when the effective wait is > 0.

- [ ] **Step 1: Write the failing unit test** `ChangeWaiterTest`
  - `effectiveWait(null, 25s)` → `ZERO`; `effectiveWait(0, 25s)` → `ZERO`; `effectiveWait(-3, 25s)` → `ZERO`; `effectiveWait(10, 25s)` → `10s`; `effectiveWait(600, 25s)` → `25s`.

- [ ] **Step 2: Write the failing integration tests** in `LongPollIntegrationTest`
  - Waiting requests run on a virtual thread (`Thread.ofVirtual().start` or `CompletableFuture.supplyAsync(..., Executors.newVirtualThreadPerTaskExecutor())`) calling MockMvc. Time them with `System.nanoTime()`.
  - `returnsSoonAfterAnotherDeviceCommits`: the tablet is caught up (cursor from `changes(tablet, null)`) and waits with `wait=10`. After 300 ms the phone runs `createAccount`. The response has 1 change, `waited == true`, and returns in under 2 s from the commit.
  - `returnsAnEmptyPageWhenTheWaitEnds`: caught up, `wait=1`. Empty `changes`, `hasMore == false`, `waited == true`, and elapsed time between 900 ms and 3 s.
  - `answersAtOnceWhenChangesAlreadyExist`: phone creates an account; tablet `wait=10` with an empty cursor. 1 change, `waited == true`, under 1 s.
  - `expiredCursorGets410WithoutWaiting`: as in `a15ExpiredCursorGets410AndSnapshotRebasePreventsResurrection` (advance the clock 91 days, purge), then `wait=10`. Expect 410 `CURSOR_EXPIRED` in under 1 s.
  - `withoutWaitTheResponseHasNoWaitedField`: `changes(tablet, null)` JSON has no `waited` property (`path("waited").isMissingNode()`).
  - `waitIgnoresPurgedRecordsBeyondTheLastChange`: phone creates account A, then creates and deletes account B; advance 91 days and purge, so the newest records are gone. Fresh `secondDevice` pulls from an empty cursor, then waits `wait=1` with the returned cursor. Expect an empty page and elapsed time ≥ 900 ms (it must not answer at once).

- [ ] **Step 3: Run them and see them fail**
  Run: `gradle25w :server:app:test --tests '*ChangeWaiter*' --tests '*LongPoll*' > $SCRATCH/server-test.txt 2>&1; echo $?`
  Expected: non-zero; compile errors for `ChangeWaiter` and an unknown `wait` parameter.

- [ ] **Step 4: Implement**
  - Add the properties and their yml keys. Add `latestChangeSequence`. Extract `validatedSequence` without changing `changes` behaviour. Add the `waited` component to `ChangePage`.
  - `ChangeWaiter` is a `@Component`. A per-workspace monitor, or one shared monitor with `notifyAll`, are both fine. Java 25 virtual threads do not pin on `synchronized`.
  - In `CommandProcessor`, inside the `transactions.execute` callback, when `result.accepted()` and the status is not `PREVIOUSLY_APPLIED`, register a `TransactionSynchronization` whose `afterCommit` calls `waiter.changed(workspace.id())`. This also works when the call joins an outer transaction (worker `submitAsServer`).
  - In the controller, add `@RequestParam(required = false) Integer wait`. If `effectiveWait > 0`: call `validatedSequence`, then `waiter.awaitChangeAfter`, then `feed.changes`, then return the page with `waited = TRUE`. The method itself must not be `@Transactional`.
  - Update the `@Operation` summary to mention `wait`.

- [ ] **Step 5: Run the new tests and the whole server suite**
  Run: `gradle25w :server:app:test > $SCRATCH/server-test.txt 2>&1; echo $?`
  Expected: `0`; `ChangeFeedIntegrationTest` and `SyncCommandsIntegrationTest` still pass.

- [ ] **Step 6: Commit**
  `git commit -m "Hold the change feed open until something changes (NFR 05)"`

### Task 2: Client waiting call and fake server support

**Files:**
- Modify: `packages/finance_store/lib/src/sync/sync_client.dart` (new call near `pull`, lines 243–331)
- Modify: `packages/finance_store/test/support/fake_server.dart` (`_changes` at lines 821–843; the `_log.add` at line 519)
- Test: `packages/finance_store/test/long_poll_test.dart` (new; reuse the set-up helpers from `sync_test.dart`)

**Interfaces:**
- Produces:
  - `class WaitResult { const WaitResult({required this.supported, this.changes = 0, this.needsPull = false}); final bool supported; final int changes; final bool needsPull; }`, exported from `finance_store.dart` with the other sync types.
  - `Future<WaitResult> SyncClient.waitForChanges({Duration wait = const Duration(seconds: 25)})`:
    1. Throws `SyncNotEnabledException` when the workspace is not synced.
    2. Returns `needsPull: true` straight away when `engine.rebuild != null`.
    3. Otherwise reads the stored cursor and sends `GET /v1/sync/changes?cursor&limit=$pageSize&wait=${wait.inSeconds}` **outside** `_serial`, accepting 410.
    4. A 410 gives `needsPull: true`.
    5. A body without `waited == true` gives `supported: false` and applies nothing.
    6. Otherwise, inside `_serial`: if the stored cursor still equals the one sent, call `engine.applyChanges(...)` and return `changes: n` and `needsPull: hasMore`. If not, drop the page and return `changes: 0`.
- Produces (fake server):
  - `bool supportsWait = true;`
  - `Duration maxHold = const Duration(milliseconds: 300);` (the real hold is the smaller of `wait` seconds and `maxHold`).
  - `int waiting = 0;` (the number of requests currently held).
  - Appending to `_log` completes the pending wake-up.
  - When `supportsWait` is false, `wait` is ignored and `waited` is left out. When true and `wait > 0`, the answer includes `'waited': true`.

- [ ] **Step 1: Write the failing tests** in `long_poll_test.dart`
  - `a waiting device receives a change from another device`: B starts `waitForChanges()` and does not await it. A saves an account and calls `push()`. The result has `supported == true` and `changes >= 1`, and B's store holds the account.
  - `an empty wait applies nothing and keeps supported`: caught-up B; result `supported == true`, `changes == 0`, `needsPull == false`.
  - `a waited page is dropped when a pull moved the cursor`: B starts waiting. A pushes. Before the wait completes, B runs `pull()`, which takes the lock and advances the cursor. The wait result has `changes == 0`, and B's cursor equals the cursor after `pull()`.
  - `an older server is reported as not supporting wait`: `server.supportsWait = false`. Result `supported == false` and B's cursor is unchanged.
  - `a push is not blocked by a wait`: with `server.maxHold = Duration(seconds: 5)`, B starts waiting, then `B.push()` of a new account completes while `server.waiting == 1`. Use `.timeout(Duration(seconds: 2))`.
  - `an expired cursor asks for a pull`: `server.expireTombstones()` after a change, then the result has `needsPull == true`.

- [ ] **Step 2: Run them and see them fail**
  Run: `cd packages/finance_store && dart test test/long_poll_test.dart > $SCRATCH/store-test.txt 2>&1; echo $?`
  Expected: non-zero; `waitForChanges` is not defined.

- [ ] **Step 3: Implement `WaitResult`, `waitForChanges` and the fake server's `wait` handling** (`_changes` becomes `async`; await the wake-up `Completer` or `maxHold` when nothing is pending).

- [ ] **Step 4: Run the store suite**
  Run: `cd packages/finance_store && dart test > $SCRATCH/store-test.txt 2>&1; echo $?` and `dart analyze`
  Expected: `0`; no new analyser notes.

- [ ] **Step 5: Commit**
  `git commit -m "Wait for changes outside the sync lock (NFR 05)"`

### Task 3: App keeps a waiting request open in the foreground

**Files:**
- Modify: `apps/finance_app/lib/data/sync_controller.dart`
- Test: `apps/finance_app/test/unit/sync_controller_test.dart`

**Interfaces:**
- Consumes: `SyncClient.waitForChanges`, `WaitResult` (Task 2); `FakeSyncServer.supportsWait`, `maxHold`, `waiting`.
- Produces:
  - New `SyncController` constructor parameters: `this.longPollWait = const Duration(seconds: 25)`, `this.waitRetryDelay = const Duration(seconds: 5)`, `this.maxWaitRetryDelay = const Duration(minutes: 2)`.
  - `bool get isWaiting`: whether a waiting loop is running.
- Behaviour:
  - Waiting starts after the first successful `syncNow` when synced and signed in (from `start()` and `enable()`).
  - It stops on `AppLifecycleState.hidden` / `paused`, `signOut()` and `dispose()`. It starts again on `resumed`.
  - Each loop iteration:
    1. Call `waitForChanges(wait: longPollWait)`.
    2. Stop for good when the result says `supported: false` (the field `_longPollUnsupported`).
    3. Call `syncNow()` when `needsPull` is true.
    4. Otherwise, when `changes > 0`, call `state.refresh()` and `notifyListeners()`.
    5. Wait again.
  - On `AuthenticationRequiredException`, set the same `lastError` / `phase` as `syncNow` and stop.
  - On any other `Exception`, sleep the back-off (`waitRetryDelay`, doubling, capped at `maxWaitRetryDelay`), and reset it after a success.
  - Use a generation counter so a stopped loop that later returns does nothing.

- [ ] **Step 1: Write the failing tests** (in the existing `device()` helper, pass the new durations as milliseconds: `waitRetryDelay: Duration(milliseconds: 20)`)
  - `an open device receives another device's change without a sync`:
    1. Connect A and B as in the first test.
    2. Wait until `syncB.isWaiting` and `server.waiting == 1`.
    3. A saves an account and calls `syncA.syncNow()`.
    4. Within 2 s, B's `state.store.accounts()` holds it, with no `syncB.syncNow()` call.
  - `waiting stops when hidden and starts on resume`: `didChangeAppLifecycleState(hidden)` gives `isWaiting == false`; `resumed` gives `isWaiting == true`.
  - `an older server turns waiting off`: `server.supportsWait = false` before connecting, then after the first sync `isWaiting` becomes false and `server.requests` holds no more than 2 requests containing `wait=`.
  - `waiting backs off while offline`: B waiting, `server.offline = true` for 200 ms. Count the requests containing `wait=` in that window: there are at most 5 of them, not a tight loop. With `RetryPolicy` defaults the transport's own retries count too, so assert on an upper bound.
  - `sign-out stops waiting`.

- [ ] **Step 2: Run them and see them fail**
  Run: `cd apps/finance_app && flutter test test/unit/sync_controller_test.dart > $SCRATCH/app-test.txt 2>&1; echo $?`
  Expected: non-zero; `isWaiting` is not defined.

- [ ] **Step 3: Implement the waiting loop in `SyncController`.**

- [ ] **Step 4: Run the app unit tests**
  Run: `cd apps/finance_app && flutter test test/unit > $SCRATCH/app-test.txt 2>&1; echo $?`
  Expected: `0`.

- [ ] **Step 5: Commit**
  `git commit -m "Keep a waiting sync request open while the app is in use (NFR 05)"`

### Task 4: Push about a second after a save

**Files:**
- Modify: `apps/finance_app/lib/data/sync_controller.dart`
- Test: `apps/finance_app/test/unit/sync_controller_test.dart`

**Interfaces:**
- Consumes: `AppState.unsyncedCount`, `SyncClient.sync(uploadAssets: false)`, `SyncClient.uploadAssets()`.
- Produces:
  - Constructor parameter `this.pushDelay = const Duration(seconds: 1)`.
  - `syncNow` gains `{bool uploadAssets = true}` and passes it to `client.sync`.
- Behaviour:
  - Listen to `state` while synced; track `_lastUnsynced`.
  - When `unsyncedCount` is greater than the last value seen, (re)start `Timer(pushDelay, _syncAfterSave)`. Always store the new value.
  - `_syncAfterSave`: if `phase == syncing`, set `_syncQueued = true`. Otherwise run `syncNow(uploadAssets: false)`, then `client.uploadAssets()`, with errors caught and left for the next sync.
  - At the end of `syncNow`, if `_syncQueued`, clear it and run `_syncAfterSave` once.
  - Remove the listener on `signOut` and `dispose`.

- [ ] **Step 1: Write the failing tests** (`pushDelay: Duration(milliseconds: 50)`)
  - `a save is sent about a moment later`: on a connected A, record `server.commandCount`, save an account, and wait up to 2 s for `commandCount` to go up. `a.unsyncedCount == 0`.
  - `a burst of saves is one sync`: three saves 10 ms apart. Count the `POST /v1/sync/commands` requests after the burst: exactly 1.
  - `a save during a running sync is sent when it ends`: set `server.putDelay` (or a slow upload with a saved receipt) so `syncNow()` takes 300 ms or more; start it, save an account during it, and within 2 s after it ends `a.unsyncedCount == 0`.
  - `a failed sync does not retrigger itself`: `server.offline = true`; one save. After 500 ms, count the requests containing `/v1/sync/commands`: no more than one sync's worth (`RetryPolicy().maxAttempts`).
  - `the post-save sync leaves receipt files for a separate upload`: a saved receipt with an asset. After the save, `POST /v1/sync/commands` appears in `server.requests` before any `objects.test` request.

- [ ] **Step 2: Run them and see them fail** (same command as Task 3 Step 2).

- [ ] **Step 3: Implement the listener, debounce and queued follow-up.**

- [ ] **Step 4: Run every app test and the analyser**
  Run: `cd apps/finance_app && flutter test > $SCRATCH/app-test.txt 2>&1; echo $?` then `flutter analyze` and `dart format --output=none --set-exit-if-changed lib test`
  Expected: `0`, `No issues found!`, and 0 files changed. Revert any regenerated `ios/Flutter/*.xcconfig` or `ios/Podfile`.

- [ ] **Step 5: Commit**
  `git commit -m "Send a change about a second after it is saved (NFR 05)"`

### Task 5: End-to-end check, protocol and documentation

**Files:**
- Modify: `packages/finance_store/test/e2e/sync_e2e_test.dart`
- Modify: `spec/sync/protocol.md` (the Change feed section, lines 83–99)
- Modify (via the asciidoc-antora-writer agent, in parallel): `src/docs/modules/sync/pages/protocol.adoc`, `src/docs/modules/architecture/pages/client-application.adoc`
- Modify: `docs/superpowers/plans/2026-10-19-p1-and-release.md` (new R7 entry)

**Interfaces:**
- Consumes: `SyncClient.waitForChanges` (Task 2); `twoDevices()` in the e2e test.

- [ ] **Step 1: Write the e2e test** `NFR 05: a change reaches a waiting device within 10 seconds`:
  1. Create two devices with `twoDevices()`.
  2. Repeat 10 times:
     - B starts `waitForChanges()` (unawaited).
     - Wait 200 ms.
     - A records the start time, saves an account and calls `push()`.
     - Await B's result.
     - Record the elapsed time until B's store holds the account. If the result had `needsPull`, call `pull()` first.
  3. Expect the slowest of the 10 to be under 10 s, and print all ten times.

- [ ] **Step 2: Run the e2e suite**
  Run: `tool/e2e/run.sh > $SCRATCH/e2e.txt 2>&1; echo $?` (Podman must be running)
  Expected: `0`. If containers can't start on this machine, say so in the report and rely on CI.

- [ ] **Step 3: Update `spec/sync/protocol.md`**
  Add the rules from the design's "Protocol change" section:
  - `wait`, the clamp to 25 s;
  - the cursor is checked before waiting;
  - an immediate answer when changes exist;
  - `waited: true`;
  - wake-ups from changes the member cannot see;
  - the client rules: outside the lock, apply only if the cursor is unchanged, stop on a missing `waited`, back-off, and push about 1 s after a save.

- [ ] **Step 4: Dispatch the asciidoc-antora-writer agent**
  - It updates the two Antora pages to match: the change feed `wait` option, and when the app syncs.
  - Then run `gradle25w antora > $SCRATCH/antora.txt 2>&1; echo $?`. Expected: `0`, with no errors in the output.

- [ ] **Step 5: Add the R7 entry to the P1 plan**
  `- [x] R7 NFR 05 second-device propagation: long-polled change feed (wait ≤ 25 s, after-commit wake plus a 2 s re-check) and a push about 1 s after each save; e2e measures the slowest of ten`, with the measured slowest time.

- [ ] **Step 6: Run every suite once more**
  - `finance_core` `dart test`
  - `finance_store` `dart test`
  - app `flutter test`
  - `gradle25w build`
  Each output goes to a file; check the exit codes.

- [ ] **Step 7: Commit**
  `git commit -m "Document long-poll sync and check NFR 05 end to end"`
