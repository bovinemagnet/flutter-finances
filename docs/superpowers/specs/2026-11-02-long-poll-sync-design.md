# Long-poll sync for prompt second-device updates (NFR 05)

**Author:** Paul Snow
**Status:** Draft for approval

## Why

PRD NFR 05: a small accepted change must reach an active second device within
10 seconds (p95, stable connection; images and suspended apps excluded). Today
the app syncs on launch, on return to the foreground and every 2 minutes, and
the server has no way to tell a device that something changed. A change made
on a phone can therefore take up to 2 minutes to show on the desktop, plus up
to 2 minutes more if the phone itself had not pushed yet.

Paul chose long-polling over push notifications, WebSockets or a shorter
timer.

## Goals

- A change saved on one device appears on another device that has the app
  open in about 1 to 3 seconds, and always within 10 seconds on a stable
  connection.
- Plain HTTP only: no new infrastructure, no third-party push service, and
  it keeps working behind ordinary reverse proxies.
- Old and new apps and servers keep working with each other.

## Non-goals

- Waking a suspended or backgrounded app (NFR 05 excludes them; background
  work stays opportunistic, UX 04).
- Receipt images and other asset bytes (excluded from NFR 05).
- Push notifications, WebSockets, server-sent events.

## Anti-goals (a failure even if it works)

- A waiting request that holds a database connection or a transaction.
- A client that spins in a tight loop against the server (for example
  against an older server that ignores the new option).
- Any change to how changes are applied, conflicts are raised or the cursor
  is advanced: this only changes *when* the existing pull happens.
- Pushing or pulling while the user has not saved anything (no extra work
  for an idle app beyond one waiting request).

## Protocol change (`spec/sync/protocol.md`, Change feed)

`GET /v1/sync/changes?cursor=…&limit=…&wait=<seconds>`

- `wait` is optional, whole seconds, default 0 (today's behaviour). The
  server clamps it to at most 25.
- With `wait > 0` and nothing after the cursor, the server holds the request
  until a change is recorded in the workspace after the cursor, or the wait
  ends, then answers exactly as today with the page after the cursor (which
  is empty if the wait ended with nothing new).
- The cursor is checked before waiting: an expired cursor still returns 410
  `CURSOR_EXPIRED` straight away. If changes already exist after the cursor
  the server answers straight away.
- Whenever the request has `wait > 0`, a server that supports it answers
  with `"waited": true`, including when it answers straight away because
  changes already exist. An older server leaves the field out; that is how a
  client learns the server cannot long-poll.
- Waking is per workspace, on any recorded change, including changes the
  device's member cannot see (household visibility). The answer is still
  filtered as today, so such a wake returns an empty page with an advanced
  cursor.
- 25 s keeps the request inside the 30 s client timeout and under common
  proxy idle timeouts.

## Server (`server/app`, sync module)

- The waiting happens **outside** any transaction and without holding a
  connection: validate the cursor, then loop: read the workspace's newest
  change record sequence (a short query), and if it is not past the cursor
  wait on an in-process signal for up to 2 seconds, until the deadline. Then
  run the existing `ChangeFeedService.changes` unchanged.
- The wake check uses `max(sequence)` from `sync_change` only, **not**
  `EntityStore.headSequence`. That method also counts `purged_through`,
  and when the tombstone purger removes the newest records a cursor can
  never pass `purged_through`, so every wait would answer at once (a tight
  loop). *(My call; `changes()` stays unchanged. A server test covers the
  "newest records purged" case.)*
- The in-process signal is raised after the command transaction commits
  (after-commit hook on the path that appends change records), keyed by
  workspace. Change records are written through `CommandProcessor`, but not
  always in the API process: import commits run as worker jobs
  (`ImportCommitJobHandler` → `SyncCommandService.submitAsServer`), and in
  production the worker is a separate process. The signal alone is
  therefore not enough; the 2-second re-check covers those writes. (The
  `e2e` profile runs the worker in-process, so it does not show this.)
- The 2-second re-check of the head sequence means waits also end promptly
  when the change was written by another server instance, so several
  instances behind a load balancer work without PostgreSQL LISTEN/NOTIFY.
  *(My call: Paul did not say whether the server runs as one or several
  copies; this covers both at the cost of one small query every 2 s per
  waiting device.)*
- Virtual threads are already enabled, so a held request costs a parked
  virtual thread, not a platform thread.
- Server shutdown must not hang on waiting requests: they end at their
  deadline or when the application stops (left to the builder how).

## Client

### Waiting (`finance_store` `SyncClient`, app `SyncController`)

- New `SyncClient` call that waits for changes: it sends the long-poll
  request with the stored cursor **outside** the client's serial lock (so a
  push after a save is never stuck behind a 25 s wait), then applies the
  page under the lock **only if the stored cursor is still the one it waited
  with**; otherwise another pull got there first and the page is dropped.
  Applying uses the existing `engine.applyChanges`, so cursor handling,
  conflicts and review stay as they are. `hasMore` and 410 lead to the
  normal pull and rebuild paths.
- `SyncController` keeps one waiting request open while the workspace is
  synced, signed in and the app is in the foreground: it starts after the
  first successful sync, stops when the app is hidden or paused and starts
  again on resume, and stops on sign-out and dispose.
- When a wait returns changes the controller calls `state.refresh()` and
  notifies listeners, as `syncNow` does.
- If a response lacks `"waited": true`, the client stops long-polling for
  the life of that `SyncController` and relies on the existing 2-minute
  timer.
- Errors: on a network or server error the client waits before trying again
  (5 s, doubling, at most 2 minutes). Authentication and
  update-required failures stop waiting and show the same messages as
  `syncNow`.
- The 2-minute periodic sync stays as a safety net.

### Prompt push after a save

- `SyncController` listens to `AppState`. When `state.unsyncedCount` goes
  **up**, it schedules a sync about 1 second later; further saves within
  that second restart the 1-second timer (debounce), so a burst of edits is
  one sync. Only an increase triggers it, so a sync that leaves changes
  pending (a conflict, an offline device) does not retrigger itself.
- If a sync is already running when the timer fires, the controller
  remembers that one more sync is wanted and runs it as soon as the current
  one ends (at most one queued). Without this, `syncNow` returns at once
  while a sync runs and the save would wait for the 2-minute timer. The
  queued sync still only comes from an increase, so a stuck sync cannot
  retrigger itself. *(My call.)*
- The post-save sync pushes and pulls without uploading receipt files
  (`sync(uploadAssets: false)`), then uploads them in a separate call, so a
  small change is never held up behind images. *(My call; images are
  outside NFR 05, and while files upload a returned wait page may wait for
  the serial lock.)*
- The waiting request is not interrupted by any of this.

## Testing

- **Server integration tests** (Testcontainers): a waiting request returns
  soon after another device's command commits and includes `"waited":
  true`; it returns an empty page at the deadline; `wait` above 25 is
  clamped; an expired cursor returns 410 without waiting; existing changes
  return without waiting; `wait` absent behaves exactly as today.
- **Client tests** with `FakeSyncServer` (which gains `wait` support and a
  way to omit `"waited"`): the page is applied when the cursor is unchanged
  and dropped when a pull moved it; an older server stops long-polling; a
  push during a wait is not blocked by it.
- **App tests** (`sync_controller_test.dart`): a save leads to one sync
  about a second later and a burst leads to one; a failed sync does not
  retrigger; waiting stops on hide or pause and resumes on resume; back-off
  on errors.
- **End-to-end** (`tool/e2e/run.sh`, `sync_e2e_test.dart`): two devices on
  the real server; device B is waiting, device A saves and pushes; B has the
  change well within 10 s. Repeat a number of times and check the slowest
  one, as a practical stand-in for the p95.

## Documentation

- `spec/sync/protocol.md` Change feed section.
- Antora: `src/docs/modules/sync/pages/protocol.adoc` and the client
  application architecture page (when the app syncs).
- Plan entry in `docs/superpowers/plans/2026-10-19-p1-and-release.md`.

## Left to the builder

- Names of the new client call, the signal class and the setting keys.
- Whether the 25 s maximum and the 2 s re-check are configuration
  properties or constants.
- How waits end at application shutdown.
- Whether to add a metric for waiting requests.
