-- One row for each webhook delivery that the inbox accepts.
CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  source      TEXT    NOT NULL,                 -- linear | github | ...
  delivery_id TEXT    NOT NULL,                 -- the source's own delivery ID, used to drop duplicates
  event_type  TEXT,                             -- Linear "type", GitHub X-GitHub-Event
  action      TEXT,                             -- create | update | opened | ...
  received_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  payload     TEXT    NOT NULL,                 -- raw JSON body
  status      TEXT    NOT NULL DEFAULT 'new',   -- new | claimed | done | failed | ignored
  attempts    INTEGER NOT NULL DEFAULT 0,
  claimed_at  TEXT,
  finished_at TEXT,
  note        TEXT,
  UNIQUE (source, delivery_id)
);

CREATE INDEX IF NOT EXISTS idx_events_status_id ON events (status, id);
