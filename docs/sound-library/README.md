# Sound library

`raw/` holds the full set of 37 Solo Leveling system sounds as they came. The app does
not bundle this folder. The cues the app plays live in `MyApp/Resources/Sounds/` as AAC
(`.m4a`), one per `SystemSound` case, each normalized so its loudest 100 ms sits at
−14 dBFS (peak capped at −1 dBFS).

| Cue (`SystemSound`) | Source file in `raw/` | Plays when |
|---|---|---|
| `launch` | sl-arise-game-check-in-login-ardz | The app opens |
| `new-day` | sl-system-notification-trus | A new day's quests arrive while the app is open |
| `system-open` | sl-system-notification-open-trus | A sheet opens |
| `system-close` | sl-system-notification-close-trus | A sheet or reveal window closes; an emergency test ends |
| `quest-complete` | sl-system-accept-trus | One quest row is verified done |
| `quest-fail` | sl-fail-trus | A tap is refused, a quest fails, or the shop refuses |
| `timer-start` | sl-count-trus | A timed quest starts |
| `day-clear` | sl-arise-game-clear-mission-ardz | The last required quest of the day is done |
| `level-up` | sl-arise-game-level-up-ardz | The STATUS level rises |
| `reward` | sl-arise-game-claim-reward-ardz | Gold is paid at rollover |
| `purchase` | sl-money-trus | A Full Recovery is bought |
| `potion` | sl-healing-trus | A potion is drunk |
| `full-recovery` | sl-full-recovery-pronounceperfectly | A Full Recovery token is spent |
| `hidden-quest` | sl-arise-game-unlocked-stage-story-ardz | A hidden quest reveal appears |
| `penalty-open` | sl-red-gate-open-trus | The penalty window arrives |
| `penalty-cleared` | sl-gate-close-trus | The penalty run is verified |
| `warning` | sl-high-level-enemy-warning-trus | An emergency starts; HP turns critical; fatigue turns red |
| `emergency-complete` | sl-arise-game-clear-stage-ardz | An emergency quest is completed |
| `emergency-failed` | sl-failed-shadow-extraction-extramllama | An emergency quest fails |

To add or swap a cue: decode the MP3 with `afconvert -f WAVE -d LEI16`, scale it to the
same loudness, encode it with `afconvert -f m4af -d aac -b 128000`, and drop it in
`MyApp/Resources/Sounds/` under the `SystemSound` raw value.
