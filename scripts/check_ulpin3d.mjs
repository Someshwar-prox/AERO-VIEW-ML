/**
 * Acceptance check for the 3D ULPIN identifier scheme.
 *
 * Pure data check -- no browser, no database -- so it runs against whatever
 * is currently committed under data/api/<slug>/, which is what lets it run in
 * CI without Docker. Reads every project's buildings.json / parcels.json /
 * detail.json and asserts, across ALL projects at once:
 *
 *   1. every ulpin3d value that appears anywhere is globally unique
 *   2. every entity's parent3D() matches its actual parent's ulpin3d
 *
 * If NO project has been re-seeded under the new scheme yet (every ulpin3d
 * field is absent, which is the state right after `npm run db:schema` +
 * db/migrations/002_ulpin3d.sql but before a re-seed), this prints that and
 * exits 0 rather than failing a check that has nothing to check yet.
 *
 * Usage:
 *   node --experimental-strip-types scripts/check_ulpin3d.mjs
 */
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { decode3D, parent3D } from '../lib/ulpin.ts';

const DATA = path.join(process.cwd(), 'data', 'api');

function readJson(...parts) {
  const p = path.join(DATA, ...parts);
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, 'utf-8'));
}

const registry = readJson('projects.json');
if (!registry) {
  console.error('check_ulpin3d: data/api/projects.json not found');
  process.exit(1);
}

/** slug -> ulpin3d -> { kind, parentUlpin3d } */
const seen = new Map();
let errors = 0;
let minted = 0;

function record(slug, ulpin3d, kind, parentUlpin3d) {
  if (!ulpin3d) return;
  minted += 1;
  if (seen.has(ulpin3d)) {
    console.error(`DUPLICATE ulpin3d "${ulpin3d}" -- first seen as ${seen.get(ulpin3d).kind} `
      + `in ${seen.get(ulpin3d).slug}, again as ${kind} in ${slug}`);
    errors += 1;
    return;
  }
  seen.set(ulpin3d, { slug, kind, parentUlpin3d });

  if (!decode3D(ulpin3d)) {
    console.error(`INVALID ulpin3d "${ulpin3d}" (${kind} in ${slug}) -- fails decode3D/check-char`);
    errors += 1;
  }
}

for (const p of registry.projects ?? []) {
  const slug = p.slug;
  const buildings = readJson(slug, 'buildings.json');
  const parcels = readJson(slug, 'parcels.json');
  const detail = readJson(slug, 'detail.json');
  const airRights = readJson(slug, 'air_rights.json');

  for (const f of parcels?.features ?? []) {
    record(slug, f.properties.ulpin3d, 'parcel', null);
  }
  for (const f of buildings?.features ?? []) {
    record(slug, f.properties.ulpin3d, 'building', null); // parent checked via detail.json below
  }
  for (const key of Object.keys(detail ?? {})) {
    const doc = detail[key];
    const bUlpin3d = doc.building?.ulpin3d;
    const pUlpin3d = doc.parcel?.ulpin3d;
    if (bUlpin3d && pUlpin3d && parent3D(bUlpin3d) !== pUlpin3d) {
      console.error(`HIERARCHY building ${bUlpin3d} (${slug}) -- parent3D() = `
        + `"${parent3D(bUlpin3d)}", expected parcel "${pUlpin3d}"`);
      errors += 1;
    }
    for (const f of doc.floors ?? []) {
      record(slug, f.ulpin3d, 'floor', bUlpin3d);
      if (f.ulpin3d && bUlpin3d && parent3D(f.ulpin3d) !== bUlpin3d) {
        console.error(`HIERARCHY floor ${f.ulpin3d} (${slug}) -- parent3D() = `
          + `"${parent3D(f.ulpin3d)}", expected building "${bUlpin3d}"`);
        errors += 1;
      }
    }
    for (const u of doc.units ?? []) {
      const floor = (doc.floors ?? []).find((f) => f.id === u.floor_id);
      record(slug, u.ulpin3d, 'unit', floor?.ulpin3d);
      if (u.ulpin3d && floor?.ulpin3d && parent3D(u.ulpin3d) !== floor.ulpin3d) {
        console.error(`HIERARCHY unit ${u.ulpin3d} (${slug}) -- parent3D() = `
          + `"${parent3D(u.ulpin3d)}", expected floor "${floor.ulpin3d}"`);
        errors += 1;
      }
    }
  }
  for (const a of airRights ?? []) {
    record(slug, a.ulpin3d, 'air_rights_volume', null);
    if (a.ulpin3d && parent3D(a.ulpin3d) === null) {
      console.error(`HIERARCHY air-rights ${a.ulpin3d} (${slug}) -- parent3D() returned null, expected the parcel`);
      errors += 1;
    }
  }
}

if (minted === 0) {
  console.log('check_ulpin3d: no project has minted a ulpin3d yet '
    + '(re-seed under db/migrations/002_ulpin3d.sql to populate) -- nothing to check.');
  process.exit(0);
}

console.log(`check_ulpin3d: checked ${minted} identifiers across `
  + `${(registry.projects ?? []).length} project(s), ${seen.size} unique.`);

if (errors > 0) {
  console.error(`check_ulpin3d: FAILED with ${errors} error(s).`);
  process.exit(1);
}
console.log('check_ulpin3d: OK.');
