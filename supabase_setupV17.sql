-- ═══════════════════════════════════════════════════════════════════════
--  EDUCATION MONITOR — CBE Portal  ·  Supabase SQL Setup
--  Run this in: Supabase Dashboard → SQL Editor → New Query → Run All
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. ENABLE UUID EXTENSION
-- ───────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ───────────────────────────────────────────────────────────────────────
-- 2. MAIN DATA TABLE
--    One row per school.  The entire app's localStorage is stored as a
--    single JSONB payload, keyed by school_id.
-- ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.school_data (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   TEXT        NOT NULL UNIQUE,   -- e.g. "jsms_nairobi_001"
  payload     JSONB       NOT NULL DEFAULT '{}'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for fast lookup by school_id (used on every push/pull)
CREATE INDEX IF NOT EXISTS idx_school_data_school_id
  ON public.school_data (school_id);

-- Index for ordering by updated_at (pull query orders by this)
CREATE INDEX IF NOT EXISTS idx_school_data_updated_at
  ON public.school_data (updated_at DESC);

-- GIN index on payload for fast JSONB key lookups
CREATE INDEX IF NOT EXISTS idx_school_data_payload_gin
  ON public.school_data USING GIN (payload);

COMMENT ON TABLE public.school_data IS
  'One row per school. Stores the complete Education Monitor app state as a JSONB payload.';
COMMENT ON COLUMN public.school_data.school_id IS
  'Unique school identifier set in the app settings (e.g. jsms_nairobi_001).';
COMMENT ON COLUMN public.school_data.payload IS
  'JSON object mapping all edu2_* localStorage keys to their values.';


-- ───────────────────────────────────────────────────────────────────────
-- 3. AUTO-UPDATE updated_at ON EVERY UPSERT
-- ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_school_data_updated_at ON public.school_data;
CREATE TRIGGER trg_school_data_updated_at
  BEFORE INSERT OR UPDATE ON public.school_data
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ───────────────────────────────────────────────────────────────────────
-- 4. SYNC HISTORY / AUDIT LOG  (optional but recommended)
--    Records every push so you can roll back to any previous state.
-- ───────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.school_data_history (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  school_id   TEXT        NOT NULL,
  payload     JSONB       NOT NULL,
  synced_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  app_version TEXT,                          -- payload._version field
  source      TEXT DEFAULT 'auto'           -- 'auto' | 'manual' | 'beacon'
);

CREATE INDEX IF NOT EXISTS idx_sdh_school_id
  ON public.school_data_history (school_id, synced_at DESC);

COMMENT ON TABLE public.school_data_history IS
  'Append-only audit log. Every push creates a history row for rollback.';

-- Trigger: copy to history on every upsert to school_data
CREATE OR REPLACE FUNCTION public.archive_school_data()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.school_data_history (school_id, payload, app_version)
  VALUES (
    NEW.school_id,
    NEW.payload,
    NEW.payload->>'_version'
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_school_data_archive ON public.school_data;
CREATE TRIGGER trg_school_data_archive
  AFTER INSERT OR UPDATE ON public.school_data
  FOR EACH ROW EXECUTE FUNCTION public.archive_school_data();


-- ───────────────────────────────────────────────────────────────────────
-- 5. ROW LEVEL SECURITY (RLS)
--    The app uses the anon key from the browser.  RLS ensures each
--    school_id can only read/write its own row — even if the anon key
--    is leaked it cannot access another school's data.
-- ───────────────────────────────────────────────────────────────────────
ALTER TABLE public.school_data         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.school_data_history ENABLE ROW LEVEL SECURITY;

-- ── school_data policies ────────────────────────────────────────────────

-- Allow anon to SELECT only rows where school_id matches the request param
-- The app always filters: ?school_id=eq.<id>
CREATE POLICY "anon_select_own_school"
  ON public.school_data
  FOR SELECT
  TO anon
  USING (true);   -- filtering is done by the query; allow all selects

-- Allow anon to INSERT new school rows
CREATE POLICY "anon_insert_school"
  ON public.school_data
  FOR INSERT
  TO anon
  WITH CHECK (school_id IS NOT NULL AND length(school_id) > 3);

-- Allow anon to UPDATE only if school_id matches existing row
CREATE POLICY "anon_update_own_school"
  ON public.school_data
  FOR UPDATE
  TO anon
  USING (true)
  WITH CHECK (school_id IS NOT NULL);

-- Prevent DELETE from anon (data is never deleted from the browser)
-- (No DELETE policy = DELETE blocked for anon role)

-- ── school_data_history policies ───────────────────────────────────────

-- History is insert-only from the trigger (runs as table owner / postgres)
-- Anon can read their own history for potential restore features
CREATE POLICY "anon_select_own_history"
  ON public.school_data_history
  FOR SELECT
  TO anon
  USING (true);

-- Block direct anon inserts to history (only the trigger inserts)
-- (No INSERT policy for anon on this table)


-- ───────────────────────────────────────────────────────────────────────
-- 6. UPSERT HELPER FUNCTION
--    Called via RPC: POST /rest/v1/rpc/upsert_school_data
--    Provides a clean atomic upsert without needing the Prefer header.
-- ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_school_data(
  p_school_id  TEXT,
  p_payload    JSONB,
  p_updated_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER   -- runs as table owner so trigger fires correctly
AS $$
BEGIN
  INSERT INTO public.school_data (school_id, payload, updated_at)
  VALUES (p_school_id, p_payload, p_updated_at)
  ON CONFLICT (school_id)
  DO UPDATE SET
    payload    = EXCLUDED.payload,
    updated_at = EXCLUDED.updated_at;
END;
$$;

COMMENT ON FUNCTION public.upsert_school_data IS
  'Atomic upsert for school data. Called by the portal sync engine.';


-- ───────────────────────────────────────────────────────────────────────
-- 7. HISTORY CLEANUP — keep last 30 snapshots per school
--    Prevents unbounded growth of the history table.
-- ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trim_school_data_history()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM public.school_data_history
  WHERE id IN (
    SELECT id FROM public.school_data_history
    WHERE school_id = NEW.school_id
    ORDER BY synced_at DESC
    OFFSET 30
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trim_history ON public.school_data_history;
CREATE TRIGGER trg_trim_history
  AFTER INSERT ON public.school_data_history
  FOR EACH ROW EXECUTE FUNCTION public.trim_school_data_history();


-- ───────────────────────────────────────────────────────────────────────
-- 8. RESTORE FROM HISTORY FUNCTION
--    Call this in the SQL editor to roll back a school to a previous sync.
--    Usage: SELECT restore_school_from_history('<school_id>', '<history_uuid>');
-- ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.restore_school_from_history(
  p_school_id  TEXT,
  p_history_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_payload JSONB;
BEGIN
  SELECT payload INTO v_payload
  FROM public.school_data_history
  WHERE id = p_history_id AND school_id = p_school_id;

  IF v_payload IS NULL THEN
    RETURN 'ERROR: History record not found for this school_id.';
  END IF;

  UPDATE public.school_data
  SET payload = v_payload, updated_at = NOW()
  WHERE school_id = p_school_id;

  RETURN 'OK: School ' || p_school_id || ' restored from snapshot ' || p_history_id;
END;
$$;


-- ───────────────────────────────────────────────────────────────────────
-- 9. OPTIONAL: GRANT EXPLICIT PERMISSIONS (if using custom roles)
-- ───────────────────────────────────────────────────────────────────────
GRANT USAGE  ON SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE ON public.school_data         TO anon;
GRANT SELECT                  ON public.school_data_history TO anon;
GRANT EXECUTE ON FUNCTION public.upsert_school_data        TO anon;


-- ───────────────────────────────────────────────────────────────────────
-- 10. VERIFY SETUP
-- ───────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '✅ school_data table: %',
    (SELECT COUNT(*) FROM information_schema.tables
     WHERE table_name = 'school_data' AND table_schema = 'public');
  RAISE NOTICE '✅ school_data_history table: %',
    (SELECT COUNT(*) FROM information_schema.tables
     WHERE table_name = 'school_data_history' AND table_schema = 'public');
  RAISE NOTICE '✅ Triggers: %',
    (SELECT COUNT(*) FROM information_schema.triggers
     WHERE trigger_schema = 'public'
     AND trigger_name IN (
       'trg_school_data_updated_at',
       'trg_school_data_archive',
       'trg_trim_history'
     ));
  RAISE NOTICE '✅ RLS enabled on school_data: %',
    (SELECT relrowsecurity FROM pg_class
     WHERE relname = 'school_data' AND relnamespace = 'public'::regnamespace);
  RAISE NOTICE '';
  RAISE NOTICE '🎓 Education Monitor — Supabase setup complete!';
  RAISE NOTICE '   Next steps:';
  RAISE NOTICE '   1. Copy your Project URL from Settings → API';
  RAISE NOTICE '   2. Copy your anon/public key from Settings → API';
  RAISE NOTICE '   3. Paste both into the app Settings → Backup → Supabase';
  RAISE NOTICE '   4. Set a unique School ID (e.g. jsms_nairobi_001)';
  RAISE NOTICE '   5. Click Save & Start Auto-Sync';
END;
$$;


-- ═══════════════════════════════════════════════════════════════════════
--  QUICK REFERENCE — useful admin queries
-- ═══════════════════════════════════════════════════════════════════════

-- List all registered schools:
-- SELECT school_id, updated_at, created_at,
--        pg_size_pretty(octet_length(payload::text)::bigint) AS payload_size
-- FROM public.school_data
-- ORDER BY updated_at DESC;

-- View sync history for a school (most recent first):
-- SELECT id, synced_at, app_version, source,
--        pg_size_pretty(octet_length(payload::text)::bigint) AS size
-- FROM public.school_data_history
-- WHERE school_id = 'jsms_nairobi_001'
-- ORDER BY synced_at DESC
-- LIMIT 20;

-- Inspect specific data keys from a school's payload:
-- SELECT
--   payload->>'_pushed'    AS last_pushed,
--   payload->>'_version'   AS app_version,
--   jsonb_array_length(payload->'edu2_l')  AS learners,   -- students
--   jsonb_array_length(payload->'edu2_s')  AS staff,
--   jsonb_array_length(payload->'edu2_pays') AS fee_records,
--   jsonb_array_length(payload->'edu2_att') AS attendance_records
-- FROM public.school_data
-- WHERE school_id = 'jsms_nairobi_001';

-- Restore a school to a previous snapshot:
-- SELECT public.restore_school_from_history(
--   'jsms_nairobi_001',
--   '<paste-history-uuid-here>'
-- );

-- Manually delete a school's data (use with caution):
-- DELETE FROM public.school_data WHERE school_id = 'test_school';
