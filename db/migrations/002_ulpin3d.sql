-- Migration 002 — 3D ULPIN, for a volume that already has data.
--
-- db/01_schema.sql is run by docker-entrypoint-initdb.d on a FRESH volume and
-- already contains everything below (see its "3D ULPIN" comments on parcel,
-- survey_parcel, building, floor, unit, utility, and the new air_rights_volume
-- / infra_parcel_link / ulpin_lineage tables). This file is for the other
-- case: an existing ulpin_pgdata volume you do not want to drop and re-seed.
-- It is additive and idempotent -- it never drops a table, a column or a row
-- -- and running it twice, or on a fresh volume, is a no-op.
--
--   docker exec -i ulpin-postgis psql -U ulpin -d ulpin -v ON_ERROR_STOP=1 \
--     -f - < db/migrations/002_ulpin3d.sql
--   docker exec -i ulpin-postgis psql -U ulpin -d ulpin -v ON_ERROR_STOP=1 \
--     -f - < db/02_functions.sql
--   -- then, per project:  SELECT * FROM ladm_backfill(<project_id>);
--
-- WHAT THIS REPLACES. The old `ulpin` column (AP-VSP-3D26-<parcel4>-<bldg3>-
-- <floor2>-<unit2>) is NOT dropped and NOT renamed. It is exposed under a
-- second name, `legacy_id`, via a GENERATED column -- so it can never drift
-- from `ulpin` by construction -- and a new `ulpin3d` column carries the true
-- vertical extension of the 14-digit ULPIN (Bhu-Aadhaar). Both exist side by
-- side so an already-printed deed's QR code, a bookmarked URL, and
-- flat-register.json's ULPIN-keyed entries all keep resolving through
-- `legacy_id` while the pipeline and the UI move to `ulpin3d`.
--
-- WHY ulpin3d STARTS NULL HERE. Unlike the old `ulpin`, it is
-- GEOMETRY-DERIVED (state + district + a geohash of the centroid) and cannot
-- be backfilled by a SQL UPDATE alone without reaching into every row's
-- geometry by hand. The intended path is: apply this migration, then re-run
-- `npm run seed` (or the SQL pipeline directly) for each project, which mints
-- ulpin3d/ulpin14 for every row via db/02_functions.sql's ulpin3d_fmt().
-- Until that re-seed, every reader falls back to `legacy_id` (see
-- ladm_backfill()'s id3() calls), so nothing regresses in the meantime.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------- parcel
ALTER TABLE parcel
  ADD COLUMN IF NOT EXISTS legacy_id text GENERATED ALWAYS AS (ulpin) STORED,
  ADD COLUMN IF NOT EXISTS ulpin3d text,
  ADD COLUMN IF NOT EXISTS ulpin14 text,
  ADD COLUMN IF NOT EXISTS ulpin14_source text NOT NULL DEFAULT 'synthetic',
  ADD COLUMN IF NOT EXISTS ulpin14_official text,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS retired_at timestamptz;

DO $$ BEGIN
  ALTER TABLE parcel ADD CONSTRAINT parcel_ulpin3d_uq UNIQUE (ulpin3d);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE parcel ADD CONSTRAINT parcel_ulpin14_uq UNIQUE (ulpin14);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE parcel ADD CONSTRAINT parcel_ulpin14_source_ck
    CHECK (ulpin14_source IN ('synthetic','official'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE parcel ADD CONSTRAINT parcel_status_ck CHECK (status IN ('active','retired'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------- survey_parcel
ALTER TABLE survey_parcel
  ADD COLUMN IF NOT EXISTS ulpin3d text,
  ADD COLUMN IF NOT EXISTS ulpin14 text,
  ADD COLUMN IF NOT EXISTS ulpin14_source text NOT NULL DEFAULT 'synthetic';
DO $$ BEGIN
  ALTER TABLE survey_parcel ADD CONSTRAINT survey_parcel_ulpin3d_uq UNIQUE (ulpin3d);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE survey_parcel ADD CONSTRAINT survey_parcel_ulpin14_uq UNIQUE (ulpin14);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE survey_parcel ADD CONSTRAINT survey_parcel_ulpin14_source_ck
    CHECK (ulpin14_source IN ('synthetic','official'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------- building
ALTER TABLE building
  ADD COLUMN IF NOT EXISTS legacy_id text GENERATED ALWAYS AS (ulpin) STORED,
  ADD COLUMN IF NOT EXISTS ulpin3d text,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS retired_at timestamptz;
DO $$ BEGIN
  ALTER TABLE building ADD CONSTRAINT building_ulpin3d_uq UNIQUE (ulpin3d);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE building ADD CONSTRAINT building_status_ck CHECK (status IN ('active','retired'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------------------------------------------ floor
ALTER TABLE floor
  ADD COLUMN IF NOT EXISTS legacy_id text GENERATED ALWAYS AS (ulpin) STORED,
  ADD COLUMN IF NOT EXISTS ulpin3d text,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS retired_at timestamptz,
  ADD COLUMN IF NOT EXISTS vertical_datum text NOT NULL DEFAULT 'placeholder';
DO $$ BEGIN
  ALTER TABLE floor ADD CONSTRAINT floor_ulpin3d_uq UNIQUE (ulpin3d);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE floor ADD CONSTRAINT floor_status_ck CHECK (status IN ('active','retired'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------------------------------------------- unit
ALTER TABLE unit
  ADD COLUMN IF NOT EXISTS legacy_id text GENERATED ALWAYS AS (ulpin) STORED,
  ADD COLUMN IF NOT EXISTS ulpin3d text,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS retired_at timestamptz,
  ADD COLUMN IF NOT EXISTS vertical_datum text NOT NULL DEFAULT 'placeholder';
DO $$ BEGIN
  ALTER TABLE unit ADD CONSTRAINT unit_ulpin3d_uq UNIQUE (ulpin3d);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE unit ADD CONSTRAINT unit_status_ck CHECK (status IN ('active','retired'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------- utility
ALTER TABLE utility
  ADD COLUMN IF NOT EXISTS vertical_datum text NOT NULL DEFAULT 'placeholder',
  ADD COLUMN IF NOT EXISTS infra_id text,
  ADD COLUMN IF NOT EXISTS infra_type text,
  ADD COLUMN IF NOT EXISTS infra_serial int;
DO $$ BEGIN
  ALTER TABLE utility ADD CONSTRAINT utility_infra_id_uq UNIQUE (infra_id);
EXCEPTION WHEN duplicate_table THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE utility ADD CONSTRAINT utility_infra_type_ck
    CHECK (infra_type IN ('SWR','WTR','GAS','ELC','TEL','MTR','ELV'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Widen asset_type to add 'gas'. CHECK constraints cannot be ADD IF NOT
-- EXISTS, so this drops and recreates it -- the same discipline
-- db/02_functions.sql already uses for ulpin_fmt()'s signature change. Never
-- destructive: dropping a CHECK cannot lose a row, and the new CHECK is a
-- superset of the old one.
ALTER TABLE utility DROP CONSTRAINT IF EXISTS utility_asset_type_check;
ALTER TABLE utility ADD CONSTRAINT utility_asset_type_check
  CHECK (asset_type IN ('water','sewer','power','metro','telecom','drainage',
                        'foundation','gas'));

-- ----------------------------------------------------- air_rights_volume
CREATE TABLE IF NOT EXISTS air_rights_volume (
  id             integer PRIMARY KEY,
  project_id     integer NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  parcel_id      integer NOT NULL REFERENCES parcel(id) ON DELETE CASCADE,
  index_no       int NOT NULL CHECK (index_no BETWEEN 1 AND 9),
  z_min          double precision NOT NULL,
  z_max          double precision NOT NULL,
  vertical_datum text NOT NULL DEFAULT 'placeholder',
  ulpin3d        text UNIQUE NOT NULL,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  retired_at     timestamptz,
  provenance     text NOT NULL DEFAULT 'estimated'
                 CHECK (provenance IN ('surveyed','derived','estimated')),
  note           text,
  UNIQUE (parcel_id, index_no)
);

-- ----------------------------------------------------- infra_parcel_link
CREATE TABLE IF NOT EXISTS infra_parcel_link (
  id             serial PRIMARY KEY,
  infra_id       text NOT NULL,
  ulpin14        text NOT NULL,
  rrr_type       text NOT NULL CHECK (rrr_type IN ('easement','restriction')),
  z_min          double precision NOT NULL,
  z_max          double precision NOT NULL,
  vertical_datum text NOT NULL DEFAULT 'placeholder',
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (infra_id, ulpin14)
);

-- ------------------------------------------------------------ ulpin_lineage
CREATE TABLE IF NOT EXISTS ulpin_lineage (
  id         serial PRIMARY KEY,
  project_id integer REFERENCES projects(id) ON DELETE CASCADE,
  parent_id  text NOT NULL,
  child_id   text NOT NULL,
  event      text NOT NULL CHECK (event IN ('split','merge','renumber')),
  event_date timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS air_rights_project_ix   ON air_rights_volume (project_id);
CREATE INDEX IF NOT EXISTS air_rights_parcel_ix    ON air_rights_volume (parcel_id);
CREATE INDEX IF NOT EXISTS infra_link_infra_ix     ON infra_parcel_link (infra_id);
CREATE INDEX IF NOT EXISTS infra_link_ulpin14_ix   ON infra_parcel_link (ulpin14);
CREATE INDEX IF NOT EXISTS ulpin_lineage_parent_ix ON ulpin_lineage (parent_id);
CREATE INDEX IF NOT EXISTS ulpin_lineage_child_ix  ON ulpin_lineage (child_id);

-- ---------------------------------------------------- la_spatial_unit widen
-- Add 'air_rights' to source_kind. Same drop-then-recreate CHECK discipline
-- as utility.asset_type above; a no-op if this volume has never had the
-- LADM tables (007) applied yet -- in that case this block simply does
-- nothing, since la_spatial_unit does not exist.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'la_spatial_unit') THEN
    ALTER TABLE la_spatial_unit DROP CONSTRAINT IF EXISTS la_spatial_unit_source_kind_check;
    ALTER TABLE la_spatial_unit ADD CONSTRAINT la_spatial_unit_source_kind_check
      CHECK (source_kind IN ('parcel','survey_parcel','unit','utility','air_rights'));
  END IF;
END
$$;

COMMIT;

-- la_spatial_unit_v (the view joining air_rights_volume's geometry back on)
-- and ladm_backfill() (which now inserts air_rights + infra_parcel_link rows,
-- and prefers ulpin3d via id3()) are NOT redefined here -- they live in
-- db/01_schema.sql (the view, CREATE OR REPLACE) and db/02_functions.sql
-- respectively, both of which are safe to re-apply. Apply
-- db/02_functions.sql after this migration; the view is redefined by
-- re-running the `CREATE OR REPLACE VIEW la_spatial_unit_v` statement at the
-- foot of db/01_schema.sql, which is idempotent by construction.

\echo '--- migration 002_ulpin3d applied ---'
SELECT p.slug,
       (SELECT count(*) FROM parcel  WHERE project_id = p.id AND ulpin3d IS NOT NULL) AS parcels_minted,
       (SELECT count(*) FROM parcel  WHERE project_id = p.id) AS parcels_total,
       (SELECT count(*) FROM air_rights_volume WHERE project_id = p.id) AS air_rights_volumes
  FROM projects p ORDER BY p.id;
\echo 'Re-run npm run seed (or the SQL pipeline) per project to mint ulpin14/ulpin3d, then:'
\echo '  SELECT * FROM ladm_backfill(<project_id>);'
