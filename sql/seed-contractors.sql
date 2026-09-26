-- WF4 seed data.
-- Postgres is used as a stand-in for <COMPANY>'s Microsoft SQL Server. The workflow logic and
-- the Code node transformation are identical; only the driver and the date function differ.
-- On SQL Server the WHERE clause becomes:
--     AND last_payment_date < DATEADD(day, -@threshold, CAST(GETDATE() AS date))

DROP TABLE IF EXISTS contractors;

CREATE TABLE contractors (
  contractor_id     TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  status            TEXT NOT NULL CHECK (status IN ('active','pending','lapsed')),
  last_payment_date DATE NOT NULL,
  agency            TEXT NOT NULL
);

-- Dates are relative to CURRENT_DATE so the demo stays meaningful whenever it is run.
INSERT INTO contractors (contractor_id, name, status, last_payment_date, agency) VALUES
  -- pending and overdue (more than 7 days) -> these are what the report must find
  ('C-40001','Marek Kowalski',   'pending', CURRENT_DATE - 29, 'Brightline Staffing'),
  ('C-40002','Priya Raman',      'pending', CURRENT_DATE - 21, 'Northgate Recruitment'),
  ('C-40003','Daniel Okoro',     'pending', CURRENT_DATE - 16, 'Brightline Staffing'),
  ('C-40004','Aisha Khan',       'pending', CURRENT_DATE - 12, 'Kestrel Contract Services'),
  ('C-40005','Tomasz Nowak',     'pending', CURRENT_DATE - 9,  'Northgate Recruitment'),
  ('C-40006','Grace O''Donnell', 'pending', CURRENT_DATE - 8,  'Brightline Staffing'),

  -- pending but NOT yet overdue -> must be excluded, tests the boundary
  ('C-40007','Sam Patel',        'pending', CURRENT_DATE - 7,  'Harborview Talent'),
  ('C-40008','Elena Petrova',    'pending', CURRENT_DATE - 3,  'Kestrel Contract Services'),

  -- other statuses, old payments -> must be excluded, tests the status filter
  ('C-40009','John Adeyemi',     'active',  CURRENT_DATE - 40, 'Northgate Recruitment'),
  ('C-40010','Fiona Bell',       'active',  CURRENT_DATE - 2,  'Brightline Staffing'),
  ('C-40011','Hassan Malik',     'lapsed',  CURRENT_DATE - 95, 'Harborview Talent'),
  ('C-40012','Chloe Devereux',   'lapsed',  CURRENT_DATE - 60, 'Kestrel Contract Services');

-- The workflow queries this every weekday at 08:00.
-- Expected result today: 6 rows, oldest Marek Kowalski at 29 days.
-- C-40007 sits exactly on the 7 day boundary and must NOT appear.

CREATE INDEX idx_contractors_status_payment ON contractors (status, last_payment_date);
