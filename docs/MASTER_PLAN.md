# The System — Master Implementation + UX Plan

**Repo:** `angelmorales0/the-system`  
**Owner:** Angel Morales (personal Solo Leveling iOS app)  
**UI constraint:** Keep the existing 4 swipe pages — `SystemView`, `GoalsView`, `HistoryView`, `StatusView` — and shared chrome in `ContentView.swift` (`SystemPanel`, `SystemTheme`, cut-corner panels, cyan/muted copy). **Do not redesign screens.** Additive content and data binding only.  
**Sources incorporated:**  
- `/workspace/research/mercury-api-fin-brief.md`  
- `/workspace/research/solo-leveling-api-integrations.md`  
- `/workspace/research/solo-leveling-ios-penalty-screen-time.md`  
- `/workspace/the-system-design/AI_DAILY_QUEST_ENGINE.md`  
- Live Swift UI: `MyApp/{System,Goals,History,Status,Content}View.swift` (main @ 2026-09-30)

---

## 1. Product feel — day-in-the-life (end-to-end)

Same swipe shell as today (`TabView` page style, no dots). System panel language stays:

```
[Daily Quest: <MODE TITLE> has arrived.]
GOAL
───
quest rows: Title ……………… [n/N] □
───
WARNING: Failure to complete…
```

### 1.1 Training day (default, no Target)

| Time | What happens |
|------|----------------|
| ~05:00 / first open | On-device mode picker → `performance_training` (WHOOP readiness green/yellow). `ContextBuilder` posts redacted `MorningContext` → cloud LLM → validated `QuestBundle`. Fallback catalog if LLM fails. |
| Open System | Header: `[Daily Quest: Performance Training has arrived.]` Rows like current mock: Run Intervals, Bench Press, Mobility, Protein — but live `[current/target]` from verifiers. |
| Morning run | Strava (or WHOOP/HK) activity lands → webhook/poll → progress fills → checkbox cyan when done. |
| Lift | WHOOP strength sport or HealthKit strength workout → STR quest clears. |
| Night | MacroFactor → HealthKit protein ≥ target → last checkbox. Day clear → XP + STR/END/AGI ticks → History. |

### 1.2 Target / interview-prep day (hybrid)

| Time | What happens |
|------|----------------|
| Active Target | Thin cyan banner under header: `TARGET ACTIVE · Interview Prep · Day 4/14` (additive; same `SystemPanel`). |
| Header | `Hybrid Training` (or Target-forced mode). |
| GOAL rows | `⟪TARGET⟫ LeetCode Mediums …… [0/3]` + lighter training + protein. Target rows are **required**. |
| Verify | Manual confirm (Face ID optional) for LC; Strava/HK/MF for the rest. Completing required set bumps Target `daysCleared` / `unitsDone`. |
| Full Recovery spend | Physical training waived; **Target injections still appear** (v1 default: career Targets don’t sleep). |

### 1.3 Sunday → bank Full Recovery

| Step | Feel |
|------|------|
| Sunday GOAL | Slightly lighter required set (or recovery if WHOOP red). |
| OPTIONAL section | After GOAL divider: `OPTIONAL` + easy quest (e.g. Evening Walk 15 min). Subtitle feel: bank Full Recovery on complete. |
| Complete optional | Status `FULL RECOVERY xN` increments (cap 3). Existing Status row already shows `FULL RECOVERY` / `x2` + bolt — wire only. |
| Spend later | Tap bank on Status → confirm sheet → assign `full_recovery` mode (today if pre-gen, else next day). Bank decrements. |

### 1.4 Full Recovery day

- Header: `[Daily Quest: Full Recovery Day has arrived.]`
- GOAL: empty or one soft REC quest; Target rows still injected if active.
- No training miss → no penalty. Warning block can soften or stay as System flavor.

### 1.5 Penalty day (missed required quests at local midnight)

| Step | Feel |
|------|------|
| Rollover | `penaltyTier` 1→3. Next morning mode locked to `penalty`. |
| System | Header: `Penalty Quest has arrived.` WARNING copy stronger (amber/red within existing cyan/muted palette). Harder / more rows. |
| Device | Selected distractor apps/sites get **ManagedSettings shields** (not full phone lock). Live Activity / Dynamic Island: `PENALTY ACTIVE — <quest>` (≤8h LA; shields persist until cleared). |
| Clear | Complete all penalty quests in app → lift shields, end LA, tier→0, XP at 0.9× that day. Miss again → escalate. |

**Copy note:** Status mock shows `DANIEL` — bind to player display name (Angel / configurable). Do not change layout.

---

## 2. Feature model — clear distinctions

| Concept | What it is | Horizon | Effect on daily quests | UI home |
|---------|------------|---------|------------------------|---------|
| **Quest** | Single actionable item with verify method, progress, XP, stat | One local day | Completing required set = day clear | System GOAL / OPTIONAL |
| **Mode** (`QuestMode`) | Day archetype; drives header + quest pool + difficulty bias | One day | Picked by **rules first**; LLM only fills quests inside mode | Header: `Daily Quest: X has arrived.` — no new tabs |
| **Target** | Time-bounded campaign (days–weeks) | Bounded (`startsOn`–`endsOn`) | **Hard injection** into GOAL (`target_injection`, `⟪TARGET⟫`) | Goals segmented **TARGETS** + System banner |
| **Goal** | Long-term metric achievement | Months / open | Soft bias only (`goalsBias`) | Goals cards (existing `GoalCard`) |
| **Stat** | STR END INT AGI FOC REC **FIN** | Persistent | Quest complete grants +difficulty weight | Status radar (add FIN = 7 axes) |
| **Penalty** | Consequence mode + optional Screen Time shields | Until cleared / escalate | Forced `penalty` mode; XP tax | System styling + Live Activity |
| **Full Recovery** | Banked rest token | Spend 1 day | Waives hard training; Target still injected (v1) | Status `FULL RECOVERY xN` |

### Modes (primary one per day)

`performance_training` · `interview_prep` · `study_block` · `recovery` · `full_recovery` · `nutrition_focus` · `finance_discipline` · `focus_deepwork` · `hybrid` · `penalty`

### Quest kinds

| Kind | Required? | Section |
|------|-----------|---------|
| `daily` | Yes (unless full_recovery) | GOAL |
| `optional` | No | OPTIONAL |
| `target_injection` | Yes while Target active | GOAL + `⟪TARGET⟫` |
| `penalty` | Yes on penalty days | GOAL (penalty styling) |

### Invariants (v1)

- At most **1 active Target**; others `scheduled`.
- LLM never marks completion; Verifier owns state.
- Goals never auto-created from Targets.

---

## 3. Integration map

| Data | Source of truth | API / framework | Powers |
|------|-----------------|-----------------|--------|
| Readiness (today 0–100) | WHOOP `recovery_score` | WHOOP API v2 OAuth + webhooks | Mode picker; soft gate STR/END load; show separate from REC |
| REC (long-term capacity) | Computed 7–28d WHOOP sleep/HRV/RHR/adherence | WHOOP sleep + recovery collections | Status REC; REC XP — **not** equal to today’s recovery_score |
| Sleep duration/stages | WHOOP Sleep (`SCORED`, non-nap) | WHOOP; fallback HK `SleepAnalysis` | Sleep quests; REC inputs |
| Day Strain | WHOOP Cycle `score.strain` | WHOOP poll (no strain webhook) | `whoop_strain` verify |
| Run distance/time | Strava DetailedActivity | Strava API v3 + push subscriptions | END quests; prefer GPS distance from Strava |
| Lift / strength | WHOOP strength sports **or** HK strength workouts | WHOOP workout / HealthKit | STR quests |
| Body mass | HealthKit via MacroFactor write | HealthKit `bodyMass` | Goals (145 lb); weight trend |
| Nutrition (kcal, P/C/F) | HealthKit via MacroFactor | HealthKit dietary types — **no MacroFactor public API** | Protein / nutrition quests |
| Steps / Watch workouts | HealthKit (+ WHOOP step_count) | HealthKit background delivery | Fallback END/STR |
| FIN balances / spend / income | Mercury accounts + txns | Mercury REST Read Only token + webhooks | FIN stat; spend-under quests; $500K YTD; overspend alerts |
| Non-Mercury banks (later) | Plaid / MX | Plaid Link later | Same FIN ledger schema |
| FOC / distractor adherence | DeviceActivity thresholds + report UI | FamilyControls / DeviceActivity / ManagedSettings | FOC score inference; penalty shields |
| Calendar busy / focus blocks | EventKit (optional) | EventKit | MorningContext `calendar` |
| Quest authoring | Cloud LLM (Grok/OpenAI via backend) | `POST /v1/quests/generate` | Daily `QuestBundle` |
| Manual / timer quests | On-device | In-app timer + confirm | INT Targets, mobility |

**Dedupe workouts:** overlap start/end within ~5–10 min + same sport family → one canonical event (`strava_id`, `whoop_uuid`, `hk_uuid`). Prefer Strava distance, WHOOP strain/zones, HK when only Watch recorded.

**Key docs:**  
https://developer.whoop.com/api · https://developers.strava.com/docs/authentication/ · https://developer.apple.com/documentation/healthkit · https://help.macrofactorapp.com/en/articles/65-connect-health-connect-or-apple-health · https://docs.mercury.com/docs/getting-started · https://developer.apple.com/documentation/familycontrols

---

## 4. Architecture — iOS + backend + secrets

```
┌─────────────────────────────────────────────┐
│  iOS (angelmorales0/the-system)             │
│  • SwiftUI: System / Goals / History / Status│
│  • QuestEngine: mode picker, DayPlan store, │
│    Target lifecycle, XP/stats, fallbacks    │
│  • Verifiers + HealthKit observers          │
│  • FamilyControls / ManagedSettings /       │
│    DeviceActivity / Live Activities         │
│  • ContextBuilder → redacted MorningContext │
│  • ASWebAuthenticationSession → OAuth start │
└──────────────────┬──────────────────────────┘
                   │ HTTPS JWT session
                   ▼
┌─────────────────────────────────────────────┐
│  Backend (small personal API)               │
│  • Token vault (WHOOP/Strava refresh;       │
│    Mercury Read Only; LLM key) — KMS/SM     │
│  • OAuth exchange/refresh                   │
│  • Webhooks: Mercury, WHOOP, Strava         │
│  • Reconciliation cron + Mercury keepalive  │
│  • POST /v1/quests/generate → LLM + schema  │
│    validate + safety filter                 │
│  • Aggregates for FIN / push on quest pass  │
└───────┬───────────┬───────────┬─────────────┘
        ▼           ▼           ▼
     Mercury     WHOOP       Strava
```

### On-device vs cloud

| Concern | Where |
|---------|-------|
| Mode picker, verification, XP, Target state, DayPlan, FallbackCatalog | **On-device** |
| HealthKit, Screen Time tokens, MacroFactor nutrition | **On-device only** (summaries to cloud) |
| LLM quest authoring + prompt registry | **Cloud** |
| Schema validate + safety filter | **Backend then re-check on-device** |
| OAuth client secrets + Mercury token | **Backend only — never in IPA** |
| Penalty shields / Live Activity | **On-device** (App Group + extensions) |

### Secrets policy

1. Mercury: Read Only token in server secrets (`secret-token:mercury_production_…`). Never Keychain-as-bank-token in app.  
2. WHOOP/Strava: client_secret server-side; refresh tokens in vault; rotate WHOOP refresh on each use.  
3. LLM API key: backend only.  
4. iOS holds session JWT + HealthKit auth + FamilyControls selection in App Group.

---

## 5. AI quest engine

### 5.1 Morning flow

1. Detect `questDayKey` change (local TZ `America/Los_Angeles`) on foreground or ~05:00 BG.  
2. **Deterministic mode picker** (locked):

```
if penaltyTier > 0 and not spending_full_recovery → penalty
elif user_confirmed_spend_full_recovery → full_recovery
elif Sunday and whoop.readinessBand == red → recovery (+ optional bank quest)
elif activeTarget and readiness != red → hybrid (or Target.kind-forced)
elif readiness red or sleepPerformance < 60 → recovery
elif calendar.busyMinutes > 360 → focus_deepwork | nutrition_focus
else → performance_training
```

3. Build `MorningContext` (player, whoop, calendar, activeTarget, goalsBias, nutrition, mercury, focus, freshness, recentQuestTitles, constraints).  
4. `POST /v1/quests/generate` → LLM returns `QuestBundle`.  
5. Server JSON Schema + safety filter → client re-validate → persist `DayPlan` → bind `SystemView`.  
6. Fail/timeout (>8s) → `FallbackCatalog.json` by mode + readinessBand; `generatedBy: "fallback"`.

LLM **must not** override `modeDecision.selectedMode` when `lockedByRules == true`. Strip any `completed` fields from LLM output.

### 5.2 QuestBundle schema summary

Required: `schemaVersion`, `dayKey`, `mode`, `quests`, `narrative`.  
Optional: `headerLine` → `[Daily Quest: {headerLine} has arrived.]`, `warnings`.

Each quest: `id`, `title`, `kind`, `stat` ∈ {STR,END,INT,AGI,FOC,REC,FIN}, `verification.{method,params}`, `deadline`, `xp`, `difficulty`, `mode`, `progress.{current,target,unit}`, optional `targetId`, `reward`.

**Verification methods (enum only):**  
`whoop_strain` · `whoop_recovery` · `strava_activity` · `healthkit_workout` · `healthkit_nutrition` · `macrofactor_protein` · `mercury_spend_under` · `screen_time_limit` · `manual_confirm` · `timer_session`

Full schema: `AI_DAILY_QUEST_ENGINE.md` §3.

### 5.3 Verification layer

```
BG fetch / foreground / HK observer / webhook push
  → IntegrationAdapters.refresh()
  → Verifier.evaluate(quest) → progress | complete | unchanged
  → QuestStore.apply (idempotent: quest.id + evidence.hash)
  → all required done → DayClear → XP/stats → Target bump
```

| Method | Pass |
|--------|------|
| `strava_activity` | Matching type today, `moving_time ≥ min` |
| `whoop_strain` | Day/workout strain ≥ min, `SCORED` |
| `whoop_recovery` | recovery_score ≥ min (REC quests) |
| `healthkit_workout` | Type + duration today |
| `macrofactor_protein` | HK dietaryProtein ≥ g (prefer MacroFactor source) |
| `mercury_spend_under` | Discretionary debits today ≤ max |
| `screen_time_limit` | Distract ≤ max **OR** deep work ≥ min (threshold inference) |
| `timer_session` / `manual_confirm` | In-app (manual ≤3/day, ≥30s after assign) |

Anti-cheat: one `externalId` → limited quest clears; LLM cannot complete; dayKey from server when online.

### 5.4 Fallbacks & rate limits

- 1 successful LLM bundle / dayKey; 3 validate retries; 1 manual regenerate/day.  
- Fallback example (training + yellow): Zone2 20m Strava · Push 30m HK · Mobility 10m timer · Protein 150g MF.  
- Hybrid fallback = Target injections verbatim + 2 light catalog quests.  
- Safety reject: protein outside ~80–250g; long runs on yellow; hard STR on red; calorie floor; unsafe phrase filter.

---

## 6. Targets — lifecycle & System injection

```
draft → scheduled → active → completed
                      ↘ expired
                      ↘ aborted
```

### Create (additive UX — no 5th page)

- Prefer **Goals screen segmented control** `GOALS | TARGETS` inside existing scroll; Target cards reuse `GoalCard`-style chrome with deadline countdown + daily injection preview.  
- Alternate: long-press System panel / Status pattern → `NEW TARGET` sheet.  
- Fields: title, kind (`interview_prep` | `study` | `cut` | `custom`), `startsOn`, `endsOn`, daily requirement templates (quota, stat, verification), optional `unitsGoal`.

### Activate

When `startsOn ≤ today ≤ endsOn` and no other active → `active`. System banner: `TARGET ACTIVE · {title} · Day {i}/{n}`. Morning generator **must** inject `target_injection` quests from `dailyRequirements` (LLM may rephrase title; Verifier keys `targetId` + `templateId`).

### Stack with training

| Readiness | Behavior |
|-----------|----------|
| Green | `hybrid`: full-ish training + Target |
| Yellow | Shorter training + full Target |
| Red | Recovery physical + Target still injected |
| Full Recovery day | Physical waived; Target still injected (toggle later) |

### Complete / expire

- Complete: `unitsDone ≥ unitsGoal` or days met by `endsOn` → toast `[Target Complete.]` + XP bonus; promote next scheduled.  
- Expire: unmet → History `FAILED`; no doom spiral.  
- Goals remain independent soft bias only.

---

## 7. FIN + Mercury

**Preference:** Mercury **direct** API for Angel’s Mercury accounts. **Not Plaid for Mercury.** Plaid later for other institutions into the same FIN ledger.

### Token setup

1. Mercury Personal/org → **All Settings → Tokens** → Create **Read Only** (or custom read scopes).  
2. Confirm Tokens UI exists on Personal; if missing → personal@mercury.com / api@mercury.com.  
   Marketing claims API on Personal: https://mercury.com/personal-banking  
3. Store token server-side only. Auth: `Authorization: Bearer secret-token:mercury_production_…`  
   Base: `https://api.mercury.com/api/v1`  
   Docs: https://docs.mercury.com/docs/getting-started · https://docs.mercury.com/docs/api-token-security-policies  
4. Keepalive: any GET ≤30 days (unused tokens auto-delete at 45d).

### Webhooks

- `POST /webhooks` with `transaction.created`, `transaction.updated`, `checkingAccount.balance.updated`, `savingsAccount.balance.updated`, `creditAccount.balance.updated`.  
- Verify `Mercury-Signature: t=…,v1=…` = HMAC-SHA256(secret, `timestamp + "." + raw_body`); reject skew >5 min.  
- Payload is a **diff** → always `GET` full txn by `resourceId`. Dedupe on event `id`.  
- **Webhooks unavailable in sandbox** — verify in prod.  
- Docs: https://docs.mercury.com/reference/webhooks · https://docs.mercury.com/reference/events

### Category rules (app-owned; Mercury has no budget API)

| Mercury signal | FIN tag |
|----------------|---------|
| `Grocery`, `Utilities`, `Insurance`, `Medical`, `Taxes`, rent-like | necessary |
| `Restaurants`, `Entertainment`, `AlcoholAndBars`, `Retail`, … | discretionary |
| Positive amounts + payroll allowlist / regex on counterparty | income (toward **$500K/yr pre-tax**) |
| `internalTransfer`, interest (optional exclude) | transfer / ignore |

Map table + user overrides. Custom Mercury categories optional via `POST /categories`.

### Alerts / quests

- Overspend: daily/weekly discretionary burn vs soft cap; `availableBalance` hard floor.  
- Quest `mercury_spend_under`: pass if discretionary ≤ max.  
- Status FIN XP from discipline quests + aggregates.  
- iOS shows **backend aggregates only** — never raw Mercury token.

---

## 8. Fitness / recovery — verification + REC vs Readiness

### Readiness vs REC

| | **Readiness** | **REC** |
|--|---------------|---------|
| Meaning | “Can I train **today**?” | Long-term recovery **capacity** (game stat) |
| Source | WHOOP daily `recovery_score` (+ RHR, HRV RMSSD, SpO2) | Rolling 7–28d: sleep consistency/performance, duration adherence, HRV/RHR trends, recovery-day adherence |
| UI | MorningContext / soft gates (not a 5th radar axis) | Status radar `REC` |

Do **not** set REC = today’s recovery_score.

### Verification priorities

| Quest | Pass rule |
|-------|-----------|
| Run X mi / Y min | Dedupe Strava∩WHOOP∩HK; distance prefer Strava; moving_time sanity |
| Lift session | WHOOP strength sports **or** HK strength **or** Strava WeightTraining; duration/strain; `SCORED` |
| Sleep Y h | WHOOP overnight non-nap; else HK asleep stages |
| Protein g | Sum HK `dietaryProtein` (MacroFactor source preferred) |
| Readiness gate | Soft: red → force recovery mode regardless of LLM |

### MacroFactor

Enable More → Integrations → Apple Health. App reads HK only.  
https://help.macrofactorapp.com/en/articles/102-integrations

### WHOOP / Strava setup (personal)

- WHOOP: Developer Dashboard app; Sandbox OK for solo (≤10). Scopes: `offline read:recovery read:sleep read:cycles read:workout read:body_measurement`.  
  https://developer-dashboard.whoop.com/ · https://developer.whoop.com/docs/developing/oauth  
- Strava: Single Player Mode (capacity 1). Scope `activity:read_all`. Webhooks preferred.  
  https://www.strava.com/settings/api · https://developers.strava.com/docs/webhooks/

---

## 9. Penalties — Screen Time stack + Live Activity

### Stack (extensions)

1. Main app — quest fail orchestration, picker, LA start  
2. DeviceActivityMonitor — re-assert/clear shields  
3. ShieldConfiguration — Solo Leveling “Penalty Zone” branding  
4. ShieldAction — deep link to app; **do not** clear shield until quest done  
5. Widget / Live Activity — Lock Screen + Dynamic Island  
6. Optional DeviceActivityReport — FOC visualization only  

Shared: App Group; Family Controls entitlement on **app + every extension**.

### Auth

```swift
try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
```

No Family Sharing required. Distribution: request **Family Controls (Distribution)** per App ID.  
https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement

### Flow

```
Miss required at rollover → PenaltyCoordinator
  1. Persist PenaltyState + FamilyActivitySelection (App Group)
  2. ManagedSettingsStore(named: .penalty).shield.{applications,categories,webDomains}
  3. DeviceActivityCenter.startMonitoring(penalty schedule)
  4. Activity.request(PenaltyAttributes…) // foreground; pushType for updates
User opens Instagram → ShieldConfiguration → ShieldAction → open app
Complete penalty quests → clearAllSettings() · stopMonitoring · activity.end
```

- Shields = selected distractors only (**not** full phone lock). Prefer `shield.*` over `blockedApplications`.  
- Live Activity max ~**8h**; shields persist longer. Start LA in main app (monitor extension cannot reliably `Activity.request`).  
- FOC: threshold events + report UI; **no** official raw minute export to main app DB.  
Docs: https://developer.apple.com/documentation/ScreenTimeAPIDocumentation · https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities · WWDC21 10123 / WWDC22 110336

---

## 10. Implementation phases (ordered against existing SwiftUI)

### MVP — playable daily loop on existing UI

| # | Build step | Touch |
|---|------------|-------|
| 1 | Models: `Quest`, `DayPlan`, `PlayerState`, `StatCode` (+FIN), SwiftData/GRDB | New `Models/` |
| 2 | `FallbackCatalog.json` + deterministic mode picker (WHOOP stub/mock OK) | New |
| 3 | Verifiers: `timer_session` + `manual_confirm` | New |
| 4 | Bind `SystemView` to `DayPlan` — replace hard-coded `quests` tuple; live `[n/N]`; checkbox from status; header from `headerLine` | `SystemView.swift` |
| 5 | Wire Status XP bar + radar from `PlayerState`; rename `DANIEL` → display name; keep Full Recovery row | `StatusView.swift` |
| 6 | History: append day-clear / quest log cards (keep Goals/STATS chart sections) | `HistoryView.swift` |
| 7 | Local midnight rollover → penaltyTier + next-day penalty fallback bundle | New |

### v1 — integrations + AI + Targets + FIN + penalties

| # | Build step | Touch |
|---|------------|-------|
| 8 | HealthKit auth + observers (workouts, nutrition, bodyMass, sleep fallback) | New + entitlements |
| 9 | MacroFactor path documented; protein verifier | Verifier |
| 10 | Backend scaffold: auth, secrets, `POST /v1/quests/generate` | Backend repo |
| 11 | WHOOP OAuth + recovery/sleep/workout sync + webhooks; readiness in mode picker; REC composite job | Backend + iOS |
| 12 | Strava OAuth + activities + webhooks; run verifier + dedupe | Backend + iOS |
| 13 | ContextBuilder + LLM path; safety filter; fallback still primary offline | iOS + backend |
| 14 | Targets CRUD: Goals segmented `GOALS \| TARGETS`; System banner + `⟪TARGET⟫` rows | `GoalsView.swift`, `SystemView.swift` |
| 15 | Optional Sunday section + Full Recovery bank spend confirm on Status | `SystemView`, `StatusView` |
| 16 | Mercury Read Only + webhooks + category map + FIN aggregates; FIN on radar | Backend + `StatusView` |
| 17 | Screen Time: FamilyControls picker, PenaltyCoordinator, monitor/shield/LA extensions | New targets |
| 18 | Push / silent notify on auto-verify complete | Backend + iOS |

### Later

| # | Item |
|---|------|
| 19 | Plaid for non-Mercury accounts into same FIN ledger |
| 20 | EventKit calendar richness in MorningContext |
| 21 | DeviceActivityReport FOC charts; multi-threshold FOC estimates |
| 22 | On-device small model as offline author (same schema) |
| 23 | watchOS companion / WorkoutKit scheduling |
| 24 | Target pause-on-Full-Recovery toggle; multiple concurrent Targets |
| 25 | Penalty tier 3 UX polish; ActivityKit push timer ticks |

---

## 11. Setup checklist for Angel

### Developer portals & tokens

- [ ] Apple Developer Program — App ID for The System + extension App IDs  
- [ ] Capabilities: HealthKit (+ background delivery), Push, App Groups, Family Controls; later Distribution entitlement for Family Controls on **each** App ID  
- [ ] Info.plist: `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSSupportsLiveActivities`  
- [ ] WHOOP Developer Dashboard app + redirect URL; membership active — https://developer-dashboard.whoop.com/  
- [ ] Strava API application — https://www.strava.com/settings/api — Single Player Mode; `activity:read_all`  
- [ ] Mercury: Settings → Tokens → **Read Only**; save once; confirm Personal has Tokens UI — https://docs.mercury.com/docs/getting-started  
- [ ] Backend host with HTTPS for webhooks (Mercury, WHOOP, Strava) + Secrets Manager  
- [ ] LLM provider key (Grok/OpenAI) on backend only  
- [ ] MacroFactor → More → Integrations → Apple Health (weight + nutrition write) — https://help.macrofactorapp.com/en/articles/65-connect-health-connect-or-apple-health  

### On device

- [ ] Sign in WHOOP / Strava via in-app OAuth (ASWebAuthenticationSession)  
- [ ] Grant HealthKit types used by quests  
- [ ] FamilyControls `.individual` auth + pick Penalty Targets (apps/sites) once  
- [ ] Enable Live Activities for the app  
- [ ] Set display name / confirm Status identity  
- [ ] Optional: EventKit calendar access  

### Ops

- [ ] Mercury webhook signature verify + YTD income backfill rules for $500K  
- [ ] Mercury keepalive cron ≤30 days  
- [ ] WHOOP/Strava reconciliation polls (webhooks are not enough alone)  
- [ ] Prompt registry version + FallbackCatalog parity tests  

---

## 12. Open decisions (short list)

1. **Backend host** — Fly.io / Railway / Cloudflare Workers / AWS: pick one for webhooks + secrets.  
2. **LLM provider** — Grok vs OpenAI vs Anthropic for daily `QuestBundle` (tone + JSON reliability).  
3. **Player display name** — hardcode Angel vs editable profile field (Status currently mocks `DANIEL`).  
4. **Penalty UX intensity** — shields-only vs shields + denyAppRemoval (recommend **shields-only** for App Review).  
5. **Income rules for $500K** — employer counterparty allowlist / payroll regex specifics for Angel’s Mercury txns.  
6. **Full Recovery vs Target** — confirm v1 “Targets never pause on Full Recovery” or ship the toggle day one.  
7. **Manual confirm trust** — Face ID required for INT Target confirms, or tap-only with 3/day cap.

---

## Appendix A — Existing UI file map (bind, don’t redesign)

| File | Keep | Wire |
|------|------|------|
| `ContentView.swift` | `TabView` pages, `SystemTheme`, `SystemPanel`, dividers, progress bar | Unchanged shell |
| `SystemView.swift` | Panel, GOAL, WARNING, checkbox row layout | `DayPlan`, banner, OPTIONAL, Target tags, live progress |
| `GoalsView.swift` | `GoalCard` chrome, progress | Live Goals + segmented Targets |
| `HistoryView.swift` | GOALS/STATS horizontal cards + charts | Real series + quest/Target events |
| `StatusView.swift` | Level, XP bar, radar, Full Recovery row | PlayerState, FIN axis, bank spend |

## Appendix B — Primary official URLs

| Area | URL |
|------|-----|
| Mercury docs index | https://docs.mercury.com/llms.txt |
| Mercury getting started | https://docs.mercury.com/docs/getting-started |
| Mercury webhooks | https://docs.mercury.com/reference/webhooks |
| WHOOP API | https://developer.whoop.com/api |
| WHOOP OAuth | https://developer.whoop.com/docs/developing/oauth |
| Strava auth | https://developers.strava.com/docs/authentication/ |
| Strava webhooks | https://developers.strava.com/docs/webhooks/ |
| HealthKit | https://developer.apple.com/documentation/healthkit |
| MacroFactor ↔ Apple Health | https://help.macrofactorapp.com/en/articles/65-connect-health-connect-or-apple-health |
| Screen Time / FamilyControls | https://developer.apple.com/documentation/ScreenTimeAPIDocumentation |
| Family Controls entitlement | https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement |
| ActivityKit Live Activities | https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities |

---

*Plan compiled 2026-10-01 for personal use. UI locked to existing Solo Leveling chrome; research briefs are authoritative for Mercury / WHOOP / Strava / HealthKit / Screen Time details.*
