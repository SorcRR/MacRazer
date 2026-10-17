-- Usage stats, sent only by Macs whose owner said yes. No IP addresses, no names, no
-- timestamps finer than a day. `id` is the app's hash of the Mac's hardware UUID: it can't be
-- turned back into the UUID or the serial number.

-- One row per Mac.
CREATE TABLE installs (
  id TEXT PRIMARY KEY,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  app TEXT NOT NULL,
  os TEXT NOT NULL,
  arch TEXT NOT NULL,
  -- "first" pings from a Mac that already had a row: the app was installed again, or its
  -- preferences were cleared.
  reinstalls INTEGER NOT NULL DEFAULT 0
);

-- The mice each Mac has reported. A product ID only means something with its link, since
-- Bluetooth IDs come from a different vendor number than USB ones.
CREATE TABLE install_mice (
  id TEXT NOT NULL,
  pid INTEGER NOT NULL,
  link TEXT NOT NULL,
  name TEXT NOT NULL,
  supported INTEGER NOT NULL,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  PRIMARY KEY (id, pid, link)
);

-- What's left after Delete My Data: the same details without the ID, so nothing here can be
-- linked back to a Mac. The mice go in their own table, not tied to these rows, and dated
-- only to the month: on a quiet day, matching days would tie them back together.
CREATE TABLE deleted_installs (
  deleted_on TEXT NOT NULL,
  app TEXT NOT NULL,
  os TEXT NOT NULL,
  arch TEXT NOT NULL,
  days_used INTEGER NOT NULL
);

CREATE TABLE deleted_mice (
  deleted_month TEXT NOT NULL,
  pid INTEGER NOT NULL,
  link TEXT NOT NULL,
  name TEXT NOT NULL,
  supported INTEGER NOT NULL
);
