-- One row for each (consumer, event) pair that a consumer marked as consumed.
-- Each consumer has its own state, so one tool never hides an event from another.
CREATE TABLE consumptions (
  event_id    INTEGER NOT NULL REFERENCES events (id) ON DELETE CASCADE,
  consumer    TEXT    NOT NULL,                -- for example: claude-runner
  consumed_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (consumer, event_id)
);

CREATE INDEX idx_consumptions_event ON consumptions (event_id);
