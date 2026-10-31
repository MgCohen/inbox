-- The inbox only receives, stores and returns events. Remove the queue columns
-- (status, attempts, claim and finish times) that 0001 added for a consumer.
-- The table had no rows when this migration was written.
DROP INDEX IF EXISTS idx_events_status_id;
DROP TABLE IF EXISTS events;

CREATE TABLE events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  source      TEXT NOT NULL,                 -- linear | github | ...
  delivery_id TEXT NOT NULL,                 -- the source's own delivery ID, used to drop duplicates
  event_type  TEXT,                          -- Linear "type", GitHub X-GitHub-Event
  action      TEXT,                          -- create | update | opened | ...
  received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  payload     TEXT NOT NULL,                 -- raw JSON body
  UNIQUE (source, delivery_id)
);

CREATE INDEX idx_events_source_id ON events (source, id);
CREATE INDEX idx_events_type_id ON events (event_type, id);
