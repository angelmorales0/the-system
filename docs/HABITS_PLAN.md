# Habits plan

A plan for new System features, from the notes on *The Courage to Be Disliked* and *Atomic Habits*.
Nothing here is built yet.

## Design rules

- **Automated first.** Each habit gets data from a source the app already reads (Hevy, Strava, WHOOP,
  Apple Health, Mercury, Screen Time, the Mac tracker), or from the phone itself (location). The only hand
  entry is the behavior log (feature 7).
- **Make spend visible.** A number in a settings page does not change behavior. Spend must be on the main
  quest screen, with color and notices, the same as Screen Time.
- **Systems before goals.** The app shows what you did today and your streaks first. The levels and
  targets come second.

## Features

### 1. Morning phone lock

| Item | Plan |
|---|---|
| Start | At wake time. Source: the end of the WHOOP sleep. Fallback when WHOOP has no sleep yet: 7:00 am. |
| Block | The same block screens as a penalty. **Spotify stays open.** Calls, Maps, and the System app stay open. |
| Unlock | The first workout after wake time, from any of these: a Hevy workout with a set (stretches count), a Strava activity, or an Apple Health workout of 10 min or more. |
| Data | The Screen Time monitor already blocks apps for penalties. The unlock check reuses the Hevy, Strava, and Health readings. |
| Rest days | No lock on a rest day you spend (a free rest day or a Full Recovery day). That is the only way the lock is off: no shop item skips it. |
| Risk | The block monitor runs while the app is closed, but the workout check runs in the app. You must open the app after the workout for the lock to end. A background refresh can shorten that wait. |

### 2. Eat-out budget: $40 a week

| Item | Plan |
|---|---|
| Rule | Restaurants and FoodDelivery spend from Mercury has its own cap: **$40 a week**, about one meal with friends. No penalty for one purchase; the cap is the rule. |
| Over the cap | A penalty at once: 8 hours after the card charge that takes the week over $40. |
| Visible | A new "Money" row on the main quest screen, under Screen Time: `Eat out $12/$40` and `Spend $85/$280` for the week. The text goes yellow at 75% and red at 100%. |
| Notices | A notice at 50, 75, 90, and 100% of the eat-out cap, like the Screen Time notices. |
| Card rule | Use the Mercury debit card for all non-essential purchases, so Mercury sees them. |

### Always-on rules

Some rules are always on. No setting, rest day, or day off turns them off. **The only way to skip one is a shop
item**, bought with gold, like the potions that exist (for example Ironblood Draught skips today's lifts).

| Rule | Skip item (new) | Price and cooldown |
|---|---|---|
| Home by 9 pm (3) | A new potion that skips one night, for example a night out with friends | 4,200 gold; 36-hour cooldown |
| Eat-out cap (2) | A new potion: today's eat-out spend does not count toward the $40 weekly cap | 4,200 gold; 36-hour cooldown |
| Morning phone lock (1) | No shop skip, ever. Off only on rest days (see feature 1). | — |

The item works like the other potions: it raises in price when you use it often, and the skip shows in the
day's record.

**Cooldown: every shop item has a 36-hour cooldown**, the new skip items and the potions that exist. After you use
an item, you cannot use that same item again for 36 hours. This changes the potions that exist today:

| Potion | Cooldown today | New cooldown |
|---|---|---|
| Gilded Indulgence Philter (FIN) | 30 days | Removed (2026-11-18) |
| Insomniac's Elixir (REC) | 14 days | 36 hours |
| Veil of Hours (FOC) | 14 days | 36 hours |
| Ironblood Draught (STR) | None | 36 hours |
| Second Wind Tonic (END) | None | 36 hours |
| Quicksilver Vial (AGI) | None | 36 hours |

The price rule stays: each use in 30 days raises the next price by 50%.

### 3. Home by 9 pm

| Item | Plan |
|---|---|
| Rule | The phone is at home at 9:00 pm. |
| Data | iPhone location: a circle around home (region monitoring). The app saves the arrival time. It needs "Always" location access. Only the arrival time is saved, not a location trail. |
| Setup | One tap in Settings: "This is home" saves the current location. |
| Quest | A daily row "Home by 9 pm" that completes on arrival before 9:00 pm. |
| Always on | Every night, on rest days and days off too. The only skip is the shop item (see Always-on rules). |

### 4. Weekly day off from knowledge work

| Item | Plan |
|---|---|
| Rule | One day a week: **0 work minutes** on the Mac tracker. The phone cap stays the same. |
| Quests that day | No knowledge-work quests and no extra quest. The other rows stay as usual. |
| Choice | Every Sunday. |

### 5. Beliefs page

| Item | Plan |
|---|---|
| Place | A new page on the Status screen: "Beliefs". |
| Content | Your own lines, which you edit in the app. First lines from your notes: "I live below my means." "I take care of where I live and the places I visit." |
| Daily | The quest screen shows one belief each morning, under the daily quest header. |

### 6. The 145 lb contract

| Item | Plan |
|---|---|
| Goal | 145 lb by the end of senior year. The END stat already has a 145 lb (±2) body weight target. |
| Path | A straight line from your start weight to 145 lb on the end date. |
| Check-in | Each week, the 7-day average weight from Apple Health (MacroFactor) must be on or under the line. |
| Missed check-in | **You lose 1 Full Recovery token and 1 rest day.** With no token left, the next token you earn is lost. With no rest day left this week, next week has one fewer. |
| Contract | The app shows the contract once, with the end date and the punishment, and you accept it. It cannot be turned off until the end date. |

### 7. Behavior log

| Item | Plan |
|---|---|
| Rule | A short note each day: what you did that could be better. |
| Entry | One text box, opened from the quest screen. Optional, no penalty. |
| Use | The log page lists past notes. The planner can read the last notes, to change the next day's quests. |

### 8. Systems view

| Item | Plan |
|---|---|
| Place | The first page of Status. Levels move to the second page. |
| Content | One row per habit, with a dot for each day of the last 4 weeks and the current streak: morning exercise, home by 9, eat-out cap, screen time, caffeine, day off, log written, gym day done. |
| Goal | You see the 1% steps each day, not only the distance to the targets. |

## Contracts instead of goals

### The problem

The daily quests already work like contracts: do the row today, or get a penalty. The goal part is the stat
levels. Each stat target is an **outcome number** that you do not control directly: 2100 Codeforces rating,
225 lb bench, 200 WPM. A monthly quest asks for "+X rating". An outcome number depends on luck and time, so you
think about the number, not about what you do today.

### The change

**Decision: the levels stay as they are.** The stat targets and levels keep measuring where you are. Contracts are
a second, separate layer.

A **contract** is a promise about an action that you control, with a check, a period, a stake, and an end date.
You sign each one deliberately, and you set it up yourself in the app. The app never makes a contract for you.
Keep few contracts at one time, only for what matters now.

| | Levels (stay as they are) | Contracts (new) |
|---|---|---|
| Measures | Where you are: outcomes such as rating, lift weight, WPM | What you do: actions such as contests played, km run |
| Made by | The app, for every stat | You, one at a time, when you decide |
| Changes | Up and down with your results | Fixed for the term |
| If you fall short | The level is lower, and max HP is lower | You lose the stake you signed |
| Count | About 50 targets | A few at one time |
| Ends | Never | On its end date; then you renew it, change it, or let it end |

| Part | Example |
|---|---|
| Action | Play 2 rated Codeforces contests |
| Period | Each month |
| Check | Codeforces API (automatic) |
| Stake | Always the same: 1 Full Recovery token and 1 rest day |
| Term | You pick an end date when you sign (a calendar date, not a number of weeks). On that date you renew it, change it, or let it end. You cannot change it before the end. |

The outcome numbers stay in the app as **information**, not as pass or fail. 145 lb is the one outcome contract,
because a straight line to it gives a weekly action check.

### Example contracts you could sign

| Stat | Level target (stays) | Possible contract (action) | Source |
|---|---|---|---|
| STR | 225 lb bench, 20 pull-ups, ... | Do the split day 4 days of 7 | Hevy |
| END | 10K time, VO₂ max, 145 lb | Run 50 km a week; the 145 lb contract | Strava, Apple Health |
| INT | 2100 rating, 200 WPM | 2 rated contests a month; solve 10 problems a week; 3 typing sessions a week | Codeforces, Monkeytype |
| AGI | Full splits, vertical jump, ... | Stretch every day (exists); test once a month | Hevy |
| FOC | Screen time on 90% of days | Phone cap every day (exists); 0 social media | Screen Time |
| FIN | 30% savings rate, budget | $40 eat-out cap a week; $280 spend cap a week; move savings on payday | Mercury |
| REC | Sleep scores, 0 caffeine average | Home by 9 pm; no caffeine on days off from the office | Location, Apple Health |

### What must change in the code

| Area | Today | Change |
|---|---|---|
| Model | `StatRequirement`: an outcome with a floor and a target | Stays. New `Contract` next to it: action rule, period, source, stake, start and end date, and a record of each period (kept or broken) |
| Checks | Each stat file scores outcomes (`IntelligenceLevel`, `StrengthLevel`, ...) | Stay. New: one contract check for each source, from the readings the app already loads |
| Levels | Level = how close the outcomes are to the targets | No change |
| Monthly quests | Codeforces "+X rating", finance goals | Removed (2026-11-18) |
| Targets page | Remove and add targets, custom STR goals | No change. New Contracts page with a "Create a contract" screen: pick the rule, enter its numbers (for 145 lb: start weight and end date), pick the end date, read the terms and the stake, and sign. Then see its record; renew it on the end date. No cancel during the term. |
| Planner | Reads `goals.strength` gaps | Also reads the active contracts, and plans the day so you keep them |
| Penalties | Daily quest penalty | Stays. A broken contract takes its own stake. |
| Systems view (feature 8) | Not built | Shows the daily habits and the active contracts |

### Decisions

1. 145 lb contract: you set the end date and your start weight yourself on the "Create a contract" screen, and
   you sign it there. The app does not set them.
2. Morning lock: when WHOOP has no sleep yet, the lock starts at 7:00 am.
3. Home by 9: always on. A night out needs the shop item: 4,200 gold, about half of a perfect week
   (7 perfect days × 1,200 gold on average = 8,400). A day that uses a potion pays no gold, so the real cost of
   one night out is about 5,400 gold. Cooldown: 36 hours, like every item.
4. Eat-out cap: a skip item at the same price excuses one day's eat-out spend from the weekly cap.
   Over the cap: the penalty comes at once, 8 hours after the charge that went over (Mercury shows a card charge
   a few hours late, so the 8 hours give it time to post).
5. Morning lock: off on rest days only. No shop item can skip it.
6. Contracts: only the 145 lb contract at first, made on a "Create a contract" screen in the app (see below).

7. Day off: every Sunday. The only rule is 0 Mac work minutes. No extra quest; the other rows stay as usual.

## Build order

| Step | Feature | Why first |
|---|---|---|
| 1 | Money row and eat-out cap (2) | Small, uses data the app already has, and fixes "spend is not visible". |
| 2 | Beliefs page (5) | Small. Sets the identity first, as Atomic Habits says. |
| 3 | Morning phone lock (1) | Large effect, uses the block screens that exist. |
| 4 | 145 lb contract (6) | Uses the weight data that exists. |
| 5 | Day off (4) | Uses the Mac tracker that exists. |
| 6 | Home by 9 (3) | Needs new location access. |
| 7 | Behavior log (7) | New input. |
| 8 | Systems view (8) | Last, so it can show every habit above. |
