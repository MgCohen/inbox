# CLAUDE.md

This repository is the `inbox` Cloudflare Worker. Read [README.md](README.md) for what it does and how to run it.

## Hard rules

**Branch and PR.** Every change ships through a feature branch and a PR. Never commit to `main`. A merge to `main` deploys to production through Cloudflare Workers Builds.

**Verify before you claim done.** Run the Worker locally and run the smoke test. All checks must pass:

```powershell
npm run migrate:local
npm run dev
.\test\smoke.ps1 -BaseUrl http://127.0.0.1:8787 -Token local-test-token -LinearSecret local-linear-secret
```

**Keep the inbox small.** It receives, stores and returns events. Do not add routing, decisions or actions here. Those belong in the tools that read the events.

**Fail closed.** A source without a secret accepts nothing. Every new source must verify a signature or a secret before it stores anything. The one exception is the Notion handshake: it writes the token to the log and stores nothing.

**No secrets in git.** Secrets go in Cloudflare (`wrangler secret`), `.dev.vars` or `.env`. Never in code, `wrangler.jsonc`, tests or docs.

**Table changes go in a new migration.** Never edit a migration that is already applied. Add the next numbered file in `migrations/`.
