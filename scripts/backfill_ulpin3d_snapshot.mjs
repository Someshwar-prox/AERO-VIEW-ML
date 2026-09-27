/**
 * Mint ulpin3d/ulpin14 for EVERY entity in a project's committed snapshot,
 * without touching PostGIS.
 *
 * The real pipeline (scripts/build_geometry.sql, wired for the new scheme)
 * mints these from live geometry during `npm run seed`. That needs a running
 * Postgres. This script is the bridge for an environment that does not have
 * one: it recovers each entity's parcel/building/floor/unit NUMBERS from its
 * existing legacy `ulpin` (parse(), old format) -- which the OSM pipeline
 * already assigned correctly -- and re-encodes them under the new grammar,
 * using a ulpin14 minted from each PARCEL's own polygon centroid (computed
 * here in pure JS, the standard area-weighted polygon-centroid formula
 * PostGIS's ST_Centroid also implements).
 *
 * So nothing is re-derived that the old pipeline did not already establish;
 * this only gives the existing hierarchy a new name. Once a real Postgres is
 * available, `npm run seed` supersedes this with the authoritative,
 * geometry-driven mint -- this script's output is a legitimate migration
 * path, not a placeholder to be thrown away, but it is why the ulpin3d
 * values it produces are marked no differently from any other synthetic
 * ulpin14: still `ulpin14_source: 'synthetic'`.
 *
 * Usage:
 *   node --experimental-strip-types scripts/backfill_ulpin3d_snapshot.mjs [slug ...]
 *   (no args -> every project in data/api/projects.json)
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import {
  parse, mintUlpin14, encode3D, decode3D, parseUnitSlot,
} from '../lib/ulpin.ts';

const DATA = path.join(process.cwd(), 'data', 'api');

function readJson(...parts) {
  const p = path.join(DATA, ...parts);
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, 'utf-8'));
}

function writeJson(obj, ...parts) {
  const p = path.join(DATA, ...parts);
  // Every file this script touches is committed minified (see
  // scripts/05_export_static.py's dump()); matching that keeps the diff to
  // the fields that actually changed rather than a whole-file reformat.
  writeFileSync(p, JSON.stringify(obj), 'utf-8');
}

/** Area-weighted centroid of a closed GeoJSON ring, [lon, lat]. */
function ringCentroid(ring) {
  let a = 0;
  let cx = 0;
  let cy = 0;
  for (let i = 0; i < ring.length - 1; i += 1) {
    const [x0, y0] = ring[i];
    const [x1, y1] = ring[i + 1];
    const cross = x0 * y1 - x1 * y0;
    a += cross;
    cx += (x0 + x1) * cross;
    cy += (y0 + y1) * cross;
  }
  a *= 0.5;
  if (Math.abs(a) < 1e-14) {
    const n = ring.length - 1;
    const sx = ring.slice(0, n).reduce((s, p) => s + p[0], 0) / n;
    const sy = ring.slice(0, n).reduce((s, p) => s + p[1], 0) / n;
    return [sx, sy];
  }
  return [cx / (6 * a), cy / (6 * a)];
}

/** Centroid of a GeoJSON Polygon geometry (exterior ring only). */
function polygonCentroid(geometry) {
  const ring = geometry.type === 'Polygon' ? geometry.coordinates[0]
    : geometry.coordinates[0][0]; // MultiPolygon: first part
  return ringCentroid(ring);
}

/** Ulpin3DUnitKind for an old-format UnitKind. Mirrors unit3DKind() in scripts/seed_demo_building.mjs. */
function unit3DKindOf(kind) {
  if (kind === 'parking') return 'parking';
  if (kind === 'flat' || kind === 'retail' || kind === 'anchor' || kind === undefined) return 'unit';
  return 'common'; // circulation, atrium, elevator, stair, plant
}

function level3DOf(levelNo) {
  if (levelNo === 0) return { kind: 'ground' };
  if (levelNo > 0) return { kind: 'floor', n: levelNo };
  return { kind: 'basement', n: -levelNo };
}

function backfillProject(slug, state, district) {
  const parcels = readJson(slug, 'parcels.json');
  const buildings = readJson(slug, 'buildings.json');
  const surveyParcels = readJson(slug, 'survey_parcels.json');
  const detail = readJson(slug, 'detail.json');
  const conflicts = readJson(slug, 'conflicts.json');
  if (!parcels || !buildings || !detail) {
    console.log(`  ${slug}: no cadastre snapshot (buildings/parcels/detail.json), skipping`);
    return { minted: 0, skipped: 0 };
  }

  let minted = 0;
  let skipped = 0;

  /** parcel id -> ulpin14 */
  const ulpin14ByParcelId = new Map();
  for (const f of parcels.features) {
    const props = f.properties;
    if (typeof props.id !== 'number' || !f.geometry) { skipped += 1; continue; }
    const [lon, lat] = polygonCentroid(f.geometry);
    const ulpin14 = mintUlpin14(state, district, lon, lat);
    const ulpin3d = encode3D({ ulpin14 });
    props.ulpin3d = ulpin3d;
    props.ulpin14 = ulpin14;
    props.ulpin14_source = 'synthetic';
    props.legacy_id = props.ulpin;
    ulpin14ByParcelId.set(props.id, ulpin14);
    minted += 1;
  }

  /** building id -> {ulpin14, building} */
  const buildingInfoById = new Map();
  for (const f of buildings.features) {
    const props = f.properties;
    const parsed = parse(props.ulpin, 'any');
    const ulpin14 = ulpin14ByParcelId.get(props.parcel_id);
    if (!parsed || parsed.building === undefined || !ulpin14) { skipped += 1; continue; }
    const ulpin3d = encode3D({ ulpin14, building: parsed.building });
    props.ulpin3d = ulpin3d;
    props.legacy_id = props.ulpin;
    buildingInfoById.set(props.id, { ulpin14, building: parsed.building, ulpin3d });
    minted += 1;
  }

  /** building id -> {floor ulpin3d by level_no}, for conflicts.json below */
  const floorUlpin3dByBuildingLevel = new Map();

  for (const [key, doc] of Object.entries(detail)) {
    const bId = Number(key);
    const info = buildingInfoById.get(bId);
    if (doc.building) {
      doc.building.ulpin3d = info?.ulpin3d ?? doc.building.ulpin3d;
      doc.building.legacy_id = doc.building.ulpin;
    }
    if (doc.parcel) {
      const parcelUlpin14 = ulpin14ByParcelId.get(doc.parcel.id);
      if (parcelUlpin14) {
        doc.parcel.ulpin3d = encode3D({ ulpin14: parcelUlpin14 });
        doc.parcel.ulpin14 = parcelUlpin14;
        doc.parcel.ulpin14_source = 'synthetic';
        doc.parcel.legacy_id = doc.parcel.ulpin;
      }
    }
    if (!info) { skipped += (doc.floors?.length ?? 0) + (doc.units?.length ?? 0); continue; }

    const levelMap = new Map();
    floorUlpin3dByBuildingLevel.set(bId, levelMap);
    for (const f of doc.floors ?? []) {
      // Skip anything already minted structurally (e.g. the demo tower,
      // wired by scripts/seed_demo_building.mjs) -- re-deriving it here from
      // its OWN ulpin3d's ulpin14 rather than the OSM-pipeline path above
      // would be redundant, not wrong, but this keeps a re-run idempotent
      // without re-minting a value that already matches.
      if (f.ulpin3d && decode3D(f.ulpin3d)) { levelMap.set(f.level_no, f.ulpin3d); continue; }
      const parsedF = parse(f.ulpin, 'any');
      if (!parsedF || parsedF.floor === undefined) { skipped += 1; continue; }
      const ulpin3d = encode3D({
        ulpin14: info.ulpin14, building: info.building, level: level3DOf(parsedF.floor),
      });
      f.ulpin3d = ulpin3d;
      f.legacy_id = f.ulpin;
      levelMap.set(f.level_no, ulpin3d);
      minted += 1;
    }
    for (const u of doc.units ?? []) {
      if (u.ulpin3d && decode3D(u.ulpin3d)) continue;
      if (!u.ulpin) { skipped += 1; continue; } // a redacted unit has no identifier to mint one from
      const parsedU = parse(u.ulpin, 'any');
      if (!parsedU || parsedU.floor === undefined || parsedU.unitSlot === undefined) { skipped += 1; continue; }
      const slot = parseUnitSlot(parsedU.unitSlot);
      const ordinal = slot?.ordinal;
      if (ordinal === undefined || ordinal < 1 || ordinal > 999) {
        // A storey-numbered flat (e.g. '2004') exceeds the new grammar's
        // fixed 3-digit unit slot -- exactly the case
        // scripts/seed_demo_building.mjs handles by re-numbering per floor
        // instead. Left un-minted here rather than silently truncated.
        skipped += 1;
        continue;
      }
      const ulpin3d = encode3D({
        ulpin14: info.ulpin14, building: info.building, level: level3DOf(parsedU.floor),
        unit: { kind: unit3DKindOf(u.kind), n: ordinal },
      });
      u.ulpin3d = ulpin3d;
      u.legacy_id = u.ulpin;
      minted += 1;
    }
  }

  writeJson(parcels, slug, 'parcels.json');
  writeJson(buildings, slug, 'buildings.json');
  writeJson(detail, slug, 'detail.json');
  if (surveyParcels) {
    for (const f of surveyParcels.features) {
      const props = f.properties;
      if (!f.geometry) { skipped += 1; continue; }
      const [lon, lat] = polygonCentroid(f.geometry);
      const ulpin14 = mintUlpin14(state, district, lon, lat);
      props.ulpin3d = encode3D({ ulpin14 });
      props.ulpin14 = ulpin14;
      props.ulpin14_source = 'synthetic';
      minted += 1;
    }
    writeJson(surveyParcels, slug, 'survey_parcels.json');
  }
  if (conflicts) {
    for (const c of conflicts) {
      const bInfo = buildingInfoById.get(c.building_id);
      if (bInfo) c.building_ulpin3d = bInfo.ulpin3d ?? buildingInfoById.get(c.building_id)?.ulpin3d;
      const levelMap = floorUlpin3dByBuildingLevel.get(c.building_id);
      if (levelMap?.has(c.level_no)) c.floor_ulpin3d = levelMap.get(c.level_no);
    }
    writeJson(conflicts, slug, 'conflicts.json');
  }

  return { minted, skipped };
}

const registry = readJson('projects.json');
if (!registry) {
  console.error('backfill_ulpin3d_snapshot: data/api/projects.json not found');
  process.exit(1);
}
const wanted = process.argv.slice(2);
const projects = registry.projects.filter((p) => wanted.length === 0 || wanted.includes(p.slug));
if (!projects.length) {
  console.error(`backfill_ulpin3d_snapshot: no matching project for [${wanted.join(', ')}]`);
  process.exit(1);
}

for (const p of projects) {
  const { minted, skipped } = backfillProject(p.slug, p.state_code, p.district_code);
  console.log(`  ${p.slug}: minted ${minted}, skipped ${skipped}`);
}
console.log('backfill_ulpin3d_snapshot: done. Re-run scripts/check_ulpin3d.mjs to verify.');
