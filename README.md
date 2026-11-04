# inbox

A Cloudflare Worker that **receives** signed webhooks, **stores** them in D1, and **returns** them on demand.
It makes no decisions and does no work. Other tools read the events through the API.

- **URL:** https://inbox.mgcohen.workers.dev
- **Runtime:** Cloudflare Workers (free plan)
- **Storage:** D1 database `webhook-hub`, tables `events` and `consumptions`

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/` | none | Health check. Lists the defined sources. |
| `POST` | `/hooks/linear` | Linear signature (`linear-signature`) | Receive a Linear webhook. |
| `POST` | `/hooks/github` | GitHub signature (`x-hub-signature-256`) | Receive a GitHub webhook. |
| `POST` | `/hooks/notion` | Notion signature (`x-notion-signature`) | Receive a Notion webhook. |
| `GET` | `/api/events` | `Authorization: Bearer <INBOX_TOKEN>` | List events. Can also consume them. |
| `GET` | `/api/events/:id` | `Authorization: Bearer <INBOX_TOKEN>` | One event with its full payload and its consumers. |
| `POST` | `/api/consume` | `Authorization: Bearer <INBOX_TOKEN>` | Mark many events as consumed. |
| `POST` | `/api/events/:id/consume` | `Authorization: Bearer <INBOX_TOKEN>` | Mark one event as consumed. |

### `GET /api/events` parameters

| Parameter | Meaning |
|---|---|
| `source` | Only this source, for example `linear`. |
| `type` | Only this event type, for example `Issue`. |
| `after` | Only events with an ID greater than this. Returns the oldest first, and `next_after` for the next call. |
| `limit` | 1 to 200. Default 50. |
| `payload=1` | Include the full JSON body of each event. |
| `consumer` | The name of the reading tool, for example `claude-runner` (lowercase letters, digits, `-`, `_`). Adds `consumed_at` to each event. |
| `pending=1` | Only events that this consumer has not consumed. Returns the oldest first. Needs `consumer`. |
| `consume=1` | Mark every returned event as consumed by this consumer. Needs `consumer`. |

Without `after` or `pending`, the list returns the newest events first.

## Consume

Each consumer has its own consumed state. An event that one tool consumed is still pending for every other tool.

Two ways to consume:

1. **On read:** `GET /api/events?consumer=X&pending=1&consume=1` returns the pending events and marks them in the same call. Two parallel calls never get the same event. If the consumer fails after the read, the event is lost for it. Use this when a lost event is acceptable.
2. **After the work:** read with `GET /api/events?consumer=X&pending=1`, do the work, then mark the events:
   - `POST /api/consume` with `{"consumer": "X", "ids": [12, 13]}` (1 to 500 IDs)
   - `POST /api/events/12/consume` with `{"consumer": "X"}`

   If the consumer fails before it marks an event, the event stays pending and comes again. The consumer must accept that an event can come two times.

The consume response lists `consumed` (new for this consumer), `already` (consumed before) and `unknown` (no such event). The single-event call returns 404 for an unknown event. When an event is deleted, its consume rows are deleted too.

## Behavior

- A source without a secret accepts nothing (503). The one exception is the Notion handshake (see [Notion](#notion)).
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
| `NOTION_WEBHOOK_SECRET` | The `verification_token` of the Notion webhook subscription. |

Set a secret with `npx wrangler secret put <NAME>`. In Windows PowerShell, do not pipe the value into that command, because PowerShell adds characters. Type the value at the prompt, or use `npx wrangler secret bulk <file.json>`.

## Add a source

1. Add an entry to `SOURCES` in `src/index.js`: the secret name, how to verify the signature, and where to find the delivery ID, event type and action.
2. Deploy.
3. In the service, add a webhook with the URL `https://inbox.mgcohen.workers.dev/hooks/<name>`.
4. Set the secret in Cloudflare.

## Notion

Notion signs each event with the `verification_token` of the subscription. Notion sends that token one time, unsigned, when you create the subscription.

| `NOTION_WEBHOOK_SECRET` | Request to `/hooks/notion` | Result |
|---|---|---|
| Not set | Body is only `{"verification_token": "secret_..."}` | 200. The token goes to the Worker log. D1 stores nothing. |
| Not set | Any other body | 503 |
| Set | Valid `x-notion-signature` | 200. The event is stored. |
| Set | Missing or bad signature | 401 |

The event type `page.properties_updated` is stored as `event_type` `page` and `action` `properties_updated`. The delivery ID is the event `id`. Notion events contain IDs only. A consumer must read the page through the Notion API.

To connect a subscription:

1. Make sure that `NOTION_WEBHOOK_SECRET` is not set.
2. Run `npm run tail`.
3. In the Notion connection settings, open **Webhooks** and create a subscription with the URL `https://inbox.mgcohen.workers.dev/hooks/notion`.
4. Copy the token from the log line `notion handshake token: secret_...`.
5. Set it with `npx wrangler secret put NOTION_WEBHOOK_SECRET`.
6. In Notion, paste the token and click **Verify subscription**.

One Worker holds one Notion secret, so it accepts one subscription.

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

Without `-NotionSecret`, the test checks the Notion handshake. The Worker must have no `NOTION_WEBHOOK_SECRET`. To check signed Notion events, start the Worker with a local secret and give the same value to the test:

```powershell
npx wrangler dev --port 8787 --ip 127.0.0.1 --var NOTION_WEBHOOK_SECRET:local-notion-secret
.\test\smoke.ps1 -BaseUrl http://127.0.0.1:8787 -Token local-test-token -LinearSecret local-linear-secret -NotionSecret local-notion-secret
```

## Deploy

A merge to `main` deploys through Cloudflare Workers Builds with `npm run deploy`. That command applies the D1 migrations first.

To deploy by hand: `npm run deploy`. To return to the previous version: `npx wrangler rollback`.

### Build settings

The build settings are stored in Cloudflare, not in this repository. Keep this table in sync with them.

| Setting | Value |
|---|---|
| Repository and branch | `MgCohen/inbox`, `main` |
| Root directory | `/` |
| Build command | empty |
| Production deploy command | `npm run deploy` |
| Preview deploy command | `npm run deploy:preview` |
| Previews | on, for every branch except `main` |

To read them: `GET /accounts/<account>/builds/workers/<script_tag>` with a token that has **Workers CI Read**.

### PR previews

Each branch gets a preview at `https://<branch>-inbox.mgcohen.workers.dev`, built with `npm run deploy:preview`.

- Previews use their own database, `webhook-hub-preview` (the `previews` block in `wrangler.jsonc`). They never touch production data.
- `npm run migrate:preview` applies migrations to that database through `wrangler.preview-migrations.jsonc`. Keep the database ID in that file and in the `previews` block the same.
- Previews have no secrets by default, so `/hooks/*` returns 503 and `/api/*` returns 401. To test them on a preview, set preview secrets with `npx wrangler preview secret`.

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
