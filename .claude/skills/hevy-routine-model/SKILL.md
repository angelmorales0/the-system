---
name: hevy-routine-model
description: Model-check the write of the day's routine to the player's real Hevy account (TLA+, TLC). Use after any change to HevyRoutine.sync, HevyRoutine.existingRoutine, GameStore.writeHevyRoutine, the writingHevyRoutine / hevyRoutineAgain flags, the Simulator guard, or the stored hevyRoutineId; and when CI says "covered code changed".
---

# Hevy routine model

The app writes the day's lifts to the player's **real** Hevy account. A mistake
there makes a second routine in the player's account, or puts the wrong day's
rows over the player's routine. Unit checks (`HevyRoutine.checkWrites()`) test
the cases someone wrote. This model checks every order of app steps, Hevy
replies, lost replies, and player deletes, up to the bounds below.

## Run

```bash
scripts/check-hevy-model.sh
```

It takes about 5 seconds. It needs Java 11 or newer on `PATH` or in
`JAVA_HOME`. The first run downloads tla2tools 1.7.4 (SHA-256 checked) to
`~/.cache/tla2tools/`. CI runs the same command in the `hevy-model` job of
`.github/workflows/engine-checks.yml`.

The script prints `HEVY MODEL PASSED` when all of these are true:

1. The covered code has the fingerprint in `formal/hevy-routine/covered.sha256`.
2. `HevyRoutine.cfg` (the current code) keeps every property.
3. Each `replay-*.cfg` (code from before a past fix) breaks the property that the
   bug broke. If a replay passes, the model can no longer catch that bug.

To run one config and see the full TLC output:
`scripts/check-hevy-model.sh replay-75159f3`.

## Properties

| Name | Plain sentence | Harm when broken |
|---|---|---|
| `AtMostOneRoutine` | The account holds at most one routine titled "The System:". | The player sees two routines in Hevy, one with old rows. |
| `OneWriteAtATime` | At most one sync talks to the account at a time, over all devices. | Two writers race; one puts its rows over the other's. |
| `WrittenPlanStays` | When the phone is idle and wrote its current rows, every app routine holds those rows. | The player opens Hevy and finds another day's workout. |
| `EventuallyLatest` | When the rows stop changing and the faults run out, the routine holds the phone's latest rows. | A change never reaches Hevy. |

## Coverage

Sync commit: `0471af976779fb07dbdc4a7aae509351cce7524d`. At this commit the model
describes this code:

| Code | Model |
|---|---|
| `GameStore.writeHevyRoutine(now:)`: `#if targetEnvironment(simulator)`, the `writingHevyRoutine` guard, `hevyRoutineAgain`, the completion that writes again | `WriteHevyRoutine`, `Return`, switch `SimulatorWrites` |
| `GameStore.snapshot.didSet` (`rowsKey` changed) | `RowsChange` |
| `GameStore.refreshStatInputs(now:)` completion | `StatInputsLoaded` |
| `HevyRoutine.sync(...)`: signature guard, `settleKey` wait and `unsure()`, stored `idKey`, PUT, 404, `removeObject(forKey: idKey)` before POST, POST reply with and without an id, non-2xx | `WriteHevyRoutine`, `PutAnswered`, `PostAnswered`, switches `KeepStaleIdBeforePost`, `StaleIdOnNoIdReply` |
| `HevyRoutine.existingRoutine(...)`: `.found`, `.none`, `.failed` | `ListAnswered`, switch `ListFailureMakesRoutine` |
| Hevy: GET/PUT/POST `/v1/routines`, lost replies, 5xx, replies with no id; the player deletes the routine | `HevyAnswers`, `PlayerDeletesRoutine` |

One model step is one MainActor job: the code between two `await`s. The
template reads (`loadTemplates`) and the plan's contents are not modeled.
A plan is a number.

`covered.sha256` holds a hash of `existingRoutine`, `sync`,
`writeHevyRoutine`, and every line of `GameStore.swift` that calls
`writeHevyRoutine(`. Any edit there fails the check until you do the steps in
"When the covered code changes".

## Bounds and assumptions

- Devices: the phone and one Simulator build with the same key.
- Up to 3 plans on the phone, 3 faults (lost reply, dropped request, 5xx, failed
  list read, reply with no id), 2 player deletes, 2 sync slots for each device.
- Start states: an empty account; a routine from an earlier install and no
  stored id; a routine and its stored id.
- Hevy's list shows a new routine at once. A list that lags is not modeled.
- The gate runs with `LateRequests = TRUE`: a PUT or POST can reach Hevy after
  `OnDeviceHTTP.sendJSON` stopped waiting (12 s). The code then waits
  `HevyRoutine.settleSeconds` (120 s, stored under `settleKey`) before it writes
  again. The model's `Settles` step assumes Hevy handles or drops a request
  within that time. If Hevy can take longer, raise `settleSeconds`.
- Not covered: 400 and 403 replies, `routinePages` paging, the player renaming
  or copying the routine, two phones, a day change during a write, the
  contents of the routine.

## Replays of past bugs

| Config | Code before | Breaks |
|---|---|---|
| `replay-75159f3.cfg` | 75159f3: the gone id stayed stored while the new routine was posted | `AtMostOneRoutine` |
| `replay-b3aa1f7-list.cfg` | b3aa1f7: a routine list that could not be read counted as "none" | `AtMostOneRoutine` |
| `replay-b3aa1f7-no-id.cfg` | b3aa1f7: `routineId(in:) ?? id` kept the gone id after a reply with no id | `AtMostOneRoutine` |
| `replay-b3aa1f7-simulator.cfg` | b3aa1f7: a Simulator build wrote with the same key | `OneWriteAtATime` |
| `replay-b3aa1f7-simulator-stays.cfg` | b3aa1f7: the Simulator's day stayed over the phone's routine | `EventuallyLatest` |
| `replay-late-requests.cfg` | before the settle wait: a write with no reply was followed by another write at once | `AtMostOneRoutine` |

`WrittenPlanStays` also breaks in `replay-75159f3.cfg`; TLC stops at the first
broken invariant, so the gate checks the one named above.

The b3aa1f7 change that dropped a rows change during a write (no
`hevyRoutineAgain`) is not replayed: the next `refreshStatInputs` writes the
rows, so no property here breaks.

## Known findings (current code)

None. The late-request finding is fixed by the settle wait and replayed by
`replay-late-requests.cfg`.

## Read a result

Read every result with the pstack `/statechart` skill. It gives the shortest
path to each broken property in steps. With no break, it draws how the write
moves between states.

In TLC output, each `State n` names the action that led to it. Map the actions
to code with the Coverage table. `storedId` is `hevyRoutineId`, `signature` is
the last rows the device wrote, `routines` is the account.

### A real bug or a modeling error?

- **Real bug**: each step of the path is a step the Swift code can take, in the
  same order, with replies Hevy can give. Replay it as a case in
  `HevyRoutine.checkWrites()` with the fake `Hevy` transport. If the case
  fails, it is a real bug. Fix the Swift code, not the model.
- **Modeling error**: a step does something the code cannot do (for example, a
  POST after `.failed` in the current code, or two steps where the code has no
  `await` between them). Fix the model so it matches the code. Never remove or
  weaken a property to make the check pass.
- A replay that passes means the model lost the path to that bug. Find the
  model edit that hid it.

## When the covered code changes

1. Read the diff of the covered functions since the sync commit:
   `git diff 0471af976779fb07dbdc4a7aae509351cce7524d -- MyApp/Engine/HevyRoutine.swift MyApp/Engine/GameStore.swift`.
2. Change `formal/hevy-routine/HevyRoutine.tla` so each step still matches the
   code. Add a variable or action for each new await, flag, or stored key.
3. Run `scripts/check-hevy-model.sh`. Read any break as above.
4. When the model describes the new code, run
   `scripts/check-hevy-model.sh --sync`, and move the sync commit above to the
   commit that you checked.
5. When a fix closes a new bug, add a switch for the old code and a
   `replay-<commit>.cfg` that breaks, and add it to the `replay` lines of the
   script.
