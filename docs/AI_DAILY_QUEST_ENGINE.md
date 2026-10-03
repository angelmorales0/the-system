# The System — AI Daily Quest Engine + Targets

Implementation-ready design for `angelmorales0/the-system`.  
UI constraint: keep the 4 swipe screens (System / Goals / History / Status). Describe feel/content within existing System patterns; Targets are additive UX that fits the same `SystemPanel` language.

---

## 0. How it feels on the System screen (no redesign)

Existing System panel structure stays:

```
[Daily Quest: <MODE TITLE> has arrived.]
GOAL
───
quest rows: Title ……………… [n/N] □
───
WARNING: Failure to complete…
```

**Additive content only (same panel language):**

| Situation | What user sees |
|-----------|----------------|
| Normal training | Header = `Performance Training`. Rows = training + protein etc. |
| Active Target | Thin cyan banner under header: `TARGET ACTIVE · Interview Prep · Day 4/14`. One+ goal rows tagged `⟪TARGET⟫` (e.g. `LeetCode Mediums …… [0/3]`). Training rows still present unless mode is Recovery. |
| Sunday optional | Extra section after GOAL divider: `OPTIONAL` with one easy quest; subtitle `Bank Full Recovery on complete`. |
| Using Full Recovery | Header = `Full Recovery Day`. GOAL rows empty or single soft REC quest; Status bank decrements visually after confirm. |
| Penalty day | Header = `Penalty Quest has arrived.` Warning block turns amber/red copy; rows are harder / more numerous. |
| Verification | Checkbox becomes filled cyan when auto-verify passes; muted spinner `…` while pending; manual override only for `manual_confirm` methods. |
| Mode chip | Mode name already in header (`Daily Quest: X has arrived.`) — that is the mode signal. Do not add new tabs. |

**Targets entry (additive, not a 5th swipe page):**

- Long-press empty area on System panel OR Status “+” on Full Recovery row pattern → sheet: `NEW TARGET`.
- Or from Goals screen: secondary control `TARGETS` vs `GOALS` segmented inside existing Goals scroll (same `GoalCard` chrome, different card fields: deadline countdown, daily injection preview). Prefer **segmented Goals screen** so Goals remain long-term and Targets are time-bounded without a new page.

**Status screen (existing):**

- Add **FIN** to radar (7 axes). Layout already supports N stats.
- Full Recovery bank (`xN`) already exists — wire to Sunday optional + spend on Recovery days.

---

## 1. Taxonomy

### 1.1 Daily Quest Modes (`QuestMode`)

Agent picks **one primary mode per calendar day** (local TZ). Mode drives header copy, quest pool, difficulty bias, and which Target injections are allowed.

| Mode | Intent | Typical stats | Notes |
|------|--------|---------------|-------|
| `performance_training` | Default lift/run/mobility day | STR, END, AGI, REC | Current shipped mock |
| `interview_prep` | Deep work on job hunt | INT, FOC | Often co-driven by active Target |
| `study_block` | Learning / coursework | INT, FOC | |
| `recovery` | Low load, sleep/mobility | REC, END | Soft caps on STR volume |
| `full_recovery` | Banked rest day spent | REC | Waives hard daily quests |
| `nutrition_focus` | Macro adherence day | END, REC | MacroFactor-heavy verify |
| `finance_discipline` | Spend guardrails | FIN | Mercury-heavy |
| `focus_deepwork` | Screen-time / deep work | FOC, INT | Screen Time verify |
| `hybrid` | Training + Target injection | mix | Default when Target active + readiness OK |
| `penalty` | Consequence day | any | Forced after miss; not AI-chosen freely |

Mode selection is **deterministic rules first**, LLM fills quests inside the chosen mode (see §2).

### 1.2 Quest kinds

| Kind | Required? | Completing… | UI section |
|------|-----------|-------------|------------|
| `daily` | Yes (unless `full_recovery`) | Clears the day | GOAL |
| `optional` | No | Banks reward (e.g. Full Recovery) | OPTIONAL |
| `target_injection` | Yes while Target active | Advances Target progress | GOAL with `⟪TARGET⟫` |
| `penalty` | Yes on penalty days | Clears penalty state | GOAL (penalty styling) |

### 1.3 Optional Quests

- **Sunday Easy Quest** (default): low difficulty, ~10–20 min, verify soft or manual.
- On complete → `full_recovery_bank += 1` (cap e.g. 3).
- Other optionals (future): double-XP weekend challenge — keep schema ready (`reward: { type, amount }`).

### 1.4 Penalty Quests

Triggered when previous day’s **required** quests incomplete at local midnight rollover (and no Full Recovery was active).

Rules:
- Enter `penalty` mode next morning.
- Quest count/difficulty ↑ (e.g. +1 quest or harder thresholds).
- Soft XP tax: −10% XP gains that day OR fixed −50 XP on Status (pick one; recommend **XP tax** to avoid negative XP bugs).
- Clearing all penalty quests restores normal mode next day.
- Stacking: consecutive misses escalate `penaltyTier` 1→3; tier 3 also blocks optional banking until cleared.

### 1.5 Targets vs Goals

| | **Goals** | **Targets** |
|--|-----------|-------------|
| Horizon | Months / open-ended | Days–weeks (bounded) |
| UI home | Goals swipe | Goals segmented **TARGETS** + System banner |
| Progress | Metric toward achievement (mile time, BW) | Checklist / quota toward deadline |
| Effect on daily quests | Soft bias only (prefer END quests if mile goal) | **Hard injection**: daily requirements appear in GOAL |
| Example | Sub-5:30 mile; 145 lb | 14-day Interview Prep: 3 LC/day |
| Completion | Hit metric | Hit quota by `endsAt` or expire |

Invariant: **at most 1 active Target** (v1). Queue others as `scheduled`.

---

## 2. AI prompt / context schema (morning generation)

Run once per local day at first open after `questDayKey` change (or BG refresh ~05:00). Build `MorningContext` JSON; send to LLM with system prompt.

### 2.1 `MorningContext` (inputs)

```json
{
  "schemaVersion": 1,
  "player": {
    "timezone": "America/Los_Angeles",
    "localDate": "2026-10-01",
    "weekday": "Wednesday",
    "level": 42,
    "xp": 3420,
    "xpToNext": 5000,
    "stats": { "STR": 142, "END": 155, "INT": 128, "AGI": 134, "FOC": 121, "REC": 118, "FIN": 110 },
    "fullRecoveryBank": 2,
    "penaltyTier": 0,
    "streaks": {
      "dailyQuestClear": 11,
      "training": 8,
      "proteinHit": 5,
      "missedLastNDays": 0
    }
  },
  "modeDecision": {
    "selectedMode": "hybrid",
    "reasonCodes": ["target_active", "whoop_readiness_ok", "not_sunday"],
    "lockedByRules": true
  },
  "whoop": {
    "available": true,
    "recoveryScore": 67,
    "restingHr": 54,
    "hrv": 62,
    "sleepPerformance": 81,
    "dayStrainYesterday": 14.2,
    "readinessBand": "yellow"
  },
  "calendar": {
    "busyMinutes": 210,
    "focusBlocks": [{ "start": "09:00", "end": "11:00", "title": "Deep work" }],
    "eventsHint": ["interview_loop", "gym_blocked_evening"],
    "wakeWindow": "06:30-07:30"
  },
  "activeTarget": {
    "id": "tgt_interview_2026_09",
    "title": "Interview Prep",
    "kind": "interview_prep",
    "dayIndex": 4,
    "totalDays": 14,
    "endsAt": "2026-10-11T23:59:59-07:00",
    "dailyRequirements": [
      { "templateId": "leetcode_solve", "title": "LeetCode problems", "quota": 3, "stat": "INT", "verification": "manual_confirm" }
    ],
    "progress": { "daysCleared": 3, "unitsDone": 9, "unitsGoal": 42 }
  },
  "goalsBias": [
    { "id": "goal_mile", "title": "5:30 Mile", "statHint": "END", "progress": 0.68 },
    { "id": "goal_bw", "title": "145 lb", "statHint": "END", "progress": 0.36 }
  ],
  "nutrition": {
    "source": "macrofactor_healthkit",
    "available": true,
    "proteinG": 42,
    "proteinTargetG": 150,
    "calories": 680,
    "calorieTarget": 2200,
    "asOf": "2026-10-01T08:15:00-07:00"
  },
  "mercury": {
    "available": true,
    "spendTodayUsd": 0,
    "softDailyCapUsd": 40,
    "discretionary7dUsd": 186,
    "state": "on_track"
  },
  "focus": {
    "screenTimeAvailable": true,
    "distractingMinutesYesterday": 95,
    "deepWorkMinutesYesterday": 110,
    "pickupCountYesterday": 48
  },
  "integrationsFreshness": {
    "whoop": "ok",
    "strava": "ok",
    "healthkit": "ok",
    "mercury": "stale",
    "screenTime": "ok"
  },
  "recentQuestTitles": ["Run Intervals", "Bench Press", "Mobility", "Protein"],
  "constraints": {
    "maxRequiredQuests": 5,
    "maxOptionalQuests": 1,
    "preferAutoVerify": true,
    "disallowUnsafeAdvice": true
  }
}
```

### 2.2 Deterministic mode picker (before LLM)

```
if penaltyTier > 0 and not spending_full_recovery:
    mode = penalty
elif user_confirmed_spend_full_recovery:
    mode = full_recovery
elif weekday == Sunday and whoop.readinessBand == red:
    mode = recovery  # still offer optional bank quest
elif activeTarget and whoop.readinessBand != red:
    mode = hybrid  # or interview_prep if Target.kind forces
elif whoop.readinessBand == red or sleepPerformance < 60:
    mode = recovery
elif calendar.busyMinutes > 360:
    mode = focus_deepwork | nutrition_focus  # lighter physical
else:
    mode = performance_training
```

LLM **must not** override `modeDecision.selectedMode` when `lockedByRules == true`. It only authors quests inside that mode.

### 2.3 System prompt (condensed)

```
You are The System. Generate today's quests as JSON matching QuestBundleSchema.
Rules:
- Obey selectedMode. Do not invent medical diagnoses or extreme deficits/surplus.
- Prefer verification methods from the allowed enum; never invent new sources.
- Keep required quests ≤ maxRequiredQuests. Titles short, actionable, Solo Leveling tone.
- If activeTarget present, include its dailyRequirements as target_injection quests (do not drop them).
- Avoid repeating recentQuestTitles when alternatives exist.
- Scale physical load using whoop.readinessBand: green=full, yellow=moderate, red=recovery only.
- Output ONLY valid JSON (QuestBundle).
```

---

## 3. Structured LLM output JSON schema

### 3.1 `QuestBundle`

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "QuestBundle",
  "type": "object",
  "required": ["schemaVersion", "dayKey", "mode", "quests", "narrative"],
  "additionalProperties": false,
  "properties": {
    "schemaVersion": { "const": 1 },
    "dayKey": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$" },
    "mode": {
      "type": "string",
      "enum": [
        "performance_training", "interview_prep", "study_block", "recovery",
        "full_recovery", "nutrition_focus", "finance_discipline", "focus_deepwork",
        "hybrid", "penalty"
      ]
    },
    "headerLine": {
      "type": "string",
      "description": "Shown as: [Daily Quest: {headerLine} has arrived.]"
    },
    "narrative": { "type": "string", "maxLength": 280 },
    "quests": {
      "type": "array",
      "minItems": 0,
      "maxItems": 8,
      "items": { "$ref": "#/$defs/Quest" }
    },
    "warnings": {
      "type": "array",
      "items": { "type": "string" }
    }
  },
  "$defs": {
    "Quest": {
      "type": "object",
      "required": [
        "id", "title", "kind", "stat", "verification", "deadline",
        "xp", "difficulty", "mode", "progress"
      ],
      "additionalProperties": false,
      "properties": {
        "id": { "type": "string", "minLength": 8, "maxLength": 64 },
        "title": { "type": "string", "minLength": 3, "maxLength": 48 },
        "kind": {
          "type": "string",
          "enum": ["daily", "optional", "target_injection", "penalty"]
        },
        "stat": {
          "type": "string",
          "enum": ["STR", "END", "INT", "AGI", "FOC", "REC", "FIN"]
        },
        "verification": {
          "type": "object",
          "required": ["method", "params"],
          "properties": {
            "method": {
              "type": "string",
              "enum": [
                "whoop_strain", "whoop_recovery", "strava_activity",
                "healthkit_workout", "healthkit_nutrition", "macrofactor_protein",
                "mercury_spend_under", "screen_time_limit", "manual_confirm",
                "timer_session"
              ]
            },
            "params": { "type": "object" }
          }
        },
        "deadline": {
          "type": "string",
          "format": "date-time",
          "description": "Usually end of local day"
        },
        "xp": { "type": "integer", "minimum": 5, "maximum": 200 },
        "difficulty": {
          "type": "string",
          "enum": ["easy", "normal", "hard", "penalty"]
        },
        "mode": { "type": "string" },
        "targetId": { "type": ["string", "null"] },
        "progress": {
          "type": "object",
          "required": ["current", "target", "unit"],
          "properties": {
            "current": { "type": "number", "minimum": 0 },
            "target": { "type": "number", "exclusiveMinimum": 0 },
            "unit": { "type": "string", "examples": ["reps", "min", "g", "problems", "usd", "bool"] }
          }
        },
        "reward": {
          "type": ["object", "null"],
          "properties": {
            "type": { "enum": ["full_recovery_token", "xp_bonus", "none"] },
            "amount": { "type": "integer", "minimum": 0 }
          }
        }
      }
    }
  }
}
```

### 3.2 Example verification `params`

| method | params example |
|--------|----------------|
| `whoop_strain` | `{ "minStrain": 8.0 }` |
| `strava_activity` | `{ "types": ["Run","Ride"], "minMovingTimeSec": 1200 }` |
| `healthkit_workout` | `{ "activityType": "traditionalStrengthTraining", "minDurationSec": 2400 }` |
| `macrofactor_protein` | `{ "minProteinG": 150 }` |
| `mercury_spend_under` | `{ "maxDiscretionaryUsd": 40, "categoriesExclude": ["rent","payroll"] }` |
| `screen_time_limit` | `{ "maxDistractingMin": 60, "orMinDeepWorkMin": 90 }` |
| `manual_confirm` | `{ "prompt": "Confirm 3 LeetCode mediums solved" }` |
| `timer_session` | `{ "minSec": 1500, "label": "Mobility" }` |

### 3.3 Example LLM output (hybrid + Target)

```json
{
  "schemaVersion": 1,
  "dayKey": "2026-10-01",
  "mode": "hybrid",
  "headerLine": "Hybrid Training",
  "narrative": "Target window open. Keep strain moderate; clear LeetCode quota.",
  "quests": [
    {
      "id": "q_20261001_lc",
      "title": "LeetCode Mediums",
      "kind": "target_injection",
      "stat": "INT",
      "verification": { "method": "manual_confirm", "params": { "prompt": "Confirm 3 problems" } },
      "deadline": "2026-10-01T23:59:59-07:00",
      "xp": 40,
      "difficulty": "normal",
      "mode": "hybrid",
      "targetId": "tgt_interview_2026_09",
      "progress": { "current": 0, "target": 3, "unit": "problems" },
      "reward": null
    },
    {
      "id": "q_20261001_run",
      "title": "Easy Run",
      "kind": "daily",
      "stat": "END",
      "verification": { "method": "strava_activity", "params": { "types": ["Run"], "minMovingTimeSec": 1200 } },
      "deadline": "2026-10-01T23:59:59-07:00",
      "xp": 35,
      "difficulty": "normal",
      "mode": "hybrid",
      "targetId": null,
      "progress": { "current": 0, "target": 20, "unit": "min" },
      "reward": null
    },
    {
      "id": "q_20261001_protein",
      "title": "Protein",
      "kind": "daily",
      "stat": "END",
      "verification": { "method": "macrofactor_protein", "params": { "minProteinG": 150 } },
      "deadline": "2026-10-01T23:59:59-07:00",
      "xp": 25,
      "difficulty": "easy",
      "mode": "hybrid",
      "targetId": null,
      "progress": { "current": 0, "target": 150, "unit": "g" },
      "reward": null
    }
  ],
  "warnings": ["Failure to complete the daily quest will result in a penalty."]
}
```

Server validates against JSON Schema + business validators (stat enum, method allowlist, progress.target > 0, required Target injections present). Reject → fallback template (§6).

---

## 4. Deterministic verification layer

**Never trust the LLM for completion.** LLM only proposes `verification.method` + `params`. A local/server `Verifier` owns state transitions.

### 4.1 Pipeline

```
BG fetch / app foreground / HealthKit observer
        ↓
IntegrationAdapters.refresh()
        ↓
For each incomplete quest:
  Verifier.evaluate(quest, snapshots) → ProgressDelta | Complete | Unchanged
        ↓
QuestStore.apply (idempotent by quest.id + evidence.hash)
        ↓
If all required complete → DayClear → XP/stat grants → Target progress bump
```

### 4.2 Verifier interface (Swift-shaped)

```swift
protocol QuestVerifying {
  func evaluate(quest: Quest, ctx: VerificationContext) async -> VerificationResult
}

enum VerificationResult {
  case unchanged
  case progress(current: Double, evidence: Evidence)
  case completed(evidence: Evidence)
  case failed(reason: String) // e.g. spend over cap for FIN quests that invert
}

struct Evidence: Codable, Hashable {
  var source: String      // "strava", "whoop", ...
  var externalId: String? // activity id
  var observedAt: Date
  var payloadHash: String // SHA256 of canonical JSON
}
```

### 4.3 Adapter rules (concrete)

| Method | Pass condition | Progress mapping |
|--------|----------------|------------------|
| `strava_activity` | Any activity today matching `types` with `moving_time ≥ min` | minutes → progress |
| `whoop_strain` | Day strain ≥ min (or workout strain) | strain → progress |
| `whoop_recovery` | Recovery score ≥ min (for REC quests) | score |
| `healthkit_workout` | HKWorkout matching type/duration today | minutes |
| `macrofactor_protein` | Protein ≥ target (HK nutrition or MF export) | grams |
| `mercury_spend_under` | Sum discretionary debits today ≤ max | `max - spent` as remaining |
| `screen_time_limit` | distracting ≤ max **OR** deepWork ≥ min | minutes |
| `timer_session` | In-app timer completed ≥ minSec | seconds |
| `manual_confirm` | User taps confirm (rate-limited; requires Face ID optional) | 0→1 bool |

### 4.4 Anti-cheat / integrity

- Evidence store: one `externalId` cannot clear two quests unless whitelisted (e.g. one run clears run + strain).
- Manual confirms: max 3/day; require ≥30s after quest assign; log for History.
- Clock skew: use server `dayKey` if online; else Device `Calendar.current` with last-known offset.
- LLM cannot mark `completed: true` in output — strip that field if present.

### 4.5 Stat & XP grants (deterministic)

On quest complete:

```
stat[quest.stat] += difficultyWeight // easy 1, normal 2, hard 3, penalty 2
xp += quest.xp * (penaltyDay ? 0.9 : 1.0)
if kind == optional && reward.type == full_recovery_token:
    bank = min(bank+1, 3)
```

Radar / Status update from `PlayerState`, not from LLM.

---

## 5. Target lifecycle

```
draft → scheduled → active → completed
                      ↘ expired
                      ↘ aborted (user)
```

### 5.1 Create

Sheet fields: title, kind (`interview_prep` | `study` | `cut` | `custom`), `startsOn`, `endsOn`, daily requirement templates (quota, stat, verification), optional total unit goal.

Persist:

```swift
struct Target: Identifiable, Codable {
  var id: String
  var title: String
  var kind: TargetKind
  var status: TargetStatus
  var startsOn: DateComponents // local date
  var endsOn: DateComponents
  var dailyRequirements: [TargetDailyRequirement]
  var unitsGoal: Int?
  var unitsDone: Int
  var daysCleared: Int
}
```

### 5.2 Activate

At local midnight when `startsOn ≤ today ≤ endsOn` and no other active → `active`. System banner appears. Morning generator **must** inject `target_injection` quests cloned from `dailyRequirements` (LLM may rephrase title slightly; Verifier keys off `targetId` + `templateId`).

### 5.3 Stack with training

| Readiness | Behavior |
|-----------|----------|
| Green | `hybrid`: full-ish training + Target rows |
| Yellow | Shorter training (LLM constrained) + full Target |
| Red | `recovery` physical + Target still injected unless Target.kind allows pause |
| Full Recovery day | Physical waived; Target still injected (interview prep doesn’t sleep) unless user sets `pauseTargetOnFullRecovery` |

v1 policy: **Targets never pause on Full Recovery** (career targets matter). Expose toggle later.

### 5.4 Complete / expire

- **Complete**: `unitsDone ≥ unitsGoal` OR (`daysCleared ≥ requiredDays` and today > endsOn with all days met). Show System toast: `[Target Complete.]` + XP bonus.
- **Expire**: endsOn passed with unmet quota → History entry `FAILED`; small FIN/INT vanity penalty optional; no doom spiral.
- Active Target completion clears banner; next `scheduled` promotes.

### 5.5 Goals interaction

Goals stay independent. Generator gets `goalsBias` only as soft preference (e.g. prefer END run if mile goal). Never auto-create Goals from Targets.

---

## 6. Safety: rate limits, fallbacks, no unsafe advice

### 6.1 Rate limits

| Resource | Limit |
|----------|-------|
| LLM quest generation | 1 successful bundle / dayKey; 3 retries on validate fail |
| Manual regenerates | 1/day (button behind long-press); costs no XP |
| Manual confirm | 3/day |
| API calls (WHOOP/Strava/Mercury) | exponential backoff; cache 15–60 min |
| Full Recovery spend | 1/day; requires bank ≥ 1 + confirm sheet |

### 6.2 Fallback templates (if AI fails)

Ship on-device `FallbackCatalog.json` keyed by mode + readinessBand.

Example `performance_training` + yellow:

1. Zone 2 Walk/Run 20 min — Strava  
2. Push Session 30 min — HealthKit  
3. Mobility 10 min — timer  
4. Protein 150g — MacroFactor  

`hybrid` + Target: fallback = Target injections verbatim + 2 light training from catalog.

Validation failure OR timeout (>8s) OR HTTP 5xx → fallback; System header still works; set `generatedBy: "fallback"`.

### 6.3 Safety rails on LLM output

Post-filters reject / rewrite if:

- Protein target < 80g or > 250g (personal bounds configurable)
- Run duration > 90 min on yellow readiness
- Any STR hard session on red readiness
- Calorie suggestion < 1500 (male adult default — user-configurable floor)
- Text matches unsafe patterns: “starve”, “all-nighter”, “ignore injury”, “max debt”, etc.
- Mercury cap < $0 or absurd

Also: System copy never diagnoses injury; WHOOP red → force recovery mode regardless of LLM.

### 6.4 Privacy

- Prefer on-device aggregation; send **summaries** in MorningContext, not raw GPS/transactions.
- Mercury: category totals only.
- Screen Time: FamilyControls / DeviceActivityShield summaries, not app-by-app list to cloud if avoidable.

---

## 7. Example day narratives (wake → complete)

### 7.1 Training day (no Target)

1. **06:45** Open app → mode picker: green WHOOP → `performance_training`.  
2. System panel: `[Daily Quest: Performance Training has arrived.]`  
   Rows: Run Intervals `[0/6]`, Bench Press `[0/4]`, Mobility `[0/10min]`, Protein `[0/150g]`.  
3. **07:30** Intervals on Strava → Verifier fills run → checkbox cyan.  
4. **12:00** Gym HK workout → bench progress.  
5. **18:00** Timer mobility complete.  
6. **21:00** MacroFactor protein hits 150 → last checkbox.  
7. Day clear → XP + STR/END/AGI ticks → History logs. Warning unused.

### 7.2 Interview-prep Target day (hybrid)

1. Banner: `TARGET ACTIVE · Interview Prep · Day 4/14`.  
2. Header: `Hybrid Training`.  
3. Rows: `⟪TARGET⟫ LeetCode Mediums [0/3]`, Easy Run `[0/20min]`, Protein `[0/150g]`.  
4. Morning deep-work: manual confirm 3 LC → Target `unitsDone += 3`, `daysCleared` pending until all required done.  
5. Afternoon easy run auto-verifies.  
6. Protein clears night.  
7. Target day counted; Status INT + FOC bump.

### 7.3 Sunday optional → bank Full Recovery

1. Mode `performance_training` or `recovery`; GOAL has normal (lighter) required set.  
2. OPTIONAL: `Evening Walk 15 min` reward `full_recovery_token`.  
3. User completes optional → Status `FULL RECOVERY x2 → x3`.  
4. Later week: Status tap bank → confirm `Spend Full Recovery?` → tomorrow assigned `full_recovery` (or immediate if before quest gen).

### 7.4 Full Recovery day

1. Header: `Full Recovery Day has arrived.`  
2. GOAL empty or single `Sleep Hygiene` REC easy optional. Target injection still shown if active.  
3. No penalty risk for missing training. Bank decremented on day assign.  
4. Complete Target row if any; sleep.

### 7.5 Penalty day

1. Yesterday incomplete at rollover → `penaltyTier = 1`.  
2. Header: `Penalty Quest has arrived.` Warning copy stronger.  
3. Rows: harder run, extra mobility, protein, plus carryover unfinished theme.  
4. Clear all → tier 0; XP at 0.9×. Miss again → tier 2.

---

## 8. Backend vs on-device AI recommendation

### Recommendation: **Hybrid — on-device orchestration + cloud LLM**

| Concern | Where | Why |
|---------|-------|-----|
| Mode picker, verification, XP, Target state, fallbacks | **On-device** (Swift, SwiftData/GRDB) | Trust boundary; works offline; never let server sole-source completion |
| MorningContext assembly | **On-device** | HealthKit / Screen Time / tokens stay local; send redacted summary |
| LLM quest authoring | **Cloud** (OpenAI/Grok API via your backend proxy) | Key security; prompt versioning; schema validation; rate limit centrally |
| Schema validation + safety filter | **Backend** then re-check **on-device** | Defense in depth |
| Integration OAuth (Strava, WHOOP, Mercury) | **Backend** token vault + on-device session | Refresh tokens off device |
| Fallback catalog | **On-device** bundled | Offline mornings |

### Why not fully on-device LLM (v1)

- Apple Foundation Models / local SLMs are improving but JSON reliability + Solo Leveling tone + multi-signal planning is still weaker than GPT/Grok-class for daily variety.
- Personal app: cloud cost is tiny at 1 call/day.

### Why not fully backend

- HealthKit & Screen Time are on-device; round-tripping raw data is privacy-heavy.
- Completion cheating if client only displays server truth without local evidence checks.

### Suggested architecture

```
iOS App
  QuestEngine (mode picker, store, verifiers, Target lifecycle)
  ContextBuilder → POST /v1/quests/generate { MorningContext }
Backend
  Auth, prompt registry, OpenAI/Grok, JSON Schema validate, safety filter
  Returns QuestBundle
iOS
  Re-validate → persist → UI bind SystemView
  Verifiers poll integrations → complete
```

Optional later: on-device small model as fallback author when offline (still behind same schema validator).

### FIN on Status

Extend radar `stats` array with `FIN` (Mercury discipline). Quests with `stat: FIN` grant FIN on verify. Goals screen unchanged.

---

## 9. Minimal data model (Swift)

```swift
enum StatCode: String, Codable { case STR, END, INT, AGI, FOC, REC, FIN }
enum QuestMode: String, Codable { /* as schema */ }
enum QuestKind: String, Codable { case daily, optional, targetInjection, penalty }

struct Quest: Identifiable, Codable {
  var id: String
  var title: String
  var kind: QuestKind
  var stat: StatCode
  var verification: VerificationSpec
  var deadline: Date
  var xp: Int
  var difficulty: Difficulty
  var mode: QuestMode
  var targetId: String?
  var progress: QuestProgress
  var reward: QuestReward?
  var status: QuestStatus // pending, completed, failed, expired
  var evidence: [Evidence]
}

struct DayPlan: Codable {
  var dayKey: String
  var mode: QuestMode
  var headerLine: String
  var quests: [Quest]
  var generatedBy: String // "llm" | "fallback"
  var activeTargetId: String?
}
```

Wire `SystemView` to `DayPlan`: replace hard-coded `quests` tuple; bind progress labels `[current/target]`; toggle checkbox from `status`.

---

## 10. Implementation order (concrete)

1. Models + SwiftData + FallbackCatalog + mode picker (no LLM yet).  
2. Verifiers: timer + manual; then HealthKit; Strava; WHOOP; MacroFactor/HK nutrition; Mercury; Screen Time.  
3. SystemView binding + optional section + Target banner.  
4. Targets CRUD on Goals segmented control.  
5. Backend `/v1/quests/generate` + on-device ContextBuilder.  
6. Penalty rollover job + Full Recovery spend.  
7. FIN on Status radar.  
8. History: quest clear log + Target complete/expire cards.

---

*Aligned to existing UI in `MyApp/SystemView.swift`, `GoalsView.swift`, `StatusView.swift` (Full Recovery bank, GOAL list, WARNING block).*
