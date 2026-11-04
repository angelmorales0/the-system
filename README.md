# the-system

Daily quests for iPhone. Phases 1–7 are on this branch.

Penalty shields and the Live Activity need a Mac, a physical iPhone, and Apple’s Family Controls capability. The device checklist is [docs/PHASE7_DEVICE.md](docs/PHASE7_DEVICE.md).

Every integration (Hevy, Strava, WHOOP, Codeforces, Monkeytype, Mercury) and the Claude quest plan run on the iPhone. Type each key once in **Status → Connections**; setup steps are in [docs/ON_DEVICE_SETUP.md](docs/ON_DEVICE_SETUP.md). `scripts/make-secrets.sh` reads the keys from `backend/.env` (`backend/.env.example` shows the names). The Mac screen time Worker is in `screentime-worker/` ([docs/FOCUS_TRACKING.md](docs/FOCUS_TRACKING.md)).
