# The System — Implementation Phases

Phases 1 through 7 are in the tree. Later polish follows `docs/MASTER_PLAN.md` §10 and `docs/AI_DAILY_QUEST_ENGINE.md`. The System, Goals, History, and Status chrome stays as it is. Penalty setup on a device is in `docs/PHASE7_DEVICE.md`.

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

History day-clear cards (master plan step 6) are still open. Midnight penalty rollover landed in Phase 7.

## Phase 3 — Targets (done)

Master plan step 14. At most one Target is active. Goals stay the long-term mocks; they are not created from Targets.

- `Target` is a dated campaign: title, kind, `startsOn`, `endsOn`, daily requirements, unit and cleared-day progress, status `draft | scheduled | active | completed | expired | aborted`.
- Goals has a `GOALS | TARGETS` segment. Create, edit, activate, and abort use the existing panel, type, and cyan.
- An active Target prefers hybrid when readiness is not red. Its requirements are injected into whatever mode the picker chose, in front of the training rows, replacing catalog `target_injection` placeholders.
- System shows `TARGET ACTIVE · {title} · Day N/M` under the header and `⟪TARGET⟫` on those GOAL rows.
- Completing an injected quest adds its quota to `unitsDone`. Clearing every injected quest for the day counts one cleared day. Hitting the unit goal grants `[Target Complete.]` and 150 XP. The next scheduled Target whose window includes today promotes the next time the day bundle is built.
- Targets persist on the same UserDefaults snapshot as the player and the quest bundle.

Full Recovery spend and the Sunday OPTIONAL token grant are in Phase 7 and the fallback catalog. History cards are still open.

## Phase 4 — Backend and AI quest generation (done)

Master plan steps 10 and 13, scoped to generation. Session auth and the secrets vault are still later.

- `ContextBuilder` assembles `MorningContext` from the player, the active Target, readiness, streaks, recent titles, and constraints. Token-shaped text is redacted. Strava and Screen Time stay unavailable in that payload. WHOOP is included only after a readiness snapshot exists. Mercury totals are included only after a finance snapshot exists (Phase 6).
- The rules-locked mode picker stays authoritative. A generated bundle whose mode does not match is rejected.
- `QuestGenerating` has a mock client and an HTTP client. The mock returns the fallback catalog for the locked mode, with the active Target injected. The HTTP client `POST`s to `{base}/v1/quests/generate`. Set `QUEST_GENERATE_BASE_URL` or UserDefaults `com.angelmorales.thesystem.questGenerateBaseURL` to an `http` or `https` URL. With no URL, the app uses the mock. Timeout or an unsafe bundle keeps the catalog (`generatedBy: fallback`).
- The morning refresh tries generation once per `dayKey`, including a failed attempt, and caches an accepted bundle. Completing a quest or starting a timer before the reply arrives keeps the catalog. A new local day clears that attempt.
- On-device validation strips `completed`, status, evidence, and grants. It rejects protein outside 80–250g, a run over 90 minutes on yellow, a hard STR session on red, calories under 1500, an absurd Mercury cap, and unsafe phrases. Target requirements must be present as `target_injection`.
- `backend/` is a FastAPI stub. Without `XAI_API_KEY` it returns a template. With that variable it calls xAI Grok (`grok-4.6`, or `XAI_MODEL`) and re-validates. The key is read from the environment only. See `backend/README.md`.

## Phase 5 — WHOOP, Strava, and HealthKit (done)

Master plan steps 8, 9, 11, and 12. Screen Time stays in Phase 7.

- `HealthKitBridge` asks to read body mass, dietary protein, dietary energy, sleep, and workouts. Observers refresh quests when those samples change. MacroFactor is preferred when the HealthKit source name or bundle id contains `macrofactor`. There is no MacroFactor API.
- `healthkit_workout`, `healthkit_nutrition`, and `macrofactor_protein` complete from those queries after authorization. Without access they stay incomplete and the row explains the TODO. They cannot be checked off by hand.
- WHOOP and Strava OAuth, refresh, and webhook receivers live in `backend/`. Tokens stay in the environment or `backend/.secrets/`. Snapshot endpoints return summaries only. The app calls them when `QUEST_GENERATE_BASE_URL` is set. Without tokens the verifiers stay incomplete and do not invent a completion.
- `WorkoutDedupe` treats recordings as the same session when the sport family matches and the intervals overlap inside a 5-minute pad and a 10-minute start gap. The canonical id prefers Strava, then WHOOP, then HealthKit.
- WHOOP `recovery_score` is stored as readiness (green ≥ 67, yellow ≥ 34, otherwise red) and can change a quiet morning's mode. It is not copied into the REC stat. REC stays the XP-driven radar value. A rolling average is kept aside until at least seven days exist.

## Phase 6 — Mercury FIN (done)

Master plan §7 and step 16. The Read Only token stays on the backend.

- `MERCURY_API_TOKEN` is read from the environment only. `MERCURY_API_BASE_URL` selects production (`https://api.mercury.com/api/v1`) or a sandbox host. The phone never receives the token.
- `POST /v1/integrations/mercury/sync` pages through accounts and transactions. `GET /v1/integrations/mercury/snapshot?day=` returns discretionary and necessary totals, pace, and YTD income toward $500,000. `GET` accounts and transactions read the same cache.
- `POST /v1/webhooks/mercury` checks `Mercury-Signature` (HMAC-SHA256 of `timestamp.raw_body`, 5-minute skew) for `transaction.created`, `transaction.updated`, and the balance-updated events.
- Category totals use a default map (Grocery and rent-like necessary; Restaurants and Retail discretionary). Override it with `mercury_categories.json` or `MERCURY_CATEGORY_MAP`. Internal transfers and interest are excluded from YTD income.
- Pace states `NORMAL` / `CAUTION` / `WARNING` / `CRITICAL` use undecided defaults (daily cap $40, weekly $280, balance floor $500, cutoffs 0.75 / 1.00 / 1.25).
- `mercury_spend_under` completes from that snapshot when the day is settled and spend is still under the cap. It cannot be checked off by hand. Without a token it stays incomplete.
- Status FIN stays the quest-granted stat plus at most 20 projection points. It is not the account balance.
- Performance Training fallback rows include an optional Light Spend Cap. Finance Discipline already had Spend Under Cap.

## Full Recovery bank (done)

Master plan step 15.

- Sunday OPTIONAL rows in the fallback catalog grant a Full Recovery token (cap 3) when that quest is completed.
- Status → FULL RECOVERY asks before spending one token. A quiet morning assigns today. A day already underway queues tomorrow. That Full Recovery day does not raise the penalty tier.

## Phase 7 — Penalties, Screen Time, Live Activity (done)

Master plan §1.5, §9, and step 17. Device steps are in `docs/PHASE7_DEVICE.md`.

- America/Los_Angeles midnight: an incomplete required set raises `penaltyTier` from 1 to 3 and selects the fallback Penalty Quest bundle. A Full Recovery day waives that miss.
- Family Controls picker on an additive Status sheet. The selection and `penaltyActive` live in the App Group. Morning context does not receive tokens or minute totals.
- Named `ManagedSettingsStore` `penalty` applies shields on activate and `clearAllSettings()` on clear. A Device Activity monitor re-asserts them, including when its interval ends.
- ActivityKit Live Activity starts and ends from the foreground. It goes stale after 8 hours. Shields outlive it.
- Completing every required penalty quest lifts shields, ends the Live Activity, and sets the tier to 0. XP was already granted at 0.9×.

Remaining: Apple Family Controls (Distribution) approval on each App ID, and a physical-device pass. This environment cannot compile the extensions.

## Later (master plan steps 18–25)

Silent push when a verifier clears a quest, Plaid for non-Mercury accounts, EventKit calendar detail, DeviceActivityReport FOC charts, an on-device model as an offline author, a watchOS companion, a Target pause on Full Recovery, History day-clear cards, and penalty tier 3 polish.
