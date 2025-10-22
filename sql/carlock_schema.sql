-- carlock saved vehicles table
CREATE TABLE IF NOT EXISTS carlock_vehicles (
  plate VARCHAR(32) NOT NULL PRIMARY KEY,
  owner_identifier VARCHAR(128) NOT NULL,
  locked TINYINT(1) NOT NULL DEFAULT 0,
  last_saved TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- optional: index on owner for quick lookups
CREATE INDEX idx_owner ON carlock_vehicles(owner_identifier);
