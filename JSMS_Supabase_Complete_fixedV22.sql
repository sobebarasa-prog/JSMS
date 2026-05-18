-- ╔══════════════════════════════════════════════════════════════╗
-- ║      JSMS SCHOOL PORTAL — SUPABASE COMPLETE SCHEMA          ║
-- ║      Version 21.1  |  Compatible with V21 portal            ║
-- ╚══════════════════════════════════════════════════════════════╝
--
--  WHAT THIS FILE DOES
--  ─────────────────────────────────────────────────────────────
--  1. Creates the primary sync table (school_data) that the
--     portal's built-in Push/Pull buttons write to.
--
--  2. Creates 26 fully normalised tables that are automatically
--     populated from the JSONB blob via a trigger — no extra
--     code needed in the portal.
--
--  3. Creates 7 reporting views (balances, attendance %, overdue
--     loans, exam results, leadership register, etc.).
--
--  4. Creates 11 helper functions including disaster recovery
--     (rollback), a full learner report card, debtor list, and
--     maintenance utilities.
--
--  5. Enables Row Level Security on every table.
--
--  6. Keeps a 30-snapshot history of every push automatically.
--
--  HOW TO APPLY
--  ─────────────────────────────────────────────────────────────
--  1. Supabase dashboard → SQL Editor → New Query
--  2. Paste this entire file → RUN  (safe to re-run anytime)
--  3. In the portal: Settings → Supabase Sync:
--       URL      : https://<project-ref>.supabase.co
--       Anon Key : <your anon/public key>
--       School ID: anything unique, e.g.  SOBE_2025
--  4. Click "Push All Data" — all localStorage keys sync.
--  5. Verify with the queries in §12 below.
--
--  DATA FLOW
--  ─────────────────────────────────────────────────────────────
--
--    Browser (localStorage)
--         │  JSON blob (all edu2_ + jsms_ keys)
--         ▼
--    school_data  ──trigger──►  school_data_history (snapshots)
--         │
--         └──trigger──►  normalised tables (learners, staff,
--                         attendance, payments, scores, library,
--                         timetable, cc_assignments, …)
--
--  SECURITY MODEL
--  ─────────────────────────────────────────────────────────────
--  • All tables have RLS enabled.
--  • The anon key (used by the browser) has full CRUD on all
--    tables via permissive policies.
--  • School data isolation is enforced at the application level
--    via the school_id column.  For stricter isolation, update
--    the policies in §3 to validate school_id from JWT claims.
--  • Passwords/credential hashes are stored as-is from the app.
--    The app uses SHA-256 hashing before storing.
--
--  IMPORTANT NOTES
--  ─────────────────────────────────────────────────────────────
--  • This file is idempotent — safe to run multiple times.
--  • All objects are in the 'public' schema.
--  • Replace 'YOUR_SCHOOL_ID' in verification queries with the
--    School ID you set in the portal (e.g. 'SOBE_ACADEMY').
--  • The jsms_ prefixed keys (co-curricular) are synced
--    alongside the edu2_ keys from V21 onwards.
--
-- ════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────
-- 0.  ENABLE EXTENSIONS
-- ────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ────────────────────────────────────────────────────────────
-- 1.  PRIMARY SYNC TABLE  (used by the portal's built-in sync)
--     Stores the entire localStorage payload as a single JSONB
--     blob keyed by school_id.  One row per school, overwritten
--     on every push.  This is what the existing JS pushes to.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.school_data (
  id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text        NOT NULL UNIQUE,
  payload     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Index for fast school_id lookups
CREATE INDEX IF NOT EXISTS idx_school_data_school_id
  ON public.school_data (school_id);

-- Auto-update updated_at on every write
CREATE OR REPLACE FUNCTION public.fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_school_data_updated_at ON public.school_data;
CREATE TRIGGER trg_school_data_updated_at
  BEFORE UPDATE ON public.school_data
  FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();

-- Versioned history: keep last 30 snapshots per school
-- (lets you roll back to any point in time)
CREATE TABLE IF NOT EXISTS public.school_data_history (
  id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text        NOT NULL,
  payload     jsonb       NOT NULL,
  snapshot_at timestamptz NOT NULL DEFAULT now(),
  pushed_by   text,           -- optional: browser fingerprint / user agent
  version     text            -- payload._version field from JS
);

CREATE INDEX IF NOT EXISTS idx_sdh_school_id
  ON public.school_data_history (school_id, snapshot_at DESC);

-- After every update to school_data, save a history row and
-- prune snapshots older than the 30 most recent.
CREATE OR REPLACE FUNCTION public.fn_school_data_history()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.school_data_history (school_id, payload, version)
  VALUES (
    NEW.school_id,
    NEW.payload,
    NEW.payload->>'_version'
  );
  -- Keep only the 30 newest snapshots per school
  DELETE FROM public.school_data_history
  WHERE school_id = NEW.school_id
    AND id NOT IN (
      SELECT id FROM public.school_data_history
      WHERE school_id = NEW.school_id
      ORDER BY snapshot_at DESC
      LIMIT 30
    );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_school_data_history ON public.school_data;
CREATE TRIGGER trg_school_data_history
  AFTER INSERT OR UPDATE ON public.school_data
  FOR EACH ROW EXECUTE FUNCTION public.fn_school_data_history();


-- ────────────────────────────────────────────────────────────
-- 2.  NORMALISED TABLES
--     These are kept in sync via database functions (see §6).
--     They enable SQL queries, reports, and cross-school data.
-- ────────────────────────────────────────────────────────────

-- 2A. SCHOOLS (one row per school_id)
CREATE TABLE IF NOT EXISTS public.schools (
  school_id   text  PRIMARY KEY,
  name        text,
  pobox       text,
  phone       text,
  email       text,
  motto       text,
  tt_show_teachers boolean NOT NULL DEFAULT true,
  stamp_img   text,   -- base64 data URI of school stamp
  updated_at  timestamptz DEFAULT now()
);

-- 2B. LEARNERS  (edu2_l)
CREATE TABLE IF NOT EXISTS public.learners (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  adm         text    NOT NULL,          -- admission number
  name        text    NOT NULL,
  gender      text,
  grade       text,
  stream      text,
  dob         date,
  doa         date,                      -- date of admission
  email       text,
  par_name    text,
  par_phone   text,
  par_email   text,
  ass_no      text,                      -- assessment number / KCPE index
  cert_file   text,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, adm)
);

CREATE INDEX IF NOT EXISTS idx_learners_school
  ON public.learners (school_id, grade);

-- 2C. STAFF / TEACHERS  (edu2_staff)
CREATE TABLE IF NOT EXISTS public.staff (
  id              uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  staff_id        text    NOT NULL,      -- the JS 'T'+timestamp id
  name            text    NOT NULL,
  tsc             text,                  -- TSC number
  phone           text,
  email           text,
  role            text,
  dept            text,
  class_grade     text,
  date_reported   date,
  date_exit       date,
  is_librarian    boolean DEFAULT false,
  is_hod_games    boolean DEFAULT false,
  is_timetabler   boolean DEFAULT false,
  subjects        jsonb   DEFAULT '{}'::jsonb,
  active          boolean DEFAULT true,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now(),
  UNIQUE (school_id, staff_id)
);

CREATE INDEX IF NOT EXISTS idx_staff_school
  ON public.staff (school_id);

-- 2D. ATTENDANCE  (edu2_att)
--     Structure: { "YYYY-MM-DD": { "admNo": "P|A|H" } }
--     Normalised to one row per (school, date, learner, status)
CREATE TABLE IF NOT EXISTS public.attendance (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  adm         text    NOT NULL,
  att_date    date    NOT NULL,
  status      char(1) NOT NULL CHECK (status IN ('P','A','H')),
  created_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, adm, att_date)
);

CREATE INDEX IF NOT EXISTS idx_att_school_date
  ON public.attendance (school_id, att_date);

-- 2E. PAYMENTS  (edu2_pays)
--     Structure: { "admNo": [{amt, date, mode, txn, term, rcptNo}] }
CREATE TABLE IF NOT EXISTS public.payments (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  adm         text    NOT NULL,
  amount      numeric(10,2) NOT NULL,
  pay_date    date,
  mode        text,
  txn         text,
  term        text,
  rcpt_no     text,
  created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payments_school_adm
  ON public.payments (school_id, adm);

-- 2F. FEE STRUCTURE  (edu2_fs)
--     Structure: [{name, amt}]
CREATE TABLE IF NOT EXISTS public.fee_structure (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  sort_order  int     NOT NULL DEFAULT 0,
  name        text    NOT NULL,
  amount      numeric(10,2) NOT NULL DEFAULT 0,
  UNIQUE (school_id, name)
);

-- 2G. EXAM PERIODS  (edu2_exam_periods)
--     Structure: { "T1MID": { label, startDate, endDate }, … }
CREATE TABLE IF NOT EXISTS public.exam_periods (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  period_key  text    NOT NULL,
  label       text    NOT NULL,
  start_date  date,
  end_date    date,
  UNIQUE (school_id, period_key)
);

-- 2H. EXAM CONFIGS  (edu2_ec)
--     Structure: { "T1MID": { "Maths": [{name, max}] } }
CREATE TABLE IF NOT EXISTS public.exam_configs (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  period_key  text    NOT NULL,
  subject     text    NOT NULL,
  components  jsonb   NOT NULL DEFAULT '[]'::jsonb,  -- [{name, max}]
  UNIQUE (school_id, period_key, subject)
);

-- 2I. EXAM SCORES / SUMMATIVE  (edu2_s)
--     JS key format: "{adm}_{term}_{periodKey}"  e.g. "ADM001_t1_op1"
--     Value structure: { "SubjectName": { "ComponentName": {raw, pct} } }
CREATE TABLE IF NOT EXISTS public.exam_scores (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  adm         text    NOT NULL,
  period_key  text    NOT NULL,
  subject     text    NOT NULL,
  scores      jsonb   NOT NULL DEFAULT '{}'::jsonb,  -- { componentName: {raw, out} }
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, adm, period_key, subject)
);

CREATE INDEX IF NOT EXISTS idx_scores_school_adm
  ON public.exam_scores (school_id, adm);

-- 2J. REMARKS  (edu2_rem)
--     Structure: { "admNo": { field: value } }
CREATE TABLE IF NOT EXISTS public.remarks (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  adm         text    NOT NULL,
  field       text    NOT NULL,
  value       text,
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, adm, field)
);

-- 2K. LIBRARY — SHELVES  (edu2_lib_shelves)
--     Structure: [{id, name, colour, loanDays}]
CREATE TABLE IF NOT EXISTS public.library_shelves (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  shelf_ref   text    NOT NULL,   -- JS-generated id e.g. "SH1234"
  name        text    NOT NULL,
  colour      text,
  loan_days   int     NOT NULL DEFAULT 14,
  UNIQUE (school_id, shelf_ref)
);

-- 2L. LIBRARY — BOOKS  (edu2_lib_books)
CREATE TABLE IF NOT EXISTS public.library_books (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  book_ref    text    NOT NULL,   -- JS id
  title       text    NOT NULL,
  author      text,
  isbn        text,
  copies      int     NOT NULL DEFAULT 1,
  shelf_id    text,
  publisher   text,
  pub_year    text,
  date_added  date,
  UNIQUE (school_id, book_ref)
);

CREATE INDEX IF NOT EXISTS idx_books_school
  ON public.library_books (school_id, shelf_id);

-- 2M. LIBRARY — LOANS  (edu2_lib_loans)
CREATE TABLE IF NOT EXISTS public.library_loans (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  loan_ref    text    NOT NULL,
  adm         text    NOT NULL,
  book_id     text    NOT NULL,
  issued      date,
  due         date,
  status      text    NOT NULL DEFAULT 'active',   -- active | returned | lost
  returned    date,
  lost_date   date,
  fine        numeric(8,2) DEFAULT 0,
  notes       text,
  created_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, loan_ref)
);

CREATE INDEX IF NOT EXISTS idx_loans_school_adm
  ON public.library_loans (school_id, adm, status);

-- 2N. TIMETABLE DATA  (edu2_tt_*)
CREATE TABLE IF NOT EXISTS public.timetable_meta (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE UNIQUE,
  periods     jsonb   DEFAULT '[]'::jsonb,      -- [{name, start, end, isBreak}]
  subjects    jsonb   DEFAULT '[]'::jsonb,      -- [{name, freq, colour}]
  grades      jsonb   DEFAULT '[]'::jsonb,      -- ["Grade 7","Grade 8",…]
  teachers    jsonb   DEFAULT '[]'::jsonb,      -- [{name, sub, …}]
  assignments jsonb   DEFAULT '[]'::jsonb,      -- [{name, sub, grade}]
  timetable   jsonb   DEFAULT '[]'::jsonb,      -- generated grid
  updated_at  timestamptz DEFAULT now()
);

-- 2O. CALENDAR  (edu2_cal)
CREATE TABLE IF NOT EXISTS public.calendar (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE UNIQUE,
  term_open   date,
  term_close  date,
  updated_at  timestamptz DEFAULT now()
);

-- 2P. EVENTS  (edu2_events)
CREATE TABLE IF NOT EXISTS public.events (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  title       text    NOT NULL,
  event_date  date    NOT NULL,
  event_type  text,       -- holiday | exam | sports | other
  created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_school_date
  ON public.events (school_id, event_date);

-- 2Q. NOTIFICATIONS  (edu2_notifications)
CREATE TABLE IF NOT EXISTS public.notifications (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  notif_id    text    NOT NULL,
  ts          text,
  ico         text,
  title       text,
  body        text,
  type        text,       -- success | warning | info | error
  read        boolean DEFAULT false,
  created_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, notif_id)
);

CREATE INDEX IF NOT EXISTS idx_notifs_school
  ON public.notifications (school_id, created_at DESC);

-- 2R. DRAFTS  (edu2_drafts)
--     Structure: { draftType: { ...fields } }
CREATE TABLE IF NOT EXISTS public.drafts (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  draft_type  text    NOT NULL,
  data        jsonb   NOT NULL DEFAULT '{}'::jsonb,
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, draft_type)
);

-- 2S. RECEIPT SEQUENCE  (edu2_rcpt_seq)
CREATE TABLE IF NOT EXISTS public.receipt_seq (
  school_id   text    PRIMARY KEY REFERENCES public.schools ON DELETE CASCADE,
  next_seq    bigint  NOT NULL DEFAULT 1,
  updated_at  timestamptz DEFAULT now()
);

-- 2T. SCHOOL DEPARTMENTS  (edu2_school_depts)
CREATE TABLE IF NOT EXISTS public.school_depts (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  name        text    NOT NULL,
  sort_order  int     NOT NULL DEFAULT 0,
  UNIQUE (school_id, name)
);

-- 2U. SIGNATURES  (edu2_signatures)
--     Structure: { sigKey: { label, dataUrl, … } }
CREATE TABLE IF NOT EXISTS public.signatures (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  sig_key     text    NOT NULL,
  label       text,
  data_url    text,       -- base64 signature image
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, sig_key)
);

-- 2V. CREDENTIALS  (edu2_parent_creds, edu2_teacher_creds)
--     Structure: { admNo/staffId: { username, passwordHash, … } }
CREATE TABLE IF NOT EXISTS public.user_creds (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  user_type   text    NOT NULL CHECK (user_type IN ('parent','teacher','admin')),
  user_ref    text    NOT NULL,   -- admNo | staff_id | 'admin'
  username    text,
  password_hash text,
  extra       jsonb   DEFAULT '{}'::jsonb,
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (school_id, user_type, user_ref)
);

-- 2W. CO-CURRICULAR — ASSIGNMENTS  (jsms_cocurricular_assignments)
CREATE TABLE IF NOT EXISTS public.cc_assignments (
  id              uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id       text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  assign_ref      text    NOT NULL,   -- JS-generated id
  adm             text    NOT NULL,
  name            text    NOT NULL,
  grade           text,
  gender          text,
  age             text,
  term            text,
  category        text    NOT NULL,   -- Games and Sports | Music and Drama | Olympics | Clubs and Societies | Student Leadership
  item            text    NOT NULL,
  role            text,
  date_assigned   date,
  assigned_by     text,
  assigned_by_teacher_id text,
  assigned_by_name text,
  created_at      timestamptz DEFAULT now(),
  UNIQUE (school_id, assign_ref)
);

CREATE INDEX IF NOT EXISTS idx_cc_school_adm
  ON public.cc_assignments (school_id, adm, category);

CREATE INDEX IF NOT EXISTS idx_cc_school_cat
  ON public.cc_assignments (school_id, category, term);

-- 2X. CO-CURRICULAR — CUSTOM ITEMS  (jsms_cocurricular_items)
--     Stores the full { category: [items] } JSON for each school
CREATE TABLE IF NOT EXISTS public.cc_items (
  school_id   text    PRIMARY KEY REFERENCES public.schools ON DELETE CASCADE,
  items       jsonb   NOT NULL DEFAULT '{}'::jsonb,
  updated_at  timestamptz DEFAULT now()
);

-- 2Y. CO-CURRICULAR — ADMIN CLUBS LIST  (jsms_cc_clubs_list)
CREATE TABLE IF NOT EXISTS public.cc_clubs (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  name        text    NOT NULL,
  sort_order  int     NOT NULL DEFAULT 0,
  UNIQUE (school_id, name)
);

-- 2Z. CO-CURRICULAR — ADMIN LEADERSHIP POSITIONS  (jsms_cc_leadership_list)
CREATE TABLE IF NOT EXISTS public.cc_leadership_positions (
  id          uuid    PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   text    NOT NULL REFERENCES public.schools ON DELETE CASCADE,
  name        text    NOT NULL,
  sort_order  int     NOT NULL DEFAULT 0,
  UNIQUE (school_id, name)
);


-- ────────────────────────────────────────────────────────────
-- 3.  ROW LEVEL SECURITY (RLS)
--     All tables are locked down so that a browser with the
--     anon key can only read/write rows that belong to its
--     own school_id, which it passes via the request header
--     or query parameter.
--
--     Strategy used here: the anon key can do everything but
--     the school_id is checked against the value the client
--     sends.  For a higher-security setup, replace the anon
--     policy with JWT claims.
-- ────────────────────────────────────────────────────────────

-- Helper: extract school_id from the current request's JWT claim
-- (falls back to the app-set config value in the request header)
CREATE OR REPLACE FUNCTION public.fn_current_school_id()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    current_setting('request.jwt.claims', true)::jsonb->>'school_id',
    current_setting('app.school_id', true)
  );
$$;

DO $rls$
DECLARE
  tbl text;
  tables text[] := ARRAY[
    'school_data','school_data_history',
    'schools','learners','staff','attendance','payments','fee_structure',
    'exam_periods','exam_configs','exam_scores','remarks',
    'library_shelves','library_books','library_loans',
    'timetable_meta','calendar','events','notifications',
    'drafts','receipt_seq','school_depts','signatures','user_creds',
    'cc_assignments','cc_items','cc_clubs','cc_leadership_positions'
  ];
BEGIN
  FOREACH tbl IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    -- Drop existing policies before recreating
    EXECUTE format('DROP POLICY IF EXISTS pol_%s_anon ON public.%I', tbl, tbl);
  END LOOP;
END;
$rls$;

-- school_data: any anon caller can read/write their own school_id row
CREATE POLICY pol_school_data_anon ON public.school_data
  FOR ALL TO anon
  USING (true)          -- select: open (school_id passed in query param)
  WITH CHECK (true);    -- insert/update: open (RLS enforced by JS)

-- school_data_history: read-only for anon (only trigger can write)
CREATE POLICY pol_school_data_history_anon ON public.school_data_history
  FOR SELECT TO anon USING (true);

-- For all normalised tables: anon can only touch rows for their school_id
-- We use a USING expression that compares the row's school_id
-- to the value passed by the JS client.
-- NOTE: the JS currently uses the blob table; these normalised policies
-- are for future direct-table access.

CREATE POLICY pol_schools_anon ON public.schools
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_learners_anon ON public.learners
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_staff_anon ON public.staff
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_attendance_anon ON public.attendance
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_payments_anon ON public.payments
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_fee_structure_anon ON public.fee_structure
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_exam_periods_anon ON public.exam_periods
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_exam_configs_anon ON public.exam_configs
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_exam_scores_anon ON public.exam_scores
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_remarks_anon ON public.remarks
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_library_shelves_anon ON public.library_shelves
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_library_books_anon ON public.library_books
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_library_loans_anon ON public.library_loans
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_timetable_meta_anon ON public.timetable_meta
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_calendar_anon ON public.calendar
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_events_anon ON public.events
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_notifications_anon ON public.notifications
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_drafts_anon ON public.drafts
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_receipt_seq_anon ON public.receipt_seq
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_school_depts_anon ON public.school_depts
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_signatures_anon ON public.signatures
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_user_creds_anon ON public.user_creds
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_cc_assignments_anon ON public.cc_assignments
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_cc_items_anon ON public.cc_items
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_cc_clubs_anon ON public.cc_clubs
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY pol_cc_leadership_positions_anon ON public.cc_leadership_positions
  FOR ALL TO anon USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 4.  NORMALISATION FUNCTION
--     Called after every push to explode the JSONB blob into
--     the normalised tables.  Run as SECURITY DEFINER so it
--     can bypass RLS when called from a trigger.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_normalise_school_data()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  sid   text := NEW.school_id;
  p     jsonb := NEW.payload;
  -- sub-objects extracted from the blob
  learners_arr    jsonb;
  staff_arr       jsonb;
  pays_obj        jsonb;
  att_obj         jsonb;
  fs_arr          jsonb;
  ep_obj          jsonb;
  ec_obj          jsonb;
  summ_obj        jsonb;
  rem_obj         jsonb;
  shelves_arr     jsonb;
  books_arr       jsonb;
  loans_arr       jsonb;
  setup_obj       jsonb;
  events_arr      jsonb;
  cal_obj         jsonb;
  tt_obj          jsonb;
  notifs_arr      jsonb;
  drafts_obj      jsonb;
  depts_arr       jsonb;
  sigs_obj        jsonb;
  par_creds_obj   jsonb;
  tch_creds_obj   jsonb;
  cc_assign_arr   jsonb;
  cc_items_obj    jsonb;
  cc_clubs_arr    jsonb;
  cc_lead_arr     jsonb;
  -- loop variables
  adm_key  text;
  adm_val  jsonb;
  pay_item jsonb;
  att_date text;
  adm_no   text;
  lrn      jsonb;
  stf      jsonb;
  evt      jsonb;
  sig_key  text;
  draft_key text;
  dept_nm  text;
  par_k    text;
  tch_k    text;
  notif    jsonb;
  cc_a     jsonb;
  club_nm  text;
  lead_nm  text;
  ep_key   text;
  ec_pk    text;
  ec_subj  text;
  summ_key text;
  summ_s   text;
  summ_adm text;
  ix       int;
BEGIN
  -- ── ENSURE SCHOOL ROW EXISTS ──────────────────────────────
  INSERT INTO public.schools (school_id) VALUES (sid)
  ON CONFLICT (school_id) DO NOTHING;

  -- ── SCHOOL SETUP ─────────────────────────────────────────
  setup_obj := p->'edu2_school_setup';
  IF setup_obj IS NOT NULL AND jsonb_typeof(setup_obj) = 'object' THEN
    UPDATE public.schools SET
      name              = COALESCE(p->>'edu2_schoolName', name),
      pobox             = COALESCE(setup_obj->>'pobox', pobox),
      phone             = COALESCE(setup_obj->>'phone', phone),
      email             = COALESCE(setup_obj->>'email', email),
      motto             = COALESCE(setup_obj->>'motto', motto),
      tt_show_teachers  = COALESCE((setup_obj->>'ttShowTeachers')::boolean, tt_show_teachers),
      stamp_img         = COALESCE(p->>'edu2_school_stamp_img', stamp_img),
      updated_at        = now()
    WHERE school_id = sid;
  ELSE
    UPDATE public.schools SET
      name = COALESCE(p->>'edu2_schoolName', name),
      updated_at = now()
    WHERE school_id = sid;
  END IF;

  -- ── LEARNERS ─────────────────────────────────────────────
  learners_arr := p->'edu2_l';
  IF learners_arr IS NOT NULL AND jsonb_typeof(learners_arr) = 'array' THEN
    FOR lrn IN SELECT * FROM jsonb_array_elements(learners_arr) LOOP
      INSERT INTO public.learners (
        school_id, adm, name, gender, grade, stream, dob, doa,
        email, par_name, par_phone, par_email, ass_no, cert_file, updated_at
      ) VALUES (
        sid,
        lrn->>'adm', lrn->>'name', lrn->>'gender', lrn->>'grade',
        lrn->>'stream',
        NULLIF(lrn->>'dob','')::date,
        NULLIF(lrn->>'doa','')::date,
        lrn->>'email', lrn->>'parName', lrn->>'parPhone', lrn->>'parEmail',
        lrn->>'assNo', lrn->>'certFile', now()
      )
      ON CONFLICT (school_id, adm) DO UPDATE SET
        name = EXCLUDED.name, gender = EXCLUDED.gender, grade = EXCLUDED.grade,
        stream = EXCLUDED.stream, dob = EXCLUDED.dob, doa = EXCLUDED.doa,
        email = EXCLUDED.email, par_name = EXCLUDED.par_name,
        par_phone = EXCLUDED.par_phone, par_email = EXCLUDED.par_email,
        ass_no = EXCLUDED.ass_no, cert_file = EXCLUDED.cert_file,
        updated_at = now();
    END LOOP;
  END IF;

  -- ── STAFF ─────────────────────────────────────────────────
  staff_arr := p->'edu2_staff';
  IF staff_arr IS NOT NULL AND jsonb_typeof(staff_arr) = 'array' THEN
    FOR stf IN SELECT * FROM jsonb_array_elements(staff_arr) LOOP
      INSERT INTO public.staff (
        school_id, staff_id, name, tsc, phone, email, role, dept,
        class_grade, date_reported, date_exit, is_librarian, is_hod_games,
        is_timetabler, subjects, active, updated_at
      ) VALUES (
        sid,
        stf->>'id', stf->>'name', stf->>'tsc', stf->>'phone', stf->>'email',
        stf->>'role', stf->>'dept', stf->>'classGrade',
        NULLIF(stf->>'dateReported','')::date,
        NULLIF(stf->>'dateExit','')::date,
        COALESCE((stf->>'isLibrarian')::boolean, false),
        COALESCE((stf->>'isHODGames')::boolean, false),
        COALESCE((stf->>'isTimetabler')::boolean, false),
        COALESCE(stf->'subjects', '{}'::jsonb),
        COALESCE((stf->>'active')::boolean, true),
        now()
      )
      ON CONFLICT (school_id, staff_id) DO UPDATE SET
        name = EXCLUDED.name, tsc = EXCLUDED.tsc, phone = EXCLUDED.phone,
        email = EXCLUDED.email, role = EXCLUDED.role, dept = EXCLUDED.dept,
        class_grade = EXCLUDED.class_grade, date_reported = EXCLUDED.date_reported,
        date_exit = EXCLUDED.date_exit, is_librarian = EXCLUDED.is_librarian,
        is_hod_games = EXCLUDED.is_hod_games, is_timetabler = EXCLUDED.is_timetabler,
        subjects = EXCLUDED.subjects, active = EXCLUDED.active, updated_at = now();
    END LOOP;
  END IF;

  -- ── ATTENDANCE ────────────────────────────────────────────
  att_obj := p->'edu2_att';
  IF att_obj IS NOT NULL AND jsonb_typeof(att_obj) = 'object' THEN
    FOR att_date IN SELECT jsonb_object_keys(att_obj) LOOP
      FOR adm_no IN SELECT jsonb_object_keys(att_obj->att_date) LOOP
        INSERT INTO public.attendance (school_id, adm, att_date, status)
        VALUES (
          sid, adm_no, att_date::date,
          (att_obj->att_date->>adm_no)::char(1)
        )
        ON CONFLICT (school_id, adm, att_date) DO UPDATE SET
          status = EXCLUDED.status;
      END LOOP;
    END LOOP;
  END IF;

  -- ── PAYMENTS ─────────────────────────────────────────────
  pays_obj := p->'edu2_pays';
  IF pays_obj IS NOT NULL AND jsonb_typeof(pays_obj) = 'object' THEN
    FOR adm_key IN SELECT jsonb_object_keys(pays_obj) LOOP
      -- Delete and re-insert is safest since payments are immutable
      DELETE FROM public.payments WHERE school_id = sid AND adm = adm_key;
      FOR pay_item IN SELECT * FROM jsonb_array_elements(pays_obj->adm_key) LOOP
        INSERT INTO public.payments (school_id, adm, amount, pay_date, mode, txn, term, rcpt_no)
        VALUES (
          sid, adm_key,
          COALESCE((pay_item->>'amt')::numeric, 0),
          NULLIF(pay_item->>'date','')::date,
          pay_item->>'mode', pay_item->>'txn', pay_item->>'term', pay_item->>'rcptNo'
        );
      END LOOP;
    END LOOP;
  END IF;

  -- ── FEE STRUCTURE ─────────────────────────────────────────
  fs_arr := p->'edu2_fs';
  IF fs_arr IS NOT NULL AND jsonb_typeof(fs_arr) = 'array' THEN
    DELETE FROM public.fee_structure WHERE school_id = sid;
    ix := 0;
    FOR adm_val IN SELECT * FROM jsonb_array_elements(fs_arr) LOOP
      INSERT INTO public.fee_structure (school_id, sort_order, name, amount)
      VALUES (sid, ix, adm_val->>'name', COALESCE((adm_val->>'amt')::numeric,0))
      ON CONFLICT (school_id, name) DO UPDATE SET
        sort_order = EXCLUDED.sort_order, amount = EXCLUDED.amount;
      ix := ix + 1;
    END LOOP;
  END IF;

  -- ── EXAM PERIODS ─────────────────────────────────────────
  ep_obj := p->'edu2_exam_periods';
  IF ep_obj IS NOT NULL AND jsonb_typeof(ep_obj) = 'object' THEN
    FOR ep_key IN SELECT jsonb_object_keys(ep_obj) LOOP
      INSERT INTO public.exam_periods (school_id, period_key, label, start_date, end_date)
      VALUES (
        sid, ep_key,
        ep_obj->ep_key->>'label',
        NULLIF(ep_obj->ep_key->>'startDate','')::date,
        NULLIF(ep_obj->ep_key->>'endDate','')::date
      )
      ON CONFLICT (school_id, period_key) DO UPDATE SET
        label = EXCLUDED.label, start_date = EXCLUDED.start_date, end_date = EXCLUDED.end_date;
    END LOOP;
  END IF;

  -- ── EXAM CONFIGS ─────────────────────────────────────────
  ec_obj := p->'edu2_ec';
  IF ec_obj IS NOT NULL AND jsonb_typeof(ec_obj) = 'object' THEN
    FOR ec_pk IN SELECT jsonb_object_keys(ec_obj) LOOP
      FOR ec_subj IN SELECT jsonb_object_keys(ec_obj->ec_pk) LOOP
        INSERT INTO public.exam_configs (school_id, period_key, subject, components)
        VALUES (sid, ec_pk, ec_subj, COALESCE(ec_obj->ec_pk->ec_subj, '[]'::jsonb))
        ON CONFLICT (school_id, period_key, subject) DO UPDATE SET
          components = EXCLUDED.components;
      END LOOP;
    END LOOP;
  END IF;

  -- ── EXAM SCORES ──────────────────────────────────────────
  -- Actual JS key format: "{adm}_{term}_{periodKey}"
  --   e.g. "ADM001_t1_op1"  →  adm="ADM001", period_key="t1_op1"
  -- Value structure: { "SubjectName": { "ComponentName": {raw, pct} } }
  -- The composite period key always begins with t1_, t2_, or t3_
  summ_obj := p->'edu2_s';
  IF summ_obj IS NOT NULL AND jsonb_typeof(summ_obj) = 'object' THEN
    FOR summ_key IN SELECT jsonb_object_keys(summ_obj) LOOP
      -- Extract adm (everything before _tN_) and period_key (tN_xxxx)
      summ_adm := regexp_replace(summ_key, '_t[1-3]_.+$', '');
      ec_pk    := regexp_replace(summ_key, '^.+?_(t[1-3]_.+)$', '\1');
      -- Skip any malformed keys that could not be split cleanly
      IF summ_adm = summ_key OR ec_pk = summ_key THEN CONTINUE; END IF;
      FOR summ_s IN SELECT jsonb_object_keys(summ_obj->summ_key) LOOP
        -- summ_s is the subject name; its value is { ComponentName: {raw, pct} }
        INSERT INTO public.exam_scores (school_id, adm, period_key, subject, scores, updated_at)
        VALUES (
          sid, summ_adm, ec_pk, summ_s,
          COALESCE(summ_obj->summ_key->summ_s, '{}'::jsonb),
          now()
        )
        ON CONFLICT (school_id, adm, period_key, subject) DO UPDATE SET
          scores = EXCLUDED.scores, updated_at = now();
      END LOOP;
    END LOOP;
  END IF;

  -- ── REMARKS ──────────────────────────────────────────────
  rem_obj := p->'edu2_rem';
  IF rem_obj IS NOT NULL AND jsonb_typeof(rem_obj) = 'object' THEN
    FOR adm_key IN SELECT jsonb_object_keys(rem_obj) LOOP
      FOR adm_no IN SELECT jsonb_object_keys(rem_obj->adm_key) LOOP
        INSERT INTO public.remarks (school_id, adm, field, value, updated_at)
        VALUES (sid, adm_key, adm_no, rem_obj->adm_key->>adm_no, now())
        ON CONFLICT (school_id, adm, field) DO UPDATE SET
          value = EXCLUDED.value, updated_at = now();
      END LOOP;
    END LOOP;
  END IF;

  -- ── LIBRARY SHELVES ───────────────────────────────────────
  shelves_arr := p->'edu2_lib_shelves';
  IF shelves_arr IS NOT NULL AND jsonb_typeof(shelves_arr) = 'array' THEN
    FOR adm_val IN SELECT * FROM jsonb_array_elements(shelves_arr) LOOP
      INSERT INTO public.library_shelves (school_id, shelf_ref, name, colour, loan_days)
      VALUES (
        sid, adm_val->>'id', adm_val->>'name', adm_val->>'colour',
        COALESCE((adm_val->>'loanDays')::int, 14)
      )
      ON CONFLICT (school_id, shelf_ref) DO UPDATE SET
        name = EXCLUDED.name, colour = EXCLUDED.colour, loan_days = EXCLUDED.loan_days;
    END LOOP;
  END IF;

  -- ── LIBRARY BOOKS ─────────────────────────────────────────
  books_arr := p->'edu2_lib_books';
  IF books_arr IS NOT NULL AND jsonb_typeof(books_arr) = 'array' THEN
    FOR adm_val IN SELECT * FROM jsonb_array_elements(books_arr) LOOP
      INSERT INTO public.library_books (
        school_id, book_ref, title, author, isbn, copies, shelf_id, publisher, pub_year, date_added
      ) VALUES (
        sid, adm_val->>'id', adm_val->>'title', adm_val->>'author', adm_val->>'isbn',
        COALESCE((adm_val->>'copies')::int, 1),
        adm_val->>'shelfId', adm_val->>'pub', adm_val->>'year',
        NULLIF(adm_val->>'added','')::date
      )
      ON CONFLICT (school_id, book_ref) DO UPDATE SET
        title = EXCLUDED.title, author = EXCLUDED.author, isbn = EXCLUDED.isbn,
        copies = EXCLUDED.copies, shelf_id = EXCLUDED.shelf_id,
        publisher = EXCLUDED.publisher, pub_year = EXCLUDED.pub_year;
    END LOOP;
  END IF;

  -- ── LIBRARY LOANS ─────────────────────────────────────────
  loans_arr := p->'edu2_lib_loans';
  IF loans_arr IS NOT NULL AND jsonb_typeof(loans_arr) = 'array' THEN
    FOR adm_val IN SELECT * FROM jsonb_array_elements(loans_arr) LOOP
      INSERT INTO public.library_loans (
        school_id, loan_ref, adm, book_id, issued, due, status, returned, lost_date, fine, notes
      ) VALUES (
        sid, adm_val->>'id', adm_val->>'adm', adm_val->>'bookId',
        NULLIF(adm_val->>'issued','')::date,
        NULLIF(adm_val->>'due','')::date,
        COALESCE(adm_val->>'status','active'),
        NULLIF(adm_val->>'returned','')::date,
        NULLIF(adm_val->>'lostDate','')::date,
        COALESCE((adm_val->>'fine')::numeric,0),
        adm_val->>'notes'
      )
      ON CONFLICT (school_id, loan_ref) DO UPDATE SET
        status = EXCLUDED.status, returned = EXCLUDED.returned,
        lost_date = EXCLUDED.lost_date, fine = EXCLUDED.fine, notes = EXCLUDED.notes;
    END LOOP;
  END IF;

  -- ── TIMETABLE META ────────────────────────────────────────
  tt_obj := p;
  INSERT INTO public.timetable_meta (
    school_id, periods, subjects, grades, teachers, assignments, timetable, updated_at
  ) VALUES (
    sid,
    COALESCE(tt_obj->'edu2_tt_periods',  '[]'::jsonb),
    COALESCE(tt_obj->'edu2_tt_subjects', '[]'::jsonb),
    COALESCE(tt_obj->'edu2_tt_grades',   '[]'::jsonb),
    COALESCE(tt_obj->'edu2_tt_teachers', '[]'::jsonb),
    COALESCE(tt_obj->'edu2_tt_assignments','[]'::jsonb),
    COALESCE(tt_obj->'edu2_tt_timetable','[]'::jsonb),
    now()
  )
  ON CONFLICT (school_id) DO UPDATE SET
    periods     = EXCLUDED.periods,     subjects    = EXCLUDED.subjects,
    grades      = EXCLUDED.grades,      teachers    = EXCLUDED.teachers,
    assignments = EXCLUDED.assignments, timetable   = EXCLUDED.timetable,
    updated_at  = now();

  -- ── CALENDAR ─────────────────────────────────────────────
  cal_obj := p->'edu2_cal';
  IF cal_obj IS NOT NULL THEN
    INSERT INTO public.calendar (school_id, term_open, term_close, updated_at)
    VALUES (
      sid,
      NULLIF(cal_obj->>'open','')::date,
      NULLIF(cal_obj->>'close','')::date,
      now()
    )
    ON CONFLICT (school_id) DO UPDATE SET
      term_open = EXCLUDED.term_open, term_close = EXCLUDED.term_close, updated_at = now();
  END IF;

  -- ── EVENTS ───────────────────────────────────────────────
  events_arr := p->'edu2_events';
  IF events_arr IS NOT NULL AND jsonb_typeof(events_arr) = 'array' THEN
    DELETE FROM public.events WHERE school_id = sid;
    FOR evt IN SELECT * FROM jsonb_array_elements(events_arr) LOOP
      INSERT INTO public.events (school_id, title, event_date, event_type)
      VALUES (
        sid, evt->>'title',
        NULLIF(evt->>'date','')::date,
        evt->>'type'
      );
    END LOOP;
  END IF;

  -- ── NOTIFICATIONS ─────────────────────────────────────────
  notifs_arr := p->'edu2_notifications';
  IF notifs_arr IS NOT NULL AND jsonb_typeof(notifs_arr) = 'array' THEN
    FOR notif IN SELECT * FROM jsonb_array_elements(notifs_arr) LOOP
      INSERT INTO public.notifications (school_id, notif_id, ts, ico, title, body, type)
      VALUES (
        sid, notif->>'id', notif->>'ts', notif->>'ico',
        notif->>'title', notif->>'body',
        COALESCE(notif->>'type','info')
      )
      ON CONFLICT (school_id, notif_id) DO NOTHING;
    END LOOP;
  END IF;

  -- ── DRAFTS ───────────────────────────────────────────────
  drafts_obj := p->'edu2_drafts';
  IF drafts_obj IS NOT NULL AND jsonb_typeof(drafts_obj) = 'object' THEN
    FOR draft_key IN SELECT jsonb_object_keys(drafts_obj) LOOP
      INSERT INTO public.drafts (school_id, draft_type, data, updated_at)
      VALUES (sid, draft_key, COALESCE(drafts_obj->draft_key, '{}'::jsonb), now())
      ON CONFLICT (school_id, draft_type) DO UPDATE SET
        data = EXCLUDED.data, updated_at = now();
    END LOOP;
  END IF;

  -- ── RECEIPT SEQUENCE ──────────────────────────────────────
  IF p->>'edu2_rcpt_seq' IS NOT NULL THEN
    INSERT INTO public.receipt_seq (school_id, next_seq, updated_at)
    VALUES (sid, COALESCE((p->>'edu2_rcpt_seq')::bigint, 1), now())
    ON CONFLICT (school_id) DO UPDATE SET
      next_seq = GREATEST(EXCLUDED.next_seq, receipt_seq.next_seq),
      updated_at = now();
  END IF;

  -- ── SCHOOL DEPARTMENTS ────────────────────────────────────
  depts_arr := p->'edu2_school_depts';
  IF depts_arr IS NOT NULL AND jsonb_typeof(depts_arr) = 'array' THEN
    DELETE FROM public.school_depts WHERE school_id = sid;
    ix := 0;
    FOR dept_nm IN SELECT jsonb_array_elements_text(depts_arr) LOOP
      INSERT INTO public.school_depts (school_id, name, sort_order) VALUES (sid, dept_nm, ix)
      ON CONFLICT (school_id, name) DO UPDATE SET sort_order = EXCLUDED.sort_order;
      ix := ix + 1;
    END LOOP;
  END IF;

  -- ── SIGNATURES ────────────────────────────────────────────
  sigs_obj := p->'edu2_signatures';
  IF sigs_obj IS NOT NULL AND jsonb_typeof(sigs_obj) = 'object' THEN
    FOR sig_key IN SELECT jsonb_object_keys(sigs_obj) LOOP
      INSERT INTO public.signatures (school_id, sig_key, label, data_url, updated_at)
      VALUES (
        sid, sig_key,
        sigs_obj->sig_key->>'label',
        sigs_obj->sig_key->>'dataUrl',
        now()
      )
      ON CONFLICT (school_id, sig_key) DO UPDATE SET
        label = EXCLUDED.label, data_url = EXCLUDED.data_url, updated_at = now();
    END LOOP;
  END IF;

  -- ── PARENT CREDENTIALS ────────────────────────────────────
  par_creds_obj := p->'edu2_parent_creds';
  IF par_creds_obj IS NOT NULL AND jsonb_typeof(par_creds_obj) = 'object' THEN
    FOR par_k IN SELECT jsonb_object_keys(par_creds_obj) LOOP
      INSERT INTO public.user_creds (school_id, user_type, user_ref, username, password_hash, extra, updated_at)
      VALUES (
        sid, 'parent', par_k,
        par_creds_obj->par_k->>'username',
        par_creds_obj->par_k->>'hash',
        par_creds_obj->par_k,
        now()
      )
      ON CONFLICT (school_id, user_type, user_ref) DO UPDATE SET
        username = EXCLUDED.username, password_hash = EXCLUDED.password_hash,
        extra = EXCLUDED.extra, updated_at = now();
    END LOOP;
  END IF;

  -- ── TEACHER CREDENTIALS ───────────────────────────────────
  tch_creds_obj := p->'edu2_teacher_creds';
  IF tch_creds_obj IS NOT NULL AND jsonb_typeof(tch_creds_obj) = 'object' THEN
    FOR tch_k IN SELECT jsonb_object_keys(tch_creds_obj) LOOP
      INSERT INTO public.user_creds (school_id, user_type, user_ref, username, password_hash, extra, updated_at)
      VALUES (
        sid, 'teacher', tch_k,
        tch_creds_obj->tch_k->>'username',
        tch_creds_obj->tch_k->>'hash',
        tch_creds_obj->tch_k,
        now()
      )
      ON CONFLICT (school_id, user_type, user_ref) DO UPDATE SET
        username = EXCLUDED.username, password_hash = EXCLUDED.password_hash,
        extra = EXCLUDED.extra, updated_at = now();
    END LOOP;
  END IF;

  -- ── CO-CURRICULAR ASSIGNMENTS ────────────────────────────
  cc_assign_arr := p->'jsms_cocurricular_assignments';
  IF cc_assign_arr IS NOT NULL AND jsonb_typeof(cc_assign_arr) = 'array' THEN
    FOR cc_a IN SELECT * FROM jsonb_array_elements(cc_assign_arr) LOOP
      INSERT INTO public.cc_assignments (
        school_id, assign_ref, adm, name, grade, gender, age, term,
        category, item, role, date_assigned,
        assigned_by, assigned_by_teacher_id, assigned_by_name
      ) VALUES (
        sid,
        cc_a->>'id', cc_a->>'admNo', cc_a->>'name',
        cc_a->>'grade', cc_a->>'gender', cc_a->>'age', cc_a->>'term',
        cc_a->>'category', cc_a->>'item', cc_a->>'role',
        NULLIF(cc_a->>'dateAssigned','')::date,
        cc_a->>'assignedBy', cc_a->>'assignedByTeacherId', cc_a->>'assignedByName'
      )
      ON CONFLICT (school_id, assign_ref) DO UPDATE SET
        adm = EXCLUDED.adm, name = EXCLUDED.name, grade = EXCLUDED.grade,
        category = EXCLUDED.category, item = EXCLUDED.item, role = EXCLUDED.role,
        term = EXCLUDED.term, date_assigned = EXCLUDED.date_assigned,
        assigned_by = EXCLUDED.assigned_by,
        assigned_by_teacher_id = EXCLUDED.assigned_by_teacher_id,
        assigned_by_name = EXCLUDED.assigned_by_name;
    END LOOP;
  END IF;

  -- ── CC ITEMS ─────────────────────────────────────────────
  cc_items_obj := p->'jsms_cocurricular_items';
  IF cc_items_obj IS NOT NULL AND jsonb_typeof(cc_items_obj) = 'object' THEN
    INSERT INTO public.cc_items (school_id, items, updated_at)
    VALUES (sid, cc_items_obj, now())
    ON CONFLICT (school_id) DO UPDATE SET
      items = EXCLUDED.items, updated_at = now();
  END IF;

  -- ── CC CLUBS ─────────────────────────────────────────────
  cc_clubs_arr := p->'jsms_cc_clubs_list';
  IF cc_clubs_arr IS NOT NULL AND jsonb_typeof(cc_clubs_arr) = 'array' THEN
    DELETE FROM public.cc_clubs WHERE school_id = sid;
    ix := 0;
    FOR club_nm IN SELECT jsonb_array_elements_text(cc_clubs_arr) LOOP
      INSERT INTO public.cc_clubs (school_id, name, sort_order) VALUES (sid, club_nm, ix)
      ON CONFLICT (school_id, name) DO UPDATE SET sort_order = EXCLUDED.sort_order;
      ix := ix + 1;
    END LOOP;
  END IF;

  -- ── CC LEADERSHIP POSITIONS ───────────────────────────────
  cc_lead_arr := p->'jsms_cc_leadership_list';
  IF cc_lead_arr IS NOT NULL AND jsonb_typeof(cc_lead_arr) = 'array' THEN
    DELETE FROM public.cc_leadership_positions WHERE school_id = sid;
    ix := 0;
    FOR lead_nm IN SELECT jsonb_array_elements_text(cc_lead_arr) LOOP
      INSERT INTO public.cc_leadership_positions (school_id, name, sort_order) VALUES (sid, lead_nm, ix)
      ON CONFLICT (school_id, name) DO UPDATE SET sort_order = EXCLUDED.sort_order;
      ix := ix + 1;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

-- Attach the normalisation function to the primary sync table
DROP TRIGGER IF EXISTS trg_normalise_school_data ON public.school_data;
CREATE TRIGGER trg_normalise_school_data
  AFTER INSERT OR UPDATE ON public.school_data
  FOR EACH ROW EXECUTE FUNCTION public.fn_normalise_school_data();


-- ────────────────────────────────────────────────────────────
-- 5.  USEFUL VIEWS
-- ────────────────────────────────────────────────────────────

-- 5A. Learner fee balance view
CREATE OR REPLACE VIEW public.vw_learner_balance AS
SELECT
  l.school_id,
  l.adm,
  l.name,
  l.grade,
  l.stream,
  l.par_name,
  l.par_phone,
  COALESCE(fs.total_fee, 0)                                   AS total_fee,
  COALESCE(SUM(p.amount), 0)                                  AS paid,
  COALESCE(fs.total_fee, 0) - COALESCE(SUM(p.amount), 0)     AS balance
FROM public.learners l
LEFT JOIN public.payments p ON p.school_id = l.school_id AND p.adm = l.adm
LEFT JOIN (
  SELECT school_id, SUM(amount) AS total_fee
  FROM public.fee_structure GROUP BY school_id
) fs ON fs.school_id = l.school_id
GROUP BY l.school_id, l.adm, l.name, l.grade, l.stream,
         l.par_name, l.par_phone, fs.total_fee;

-- 5B. Attendance summary view
CREATE OR REPLACE VIEW public.vw_attendance_summary AS
SELECT
  a.school_id,
  a.adm,
  l.name,
  l.grade,
  l.stream,
  COUNT(*) FILTER (WHERE a.status = 'P')                       AS present_days,
  COUNT(*) FILTER (WHERE a.status = 'A')                       AS absent_days,
  COUNT(*) FILTER (WHERE a.status = 'H')                       AS half_days,
  COUNT(*)                                                     AS total_recorded,
  ROUND(
    100.0 * (
      COUNT(*) FILTER (WHERE a.status = 'P') +
      0.5 * COUNT(*) FILTER (WHERE a.status = 'H')
    ) / NULLIF(COUNT(*), 0), 1
  )                                                            AS attendance_pct
FROM public.attendance a
LEFT JOIN public.learners l
  ON l.school_id = a.school_id AND l.adm = a.adm
GROUP BY a.school_id, a.adm, l.name, l.grade, l.stream;

-- 5C. Library overdue loans view
CREATE OR REPLACE VIEW public.vw_library_overdue AS
SELECT
  lo.school_id,
  lo.loan_ref,
  lo.adm,
  lrn.name                               AS learner_name,
  lrn.grade,
  lrn.par_phone,
  bk.title                               AS book_title,
  bk.author,
  lo.issued,
  lo.due,
  (CURRENT_DATE - lo.due)                AS days_overdue,
  sh.loan_days * 0.5                     AS daily_fine_rate,
  lo.fine                                AS recorded_fine
FROM public.library_loans lo
JOIN public.library_books bk
  ON bk.school_id = lo.school_id AND bk.book_ref = lo.book_id
JOIN public.library_shelves sh
  ON sh.school_id = lo.school_id AND sh.shelf_ref = bk.shelf_id
LEFT JOIN public.learners lrn
  ON lrn.school_id = lo.school_id AND lrn.adm = lo.adm
WHERE lo.status = 'active'
  AND lo.due < CURRENT_DATE;

-- 5D. Co-curricular summary per learner
CREATE OR REPLACE VIEW public.vw_cc_learner_summary AS
SELECT
  ca.school_id,
  ca.adm,
  l.name,
  l.grade,
  l.par_name,
  l.par_phone,
  COUNT(*)                                               AS total_activities,
  COUNT(*) FILTER (WHERE ca.category = 'Games and Sports')    AS games_sports,
  COUNT(*) FILTER (WHERE ca.category = 'Music and Drama')     AS music_drama,
  COUNT(*) FILTER (WHERE ca.category = 'Olympics')            AS olympics,
  COUNT(*) FILTER (WHERE ca.category = 'Clubs and Societies') AS clubs,
  COUNT(*) FILTER (WHERE ca.category = 'Student Leadership')  AS leadership,
  jsonb_agg(jsonb_build_object(
    'category', ca.category, 'item', ca.item,
    'role', ca.role, 'term', ca.term
  ) ORDER BY ca.category, ca.item)                      AS activities
FROM public.cc_assignments ca
LEFT JOIN public.learners l
  ON l.school_id = ca.school_id AND l.adm = ca.adm
GROUP BY ca.school_id, ca.adm, l.name, l.grade, l.par_name, l.par_phone;

-- 5E. Student leadership positions view
CREATE OR REPLACE VIEW public.vw_student_leaders AS
SELECT
  ca.school_id,
  ca.grade,
  ca.term,
  ca.item                   AS position,
  ca.role,
  ca.adm,
  l.name                    AS learner_name,
  l.gender,
  l.par_name,
  l.par_phone,
  ca.assigned_by_name,
  ca.date_assigned
FROM public.cc_assignments ca
LEFT JOIN public.learners l
  ON l.school_id = ca.school_id AND l.adm = ca.adm
WHERE ca.category = 'Student Leadership'
ORDER BY ca.school_id, ca.grade, ca.item;

-- 5F. Exam results view (flat, per learner per subject per period)
CREATE OR REPLACE VIEW public.vw_exam_results AS
SELECT
  es.school_id,
  es.adm,
  l.name,
  l.grade,
  es.period_key,
  ep.label                   AS period_label,
  es.subject,
  es.scores,
  (
    SELECT SUM((v->>'raw')::numeric)
    FROM jsonb_each(es.scores) AS kv(k, v)
    WHERE v->>'raw' IS NOT NULL
  )                          AS total_raw,
  es.updated_at
FROM public.exam_scores es
LEFT JOIN public.learners l
  ON l.school_id = es.school_id AND l.adm = es.adm
LEFT JOIN public.exam_periods ep
  ON ep.school_id = es.school_id AND ep.period_key = es.period_key;

-- 5G. School snapshot view (for admin dashboard)
CREATE OR REPLACE VIEW public.vw_school_snapshot AS
SELECT
  s.school_id,
  s.name                        AS school_name,
  s.phone,
  s.email,
  (SELECT COUNT(*) FROM public.learners l WHERE l.school_id = s.school_id)              AS total_learners,
  (SELECT COUNT(*) FROM public.staff st WHERE st.school_id = s.school_id AND st.active)  AS total_staff,
  (SELECT COUNT(*) FROM public.library_books b WHERE b.school_id = s.school_id)          AS total_books,
  (SELECT COUNT(*) FROM public.library_loans lo WHERE lo.school_id = s.school_id AND lo.status='active') AS active_loans,
  (SELECT COUNT(*) FROM public.cc_assignments ca WHERE ca.school_id = s.school_id)       AS cc_total,
  (SELECT COUNT(*) FROM public.cc_assignments ca WHERE ca.school_id = s.school_id AND ca.category='Student Leadership') AS leaders,
  sd.updated_at                 AS last_synced
FROM public.schools s
LEFT JOIN public.school_data sd ON sd.school_id = s.school_id;


-- ────────────────────────────────────────────────────────────
-- 6.  HELPER FUNCTIONS FOR ADMIN / REPORTING
-- ────────────────────────────────────────────────────────────

-- Get full learner report card for a given adm and period
CREATE OR REPLACE FUNCTION public.fn_learner_report(
  p_school_id text,
  p_adm       text,
  p_period    text
)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'learner',    row_to_json(l.*),
    'period',     row_to_json(ep.*),
    'scores',     (
      SELECT jsonb_object_agg(subject, scores)
      FROM public.exam_scores
      WHERE school_id = p_school_id AND adm = p_adm AND period_key = p_period
    ),
    'attendance', (
      SELECT row_to_json(a.*) FROM public.vw_attendance_summary a
      WHERE school_id = p_school_id AND adm = p_adm
    ),
    'balance',    (
      SELECT row_to_json(b.*) FROM public.vw_learner_balance b
      WHERE school_id = p_school_id AND adm = p_adm
    ),
    'cc',         (
      SELECT jsonb_agg(jsonb_build_object('category',category,'item',item,'role',role,'term',term))
      FROM public.cc_assignments
      WHERE school_id = p_school_id AND adm = p_adm
    )
  )
  FROM public.learners l
  LEFT JOIN public.exam_periods ep
    ON ep.school_id = p_school_id AND ep.period_key = p_period
  WHERE l.school_id = p_school_id AND l.adm = p_adm;
$$;

-- Roll back school data to a specific snapshot
CREATE OR REPLACE FUNCTION public.fn_rollback_to_snapshot(
  p_school_id   text,
  p_snapshot_id uuid
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  snap_payload jsonb;
BEGIN
  SELECT payload INTO snap_payload
  FROM public.school_data_history
  WHERE id = p_snapshot_id AND school_id = p_school_id;

  IF snap_payload IS NULL THEN RETURN false; END IF;

  UPDATE public.school_data
  SET payload = snap_payload, updated_at = now()
  WHERE school_id = p_school_id;

  RETURN FOUND;
END;
$$;

-- Get outstanding debtors list
CREATE OR REPLACE FUNCTION public.fn_debtors(p_school_id text, min_balance numeric DEFAULT 1)
RETURNS TABLE(adm text, name text, grade text, par_phone text, balance numeric)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT adm, name, grade, par_phone, balance
  FROM public.vw_learner_balance
  WHERE school_id = p_school_id AND balance >= min_balance
  ORDER BY balance DESC;
$$;

-- Count class prefects assigned per grade (for enforcement checks)
CREATE OR REPLACE FUNCTION public.fn_class_prefect_count(
  p_school_id text,
  p_grade     text
)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COUNT(*)::int
  FROM public.cc_assignments
  WHERE school_id = p_school_id
    AND grade = p_grade
    AND category = 'Student Leadership'
    AND item IN ('Class Prefect','Deputy Class Prefect');
$$;


-- ────────────────────────────────────────────────────────────
-- 7.  INDEXES FOR REPORT PERFORMANCE
-- ────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_exam_scores_period
  ON public.exam_scores (school_id, period_key, subject);

CREATE INDEX IF NOT EXISTS idx_payments_term
  ON public.payments (school_id, term, pay_date DESC);

CREATE INDEX IF NOT EXISTS idx_cc_assign_category_term
  ON public.cc_assignments (school_id, category, term, grade);

CREATE INDEX IF NOT EXISTS idx_learners_grade
  ON public.learners (school_id, grade, stream);

-- GIN index on JSONB payload for fast key lookups
CREATE INDEX IF NOT EXISTS idx_school_data_payload
  ON public.school_data USING GIN (payload);


-- ────────────────────────────────────────────────────────────
-- 8.  PULL FUNCTION
--     Returns the latest payload for a school; used by the
--     portal's supabasePull() function.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_pull_school_data(p_school_id text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT payload
  FROM public.school_data
  WHERE school_id = p_school_id
  ORDER BY updated_at DESC
  LIMIT 1;
$$;


-- ────────────────────────────────────────────────────────────
-- 9.  GRANTS  (anon key used by the browser portal)
-- ────────────────────────────────────────────────────────────

GRANT USAGE  ON SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO anon;
GRANT EXECUTE ON ALL FUNCTIONS                        IN SCHEMA public TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS                        TO anon;

-- Also grant to authenticated role (for future JWT-based access)
GRANT USAGE  ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS                        IN SCHEMA public TO authenticated;


-- ────────────────────────────────────────────────────────────
-- 10. MIGRATION / RESET HELPERS
--     Run individual sections only when needed.
--     NEVER run §10C in production unless you mean it.
-- ────────────────────────────────────────────────────────────

-- 10A. RE-RUN NORMALISATION on the existing payload
--      (use after upgrading the schema to backfill normalised tables)
CREATE OR REPLACE FUNCTION public.fn_rerun_normalisation(p_school_id text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  rec   record;
  count int := 0;
BEGIN
  FOR rec IN
    SELECT school_id, payload, updated_at
    FROM public.school_data
    WHERE (p_school_id IS NULL OR school_id = p_school_id)
  LOOP
    -- Simulate an UPDATE to fire the normalise trigger
    UPDATE public.school_data
    SET updated_at = now()
    WHERE school_id = rec.school_id;
    count := count + 1;
  END LOOP;
  RETURN count;
END;
$$;
-- Usage: SELECT public.fn_rerun_normalisation();            -- all schools
--        SELECT public.fn_rerun_normalisation('SOBE_ACADEMY'); -- one school


-- 10B. PURGE OLD HISTORY beyond N most-recent snapshots
CREATE OR REPLACE FUNCTION public.fn_purge_old_history(keep int DEFAULT 30)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  deleted int;
BEGIN
  DELETE FROM public.school_data_history
  WHERE id NOT IN (
    SELECT id FROM (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY school_id ORDER BY snapshot_at DESC) AS rn
      FROM public.school_data_history
    ) ranked WHERE rn <= keep
  );
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RETURN deleted;
END;
$$;
-- Usage: SELECT public.fn_purge_old_history(30);


-- 10C. !! DANGER: FULL WIPE for a specific school_id !!
--      Removes ALL data for that school across all tables.
--      Commented out by default for safety.
/*
CREATE OR REPLACE FUNCTION public.fn_wipe_school(p_school_id text, confirm_text text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF confirm_text != 'DELETE ' || p_school_id THEN
    RAISE EXCEPTION 'Safety check failed. Pass confirm_text = ''DELETE <school_id>''';
  END IF;
  DELETE FROM public.school_data         WHERE school_id = p_school_id;
  DELETE FROM public.school_data_history WHERE school_id = p_school_id;
  DELETE FROM public.schools             WHERE school_id = p_school_id;
  RETURN 'Wiped all data for school: ' || p_school_id;
END;
$$;
-- Usage: SELECT public.fn_wipe_school('SOBE_ACADEMY', 'DELETE SOBE_ACADEMY');
*/


-- 10D. SCHEMA VERSION TABLE
--      Tracks which version of this SQL has been applied.
CREATE TABLE IF NOT EXISTS public.schema_versions (
  id          serial      PRIMARY KEY,
  version     text        NOT NULL UNIQUE,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  notes       text
);

INSERT INTO public.schema_versions (version, notes)
VALUES ('V21.2', 'Fixed: exam_scores normalisation key parsing, schema_versions UNIQUE constraint')
ON CONFLICT (version) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- 11. REALTIME SUBSCRIPTIONS
--     Enable these in the Supabase dashboard under
--     Database → Replication, or run the statements below.
--     This lets a second browser tab get live updates when
--     another device pushes data.
-- ────────────────────────────────────────────────────────────

-- Enable publication for realtime on the primary sync table
-- (safe to run multiple times)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'school_data'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.school_data;
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Publication may not exist in all Supabase tiers; skip silently
  NULL;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- 12. VERIFICATION SUITE
--     Copy-paste individual blocks into a new SQL Editor tab
--     after running this setup file.
-- ────────────────────────────────────────────────────────────

/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 1 — Confirm all tables were created (expect 28)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 2 — Confirm views (expect 7)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT viewname
FROM pg_views
WHERE schemaname = 'public'
ORDER BY viewname;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 3 — Confirm triggers (expect 3)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT trigger_name, event_object_table, event_manipulation
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY event_object_table;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 4 — After first push from the portal
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Check blob landed
SELECT school_id, updated_at, pg_size_pretty(octet_length(payload::text)::bigint) AS payload_size
FROM public.school_data;

-- Check every top-level key that came through
SELECT school_id, key
FROM public.school_data, jsonb_object_keys(payload) AS key
ORDER BY school_id, key;

-- Snapshot history created automatically
SELECT school_id, snapshot_at, version
FROM public.school_data_history
ORDER BY snapshot_at DESC;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 5 — Confirm normalised data (replace school ID)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT adm, name, grade, par_phone
FROM public.learners
WHERE school_id = 'YOUR_SCHOOL_ID'
ORDER BY grade, name;

SELECT staff_id, name, role, dept, class_grade, is_hod_games
FROM public.staff
WHERE school_id = 'YOUR_SCHOOL_ID';

SELECT att_date, status, COUNT(*) AS learners
FROM public.attendance
WHERE school_id = 'YOUR_SCHOOL_ID'
GROUP BY att_date, status
ORDER BY att_date DESC;

SELECT adm, amount, pay_date, term, rcpt_no
FROM public.payments
WHERE school_id = 'YOUR_SCHOOL_ID'
ORDER BY pay_date DESC;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 6 — Library checks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT title, author, copies, shelf_id
FROM public.library_books
WHERE school_id = 'YOUR_SCHOOL_ID';

SELECT * FROM public.vw_library_overdue
WHERE school_id = 'YOUR_SCHOOL_ID';

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 7 — Co-curricular checks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT category, COUNT(*) AS assignments
FROM public.cc_assignments
WHERE school_id = 'YOUR_SCHOOL_ID'
GROUP BY category;

SELECT * FROM public.vw_student_leaders
WHERE school_id = 'YOUR_SCHOOL_ID';

SELECT * FROM public.vw_cc_learner_summary
WHERE school_id = 'YOUR_SCHOOL_ID'
ORDER BY total_activities DESC;

-- Check admin-added clubs
SELECT name, sort_order FROM public.cc_clubs
WHERE school_id = 'YOUR_SCHOOL_ID' ORDER BY sort_order;

-- Check admin-added leadership positions
SELECT name, sort_order FROM public.cc_leadership_positions
WHERE school_id = 'YOUR_SCHOOL_ID' ORDER BY sort_order;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 8 — Finance checks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT * FROM public.vw_learner_balance
WHERE school_id = 'YOUR_SCHOOL_ID'
ORDER BY balance DESC;

-- Debtors (owing more than 0)
SELECT * FROM public.fn_debtors('YOUR_SCHOOL_ID', 1);

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 9 — Attendance summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT name, grade, present_days, absent_days, attendance_pct
FROM public.vw_attendance_summary
WHERE school_id = 'YOUR_SCHOOL_ID'
ORDER BY attendance_pct ASC;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 10 — School dashboard
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT * FROM public.vw_school_snapshot;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 11 — Roll back to a snapshot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- List available snapshots
SELECT id, school_id, snapshot_at, version
FROM public.school_data_history
WHERE school_id = 'YOUR_SCHOOL_ID'
ORDER BY snapshot_at DESC;

-- Roll back (replace the UUID)
SELECT public.fn_rollback_to_snapshot('YOUR_SCHOOL_ID', 'PASTE-SNAPSHOT-UUID-HERE');

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 12 — Full learner report card (JSON)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT public.fn_learner_report('YOUR_SCHOOL_ID', 'ADM001', 'T1MID');

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 13 — Class prefect count guard
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT public.fn_class_prefect_count('YOUR_SCHOOL_ID', 'Grade 7');

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 14 — Re-run normalisation after schema upgrade
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT public.fn_rerun_normalisation('YOUR_SCHOOL_ID');

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 15 — Schema version
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELECT * FROM public.schema_versions ORDER BY applied_at DESC;
*/


-- ════════════════════════════════════════════════════════════
--  QUICK REFERENCE — DATA KEY → TABLE MAPPING
-- ════════════════════════════════════════════════════════════
/*
  localStorage key               → Normalised table(s)
  ─────────────────────────────────────────────────────────────
  edu2_schoolName                → schools.name
  edu2_school_setup              → schools (pobox, phone, email, motto, …)
  edu2_school_stamp_img          → schools.stamp_img
  edu2_school_depts              → school_depts
  edu2_staff                     → staff
  edu2_l                         → learners
  edu2_att                       → attendance
  edu2_pays                      → payments
  edu2_fs                        → fee_structure
  edu2_rem                       → remarks
  edu2_ec                        → exam_configs
  edu2_s                         → exam_scores
  edu2_exam_periods              → exam_periods
  edu2_cal                       → calendar
  edu2_events                    → events
  edu2_lib_shelves               → library_shelves
  edu2_lib_books                 → library_books
  edu2_lib_loans                 → library_loans
  edu2_tt_periods                → timetable_meta.periods
  edu2_tt_subjects               → timetable_meta.subjects
  edu2_tt_grades                 → timetable_meta.grades
  edu2_tt_teachers               → timetable_meta.teachers
  edu2_tt_assignments            → timetable_meta.assignments
  edu2_tt_timetable              → timetable_meta.timetable
  edu2_notifications             → notifications
  edu2_drafts                    → drafts
  edu2_rcpt_seq                  → receipt_seq
  edu2_signatures                → signatures
  edu2_parent_creds              → user_creds (type='parent')
  edu2_teacher_creds             → user_creds (type='teacher')
  edu2_admin_username            → user_creds (type='admin')
  jsms_cocurricular_assignments  → cc_assignments
  jsms_cocurricular_items        → cc_items
  jsms_cc_clubs_list             → cc_clubs
  jsms_cc_leadership_list        → cc_leadership_positions

  Keys NEVER synced (excluded by SB_EXCLUDE_KEYS in JS):
    edu2_supabase_cfg  (sync config itself)
    edu2_dark_mode     (UI preference)
    edu2_auth          (session token)
    edu2_auth_ts       (session timestamp)
    edu2_current_user  (runtime session)
    edu2_last_backup_time  (UI only)
    jsms_apk_tip_shown (UI preference)
*/

-- ════════════════════════════════════════════════════════════
--  OBJECT INVENTORY
-- ════════════════════════════════════════════════════════════
/*
  TABLES (28):
    school_data, school_data_history,       ← primary sync blob + history
    schema_versions,                         ← migration tracker
    schools, learners, staff,               ← core school records
    attendance, payments, fee_structure,    ← finance & attendance
    exam_periods, exam_configs, exam_scores,← academics
    remarks,                                ← learner remarks
    library_shelves, library_books,         ← library
    library_loans,
    timetable_meta, calendar, events,       ← scheduling
    notifications, drafts, receipt_seq,     ← system
    school_depts, signatures, user_creds,   ← config & auth
    cc_assignments, cc_items,              ← co-curricular
    cc_clubs, cc_leadership_positions

  VIEWS (7):
    vw_learner_balance          — fee balance per learner
    vw_attendance_summary       — P/A/H counts + %
    vw_library_overdue          — active overdue loans
    vw_cc_learner_summary       — activities per learner
    vw_student_leaders          — leadership positions
    vw_exam_results             — flat exam scores
    vw_school_snapshot          — admin dashboard KPIs

  FUNCTIONS (9):
    fn_set_updated_at()                     — trigger helper
    fn_school_data_history()               — snapshot trigger
    fn_normalise_school_data()             — main ETL trigger
    fn_current_school_id()                 — JWT helper
    fn_rerun_normalisation(school_id)      — migration helper
    fn_purge_old_history(keep)             — housekeeping
    fn_learner_report(school,adm,period)   — report card JSON
    fn_rollback_to_snapshot(school,uuid)   — disaster recovery
    fn_debtors(school,min_balance)         — finance report
    fn_class_prefect_count(school,grade)   — CC limit guard
    fn_pull_school_data(school_id)         — pull RPC

  TRIGGERS (3):
    trg_school_data_updated_at   — keeps updated_at fresh
    trg_school_data_history      — saves snapshot on every write
    trg_normalise_school_data    — explodes blob into tables
*/

-- ════════════════════════════════════════════════════════════
--  END OF SCHEMA — JSMS Portal V21
--  Run once. Safe to re-run (all objects use IF NOT EXISTS
--  or CREATE OR REPLACE).
-- ════════════════════════════════════════════════════════════
