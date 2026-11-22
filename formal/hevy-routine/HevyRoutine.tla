---------------------------- MODULE HevyRoutine ----------------------------
(***************************************************************************)
(* The write of the day's routine to the player's real Hevy account.       *)
(*                                                                         *)
(*   GameStore.writeHevyRoutine(now:)   -> WriteHevyRoutine                *)
(*   HevyRoutine.sync(...)              -> one step per await              *)
(*   HevyRoutine.existingRoutine(...)   -> GET /v1/routines                *)
(*   UserDefaults hevyRoutineId         -> storedId                        *)
(*   UserDefaults signatureKey          -> signature                       *)
(*   UserDefaults settleKey             -> settling                        *)
(*                                                                         *)
(* A task step is one MainActor job: the code between two awaits.          *)
(* Plans are numbers. The phone's plan grows by one at each change of the  *)
(* day's rows; the Simulator has its own day, SimPlan.                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxPlan,      \* changes of the phone's rows: plans 1..MaxPlan
    MaxFaults,    \* lost replies, failed list reads, 5xx, replies with no id
    MaxDeletes,   \* the player deletes the app's routine in Hevy
    Slots,        \* sync tasks one device can hold at once
    \* Switches back to earlier code. All FALSE is the current code.
    SimulatorWrites,          \* before b3aa1f7: no #if targetEnvironment(simulator) return
    ListFailureMakesRoutine,  \* before b3aa1f7: an unread list counted as "none"
    StaleIdOnNoIdReply,       \* before b3aa1f7: routineId(in:) ?? id kept the old id
    KeepStaleIdBeforePost,    \* before 75159f3: no removeObject(forKey: idKey) before POST
    NoSettle,                 \* before the settle fix: a write with no reply did not wait
    \* An assumption, not a code switch: the request reaches Hevy after the
    \* app stopped waiting (OnDeviceHTTP timeout, 12 s for a send).
    LateRequests

Devices == {"Phone", "Simulator"}
Tasks == Devices \X (1..Slots)
Nil == 0
SimPlan == MaxPlan + 1

VARIABLES
    routines,   \* the account's routines titled "The System:", as [id, plan]
    nextId,     \* the id Hevy gives the next new routine
    plan,       \* the day's rows on each device (snapshot.bundle)
    storedId,   \* hevyRoutineId in each device's UserDefaults
    signature,  \* the plan last written by each device
    settling,   \* a PUT or POST got no reply: no write until it settles
    writing,    \* writingHevyRoutine
    again,      \* hevyRoutineAgain
    pc,         \* where each sync task waits: idle, list, put, post
    wplan,      \* the bundle the task captured
    wid,        \* the task's local id
    reply,      \* the reply the task waits for: wait, or what came back
    replyId,    \* the id in the reply
    late,       \* requests still on their way after the app stopped waiting
    faults,
    deletes

vars == <<routines, nextId, plan, storedId, signature, settling, writing, again,
          pc, wplan, wid, reply, replyId, late, faults, deletes>>
taskVars == <<pc, wplan, wid, reply, replyId>>

Writes(d) == d = "Phone" \/ SimulatorWrites
Ids == {r.id : r \in routines}
Owner(t) == t[1]

Init ==
    /\ \E start \in {"empty", "earlierInstall", "thisInstall"} :
        /\ routines = IF start = "empty" THEN {} ELSE {[id |-> 1, plan |-> 0]}
        /\ nextId = IF start = "empty" THEN 1 ELSE 2
        /\ storedId = [d \in Devices |-> IF start = "thisInstall" /\ d = "Phone" THEN 1 ELSE Nil]
    /\ plan = [d \in Devices |-> IF d = "Phone" THEN 1 ELSE SimPlan]
    /\ signature = [d \in Devices |-> 0]
    /\ settling = [d \in Devices |-> FALSE]
    /\ writing = [d \in Devices |-> FALSE]
    /\ again = [d \in Devices |-> FALSE]
    /\ pc = [t \in Tasks |-> "idle"]
    /\ wplan = [t \in Tasks |-> 0]
    /\ wid = [t \in Tasks |-> Nil]
    /\ reply = [t \in Tasks |-> "none"]
    /\ replyId = [t \in Tasks |-> Nil]
    /\ late = {}
    /\ faults = 0
    /\ deletes = 0

Fault == faults < MaxFaults /\ faults' = faults + 1

(* sync() up to its first await: GET the list when no id is stored, else PUT. *)
Send(t, p, id) ==
    /\ pc' = [pc EXCEPT ![t] = IF id = Nil THEN "list" ELSE "put"]
    /\ wplan' = [wplan EXCEPT ![t] = p]
    /\ wid' = [wid EXCEPT ![t] = id]
    /\ reply' = [reply EXCEPT ![t] = "wait"]
    /\ replyId' = [replyId EXCEPT ![t] = Nil]

SendPut(t, id) ==
    /\ pc' = [pc EXCEPT ![t] = "put"]
    /\ wid' = [wid EXCEPT ![t] = id]
    /\ reply' = [reply EXCEPT ![t] = "wait"]
    /\ replyId' = [replyId EXCEPT ![t] = Nil]
    /\ UNCHANGED <<wplan, writing, again>>

SendPost(t) ==
    /\ pc' = [pc EXCEPT ![t] = "post"]
    /\ reply' = [reply EXCEPT ![t] = "wait"]
    /\ replyId' = [replyId EXCEPT ![t] = Nil]
    /\ UNCHANGED <<wplan, wid, writing, again>>

(* GameStore.writeHevyRoutine(now:) with the bundle p. When sync's signature *)
(* guard returns nil at once, nothing changes.                              *)
WriteHevyRoutine(d, p) ==
    IF ~Writes(d) THEN UNCHANGED <<writing, again, taskVars>>
    ELSE IF writing[d]
    THEN /\ again' = [again EXCEPT ![d] = TRUE]
         /\ UNCHANGED <<writing, taskVars>>
    ELSE IF signature[d] = p \/ settling[d] THEN UNCHANGED <<writing, again, taskVars>>
    ELSE \E k \in 1..Slots :
            /\ pc[<<d, k>>] = "idle"
            /\ writing' = [writing EXCEPT ![d] = TRUE]
            /\ UNCHANGED again
            /\ Send(<<d, k>>, p, storedId[d])

(* sync() returns; the completion in writeHevyRoutine clears the flag and,  *)
(* when the rows changed during the write, writes again with the new rows.  *)
(* Needs storedId', signature' and settling' set before it.                 *)
Return(t) ==
    LET d == Owner(t) IN
    IF again[d] /\ signature'[d] # plan[d] /\ ~settling'[d]
    THEN /\ again' = [again EXCEPT ![d] = FALSE]
         /\ UNCHANGED writing
         /\ Send(t, plan[d], storedId'[d])
    ELSE /\ again' = [again EXCEPT ![d] = FALSE]
         /\ writing' = [writing EXCEPT ![d] = FALSE]
         /\ pc' = [pc EXCEPT ![t] = "idle"]
         /\ wplan' = [wplan EXCEPT ![t] = 0]
         /\ wid' = [wid EXCEPT ![t] = Nil]
         /\ reply' = [reply EXCEPT ![t] = "none"]
         /\ replyId' = [replyId EXCEPT ![t] = Nil]

Unsure(d) == settling' = IF NoSettle THEN settling ELSE [settling EXCEPT ![d] = TRUE]

---------------------------------------------------------------------------
(* The app *)

RowsChange ==
    /\ plan["Phone"] < MaxPlan
    /\ plan' = [plan EXCEPT !["Phone"] = @ + 1]
    /\ WriteHevyRoutine("Phone", plan["Phone"] + 1)
    /\ UNCHANGED <<routines, nextId, storedId, signature, settling, late, faults, deletes>>

(* refreshStatInputs ends: self.writeHevyRoutine(now: now). *)
StatInputsLoaded(d) ==
    /\ WriteHevyRoutine(d, plan[d])
    /\ UNCHANGED <<routines, nextId, plan, storedId, signature, settling, late, faults, deletes>>

(* existingRoutine returns .found, .none, or .failed. *)
ListAnswered(t) ==
    /\ pc[t] = "list"
    /\ reply[t] \in {"found", "empty", "failed"}
    /\ UNCHANGED settling
    /\ CASE reply[t] = "found" -> SendPut(t, replyId[t]) /\ UNCHANGED <<storedId, signature>>
         [] reply[t] = "empty" -> SendPost(t) /\ UNCHANGED <<storedId, signature>>
         [] reply[t] = "failed" ->
              IF ListFailureMakesRoutine
              THEN SendPost(t) /\ UNCHANGED <<storedId, signature>>
              ELSE UNCHANGED <<storedId, signature>> /\ Return(t)
    /\ UNCHANGED <<routines, nextId, plan, late, faults, deletes>>

PutAnswered(t) ==
    LET d == Owner(t) IN
    /\ pc[t] = "put"
    /\ reply[t] \in {"ok", "notFound", "lost", "err"}
    /\ CASE reply[t] = "ok" ->
              /\ storedId' = [storedId EXCEPT ![d] = wid[t]]
              /\ signature' = [signature EXCEPT ![d] = wplan[t]]
              /\ UNCHANGED settling
              /\ Return(t)
         [] reply[t] = "notFound" ->
              /\ storedId' = IF KeepStaleIdBeforePost THEN storedId
                             ELSE [storedId EXCEPT ![d] = Nil]
              /\ UNCHANGED <<signature, settling>>
              /\ SendPost(t)
         [] reply[t] = "lost" ->
              UNCHANGED <<storedId, signature>> /\ Unsure(d) /\ Return(t)
         [] reply[t] = "err" ->
              UNCHANGED <<storedId, signature, settling>> /\ Return(t)
    /\ UNCHANGED <<routines, nextId, plan, late, faults, deletes>>

PostAnswered(t) ==
    LET d == Owner(t) IN
    /\ pc[t] = "post"
    /\ reply[t] \in {"ok", "okNoId", "lost", "err"}
    /\ CASE reply[t] = "ok" ->
              /\ storedId' = [storedId EXCEPT ![d] = replyId[t]]
              /\ signature' = [signature EXCEPT ![d] = wplan[t]]
         [] reply[t] = "okNoId" ->
              /\ storedId' = [storedId EXCEPT ![d] = IF StaleIdOnNoIdReply THEN wid[t] ELSE Nil]
              /\ signature' = [signature EXCEPT ![d] = wplan[t]]
         [] reply[t] = "lost" ->
              UNCHANGED <<storedId, signature>> /\ Unsure(d)
         [] reply[t] = "err" ->
              /\ storedId' = IF StaleIdOnNoIdReply THEN storedId
                             ELSE [storedId EXCEPT ![d] = Nil]
              /\ UNCHANGED signature
    /\ reply[t] \in {"ok", "okNoId", "err"} => UNCHANGED settling
    /\ Return(t)
    /\ UNCHANGED <<routines, nextId, plan, late, faults, deletes>>

---------------------------------------------------------------------------
(* Hevy *)

Put(id, p) == {IF r.id = id THEN [id |-> id, plan |-> p] ELSE r : r \in routines}
Made(p) == routines \cup {[id |-> nextId, plan |-> p]}

HevyAnswers(t) ==
    /\ reply[t] = "wait"
    /\ CASE pc[t] = "list" ->
              \/ /\ reply' = [reply EXCEPT ![t] = IF routines = {} THEN "empty" ELSE "found"]
                 /\ replyId' = [replyId EXCEPT ![t] =
                        IF routines = {} THEN Nil ELSE CHOOSE i \in Ids : \A j \in Ids : i <= j]
                 /\ UNCHANGED <<routines, nextId, faults>>
              \/ /\ Fault
                 /\ reply' = [reply EXCEPT ![t] = "failed"]
                 /\ UNCHANGED <<routines, nextId, replyId>>
         [] pc[t] = "put" ->
              \/ /\ routines' = Put(wid[t], wplan[t])
                 /\ reply' = [reply EXCEPT ![t] = IF wid[t] \in Ids THEN "ok" ELSE "notFound"]
                 /\ UNCHANGED <<nextId, replyId, faults>>
              \/ /\ Fault
                 /\ routines' = Put(wid[t], wplan[t])
                 /\ reply' = [reply EXCEPT ![t] = "lost"]
                 /\ UNCHANGED <<nextId, replyId>>
              \/ /\ Fault
                 /\ \E r \in {"lost", "err"} : reply' = [reply EXCEPT ![t] = r]
                 /\ UNCHANGED <<routines, nextId, replyId>>
         [] pc[t] = "post" ->
              \/ /\ routines' = Made(wplan[t])
                 /\ nextId' = nextId + 1
                 /\ reply' = [reply EXCEPT ![t] = "ok"]
                 /\ replyId' = [replyId EXCEPT ![t] = nextId]
                 /\ UNCHANGED faults
              \/ /\ Fault
                 /\ routines' = Made(wplan[t])
                 /\ nextId' = nextId + 1
                 /\ \E r \in {"okNoId", "lost"} : reply' = [reply EXCEPT ![t] = r]
                 /\ UNCHANGED replyId
              \/ /\ Fault
                 /\ \E r \in {"lost", "err"} : reply' = [reply EXCEPT ![t] = r]
                 /\ UNCHANGED <<routines, nextId, replyId>>
    /\ UNCHANGED <<plan, storedId, signature, settling, writing, again, pc, wplan, wid, late, deletes>>

(* The app's timeout ends the wait; the request still reaches Hevy later. *)
AppStopsWaiting(t) ==
    /\ LateRequests
    /\ reply[t] = "wait"
    /\ pc[t] \in {"put", "post"}
    /\ Fault
    /\ late' = late \cup {[op |-> pc[t], id |-> wid[t], plan |-> wplan[t], dev |-> Owner(t)]}
    /\ reply' = [reply EXCEPT ![t] = "lost"]
    /\ UNCHANGED <<routines, nextId, plan, storedId, signature, settling, writing, again, pc, wplan, wid, replyId, deletes>>

HevyHandlesLate(m) ==
    /\ late' = late \ {m}
    /\ IF m.op = "put"
       THEN routines' = Put(m.id, m.plan) /\ UNCHANGED nextId
       ELSE routines' = Made(m.plan) /\ nextId' = nextId + 1
    /\ UNCHANGED <<plan, storedId, signature, settling, writing, again, taskVars, faults, deletes>>

(* settleKey's time passes. The assumption that makes it safe: Hevy handles *)
(* or drops a request within HevyRoutine.settleSeconds of its send.          *)
Settles(d) ==
    /\ settling[d]
    /\ \A m \in late : m.dev # d
    /\ settling' = [settling EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<routines, nextId, plan, storedId, signature, writing, again, taskVars, late, faults, deletes>>

PlayerDeletesRoutine ==
    /\ deletes < MaxDeletes
    /\ \E r \in routines : routines' = routines \ {r}
    /\ deletes' = deletes + 1
    /\ UNCHANGED <<nextId, plan, storedId, signature, settling, writing, again, taskVars, late, faults>>

---------------------------------------------------------------------------

Next ==
    \/ RowsChange
    \/ \E d \in Devices : StatInputsLoaded(d)
    \/ \E t \in Tasks : ListAnswered(t) \/ PutAnswered(t) \/ PostAnswered(t)
    \/ \E t \in Tasks : HevyAnswers(t) \/ AppStopsWaiting(t)
    \/ \E m \in late : HevyHandlesLate(m)
    \/ \E d \in Devices : Settles(d)
    \/ PlayerDeletesRoutine

Fairness ==
    /\ WF_vars(StatInputsLoaded("Phone"))
    /\ \A t \in Tasks : WF_vars(ListAnswered(t) \/ PutAnswered(t) \/ PostAnswered(t) \/ HevyAnswers(t))
    /\ WF_vars(\E m \in late : HevyHandlesLate(m))
    /\ WF_vars(Settles("Phone"))

Spec == Init /\ [][Next]_vars /\ Fairness

---------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A t \in Tasks : pc[t] \in {"idle", "list", "put", "post"}
    /\ faults <= MaxFaults

(* The account holds at most one routine of the app. *)
AtMostOneRoutine == Cardinality(routines) <= 1

(* At most one sync talks to the account at a time, over all devices. *)
OneWriteAtATime == Cardinality({t \in Tasks : pc[t] # "idle"}) <= 1

(* When the phone is idle and has written its current rows, every app routine *)
(* in the account holds those rows.                                          *)
WrittenPlanStays ==
    (/\ \A t \in Tasks : Owner(t) = "Phone" => pc[t] = "idle"
     /\ signature["Phone"] = plan["Phone"])
    => \A r \in routines : r.plan = plan["Phone"]

(* Once the rows stop changing and the faults run out, the app's routine *)
(* holds the phone's latest rows.                                        *)
EventuallyLatest == <>[](\A r \in routines : r.plan = plan["Phone"])

=============================================================================
