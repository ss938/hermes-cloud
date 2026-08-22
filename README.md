# hermes-cloud

Hermes Agent gateway running 24/7 on Render.com free tier, with persistent
memory backed by a private Hugging Face dataset repo.

## How it works
- On boot: restores `~/.hermes` (memory, sessions, config) from
  `hf://datasets/salah1593/hermes-memory`
- Every 15 min: snapshots state.db / kanban.db / memories back up to the same repo
- `/health` endpoint keeps the service alive via external ping (UptimeRobot)

## Required environment variables
`HERMES_HF_TOKEN`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `NOTION_TOKEN`,
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`,
`TELEGRAM_HOME_CHANNEL_THREAD_ID`

No secrets are stored in this repository.
