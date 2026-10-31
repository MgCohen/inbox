// Inbox: receives signed webhooks, stores them in D1, and returns them on demand.
// It makes no decisions and does no work. Consumers read the events through /api/*.

const MAX_TIMESTAMP_SKEW_MS = 5 * 60 * 1000;

// Each source says how to verify a delivery and how to read its metadata.
const SOURCES = {
  linear: {
    secretVar: "LINEAR_WEBHOOK_SECRET",
    async verify(request, rawBody, secret) {
      const signature = request.headers.get("linear-signature");
      if (!signature || !(await verifyHmacHex(secret, rawBody, signature))) return false;
      // Linear puts the send time in the body. Reject old deliveries (replay).
      const body = JSON.parse(rawBody);
      return Math.abs(Date.now() - Number(body.webhookTimestamp)) <= MAX_TIMESTAMP_SKEW_MS;
    },
    describe(request, body) {
      return {
        deliveryId: request.headers.get("linear-delivery") ?? crypto.randomUUID(),
        eventType: body.type ?? null,
        action: body.action ?? null,
      };
    },
  },
  github: {
    secretVar: "GITHUB_WEBHOOK_SECRET",
    async verify(request, rawBody, secret) {
      const header = request.headers.get("x-hub-signature-256") ?? "";
      if (!header.startsWith("sha256=")) return false;
      return verifyHmacHex(secret, rawBody, header.slice("sha256=".length));
    },
    describe(request, body) {
      return {
        deliveryId: request.headers.get("x-github-delivery") ?? crypto.randomUUID(),
        eventType: request.headers.get("x-github-event"),
        action: body.action ?? null,
      };
    },
  },
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    try {
      if (path === "/" && request.method === "GET") {
        return json({ ok: true, service: "inbox", sources: Object.keys(SOURCES) });
      }

      // Receive + store.
      const hookMatch = path.match(/^\/hooks\/([a-z0-9-]+)$/);
      if (hookMatch && request.method === "POST") {
        return receiveHook(hookMatch[1], request, env);
      }

      // Retrieve + consume.
      if (path.startsWith("/api/")) {
        if (!isAuthorized(request, env)) return json({ error: "unauthorized" }, 401);

        if (request.method === "GET") {
          if (path === "/api/events") return listEvents(url, env);

          const eventMatch = path.match(/^\/api\/events\/(\d+)$/);
          if (eventMatch) return getEvent(Number(eventMatch[1]), env);
        }

        if (request.method === "POST") {
          if (path === "/api/consume") return consumeMany(request, env);

          const consumeMatch = path.match(/^\/api\/events\/(\d+)\/consume$/);
          if (consumeMatch) return consumeOne(Number(consumeMatch[1]), request, env);
        }
      }

      return json({ error: "not found" }, 404);
    } catch (err) {
      console.error(err);
      return json({ error: "internal error" }, 500);
    }
  },
};

async function receiveHook(sourceName, request, env) {
  const source = SOURCES[sourceName];
  if (!source) return json({ error: "unknown source" }, 404);

  // Fail closed: a source without a secret accepts nothing.
  const secret = env[source.secretVar];
  if (!secret) return json({ error: "source not configured" }, 503);

  const rawBody = await request.text();
  let verified = false;
  try {
    verified = await source.verify(request, rawBody, secret);
  } catch {
    verified = false;
  }
  if (!verified) return json({ error: "invalid signature" }, 401);

  const body = JSON.parse(rawBody);
  const { deliveryId, eventType, action } = source.describe(request, body);

  const result = await env.DB.prepare(
    `INSERT OR IGNORE INTO events (source, delivery_id, event_type, action, payload)
     VALUES (?, ?, ?, ?, ?)`
  )
    .bind(sourceName, deliveryId, eventType, action, rawBody)
    .run();

  // Always 200, also for a duplicate, so that the source stops its retries.
  return json({ ok: true, duplicate: result.meta.changes === 0 });
}

// GET /api/events?source=linear&type=Issue&after=120&limit=50&payload=1
//   &consumer=claude-runner&pending=1&consume=1
// Oldest first after the cursor, so a consumer can read forward with "after".
// "pending=1" also returns oldest first, like a queue.
// Otherwise, returns the newest events (newest first).
// "consume=1" marks every returned event as consumed by the consumer.
async function listEvents(url, env) {
  const params = url.searchParams;
  const limit = clamp(Number(params.get("limit")) || 50, 1, 200);
  const after = params.has("after") ? Number(params.get("after")) : null;
  const withPayload = params.get("payload") === "1";
  const consumer = params.get("consumer");
  const pending = params.get("pending") === "1";
  const consume = params.get("consume") === "1";

  if ((pending || consume) && !consumer) {
    return json({ error: "pending and consume need a consumer" }, 400);
  }
  if (consumer && !isValidConsumer(consumer)) return json({ error: "invalid consumer name" }, 400);

  const where = [];
  const binds = [];
  if (params.get("source")) {
    where.push("source = ?");
    binds.push(params.get("source"));
  }
  if (params.get("type")) {
    where.push("event_type = ?");
    binds.push(params.get("type"));
  }
  if (after !== null && Number.isFinite(after)) {
    where.push("id > ?");
    binds.push(after);
  }
  if (pending) {
    where.push("NOT EXISTS (SELECT 1 FROM consumptions c WHERE c.event_id = events.id AND c.consumer = ?)");
    binds.push(consumer);
  }

  const order = after !== null || pending ? "ASC" : "DESC";
  const { results: selected } = await env.DB.prepare(
    `SELECT id FROM events` +
      (where.length ? ` WHERE ${where.join(" AND ")}` : "") +
      ` ORDER BY id ${order} LIMIT ?`
  )
    .bind(...binds, limit)
    .all();
  let ids = selected.map((row) => row.id);

  if (consume && ids.length) {
    const newlyConsumed = await markConsumed(env, consumer, ids);
    // A parallel pending+consume call can take an event between our SELECT and
    // INSERT. Return only the events that this call consumed.
    if (pending) ids = ids.filter((id) => newlyConsumed.has(id));
  }

  const events = await fetchEvents(env, ids, order, withPayload, consumer);
  const last = events.length ? events[events.length - 1].id : null;
  return json({ events, next_after: after !== null ? (last ?? after) : null });
}

// GET /api/events/:id — one event with its full payload and who consumed it.
async function getEvent(id, env) {
  const row = await env.DB.prepare(
    `SELECT id, source, delivery_id, event_type, action, received_at, payload
     FROM events WHERE id = ?`
  )
    .bind(id)
    .first();
  if (!row) return json({ error: "not found" }, 404);

  const { results: consumers } = await env.DB.prepare(
    `SELECT consumer, consumed_at FROM consumptions WHERE event_id = ? ORDER BY consumed_at`
  )
    .bind(id)
    .all();
  return json({ ...parsePayload(row), consumers });
}

// POST /api/consume  {"consumer": "claude-runner", "ids": [12, 13]}
async function consumeMany(request, env) {
  const body = await readJson(request);
  if (!isValidConsumer(body.consumer)) return json({ error: "invalid consumer name" }, 400);
  if (!Array.isArray(body.ids) || body.ids.length === 0 || body.ids.length > 500) {
    return json({ error: "ids must be an array of 1 to 500 event IDs" }, 400);
  }
  const ids = [...new Set(body.ids.map(Number))];
  if (!ids.every((id) => Number.isInteger(id) && id > 0)) {
    return json({ error: "ids must be positive integers" }, 400);
  }
  return json(await consumeIds(env, body.consumer, ids));
}

// POST /api/events/:id/consume  {"consumer": "claude-runner"}
async function consumeOne(id, request, env) {
  const body = await readJson(request);
  if (!isValidConsumer(body.consumer)) return json({ error: "invalid consumer name" }, 400);
  const result = await consumeIds(env, body.consumer, [id]);
  if (result.unknown.length) return json({ error: "not found" }, 404);
  return json(result);
}

async function consumeIds(env, consumer, ids) {
  const { results } = await env.DB.prepare(
    `SELECT id FROM events WHERE id IN (SELECT value FROM json_each(?))`
  )
    .bind(JSON.stringify(ids))
    .all();
  const known = results.map((row) => row.id);
  const knownSet = new Set(known);
  const newlyConsumed = known.length ? await markConsumed(env, consumer, known) : new Set();

  return {
    consumer,
    consumed: known.filter((id) => newlyConsumed.has(id)),
    already: known.filter((id) => !newlyConsumed.has(id)),
    unknown: ids.filter((id) => !knownSet.has(id)),
  };
}

// Inserts consumption rows and returns the set of event IDs that were new for this consumer.
async function markConsumed(env, consumer, ids) {
  const { results } = await env.DB.prepare(
    `INSERT OR IGNORE INTO consumptions (event_id, consumer)
     SELECT value, ? FROM json_each(?)
     RETURNING event_id`
  )
    .bind(consumer, JSON.stringify(ids))
    .all();
  return new Set(results.map((row) => row.event_id));
}

async function fetchEvents(env, ids, order, withPayload, consumer) {
  if (!ids.length) return [];
  const columns =
    "e.id, e.source, e.delivery_id, e.event_type, e.action, e.received_at" +
    (withPayload ? ", e.payload" : "") +
    (consumer ? ", c.consumed_at" : "");
  const join = consumer ? " LEFT JOIN consumptions c ON c.event_id = e.id AND c.consumer = ?" : "";
  const binds = consumer ? [consumer, JSON.stringify(ids)] : [JSON.stringify(ids)];

  const { results } = await env.DB.prepare(
    `SELECT ${columns} FROM events e${join}
     WHERE e.id IN (SELECT value FROM json_each(?))
     ORDER BY e.id ${order}`
  )
    .bind(...binds)
    .all();
  return withPayload ? results.map(parsePayload) : results;
}

function isValidConsumer(name) {
  return typeof name === "string" && /^[a-z0-9][a-z0-9_-]{0,63}$/.test(name);
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

function parsePayload(row) {
  return { ...row, payload: JSON.parse(row.payload) };
}

function isAuthorized(request, env) {
  if (!env.INBOX_TOKEN) return false;
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  return timingSafeEqualStrings(token, env.INBOX_TOKEN);
}

async function verifyHmacHex(secret, message, signatureHex) {
  const signature = hexToBytes(signatureHex);
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );
  // subtle.verify compares in constant time.
  return crypto.subtle.verify("HMAC", key, signature, new TextEncoder().encode(message));
}

function timingSafeEqualStrings(a, b) {
  const enc = new TextEncoder();
  const bufA = enc.encode(a);
  const bufB = enc.encode(b);
  if (bufA.byteLength !== bufB.byteLength) return false;
  return crypto.subtle.timingSafeEqual(bufA, bufB);
}

function hexToBytes(hex) {
  if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  return bytes;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}
