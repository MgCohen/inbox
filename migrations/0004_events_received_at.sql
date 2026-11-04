-- The daily cleanup deletes events by received_at. This index keeps that delete
-- from a full scan of the events table.
CREATE INDEX idx_events_received_at ON events (received_at);
