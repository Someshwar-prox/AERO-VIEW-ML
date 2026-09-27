-- Geometry + identifier helpers.
--
-- make_prism() builds a closed POLYHEDRALSURFACE Z by hand rather than calling
-- SFCGAL's ST_Extrude, so the pipeline still produces correct solids on a
-- PostGIS build without SFCGAL. SFCGAL is then only needed for ST_3DIntersects,
-- and even that has an exact fallback (see detect_conflicts below).

CREATE OR REPLACE FUNCTION make_prism(poly geometry, z0 double precision, z1 double precision)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  g     geometry;
  ring  geometry;
  n     int;
  i     int;
  xs    double precision[];
  ys    double precision[];
  faces text[] := '{}';
  face  text;
  srid  int;
BEGIN
  IF poly IS NULL THEN RETURN NULL; END IF;
  srid := ST_SRID(poly);
  g := ST_Force2D(poly);
  IF NOT ST_IsValid(g) THEN g := ST_MakeValid(g); END IF;

  -- MakeValid on a self-touching OSM ring can yield a collection; keep the
  -- largest polygon, which is the building the mapper actually drew.
  IF GeometryType(g) <> 'POLYGON' THEN
    SELECT d.geom INTO g
      FROM (SELECT (ST_Dump(g)).geom AS geom) d
     WHERE GeometryType(d.geom) = 'POLYGON'
     ORDER BY ST_Area(d.geom) DESC
     LIMIT 1;
  END IF;
  IF g IS NULL OR ST_IsEmpty(g) THEN RETURN NULL; END IF;

  ring := ST_ExteriorRing(ST_ForceRHR(g));
  n := ST_NPoints(ring);
  IF n < 4 THEN RETURN NULL; END IF;

  FOR i IN 1..n LOOP
    xs[i] := ST_X(ST_PointN(ring, i));
    ys[i] := ST_Y(ST_PointN(ring, i));
  END LOOP;

  -- floor face (as drawn)
  face := '';
  FOR i IN 1..n LOOP
    face := face || CASE WHEN i > 1 THEN ',' ELSE '' END
                 || xs[i] || ' ' || ys[i] || ' ' || z0;
  END LOOP;
  faces := array_append(faces, '((' || face || '))');

  -- ceiling face (reversed so the surface is consistently oriented outward)
  face := '';
  FOR i IN REVERSE n..1 LOOP
    face := face || CASE WHEN i < n THEN ',' ELSE '' END
                 || xs[i] || ' ' || ys[i] || ' ' || z1;
  END LOOP;
  faces := array_append(faces, '((' || face || '))');

  -- one quad per wall segment
  FOR i IN 1..(n - 1) LOOP
    faces := array_append(faces, '((' ||
        xs[i]     || ' ' || ys[i]     || ' ' || z0 || ',' ||
        xs[i + 1] || ' ' || ys[i + 1] || ' ' || z0 || ',' ||
        xs[i + 1] || ' ' || ys[i + 1] || ' ' || z1 || ',' ||
        xs[i]     || ' ' || ys[i]     || ' ' || z1 || ',' ||
        xs[i]     || ' ' || ys[i]     || ' ' || z0 || '))');
  END LOOP;

  RETURN ST_SetSRID(
           ST_GeomFromText('POLYHEDRALSURFACE Z(' || array_to_string(faces, ',') || ')'),
           srid);
END
$fn$;


-- ULPIN: <state>-<district>-<scheme>-<parcel4>-<bldg3>-<floor2>-<unit2>,
-- right-truncated. Floor codes: '00' ground, '01'..'99' above, 'B1'..'B9'
-- basements. Mirrored byte-for-byte in lib/ulpin.ts.
--
-- The revenue codes come from the project row (projects.state_code,
-- district_code, scheme_code) and are passed in by the caller. They DEFAULT to
-- AP/VSP/3D26, and that default is load-bearing rather than a convenience: a
-- call site that passes only (p, b, f, u) produces exactly the string it
-- produced when the prefix was a literal, which is what keeps every identifier
-- already minted for siripuram -- and every ULPIN in data/api/siripuram/ --
-- byte-identical across this signature change.
-- The four-argument version has to GO, not merely be replaced. CREATE OR
-- REPLACE only matches an identical signature, so on a volume that already has
-- the old function the new one is an OVERLOAD, and `ulpin_fmt(42)` then fails
-- with "function ulpin_fmt(integer) is not unique" -- every call site in
-- build_geometry.sql at once. Dropping first is what makes `npm run db:schema`
-- against an existing volume work rather than half-work.
DROP FUNCTION IF EXISTS ulpin_fmt(int, int, int, int);

CREATE OR REPLACE FUNCTION ulpin_fmt(p int, b int DEFAULT NULL,
                                     f int DEFAULT NULL, u int DEFAULT NULL,
                                     st text DEFAULT 'AP',
                                     di text DEFAULT 'VSP',
                                     sc text DEFAULT '3D26')
RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT st || '-' || di || '-' || sc || '-' || lpad(p::text, 4, '0')
    || CASE WHEN b IS NULL THEN '' ELSE '-' || lpad(b::text, 3, '0') END
    || CASE WHEN b IS NULL OR f IS NULL THEN ''
            WHEN f < 0 THEN '-B' || abs(f)::text
            ELSE '-' || lpad(f::text, 2, '0') END
    || CASE WHEN b IS NULL OR f IS NULL OR u IS NULL THEN ''
            ELSE '-' || lpad(u::text, 2, '0') END;
$fn$;


-- True when SFCGAL is available, i.e. ST_3DIntersects can take solids.
CREATE OR REPLACE FUNCTION has_sfcgal() RETURNS boolean
LANGUAGE plpgsql STABLE AS $fn$
BEGIN
  PERFORM 1 FROM pg_extension WHERE extname = 'postgis_sfcgal';
  RETURN FOUND;
END
$fn$;


-- Solid-vs-solid test. Uses SFCGAL's ST_3DIntersects when present; otherwise
-- falls back to (2D footprint intersect AND Z-range overlap), which is not an
-- approximation for our geometry -- every solid here is a vertical prism, so
-- the two tests are equivalent.
CREATE OR REPLACE FUNCTION solids_intersect(a geometry, az0 double precision, az1 double precision,
                                            b geometry, bz0 double precision, bz1 double precision)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $fn$
BEGIN
  IF has_sfcgal() THEN
    BEGIN
      -- ST_MakeSolid: without it these are open shells, not volumes.
      RETURN ST_3DIntersects(ST_MakeSolid(a), ST_MakeSolid(b));
    EXCEPTION WHEN OTHERS THEN
      -- fall through to the prism-exact test
    END;
  END IF;
  RETURN ST_Intersects(ST_Force2D(a), ST_Force2D(b))
         AND az0 <= bz1 AND bz0 <= az1;
END
$fn$;


-- ---------------------------------------------------------------------------
-- ULPIN with a TYPED unit slot.
--
-- ulpin_fmt() above takes an integer unit and pads it to two digits, which is
-- right for a flat and cannot express anything else. A level holds more than
-- flats -- parking bays, shops, an atrium, the lift and stair cores -- and the
-- slot says which by carrying a prefix: 'R01' a retail bay, 'P101' a parking
-- slot, 'C01' common space, 'EV' a lift shaft, 'ST' a staircase.
--
-- A SEPARATE FUNCTION, not a widened ulpin_fmt(). Every identifier already
-- minted came out of the four-argument form, and changing that signature again
-- would repeat the overload breakage the DROP above exists to prevent. This
-- one delegates to it for the prefix, so the two cannot drift.
--
-- Mirrors generate() + unitSlot() in lib/ulpin.ts; lib/ulpin.test.ts asserts
-- the pair against fixed expectations.
CREATE OR REPLACE FUNCTION ulpin_fmt_slot(p int, b int, f int, uslot text,
                                          st text DEFAULT 'AP',
                                          di text DEFAULT 'VSP',
                                          sc text DEFAULT '3D26')
RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN b IS NULL OR f IS NULL OR uslot IS NULL
      THEN ulpin_fmt(p, b, f, NULL, st, di, sc)
    ELSE ulpin_fmt(p, b, f, NULL, st, di, sc) || '-' || upper(uslot)
  END;
$fn$;


-- The slot a kind writes, e.g. ('retail', 1) -> 'R01', ('elevator', NULL) -> 'EV'.
-- Ordinals below 100 are padded to two digits; above that they are left alone,
-- so a flat numbered 2004 stays '2004' rather than being truncated by lpad().
CREATE OR REPLACE FUNCTION unit_slot(kind text, ordinal int DEFAULT NULL)
RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE kind
           WHEN 'flat' THEN ''
           WHEN 'retail' THEN 'R'  WHEN 'anchor' THEN 'R'
           WHEN 'parking' THEN 'P'
           WHEN 'circulation' THEN 'C' WHEN 'atrium' THEN 'C'
           WHEN 'elevator' THEN 'EV' WHEN 'stair' THEN 'ST'
           WHEN 'plant' THEN 'PL'
         END
      || CASE WHEN ordinal IS NULL THEN ''
              WHEN ordinal < 100 THEN lpad(ordinal::text, 2, '0')
              ELSE ordinal::text END;
$fn$;


-- The spatial-unit identifier for a utility run, which has no ULPIN of its
-- own: '<state>-<district>-<scheme>-UTL-<id>'.
--
-- STATED ONCE, here, because ladm_backfill() writes it in two places and
-- suIdForUtility() in lib/ladm.ts has to mint the identical string for the
-- snapshot backend. Three copies of a primary key is three chances to disagree.
--
-- The id is padded to five digits and LEFT ALONE above that. lpad() TRUNCATES
-- a longer string rather than passing it through -- unlike JavaScript's
-- padStart, which only pads up -- so a bare lpad(id, 5, '0') mapped utility
-- 100000 and utility 100001 both onto 'UTL-10000' and the second one violated
-- the primary key. This is the same trap unit_slot() above documents for
-- flat ordinals, and it is the same fix.
CREATE OR REPLACE FUNCTION ladm_utility_su_id(prefix text, id integer)
RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT prefix || '-UTL-'
      || CASE WHEN id < 100000 THEN lpad(id::text, 5, '0') ELSE id::text END;
$fn$;


-- The 2-D PLAN geometry of a spatial unit, whatever its source stores.
--
-- WHY THIS EXISTS AT ALL. GEOS and the geography type both refuse a
-- POLYHEDRALSURFACE outright -- "Unknown geometry type: 13" from ST_Intersects,
-- "Geography type does not support PolyhedralSurface" from a ::geography cast
-- -- and ST_Force2D does NOT help, because the 2-D projection of a polyhedral
-- surface is still a polyhedral surface. Every solid this schema stores is a
-- vertical prism built by make_prism(), whose FIRST face is the floor plate, so
-- taking that face is an exact plan footprint rather than an approximation.
--
-- Stated once, here, because three callers need it and each of them failed
-- differently when they did it themselves: the ring on the LADM document, the
-- easement predicate in lib/db.ts, and the same predicate in
-- scripts/05_export_static.py. The two predicates failed only for a 2-D
-- surface plot -- on a volume the z-range test happened to prune every
-- candidate before the geometry was touched -- which is exactly the kind of
-- planner-order accident that reaches production.
CREATE OR REPLACE FUNCTION ladm_plan_geom(g geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
           WHEN g IS NULL THEN NULL
           WHEN GeometryType(g) = 'POLYHEDRALSURFACE'
             THEN ST_Force2D(ST_GeometryN(g, 1))
           ELSE ST_Force2D(g)
         END;
$fn$;


-- ---------------------------------------------------------- ladm_backfill
-- Project one project's cadastre into the LADM classes.
--
-- SAFE TO RE-RUN, and re-running is how the projection is refreshed after a
-- re-seed. It deletes this project's LADM rows and rebuilds them; it never
-- touches another project's, and it never touches the cadastre it reads.
--
-- IT INVENTS NOTHING. Every party is a name already written on a row, every
-- right is a tenure or encumbrance string already stored, every share is 1/1
-- unless the cadastre says otherwise. Where the register is silent -- a
-- staircase with no holder, a flat whose owner column is NULL -- the
-- projection is silent too, and the panel prints nothing rather than a
-- plausible blank. That is the same rule lib/deed/certificate.ts states for
-- the deed, applied one layer down.
--
-- WHY IT IS A FUNCTION AND NOT A SEED SCRIPT. It reads only from tables, so
-- it works identically after the Python pipeline, after seed_demo_building.mjs
-- and after seed_dutt_retail.mjs, none of which know about each other.
CREATE OR REPLACE FUNCTION ladm_backfill(p_project_id integer)
RETURNS TABLE (parties bigint, spatial_units bigint, ba_units bigint, rrrs bigint)
LANGUAGE plpgsql AS $$
DECLARE
  v_prefix text;
BEGIN
  SELECT state_code || '-' || district_code || '-' || scheme_code
    INTO v_prefix
    FROM projects WHERE id = p_project_id;
  IF v_prefix IS NULL THEN
    RAISE EXCEPTION 'ladm_backfill: no project with id %', p_project_id;
  END IF;

  -- Cascades take la_ba_unit_member and la_rrr with them.
  DELETE FROM la_ba_unit      WHERE project_id = p_project_id;
  DELETE FROM la_spatial_unit WHERE project_id = p_project_id;
  DELETE FROM la_party        WHERE project_id = p_project_id;

  -- ------------------------------------------------------------- parties
  -- Title holders, from the two columns that carry a name.
  INSERT INTO la_party (project_id, name, party_type, role)
  SELECT DISTINCT p_project_id, t.name, 'natural_person', 'owner'
    FROM (
      SELECT p.owner AS name FROM parcel p
       WHERE p.project_id = p_project_id AND p.owner IS NOT NULL AND p.owner <> ''
      UNION
      SELECT u.owner FROM unit u
       JOIN floor f ON f.id = u.floor_id
       JOIN building b ON b.id = f.building_id
       WHERE b.project_id = p_project_id AND u.owner IS NOT NULL AND u.owner <> ''
    ) t
  ON CONFLICT (project_id, name, role) DO NOTHING;

  -- Utility operators. `authority` is an organisation, never a person, which
  -- is why the party_type differs from the block above rather than being
  -- guessed from the shape of the string.
  INSERT INTO la_party (project_id, name, party_type, role, authority_code)
  SELECT DISTINCT p_project_id, u.authority, 'non_natural_person', 'utility_operator',
         CASE
           WHEN u.authority LIKE 'GVMC%'    THEN 'GVMC'
           WHEN u.authority LIKE 'APEPDCL%' THEN 'APEPDCL'
           ELSE NULL
         END
    FROM utility u
   WHERE u.project_id = p_project_id AND u.authority IS NOT NULL AND u.authority <> ''
  ON CONFLICT (project_id, name, role) DO NOTHING;

  -- Banks named in an encumbrance. The two seeders write 'Mortgage - SBI'
  -- and 'Mortgage · HDFC Bank'; both separators are split here so that a
  -- charge resolves to a party rather than staying a sentence. An
  -- encumbrance that names no bank ('Lien - municipal dues') matches
  -- nothing and correctly produces no party.
  INSERT INTO la_party (project_id, name, party_type, role)
  SELECT DISTINCT p_project_id,
         btrim(regexp_replace(u.encumbrance, '^Mortgage\s*[-·]\s*', '')),
         'non_natural_person', 'bank'
    FROM unit u
    JOIN floor f ON f.id = u.floor_id
    JOIN building b ON b.id = f.building_id
   WHERE b.project_id = p_project_id
     AND u.encumbrance ~ '^Mortgage\s*[-·]\s*\S'
  ON CONFLICT (project_id, name, role) DO NOTHING;

  -- ------------------------------------------------------- spatial units
  -- Surface: the curtilage parcels, which carry a real ULPIN. 2D, because
  -- parcel.geom is a Polygon with no Z -- a plot's vertical extent is not
  -- recorded here, and writing 0 would be a claim that it has none.
  --
  -- COALESCE(p.ulpin3d, p.ulpin): a re-seeded project mints ulpin3d and this
  -- picks it up automatically; a volume not yet re-seeded still has NULL
  -- ulpin3d and this falls back to the legacy identifier exactly as before.
  INSERT INTO la_spatial_unit
    (su_id, project_id, source_kind, source_id, su_type, dimension, provenance)
  SELECT COALESCE(p.ulpin3d, p.ulpin), p_project_id, 'parcel', p.id, 'surface', '2D', 'derived'
    FROM parcel p WHERE p.project_id = p_project_id;

  -- Surface, from the survey layer -- ONLY where a real survey record was
  -- imported and carries the official 14-digit identifier. The 'derived'
  -- rows scripts/survey_parcels.sql generates are Voronoi shares of a block,
  -- have no survey number, and minting an su_id for them would dress a
  -- derivation up as a register entry.
  INSERT INTO la_spatial_unit
    (su_id, project_id, source_kind, source_id, su_type, dimension, provenance)
  SELECT sp.ulpin_14, p_project_id, 'survey_parcel', sp.id, 'surface', '2D', 'surveyed'
    FROM survey_parcel sp
   WHERE sp.project_id = p_project_id
     AND sp.provenance = 'survey_dept'
     AND sp.ulpin_14 IS NOT NULL
  ON CONFLICT (su_id) DO NOTHING;

  -- Multi-storey: every volume in `unit` -- flats, shops, parking bays, and
  -- the circulation and structural cores too. A lift shaft is a spatial unit
  -- that nobody holds, which LADM expresses precisely; leaving it out would
  -- make the volumes of a building fail to add up.
  INSERT INTO la_spatial_unit
    (su_id, project_id, source_kind, source_id, su_type, dimension,
     z_min, z_max, volume_m3, provenance)
  SELECT COALESCE(u.ulpin3d, u.ulpin), p_project_id, 'unit', u.id, 'multi_storey', '3D',
         u.z_min, u.z_max,
         -- Built area times clear height: the same figure the deed prints.
         u.built_m2 * (u.z_max - u.z_min),
         CASE f.detect_source
           WHEN 'surveyed_plan' THEN 'surveyed'
           WHEN 'osm_tag'       THEN 'derived'
           ELSE 'estimated'
         END
    FROM unit u
    JOIN floor f ON f.id = u.floor_id
    JOIN building b ON b.id = f.building_id
   WHERE b.project_id = p_project_id;

  -- Subterranean: utility corridors. No ULPIN exists for these, so the
  -- identifier is namespaced under the same revenue prefix -- see
  -- suIdForUtility() in lib/ladm.ts, which mints the identical string.
  --
  -- z comes from depth_m +/- radius_m against the building ground the run is
  -- hung off, or against the project's own reference where it is a street
  -- run. A run above ground (a riser, depth_m >= 0) is still registered:
  -- 'subterranean' names the corridor class, not the sign of its z.
  INSERT INTO la_spatial_unit
    (su_id, project_id, source_kind, source_id, su_type, dimension,
     z_min, z_max, volume_m3, provenance)
  SELECT ladm_utility_su_id(v_prefix, u.id),
         p_project_id, 'utility', u.id, 'subterranean', '3D',
         ST_ZMin(u.geom_3d) - u.radius_m,
         ST_ZMax(u.geom_3d) + u.radius_m,
         -- A cylinder along the centreline: pi r^2 L. ST_Length on a
         -- geography gives metres on the ellipsoid, which is what the run
         -- actually measures; ST_Length on the 4326 geometry would give
         -- degrees.
         pi() * u.radius_m * u.radius_m
           * ST_Length(ST_Force2D(u.geom_3d)::geography),
         CASE u.provenance
           WHEN 'surveyed' THEN 'surveyed'
           WHEN 'demonstration' THEN 'derived'
           ELSE 'estimated'
         END
    FROM utility u WHERE u.project_id = p_project_id;

  -- Air-rights volumes: attached to the parcel directly (no building), per
  -- the 3D-ULPIN grammar's own X-level branch. Demonstration envelopes only
  -- (see scripts/build_geometry.sql) -- provenance stays 'estimated' unless a
  -- real permitted-envelope calculation is ever supplied.
  INSERT INTO la_spatial_unit
    (su_id, project_id, source_kind, source_id, su_type, dimension,
     z_min, z_max, provenance)
  SELECT a.ulpin3d, p_project_id, 'air_rights', a.id, 'air_rights', '3D',
         a.z_min, a.z_max, a.provenance
    FROM air_rights_volume a WHERE a.project_id = p_project_id
  ON CONFLICT (source_kind, source_id) DO NOTHING;

  -- ------------------------------------------------------------ BA units
  -- One BA unit per titled volume, named for the volume itself.
  --
  -- A CONDOMINIUM UNIT, in LADM's sense: a flat or a shop is held absolutely,
  -- and the ground under it is held in common with every other holder in the
  -- building. That is why the flat is the `principal` member and the parcel
  -- joins as an `undivided_share` below rather than as a second holding.
  --
  -- Untitled volumes -- stairs, lifts, plant, atria, circulation, and parking
  -- bays, which are appurtenant rather than separately titled -- get NO BA
  -- unit of their own. They are spatial units held by nobody, and inventing
  -- an administrative record for a staircase would put a holder where the
  -- register has none.
  INSERT INTO la_ba_unit (project_id, ba_ulpin, name, ba_type)
  SELECT p_project_id, id3(u.ulpin3d, u.ulpin) || '-BA',
         COALESCE(u.label, initcap(u.kind) || ' ' || u.unit_no),
         'condominium_unit'
    FROM unit u
    JOIN floor f ON f.id = u.floor_id
    JOIN building b ON b.id = f.building_id
   WHERE b.project_id = p_project_id
     AND u.kind IN ('flat','retail','anchor')
     AND u.owner IS NOT NULL AND u.owner <> '';

  -- The titled volume itself.
  INSERT INTO la_ba_unit_member (ba_unit_id, su_id, member_role, share_num, share_den)
  SELECT ba.ba_unit_id, id3(u.ulpin3d, u.ulpin), 'principal', 1, 1
    FROM la_ba_unit ba
    JOIN unit u ON id3(u.ulpin3d, u.ulpin) || '-BA' = ba.ba_ulpin
   WHERE ba.project_id = p_project_id;

  -- One BA unit per surface plot that names a holder.
  --
  -- `parcel.owner` is NOT NULL, so in practice this is every plot. A plot is a
  -- holding in its own right -- the flats above it hold an undivided SHARE of
  -- it, which is a different thing and is recorded as a share below -- and
  -- without this a citizen selecting a surface plot would see a spatial unit
  -- with no legal unit behind it, which would read as "unregistered" rather
  -- than "held by the person the cadastre names".
  --
  -- 'basic_administrative_unit', not 'condominium_unit': the ground is held
  -- whole. Only the volumes stacked on it are condominium units.
  INSERT INTO la_ba_unit (project_id, ba_ulpin, name, ba_type)
  SELECT p_project_id, id3(p.ulpin3d, p.ulpin) || '-BA',
         'Plot ' || id3(p.ulpin3d, p.ulpin), 'basic_administrative_unit'
    FROM parcel p
   WHERE p.project_id = p_project_id AND p.owner IS NOT NULL AND p.owner <> '';

  INSERT INTO la_ba_unit_member (ba_unit_id, su_id, member_role, share_num, share_den)
  SELECT ba.ba_unit_id, id3(p.ulpin3d, p.ulpin), 'principal', 1, 1
    FROM la_ba_unit ba
    JOIN parcel p ON id3(p.ulpin3d, p.ulpin) || '-BA' = ba.ba_ulpin
   WHERE ba.project_id = p_project_id;

  -- One BA unit per utility corridor.
  --
  -- A run is not owned, it is EASED: the operator holds a right to occupy a
  -- corridor through ground somebody else holds. LADM has no way to say that
  -- without a BA unit to hang the easement on, so each run gets one, named for
  -- the asset rather than for a plot.
  INSERT INTO la_ba_unit (project_id, ba_ulpin, name, ba_type)
  SELECT p_project_id,
         ladm_utility_su_id(v_prefix, u.id) || '-BA',
         initcap(u.asset_type) || ' corridor ' || COALESCE(u.ref, u.id::text),
         'basic_administrative_unit'
    FROM utility u WHERE u.project_id = p_project_id;

  INSERT INTO la_ba_unit_member (ba_unit_id, su_id, member_role, share_num, share_den)
  SELECT ba.ba_unit_id, s.su_id, 'principal', 1, 1
    FROM la_ba_unit ba
    JOIN la_spatial_unit s ON s.su_id || '-BA' = ba.ba_ulpin
                          AND s.source_kind = 'utility'
   WHERE ba.project_id = p_project_id;

  -- The parking bay on the same title.
  --
  -- MATCHED BY OWNER WITHIN A BUILDING, which is the only link the cadastre
  -- actually records -- there is no allocation table. A bay whose owner
  -- column is NULL (every bay the demo seeder writes, deliberately) joins to
  -- nothing and is left as an unattached spatial unit, which is the honest
  -- answer: the register does not say whose it is.
  INSERT INTO la_ba_unit_member (ba_unit_id, su_id, member_role, share_num, share_den)
  SELECT DISTINCT ba.ba_unit_id, id3(pu.ulpin3d, pu.ulpin), 'appurtenant', 1, 1
    FROM la_ba_unit ba
    JOIN unit u   ON id3(u.ulpin3d, u.ulpin) || '-BA' = ba.ba_ulpin
    JOIN floor f  ON f.id = u.floor_id
    JOIN unit pu  ON pu.kind = 'parking' AND pu.owner = u.owner
    JOIN floor pf ON pf.id = pu.floor_id AND pf.building_id = f.building_id
   WHERE ba.project_id = p_project_id
  ON CONFLICT DO NOTHING;

  -- The undivided share of the ground.
  --
  -- The denominator is the number of titled volumes in the building, so the
  -- shares of one building's flats sum to exactly 1. This is a DERIVATION,
  -- not a register entry -- no deed in this database states a share -- and
  -- the API and the panel mark it as such. It is here rather than in
  -- TypeScript so that "what fraction of the plot does this flat carry" is
  -- one join for every consumer.
  INSERT INTO la_ba_unit_member (ba_unit_id, su_id, member_role, share_num, share_den)
  SELECT ba.ba_unit_id, id3(p.ulpin3d, p.ulpin), 'undivided_share', 1, cnt.n
    FROM la_ba_unit ba
    JOIN unit u    ON id3(u.ulpin3d, u.ulpin) || '-BA' = ba.ba_ulpin
    JOIN floor f   ON f.id = u.floor_id
    JOIN building b ON b.id = f.building_id
    JOIN parcel p  ON p.id = b.parcel_id
    JOIN LATERAL (
      SELECT count(*)::int AS n
        FROM unit u2
        JOIN floor f2 ON f2.id = u2.floor_id
       WHERE f2.building_id = b.id
         AND u2.kind IN ('flat','retail','anchor')
         AND u2.owner IS NOT NULL AND u2.owner <> ''
    ) cnt ON true
   WHERE ba.project_id = p_project_id AND cnt.n > 0
  ON CONFLICT DO NOTHING;

  -- ---------------------------------------------------------------- RRRs
  -- Ownership, from unit.owner and unit.tenure.
  INSERT INTO la_rrr (ba_unit_id, party_id, rrr_class, rrr_type, description)
  SELECT ba.ba_unit_id, pa.party_id, 'right', 'ownership', u.tenure
    FROM la_ba_unit ba
    JOIN unit u ON id3(u.ulpin3d, u.ulpin) || '-BA' = ba.ba_ulpin
    JOIN la_party pa ON pa.project_id = p_project_id
                    AND pa.name = u.owner AND pa.role = 'owner'
   WHERE ba.project_id = p_project_id;

  -- Ownership of a surface plot, from parcel.owner. No tenure column exists on
  -- `parcel`, so the description is left NULL rather than filled with the
  -- commonest value found on the flats above it.
  INSERT INTO la_rrr (ba_unit_id, party_id, rrr_class, rrr_type)
  SELECT ba.ba_unit_id, pa.party_id, 'right', 'ownership'
    FROM la_ba_unit ba
    JOIN parcel p ON id3(p.ulpin3d, p.ulpin) || '-BA' = ba.ba_ulpin
    JOIN la_party pa ON pa.project_id = p_project_id
                    AND pa.name = p.owner AND pa.role = 'owner'
   WHERE ba.project_id = p_project_id;

  -- The operator's easement over a utility corridor.
  --
  -- A RIGHT, not a restriction, from the operator's side: it is the operator
  -- who holds it. The matching burden on the plots it crosses is a
  -- restriction, and it is NOT recorded here -- which plots a run burdens is a
  -- spatial question this projection would have to answer with a join it
  -- cannot keep current, so the API resolves it per request instead (see
  -- getLadmEasementsFor in lib/db.ts) and says so.
  INSERT INTO la_rrr (ba_unit_id, party_id, rrr_class, rrr_type, description)
  SELECT ba.ba_unit_id, pa.party_id, 'right', 'easement',
         initcap(u.asset_type) || ' corridor, '
           || abs(u.depth_m)::numeric(6,2)
           || CASE WHEN u.depth_m < 0 THEN ' m below ground' ELSE ' m above ground' END
           || ', radius ' || u.radius_m::numeric(6,2) || ' m'
    FROM la_ba_unit ba
    JOIN la_spatial_unit s ON s.su_id || '-BA' = ba.ba_ulpin AND s.source_kind = 'utility'
    JOIN utility u ON u.id = s.source_id
    LEFT JOIN la_party pa ON pa.project_id = p_project_id
                         AND pa.name = u.authority AND pa.role = 'utility_operator'
   WHERE ba.project_id = p_project_id;

  -- A charge, where the encumbrance names a bank.
  INSERT INTO la_rrr (ba_unit_id, party_id, rrr_class, rrr_type, description)
  SELECT ba.ba_unit_id, pa.party_id, 'restriction', 'mortgage', u.encumbrance
    FROM la_ba_unit ba
    JOIN unit u ON id3(u.ulpin3d, u.ulpin) || '-BA' = ba.ba_ulpin
    LEFT JOIN la_party pa ON pa.project_id = p_project_id
                         AND pa.role = 'bank'
                         AND pa.name = btrim(regexp_replace(u.encumbrance, '^Mortgage\s*[-·]\s*', ''))
   WHERE ba.project_id = p_project_id
     AND u.encumbrance ~ '^Mortgage\s*[-·]';

  -- Any other encumbrance -- a lien, a pending suit -- as a restriction with
  -- no holder, because the string names a condition rather than a party.
  INSERT INTO la_rrr (ba_unit_id, rrr_class, rrr_type, description)
  SELECT ba.ba_unit_id, 'restriction', 'structural_restriction', u.encumbrance
    FROM la_ba_unit ba
    JOIN unit u ON id3(u.ulpin3d, u.ulpin) || '-BA' = ba.ba_ulpin
   WHERE ba.project_id = p_project_id
     AND u.encumbrance IS NOT NULL
     AND u.encumbrance <> 'None'
     AND u.encumbrance !~ '^Mortgage\s*[-·]';

  -- The burden side of a cross-parcel infrastructure easement -- the parcel
  -- is crossed under or over, and that is a restriction on ITS BA unit, not a
  -- right of the operator's (which is recorded above, against the utility's
  -- own BA unit). Only where the parcel names an owner: an unowned parcel has
  -- no administrative record here to burden. 'easement' names an underground
  -- crossing; an elevated/overhead one is recorded as a height restriction,
  -- since the parcel's owner is not burdened with occupying ground so much as
  -- with what they may build into the air above it.
  INSERT INTO la_rrr (ba_unit_id, party_id, rrr_class, rrr_type, description)
  SELECT ba.ba_unit_id, pa.party_id, 'restriction',
         CASE WHEN l.rrr_type = 'easement' THEN 'easement' ELSE 'height_restriction' END,
         'Infrastructure ' || l.infra_id || ', z ' || l.z_min::numeric(6,2)
           || ' to ' || l.z_max::numeric(6,2) || ' m (' || l.vertical_datum || ')'
    FROM infra_parcel_link l
    JOIN parcel p ON p.project_id = p_project_id AND p.ulpin14 = l.ulpin14
    JOIN la_ba_unit ba ON ba.ba_ulpin = id3(p.ulpin3d, p.ulpin) || '-BA'
                      AND ba.project_id = p_project_id
    LEFT JOIN utility u ON u.infra_id = l.infra_id AND u.project_id = p_project_id
    LEFT JOIN la_party pa ON pa.project_id = p_project_id
                         AND pa.name = u.authority AND pa.role = 'utility_operator';

  RETURN QUERY
    SELECT (SELECT count(*) FROM la_party        WHERE project_id = p_project_id),
           (SELECT count(*) FROM la_spatial_unit WHERE project_id = p_project_id),
           (SELECT count(*) FROM la_ba_unit      WHERE project_id = p_project_id),
           (SELECT count(*) FROM la_rrr r JOIN la_ba_unit ba USING (ba_unit_id)
             WHERE ba.project_id = p_project_id);
END
$$;


-- ===========================================================================
-- 3D ULPIN -- a true vertical extension of the 14-digit ULPIN (Bhu-Aadhaar).
--
--     <ULPIN14>[-B<bb>][-<LEVEL>][-<UNIT>]-<CHK>
--     e.g.  TSHY4K7Q2M9RXP-B01-F05-012-Q
--
-- Sits ALONGSIDE ulpin_fmt()/ulpin_fmt_slot() above, which are untouched: every
-- row keeps its old `ulpin` (exposed as `legacy_id`, see migration 002) and
-- gains a new `ulpin3d`. Mirrored byte-for-byte in lib/ulpin.ts -- the pairing
-- discipline this file has used since ulpin_fmt() itself.
-- ===========================================================================

-- Two-letter shorthand for a project's district code: 'VSP' -> 'VS'. Mirrors
-- district2() in lib/ulpin.ts. Used both in ulpin14 and in infra_fmt(), so
-- 'INF-AP-VS-...' and a Visakhapatnam parcel's ulpin14 agree on what "VS" is.
CREATE OR REPLACE FUNCTION ulpin3d_district2(di text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT upper(left(btrim(di), 2));
$fn$;


-- The identifier a row is addressed by: its new ulpin3d where one has been
-- minted, its legacy ulpin otherwise. Used everywhere ladm_backfill() mints or
-- joins an su_id/ba_ulpin from a parcel or unit row, so a project re-seeded
-- under the 3D scheme picks it up automatically and one not yet re-seeded
-- keeps behaving exactly as before.
CREATE OR REPLACE FUNCTION id3(new_id text, old_id text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT COALESCE(new_id, old_id);
$fn$;


-- Mint a synthetic ULPIN14 from a parcel centroid: 2-char state + 2-char
-- district + a 10-character geohash of (lon, lat), uppercased. PostGIS's own
-- ST_GeoHash is the reference implementation; lib/ulpin.ts's geohash()
-- reimplements the same (unmodified) geohash.org algorithm so the two agree
-- without either side reinventing the bit-interleave by hand.
CREATE OR REPLACE FUNCTION ulpin3d_mint14(st text, di text,
                                          lon double precision, lat double precision)
RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT upper(btrim(st)) || ulpin3d_district2(di)
      || upper(ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 10));
$fn$;


-- ISO 7064 MOD 37,36 (pure system) check character over an uppercase
-- alphanumeric body with separators already stripped. Identical algorithm to
-- checkChar3736() in lib/ulpin.ts -- see that function's comment for why the
-- iterated "add, then multiply by the radix" step guarantees detection of
-- every single-character substitution and adjacent transposition.
CREATE OR REPLACE FUNCTION ulpin3d_check(body text) RETURNS char(1)
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  alphabet       text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  check_alphabet text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ*';
  m int := 37;
  r int := 36;
  p int := 37;
  i int;
  v int;
  check_value int;
BEGIN
  FOR i IN 1..length(body) LOOP
    v := position(upper(substr(body, i, 1)) IN alphabet) - 1;
    IF v < 0 THEN
      RAISE EXCEPTION 'ulpin3d_check: invalid character % in %', substr(body, i, 1), body;
    END IF;
    p := (p + v) % m;
    IF p = 0 THEN p := m; END IF;
    p := (p * r) % m;
    IF p = 0 THEN p := m; END IF;
  END LOOP;
  check_value := (m + 1 - p) % m;
  IF check_value = 0 THEN check_value := m; END IF;
  RETURN substr(check_alphabet, check_value, 1);
END
$fn$;


-- Build a full 3D ULPIN body + check character.
--
-- level_kind is one of 'ground','floor','basement','air_rights', matching
-- lib/ulpin.ts's Ulpin3DLevel['kind']. An air-rights level attaches directly
-- to the parcel and carries NO building segment -- the brief's own example is
-- 'TSHY4K7Q2M9RXP-X01-8', not '...-B01-X01-...' -- so `building` is ignored
-- whenever level_kind = 'air_rights'.
--
-- unit_kind is one of 'unit','parking','common', matching Ulpin3DUnitKind.
CREATE OR REPLACE FUNCTION ulpin3d_fmt(ulpin14 text,
                                       building int DEFAULT NULL,
                                       level_kind text DEFAULT NULL,
                                       level_n int DEFAULT NULL,
                                       unit_kind text DEFAULT NULL,
                                       unit_n int DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  body text;
  level_code text;
  unit_slot3d text;
BEGIN
  IF level_kind = 'air_rights' THEN
    body := upper(ulpin14) || '-X' || lpad(level_n::text, 2, '0');
    RETURN body || '-' || ulpin3d_check(replace(body, '-', ''));
  END IF;

  body := upper(ulpin14);
  IF building IS NULL THEN
    RETURN body || '-' || ulpin3d_check(replace(body, '-', ''));
  END IF;
  body := body || '-B' || lpad(building::text, 2, '0');

  IF level_kind IS NULL THEN
    RETURN body || '-' || ulpin3d_check(replace(body, '-', ''));
  END IF;
  level_code := CASE level_kind
    WHEN 'ground'   THEN 'G00'
    WHEN 'floor'    THEN 'F' || lpad(level_n::text, 2, '0')
    WHEN 'basement' THEN 'D' || lpad(level_n::text, 2, '0')
  END;
  body := body || '-' || level_code;

  IF unit_kind IS NULL THEN
    RETURN body || '-' || ulpin3d_check(replace(body, '-', ''));
  END IF;
  unit_slot3d := CASE unit_kind
    WHEN 'unit'    THEN ''
    WHEN 'parking' THEN 'PK'
    WHEN 'common'  THEN 'CA'
  END || lpad(unit_n::text, 3, '0');
  body := body || '-' || unit_slot3d;

  RETURN body || '-' || ulpin3d_check(replace(body, '-', ''));
END
$fn$;


-- Structural + check-character validity of a 3D ULPIN. Does not verify
-- ulpin14 against any centroid -- that would need the parcel row, which a
-- pure function does not have.
CREATE OR REPLACE FUNCTION ulpin3d_valid(id text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  body text;
  chk  text;
BEGIN
  IF id IS NULL OR id !~ '^[A-Z0-9]{4,}(-[A-Z0-9]+)*-[0-9A-Z*]$' THEN RETURN false; END IF;
  body := left(id, length(id) - 2);
  chk  := right(id, 1);
  BEGIN
    RETURN ulpin3d_check(replace(body, '-', '')) = chk;
  EXCEPTION WHEN OTHERS THEN
    RETURN false;
  END;
END
$fn$;


-- ---------------------------------------------------------------------------
-- Persistence: split a unit into two, proving IDs are never reused.
--
-- Bisects the unit's 2D plan footprint through its centroid, perpendicular to
-- its oriented envelope's long axis -- the same "axis-align, then slice"
-- approach unit_cells() in scripts/build_geometry.sql already uses, just for
-- one existing polygon into two instead of a footprint into a grid. Each half
-- becomes a NEW unit row with a freshly minted 3D-ULPIN unit slot; the parent
-- is RETIRED (status='retired', retired_at=now()), never deleted and never
-- reused, and ulpin_lineage records the parent -> children edge.
--
-- Demonstration geometry, like unit_cells(): a straight bisection is not a
-- surveyed subdivision plan, which is why the two new rows keep the parent's
-- tenure/encumbrance/owner rather than inventing new ones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION unit_split(p_unit_id integer)
RETURNS TABLE (child1_id integer, child1_ulpin3d text, child2_id integer, child2_ulpin3d text)
LANGUAGE plpgsql AS $fn$
DECLARE
  v_floor_id integer;
  v_kind     text;
  v_owner    text;
  v_tenure   text;
  v_encumbrance text;
  v_z_min    double precision;
  v_z_max    double precision;
  v_plan     geometry;
  v_ctr      geometry;
  v_env      geometry;
  v_ang      double precision;
  v_split_line geometry;
  v_pieces   geometry[];
  v_level_no integer;
  v_ulpin14  text;
  v_bno      int;
  v_kind3d   text;
  v_slot_prefix text;
  v_next     int;
  v_new_id1  integer;
  v_new_id2  integer;
  v_ulpin3d_1 text;
  v_ulpin3d_2 text;
  v_carpet_total double precision;
  v_built_total  double precision;
BEGIN
  SELECT u.floor_id, u.kind, u.owner, u.tenure, u.encumbrance, u.z_min, u.z_max,
         ladm_plan_geom(u.geom_3d), u.carpet_m2, u.built_m2
    INTO v_floor_id, v_kind, v_owner, v_tenure, v_encumbrance, v_z_min, v_z_max,
         v_plan, v_carpet_total, v_built_total
    FROM unit u WHERE u.id = p_unit_id AND u.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unit_split: unit % not found or already retired', p_unit_id;
  END IF;

  SELECT f.level_no, p.ulpin14,
         substring(b.ulpin3d from '-B(\d{2})')::int
    INTO v_level_no, v_ulpin14, v_bno
    FROM floor f
    JOIN building b ON b.id = f.building_id
    JOIN parcel p   ON p.id = b.parcel_id
   WHERE f.id = v_floor_id;
  IF v_ulpin14 IS NULL OR v_bno IS NULL THEN
    RAISE EXCEPTION 'unit_split: unit % is on a building not yet minted under the 3D-ULPIN scheme', p_unit_id;
  END IF;

  v_kind3d := CASE WHEN v_kind = 'parking' THEN 'parking' WHEN v_kind IN ('flat','retail','anchor') THEN 'unit' ELSE 'common' END;
  v_slot_prefix := CASE v_kind3d WHEN 'parking' THEN 'PK' WHEN 'common' THEN 'CA' ELSE '' END;

  -- Bisect the plan footprint through its centroid, perpendicular to the
  -- oriented envelope's long axis.
  v_ctr := ST_Centroid(v_plan);
  v_env := ST_OrientedEnvelope(v_plan);
  v_ang := CASE WHEN v_env IS NULL OR ST_GeometryType(v_env) <> 'ST_Polygon' THEN 0
                ELSE ST_Azimuth(ST_PointN(ST_ExteriorRing(v_env), 1), ST_PointN(ST_ExteriorRing(v_env), 2)) END;
  v_split_line := ST_Rotate(
    ST_MakeLine(ST_Translate(v_ctr, 0, -1000), ST_Translate(v_ctr, 0, 1000)),
    v_ang, v_ctr);

  SELECT array_agg(d.geom ORDER BY ST_XMin(d.geom))
    INTO v_pieces
    FROM (SELECT (ST_Dump(ST_Split(v_plan, v_split_line))).geom AS geom) d
   WHERE ST_Area(d.geom) > 1.0;
  IF v_pieces IS NULL OR array_length(v_pieces, 1) <> 2 THEN
    RAISE EXCEPTION 'unit_split: could not bisect unit % into exactly two pieces', p_unit_id;
  END IF;

  -- Next free 3-digit ordinal(s) in this unit kind's namespace, on this
  -- floor. Best-effort: scans existing (including retired) ulpin3d unit
  -- slots on the floor so a re-split of an already-split floor still mints
  -- fresh numbers rather than colliding.
  SELECT COALESCE(max(
           CASE WHEN v_slot_prefix = ''
                THEN substring(u2.ulpin3d from '-(\d{3})-[0-9A-Z*]$')::int
                ELSE substring(u2.ulpin3d from '-' || v_slot_prefix || '(\d{3})-[0-9A-Z*]$')::int
           END), 0) + 1
    INTO v_next
    FROM unit u2 JOIN floor f2 ON f2.id = u2.floor_id
   WHERE f2.id = v_floor_id;

  v_new_id1 := (SELECT COALESCE(max(id), 0) FROM unit) + 1;
  v_ulpin3d_1 := ulpin3d_fmt(v_ulpin14, v_bno,
                CASE WHEN v_level_no = 0 THEN 'ground' WHEN v_level_no > 0 THEN 'floor' ELSE 'basement' END,
                CASE WHEN v_level_no = 0 THEN NULL ELSE abs(v_level_no) END,
                v_kind3d, v_next);
  INSERT INTO unit (id, floor_id, ulpin, ulpin3d, unit_no, geom_3d, z_min, z_max,
                    carpet_m2, built_m2, tenure, encumbrance, kind, owner)
  VALUES (v_new_id1, v_floor_id,
          -- The old-format `ulpin` column is NOT NULL; this row has no old
          -- identifier of its own (it was born after the switch), so it
          -- carries its OWN ulpin3d string there too, structurally distinct
          -- from every real legacy ULPIN because it is far longer than
          -- seven dash-separated groups -- never mistakeable for one.
          v_ulpin3d_1, v_ulpin3d_1,
          (SELECT unit_no FROM unit WHERE id = p_unit_id) || 'A',
          make_prism(v_pieces[1], v_z_min, v_z_max), v_z_min, v_z_max,
          round((v_carpet_total * ST_Area(v_pieces[1]) / ST_Area(v_plan))::numeric, 2),
          round((v_built_total  * ST_Area(v_pieces[1]) / ST_Area(v_plan))::numeric, 2),
          v_tenure, v_encumbrance, v_kind, v_owner);

  v_new_id2 := v_new_id1 + 1;
  v_ulpin3d_2 := ulpin3d_fmt(v_ulpin14, v_bno,
                CASE WHEN v_level_no = 0 THEN 'ground' WHEN v_level_no > 0 THEN 'floor' ELSE 'basement' END,
                CASE WHEN v_level_no = 0 THEN NULL ELSE abs(v_level_no) END,
                v_kind3d, v_next + 1);
  INSERT INTO unit (id, floor_id, ulpin, ulpin3d, unit_no, geom_3d, z_min, z_max,
                    carpet_m2, built_m2, tenure, encumbrance, kind, owner)
  VALUES (v_new_id2, v_floor_id, v_ulpin3d_2, v_ulpin3d_2,
          (SELECT unit_no FROM unit WHERE id = p_unit_id) || 'B',
          make_prism(v_pieces[2], v_z_min, v_z_max), v_z_min, v_z_max,
          round((v_carpet_total * ST_Area(v_pieces[2]) / ST_Area(v_plan))::numeric, 2),
          round((v_built_total  * ST_Area(v_pieces[2]) / ST_Area(v_plan))::numeric, 2),
          v_tenure, v_encumbrance, v_kind, v_owner);

  UPDATE unit SET status = 'retired', retired_at = now() WHERE id = p_unit_id;

  INSERT INTO ulpin_lineage (project_id, parent_id, child_id, event)
  SELECT b.project_id, COALESCE(u.ulpin3d, u.ulpin), x.child, 'split'
    FROM unit u
    JOIN floor f ON f.id = u.floor_id
    JOIN building b ON b.id = f.building_id
    CROSS JOIN LATERAL (VALUES (v_ulpin3d_1), (v_ulpin3d_2)) AS x(child)
   WHERE u.id = p_unit_id;

  RETURN QUERY SELECT v_new_id1, v_ulpin3d_1, v_new_id2, v_ulpin3d_2;
END
$fn$;


-- INF-<ST>-<DT>-<TYPE><serial4>[-S<seg3>]-<CHK> -- the root for cross-parcel
-- infrastructure (utility corridors, metro tunnels, elevated corridors), which
-- is not anchored to any one parcel's ulpin14.
CREATE OR REPLACE FUNCTION infra_fmt(st text, di text, itype text, serial int,
                                     seg int DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  body text;
BEGIN
  body := 'INF-' || upper(btrim(st)) || '-' || ulpin3d_district2(di) || '-'
       || upper(itype) || lpad(serial::text, 4, '0');
  IF seg IS NOT NULL THEN
    body := body || '-S' || lpad(seg::text, 3, '0');
  END IF;
  RETURN body || '-' || ulpin3d_check(replace(body, '-', ''));
END
$fn$;
