-- One-off bridge: mint ulpin3d/ulpin14 for every EXISTING row of one project
-- on a live database, without a full re-seed (no DELETE/INSERT, only
-- UPDATE). Recovers each entity's building/floor/unit NUMBERS from its
-- existing legacy `ulpin` (the OSM pipeline already assigned these
-- correctly) and mints a ulpin14 from each PARCEL's actual centroid.
-- Mirrors scripts/backfill_ulpin3d_snapshot.mjs, in SQL, for the DB itself.
\set ON_ERROR_STOP on
\set project_slug 'siripuram'

BEGIN;

CREATE OR REPLACE FUNCTION _tmp_unit3d(old_ulpin text, p_ulpin14 text, p_bno int,
                                       p_level_kind text, p_level_n int)
RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  slot text;
  kind3d text;
  ordinal int;
BEGIN
  slot := substring(old_ulpin from '-([^-]+)$');
  IF slot IS NULL OR slot IN ('EV', 'ST', 'PL') THEN
    RETURN NULL; -- fabric core: no numbered slot in the new grammar
  ELSIF slot ~ '^P\d+$' THEN
    kind3d := 'parking'; ordinal := substring(slot from '\d+')::int;
  ELSIF slot ~ '^R\d+$' THEN
    kind3d := 'unit'; ordinal := substring(slot from '\d+')::int;
  ELSIF slot ~ '^C\d+$' THEN
    kind3d := 'common'; ordinal := substring(slot from '\d+')::int;
  ELSIF slot ~ '^\d+$' THEN
    kind3d := 'unit'; ordinal := slot::int;
  ELSE
    RETURN NULL;
  END IF;
  IF ordinal < 1 OR ordinal > 999 THEN RETURN NULL; END IF; -- e.g. a storey-numbered flat like '2004'
  RETURN ulpin3d_fmt(p_ulpin14, p_bno, p_level_kind, p_level_n, kind3d, ordinal);
END
$fn$;

-- 1. Parcels: ulpin14 from the parcel's own centroid.
UPDATE parcel p
   SET ulpin14 = ulpin3d_mint14(pr.state_code, pr.district_code,
                                ST_X(ST_Centroid(p.geom)), ST_Y(ST_Centroid(p.geom))),
       ulpin14_source = 'synthetic'
  FROM projects pr
 WHERE pr.id = p.project_id AND pr.slug = :'project_slug';

UPDATE parcel
   SET ulpin3d = ulpin3d_fmt(ulpin14)
 WHERE ulpin14 IS NOT NULL AND ulpin3d IS NULL
   AND project_id = (SELECT id FROM projects WHERE slug = :'project_slug');

-- 2. Buildings: building number is the trailing group of the legacy ulpin.
UPDATE building b
   SET ulpin3d = ulpin3d_fmt(p.ulpin14, substring(b.ulpin from '-(\d+)$')::int)
  FROM parcel p
 WHERE p.id = b.parcel_id AND p.ulpin14 IS NOT NULL AND b.ulpin3d IS NULL;

-- 3. Floors.
UPDATE floor f
   SET ulpin3d = ulpin3d_fmt(
         p.ulpin14, substring(b.ulpin from '-(\d+)$')::int,
         CASE WHEN f.level_no = 0 THEN 'ground' WHEN f.level_no > 0 THEN 'floor' ELSE 'basement' END,
         CASE WHEN f.level_no = 0 THEN NULL ELSE abs(f.level_no) END)
  FROM building b
  JOIN parcel p ON p.id = b.parcel_id
 WHERE f.building_id = b.id AND p.ulpin14 IS NOT NULL AND f.ulpin3d IS NULL;

-- 4. Units.
UPDATE unit u
   SET ulpin3d = _tmp_unit3d(
         u.ulpin, p.ulpin14, substring(b.ulpin from '-(\d+)$')::int,
         CASE WHEN f.level_no = 0 THEN 'ground' WHEN f.level_no > 0 THEN 'floor' ELSE 'basement' END,
         CASE WHEN f.level_no = 0 THEN NULL ELSE abs(f.level_no) END)
  FROM floor f
  JOIN building b ON b.id = f.building_id
  JOIN parcel p ON p.id = b.parcel_id
 WHERE u.floor_id = f.id AND p.ulpin14 IS NOT NULL AND u.ulpin3d IS NULL;

-- 5. Survey parcels: same treatment, own centroid.
UPDATE survey_parcel sp
   SET ulpin14 = ulpin3d_mint14(pr.state_code, pr.district_code,
                                ST_X(ST_Centroid(sp.geom)), ST_Y(ST_Centroid(sp.geom))),
       ulpin14_source = 'synthetic'
  FROM projects pr
 WHERE pr.id = sp.project_id AND pr.slug = :'project_slug' AND sp.ulpin14 IS NULL;

UPDATE survey_parcel
   SET ulpin3d = ulpin3d_fmt(ulpin14)
 WHERE ulpin14 IS NOT NULL AND ulpin3d IS NULL
   AND project_id = (SELECT id FROM projects WHERE slug = :'project_slug');

DROP FUNCTION _tmp_unit3d(text, text, int, text, int);

COMMIT;

\echo '--- backfill summary ---'
SELECT 'parcel' AS entity, count(*) FILTER (WHERE ulpin3d IS NOT NULL) AS minted, count(*) AS total
  FROM parcel WHERE project_id = (SELECT id FROM projects WHERE slug = :'project_slug')
UNION ALL
SELECT 'building', count(*) FILTER (WHERE ulpin3d IS NOT NULL), count(*)
  FROM building WHERE project_id = (SELECT id FROM projects WHERE slug = :'project_slug')
UNION ALL
SELECT 'floor', count(*) FILTER (WHERE f.ulpin3d IS NOT NULL), count(*)
  FROM floor f JOIN building b ON b.id = f.building_id
 WHERE b.project_id = (SELECT id FROM projects WHERE slug = :'project_slug')
UNION ALL
SELECT 'unit', count(*) FILTER (WHERE u.ulpin3d IS NOT NULL), count(*)
  FROM unit u JOIN floor f ON f.id = u.floor_id JOIN building b ON b.id = f.building_id
 WHERE b.project_id = (SELECT id FROM projects WHERE slug = :'project_slug');
