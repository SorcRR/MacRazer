-- Reports counted per day, for the daily caps. Nothing else is stored: no report content,
-- and no IP address, only a salted hash of one, which the daily cleanup removes.
CREATE TABLE counters (
  day TEXT NOT NULL,
  key TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, key)
);
