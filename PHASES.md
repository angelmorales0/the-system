# The System — Implementation Phases

Phases 1 and 2 are in the tree. Later phases follow `docs/MASTER_PLAN.md` §10 and `docs/AI_DAILY_QUEST_ENGINE.md`. The System, Goals, History, and Status chrome stays as it is.

## Phase 1 — Models, fallback quests, live binding (done)

- `Quest`, `QuestMode`, `QuestKind`, `Stat` (including FIN), `QuestBundle`, verification-method enum, `PlayerState` (level, XP, display name, Full Recovery bank).
- On-device `Resources/FallbackCatalog.json` keyed by mode × readiness band, including performance training, recovery, hybrid, full recovery, and penalty.
- Deterministic mode picker. Readiness is a placeholder, not WHOOP.
- System GOAL rows and `[Daily Quest: … has arrived.]` bind to today’s fallback bundle.
- Status binds display name (default Angel), the seven-stat radar, XP / level, and `FULL RECOVERY xN`.
- A checkbox toggled completion and granted stub XP. Verifiers were not wired yet.
- Not in this phase: Mercury, WHOOP, Strava, HealthKit, Screen Time, Live Activities, live LLM calls, Target UI, midnight penalty rollover.

## Phase 2 — Verifiers (done)

Master plan MVP step 3.

- `Evidence` carries `source`, `externalId`, `payloadHash`, and `timestamp`. A `Verifier` returns unchanged, progress, completed, failed, or incomplete.
- `manual_confirm` is a tap. It waits 30 seconds after the quest is assigned and allows 3 confirms per local day. Face ID stays later.
- `timer_session` is an in-app timer. The quest completes when wall-clock time reaches `minSec`.
- Stubs return incomplete for `whoop_strain`, `whoop_recovery`, `strava_activity`, `healthkit_workout`, `healthkit_nutrition`, `macrofactor_protein`, `mercury_spend_under`, and `screen_time_limit`. Each stub is marked with the phase that connects the live API.
- System rows go through a verifier. Timer rows start the timer. Manual rows confirm through the verifier. Stubbed rows still take a local checkbox, stored as on-device evidence rather than a forged API event.
- One `externalId` cannot clear a second quest on the same day. New bundles run through `strippingModelCompletion()`, so a model cannot mark a quest complete.

History day-clear cards and local midnight penalty rollover (master plan steps 6 and 7) are still open. They are not part of this slice.

## Phase 3 — HealthKit and nutrition

Master plan steps 8 and 9.

- HealthKit authorization and observers (workouts, nutrition, body mass, sleep fallback).
- Protein quests verify from HealthKit dietary protein. MacroFactor writes Apple Health; there is no MacroFactor API.

## Phase 4 — Backend and AI quest generation

Master plan steps 10 and 13.

- Personal backend: session auth, secrets vault, `POST /v1/quests/generate`.
- On-device morning context, schema re-check, and safety filter. The model cannot change a rules-locked mode or mark quests complete.
- The fallback catalog stays the offline path. One successful bundle per day key.

## Phase 5 — WHOOP and Strava

Master plan steps 11 and 12.

- WHOOP OAuth, recovery / sleep / workout sync, and webhooks. Readiness replaces the placeholder in the mode picker. REC stays a rolling composite, not today’s recovery score.
- Strava OAuth, activities, and webhooks. Run quests verify from Strava, with workout dedupe against WHOOP and HealthKit.

## Phase 6 — Targets and Full Recovery bank

Master plan steps 14 and 15.

- Goals screen segmented `GOALS | TARGETS` using the existing card chrome.
- System banner `TARGET ACTIVE` and `⟪TARGET⟫` rows. At most one active Target.
- Sunday OPTIONAL section banks a Full Recovery token (cap 3). The Status row spends a token through a confirm sheet.

## Phase 7 — FIN, penalties, push

Master plan steps 16, 17, and 18.

- Mercury Read Only token stays on the backend. FIN aggregates, spend-under quests, and the FIN radar stat update from those aggregates.
- Screen Time: FamilyControls picker, penalty shields on selected distractors, DeviceActivity monitor, Live Activity. Shields are not a full phone lock.
- Silent push when a verifier clears a quest.

## Later (master plan steps 19–25)

Plaid for non-Mercury accounts, EventKit calendar detail, DeviceActivityReport FOC charts, an on-device model as an offline author, a watchOS companion, a Target pause on Full Recovery, and penalty tier 3 polish.
