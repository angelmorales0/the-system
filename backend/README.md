# Quest generation stub

Local stand-in for `POST /v1/quests/generate`. It checks the morning-context shape, then returns a quest bundle from templates. If `XAI_API_KEY` is set in the environment, it asks xAI Grok (`grok-4.6` unless `XAI_MODEL` overrides it) and keeps the reply only when that reply passes the same safety checks. Otherwise it serves the template.

The app does not read a secrets file. Nothing in this directory should contain a live key.

## Run

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python app.py --check
python app.py
```

The server listens on `http://127.0.0.1:8787`.

To use Grok, export the key in the shell (or source a gitignored `.env` you created from `.env.example`) and start the process in that same shell:

```bash
export XAI_API_KEY
export XAI_MODEL=grok-4.6
python app.py
```

`GET /health` reports whether the process will call Grok or stay on templates. It does not print the key.

## iOS

With no base URL, the app uses the on-device mock (the fallback catalog for the rules-locked mode). To send morning context to this stub:

Launch the app with `QUEST_GENERATE_BASE_URL=http://127.0.0.1:8787` (Xcode scheme environment, or `simctl launch --env`). The simulator reaches this process at `127.0.0.1`.

Or set UserDefaults key `com.angelmorales.thesystem.questGenerateBaseURL` to `http://127.0.0.1:8787` and relaunch. Only `http` and `https` URLs are used. A timeout past 8 seconds, or a bundle that fails the on-device check, keeps the fallback catalog. The phone never sends an API key.
