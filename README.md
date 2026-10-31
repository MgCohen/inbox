# inbox

A Cloudflare Worker that **receives** signed webhooks, **stores** them in D1, and **returns** them on demand.
It makes no decisions and does no work. Other tools read the events through the API.

- **URL:** https://inbox.mgcohen.workers.dev
- **Runtime:** Cloudflare Workers (free plan)
- **Storage:** D1 database `webhook-hub`, table `events`

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/` | none | Health check. Lists the defined sources. |
| `POST` | `/hooks/linear` | Linear signature (`linear-signature`) | Receive a Linear webhook. |
| `POST` | `/hooks/github` | GitHub signature (`x-hub-signature-256`) | Receive a GitHub webhook. |
| `GET` | `/api/events` | `Authorization: Bearer <INBOX_TOKEN>` | List events. |
| `GET` | `/api/events/:id` | `Authorization: Bearer <INBOX_TOKEN>` | One event with its full payload. |

### `GET /api/events` parameters

| Parameter | Meaning |
|---|---|
| `source` | Only this source, for example `linear`. |
| `type` | Only this event type, for example `Issue`. |
| `after` | Only events with an ID greater than this. Returns the oldest first, and `next_after` for the next call. |
| `limit` | 1 to 200. Default 50. |
| `payload=1` | Include the full JSON body of each event. |

Without `after`, the list returns the newest events first.

## Behavior

- A source without a secret accepts nothing (503).
- A bad signature gets 401. A Linear delivery older than 5 minutes gets 401.
- Each delivery is stored one time. A delivery with a known delivery ID returns 200 with `"duplicate": true`.
- An unknown source gets 404.
- Events are not deleted automatically.

## Secrets

Secrets are only in Cloudflare and in local files that git ignores. Never put them in the code or in `wrangler.jsonc`.

| Name | Purpose |
|---|---|
| `INBOX_TOKEN` | Bearer token for `/api/*`. A local copy is in `.env`. |
| `LINEAR_WEBHOOK_SECRET` | Signing secret from the Linear webhook. |
| `GITHUB_WEBHOOK_SECRET` | Secret from the GitHub webhook. |

Set a secret with `npx wrangler secret put <NAME>`. In Windows PowerShell, do not pipe the value into that command, because PowerShell adds characters. Type the value at the prompt, or use `npx wrangler secret bulk <file.json>`.

## Add a source

1. Add an entry to `SOURCES` in `src/index.js`: the secret name, how to verify the signature, and where to find the delivery ID, event type and action.
2. Deploy.
3. In the service, add a webhook with the URL `https://inbox.mgcohen.workers.dev/hooks/<name>`.
4. Set the secret in Cloudflare.

## Develop and test

```bash
npm install
npm run migrate:local
npm run dev
```

`npm run dev` reads local secrets from `.dev.vars` (git ignores this file), for example:

```
INBOX_TOKEN=local-test-token
LINEAR_WEBHOOK_SECRET=local-linear-secret
```

In a second terminal, run the smoke test:

```powershell
.\test\smoke.ps1 -BaseUrl http://127.0.0.1:8787 -Token local-test-token -LinearSecret local-linear-secret
```

## Deploy

A merge to `main` deploys through Cloudflare Workers Builds. The deploy command applies the D1 migrations first.

To deploy by hand: `npm run deploy`. To return to the previous version: `npx wrangler rollback`.

## Start and stop

The Worker always runs. To stop it:

- **One source:** `npx wrangler secret delete <SECRET>`. That source returns 503.
- **The public URL:** set `"workers_dev": false` in `wrangler.jsonc` and deploy. The data stays.
- **Everything:** `npx wrangler delete inbox`. The D1 data stays until you delete the database.

## Operate

- Live logs: `npm run tail`
- Query the data: `npx wrangler d1 execute webhook-hub --remote --command "SELECT id, source, event_type, action, received_at FROM events ORDER BY id DESC LIMIT 20"`

## Cost

The free plan is enough. Its daily limits apply to the whole Cloudflare account: 100,000 Worker requests, 100,000 D1 rows written, 5 million D1 rows read, and 5 GB of D1 storage. If a limit is reached, requests fail until the next day. Nothing is charged.
