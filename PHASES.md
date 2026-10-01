# The System — Implementation Phases

Phases 1 through 4 are in the tree. Later phases follow `docs/MASTER_PLAN.md` §10 and `docs/AI_DAILY_QUEST_ENGINE.md`. The System, Goals, History, and Status chrome stays as it is.

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

## Phase 3 — Targets (done)

Master plan step 14. At most one Target is active. Goals stay the long-term mocks; they are not created from Targets.

- `Target` is a dated campaign: title, kind, `startsOn`, `endsOn`, daily requirements, unit and cleared-day progress, status `draft | scheduled | active | completed | expired | aborted`.
- Goals has a `GOALS | TARGETS` segment. Create, edit, activate, and abort use the existing panel, type, and cyan.
- An active Target prefers hybrid when readiness is not red. Its requirements are injected into whatever mode the picker chose, in front of the training rows, replacing catalog `target_injection` placeholders.
- System shows `TARGET ACTIVE · {title} · Day N/M` under the header and `⟪TARGET⟫` on those GOAL rows.
- Completing an injected quest adds its quota to `unitsDone`. Clearing every injected quest for the day counts one cleared day. Hitting the unit goal grants `[Target Complete.]` and 150 XP. The next scheduled Target whose window includes today promotes the next time the day bundle is built.
- Targets persist on the same UserDefaults snapshot as the player and the quest bundle.

Full Recovery spend, the Sunday OPTIONAL bank, and History cards are still open.

## HealthKit and nutrition (not started)

Master plan steps 8 and 9.

- HealthKit authorization and observers (workouts, nutrition, body mass, sleep fallback).
- Protein quests verify from HealthKit dietary protein. MacroFactor writes Apple Health; there is no MacroFactor API.

## Phase 4 — Backend and AI quest generation (done)

Master plan steps 10 and 13, scoped to generation. Session auth and the secrets vault are still later.

- `ContextBuilder` assembles `MorningContext` from the player, the active Target, placeholder readiness, streaks, recent titles, and constraints. Token-shaped text is redacted. WHOOP, Strava, Mercury, and Screen Time are marked unavailable.
- The rules-locked mode picker stays authoritative. A generated bundle whose mode does not match is rejected.
- `QuestGenerating` has a mock client and an HTTP client. The mock returns the fallback catalog for the locked mode, with the active Target injected. The HTTP client `POST`s to `{base}/v1/quests/generate`. Set `QUEST_GENERATE_BASE_URL` or UserDefaults `com.angelmorales.thesystem.questGenerateBaseURL` to an `http` or `https` URL. With no URL, the app uses the mock. Timeout or an unsafe bundle keeps the catalog (`generatedBy: fallback`).
- The morning refresh tries generation once per `dayKey`, including a failed attempt, and caches an accepted bundle. Completing a quest or starting a timer before the reply arrives keeps the catalog. A new local day clears that attempt.
- On-device validation strips `completed`, status, evidence, and grants. It rejects protein outside 80–250g, a run over 90 minutes on yellow, a hard STR session on red, calories under 1500, an absurd Mercury cap, and unsafe phrases. Target requirements must be present as `target_injection`.
- `backend/` is a FastAPI stub. Without `XAI_API_KEY` it returns a template. With that variable it calls xAI Grok (`grok-4.6`, or `XAI_MODEL`) and re-validates. The key is read from the environment only. See `backend/README.md`.

## Phase 5 — WHOOP and Strava

Master plan steps 11 and 12.

- WHOOP OAuth, recovery / sleep / workout sync, and webhooks. Readiness replaces the placeholder in the mode picker. REC stays a rolling composite, not today’s recovery score.
- Strava OAuth, activities, and webhooks. Run quests verify from Strava, with workout dedupe against WHOOP and HealthKit.

## Phase 6 — Full Recovery bank (open)

Master plan step 15. Targets themselves landed in Phase 3.

- Sunday OPTIONAL section banks a Full Recovery token (cap 3). The Status row spends a token through a confirm sheet.

## Phase 7 — FIN, penalties, push

Master plan steps 16, 17, and 18.

- Mercury Read Only token stays on the backend. FIN aggregates, spend-under quests, and the FIN radar stat update from those aggregates.
- Screen Time: FamilyControls picker, penalty shields on selected distractors, DeviceActivity monitor, Live Activity. Shields are not a full phone lock.
- Silent push when a verifier clears a quest.

## Later (master plan steps 19–25)

Plaid for non-Mercury accounts, EventKit calendar detail, DeviceActivityReport FOC charts, an on-device model as an offline author, a watchOS companion, a Target pause on Full Recovery, and penalty tier 3 polish.
