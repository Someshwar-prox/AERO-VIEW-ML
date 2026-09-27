/**
 * 3D ULPIN round-trip + property tests.
 *
 * Run with:  node --test lib/ulpin3d.test.ts
 *
 * This is the NEW `<ULPIN14>[-B<bb>][-<LEVEL>][-<UNIT>]-<CHK>` format. It does
 * not touch the legacy `AP-VSP-3D26-...` grammar tested in lib/ulpin.test.ts --
 * both live side by side in lib/ulpin.ts.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  geohash, mintUlpin14, parseUlpin14, district2, checkChar3736,
  encode3D, decode3D, validate3D, parent3D,
  levelCode3D, parseLevelCode3D, unit3DSlot, parseUnit3DSlot,
  encodeInfra, decodeInfra, isInfrastructure,
  type Ulpin3DLevel, type Ulpin3DUnitKind,
} from './ulpin.ts';

// A deterministic PRNG so the 1000-sample tests are reproducible.
function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = mulberry32(20260927);
const randInt = (lo: number, hi: number) => lo + Math.floor(rand() * (hi - lo + 1));
const CHK_ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

test('district2 truncates to two letters', () => {
  assert.equal(district2('VSP'), 'VS');
  assert.equal(district2('HYD'), 'HY');
  assert.equal(district2('vs'), 'VS');
});

test('geohash is deterministic and the documented length', () => {
  const g = geohash(83.32, 17.72, 10);
  assert.equal(g.length, 10);
  assert.equal(g, geohash(83.32, 17.72, 10));
  assert.notEqual(g, geohash(83.33, 17.73, 10));
});

test('mintUlpin14 is 14 uppercase alphanumeric characters and round-trips structurally', () => {
  const id = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  assert.equal(id.length, 14);
  assert.match(id, /^[A-Z0-9]{14}$/);
  assert.ok(id.startsWith('TSHY'));
  const parsed = parseUlpin14(id);
  assert.ok(parsed);
  assert.equal(parsed!.state, 'TS');
  assert.equal(parsed!.district, 'HY');
});

test('parseUlpin14 rejects malformed strings', () => {
  for (const bad of ['', 'TSHY4K7Q2M9RX', 'TSHY4K7Q2M9RXPP', '1SHY4K7Q2M9RXP', 'TS-HY4K7Q2M9RXP']) {
    assert.equal(parseUlpin14(bad), null, `should reject ${JSON.stringify(bad)}`);
  }
});

test('levelCode3D encodes and parses every kind', () => {
  const cases: Ulpin3DLevel[] = [
    { kind: 'ground' }, { kind: 'floor', n: 5 }, { kind: 'floor', n: 99 },
    { kind: 'basement', n: 1 }, { kind: 'basement', n: 9 },
    { kind: 'airRights', n: 1 }, { kind: 'airRights', n: 9 },
  ];
  for (const level of cases) {
    const code = levelCode3D(level);
    assert.deepEqual(parseLevelCode3D(code), level, code);
  }
  assert.equal(levelCode3D({ kind: 'ground' }), 'G00');
  assert.equal(levelCode3D({ kind: 'floor', n: 5 }), 'F05');
  assert.equal(levelCode3D({ kind: 'basement', n: 1 }), 'D01');
  assert.equal(levelCode3D({ kind: 'airRights', n: 1 }), 'X01');
});

test('parseLevelCode3D rejects out-of-range and malformed codes', () => {
  for (const bad of ['G01', 'F00', 'F100', 'D00', 'D10', 'X00', 'X10', 'Q01', '', 'F5']) {
    assert.equal(parseLevelCode3D(bad), null, `should reject ${JSON.stringify(bad)}`);
  }
});

test('unit3DSlot encodes plain units and reserved prefixes, always 3 digits', () => {
  assert.equal(unit3DSlot('unit', 12), '012');
  assert.equal(unit3DSlot('unit', 999), '999');
  assert.equal(unit3DSlot('parking', 14), 'PK014');
  assert.equal(unit3DSlot('common', 1), 'CA001');
  assert.deepEqual(parseUnit3DSlot('012'), { kind: 'unit', n: 12 });
  assert.deepEqual(parseUnit3DSlot('PK014'), { kind: 'parking', n: 14 });
  assert.deepEqual(parseUnit3DSlot('CA001'), { kind: 'common', n: 1 });
});

test('unit3DSlot rejects ordinals outside 1-999', () => {
  assert.throws(() => unit3DSlot('unit', 0));
  assert.throws(() => unit3DSlot('unit', 1000));
});

test('checkChar3736 is a single character from the 37-symbol alphabet', () => {
  for (const body of ['TSHY4K7Q2M9RXP', 'TSHY4K7Q2M9RXPB01', 'INFAPVSSWR0042']) {
    const c = checkChar3736(body);
    assert.equal(c.length, 1);
    assert.ok((CHK_ALPHABET + '*').includes(c));
  }
});

// ---------------------------------------------------------------------------
// Round trips for every level/unit type, including D, X, PK, CA.
// ---------------------------------------------------------------------------

test('round-trips a bare parcel', () => {
  const ulpin14 = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  const id = encode3D({ ulpin14 });
  const back = decode3D(id);
  assert.ok(back, id);
  assert.equal(back!.ulpin14, ulpin14);
  assert.equal(back!.building, undefined);
  assert.equal(encode3D({ ulpin14: back!.ulpin14 }), id);
});

test('round-trips a building', () => {
  const ulpin14 = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  const id = encode3D({ ulpin14, building: 1 });
  const back = decode3D(id);
  assert.deepEqual(back && { ulpin14: back.ulpin14, building: back.building, level: back.level, unit: back.unit },
    { ulpin14, building: 1, level: undefined, unit: undefined });
});

test('round-trips ground, floor, basement and air-rights levels', () => {
  const ulpin14 = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  for (const level of [
    { kind: 'ground' } as const, { kind: 'floor', n: 5 } as const,
    { kind: 'basement', n: 1 } as const,
  ]) {
    const id = encode3D({ ulpin14, building: 1, level });
    assert.deepEqual(decode3D(id)?.level, level, id);
  }
  // Air rights: no building segment.
  const airId = encode3D({ ulpin14, level: { kind: 'airRights', n: 1 } });
  assert.equal(airId.split('-').length, 3); // ULPIN14 - X01 - CHK
  const back = decode3D(airId);
  assert.deepEqual(back?.level, { kind: 'airRights', n: 1 });
  assert.equal(back?.building, undefined);
});

test('round-trips a unit on a floor, incl. parking and common-area slots', () => {
  const ulpin14 = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  const level = { kind: 'floor', n: 5 } as const;
  const plain = encode3D({ ulpin14, building: 1, level, unit: { kind: 'unit', n: 12 } });
  assert.deepEqual(decode3D(plain)?.unit, { kind: 'unit', n: 12 });

  const basement = { kind: 'basement', n: 1 } as const;
  const parking = encode3D({ ulpin14, building: 1, level: basement, unit: { kind: 'parking', n: 14 } });
  assert.deepEqual(decode3D(parking)?.unit, { kind: 'parking', n: 14 });

  const common = encode3D({ ulpin14, building: 1, level: { kind: 'ground' }, unit: { kind: 'common', n: 1 } });
  assert.deepEqual(decode3D(common)?.unit, { kind: 'common', n: 1 });
});

test('matches the brief\'s own worked examples structurally', () => {
  const ulpin14 = 'TSHY4K7Q2M9RXP';
  const parcel = encode3D({ ulpin14 });
  assert.match(parcel, /^TSHY4K7Q2M9RXP-[0-9A-Z*]$/);
  const building = encode3D({ ulpin14, building: 1 });
  assert.match(building, /^TSHY4K7Q2M9RXP-B01-[0-9A-Z*]$/);
  const floor5 = encode3D({ ulpin14, building: 1, level: { kind: 'floor', n: 5 } });
  assert.match(floor5, /^TSHY4K7Q2M9RXP-B01-F05-[0-9A-Z*]$/);
  const unit = encode3D({ ulpin14, building: 1, level: { kind: 'floor', n: 5 }, unit: { kind: 'unit', n: 12 } });
  assert.match(unit, /^TSHY4K7Q2M9RXP-B01-F05-012-[0-9A-Z*]$/);
  const parking = encode3D({ ulpin14, building: 1, level: { kind: 'basement', n: 1 }, unit: { kind: 'parking', n: 14 } });
  assert.match(parking, /^TSHY4K7Q2M9RXP-B01-D01-PK014-[0-9A-Z*]$/);
  const air = encode3D({ ulpin14, level: { kind: 'airRights', n: 1 } });
  assert.match(air, /^TSHY4K7Q2M9RXP-X01-[0-9A-Z*]$/);
});

// ---------------------------------------------------------------------------
// INF- root
// ---------------------------------------------------------------------------

test('encodes and round-trips an infrastructure identifier, with and without a segment', () => {
  const id = encodeInfra({ state: 'AP', district: 'VSP', type: 'SWR', serial: 42 });
  assert.ok(isInfrastructure(id));
  assert.match(id, /^INF-AP-VS-SWR0042-[0-9A-Z*]$/);
  const back = decodeInfra(id);
  assert.deepEqual(back && { state: back.state, district: back.district, type: back.type, serial: back.serial, segment: back.segment },
    { state: 'AP', district: 'VS', type: 'SWR', serial: 42, segment: undefined });

  const seg = encodeInfra({ state: 'AP', district: 'VSP', type: 'SWR', serial: 42, segment: 3 });
  assert.match(seg, /^INF-AP-VS-SWR0042-S003-[0-9A-Z*]$/);
  assert.deepEqual(decodeInfra(seg)?.segment, 3);
});

test('isInfrastructure distinguishes the INF root from a parcel-anchored id', () => {
  assert.equal(isInfrastructure('INF-AP-VS-SWR0042-M'), true);
  assert.equal(isInfrastructure(encode3D({ ulpin14: mintUlpin14('AP', 'VSP', 83.3, 17.7) })), false);
});

// ---------------------------------------------------------------------------
// Hierarchy
// ---------------------------------------------------------------------------

test('walks up the hierarchy: unit -> floor -> building -> parcel', () => {
  const ulpin14 = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  const unit = encode3D({ ulpin14, building: 7, level: { kind: 'floor', n: 5 }, unit: { kind: 'unit', n: 3 } });
  const floor = parent3D(unit);
  assert.equal(decode3D(floor!)?.level?.kind, 'floor');
  assert.equal(decode3D(floor!)?.unit, undefined);
  const building = parent3D(floor!);
  assert.equal(decode3D(building!)?.building, 7);
  assert.equal(decode3D(building!)?.level, undefined);
  const parcel = parent3D(building!);
  assert.equal(decode3D(parcel!)?.building, undefined);
  assert.equal(parent3D(parcel!), null);
});

test('air-rights volume\'s parent is the parcel', () => {
  const ulpin14 = mintUlpin14('TS', 'HYD', 78.45, 17.41);
  const air = encode3D({ ulpin14, level: { kind: 'airRights', n: 1 } });
  const parcel = parent3D(air);
  assert.equal(decode3D(parcel!)?.building, undefined);
  assert.equal(decode3D(parcel!)?.level, undefined);
  assert.equal(parent3D(parcel!), null);
});

// ---------------------------------------------------------------------------
// Uniqueness / round-trip corpus (1000 random entities)
// ---------------------------------------------------------------------------

function randomLevel(): Ulpin3DLevel {
  const kinds: Ulpin3DLevel['kind'][] = ['ground', 'floor', 'basement'];
  const kind = kinds[randInt(0, 2)];
  if (kind === 'ground') return { kind };
  if (kind === 'floor') return { kind, n: randInt(1, 99) };
  return { kind, n: randInt(1, 9) };
}

function randomUnitKind(): Ulpin3DUnitKind {
  const kinds: Ulpin3DUnitKind[] = ['unit', 'parking', 'common'];
  return kinds[randInt(0, 2)];
}

test('1000 random entities round-trip through decode3D(encode3D(x)) == x', () => {
  for (let i = 0; i < 1000; i++) {
    const ulpin14 = mintUlpin14(rand() < 0.5 ? 'AP' : 'TS', rand() < 0.5 ? 'VSP' : 'HYD',
      70 + rand() * 20, 10 + rand() * 20);
    const depth = randInt(0, 3);
    const parts: Parameters<typeof encode3D>[0] = { ulpin14 };
    if (depth >= 1) parts.building = randInt(1, 99);
    if (depth >= 2) parts.level = randomLevel();
    if (depth >= 3) parts.unit = { kind: randomUnitKind(), n: randInt(1, 999) };
    const id = encode3D(parts);
    const back = decode3D(id);
    assert.ok(back, `failed to decode ${id}`);
    assert.equal(encode3D({ ulpin14: back!.ulpin14, building: back!.building, level: back!.level, unit: back!.unit }), id);
  }
});

// ---------------------------------------------------------------------------
// Check-character error detection: every single-character substitution and
// every adjacent transposition across a sample of 1000 IDs must be rejected.
// ---------------------------------------------------------------------------

function randomId(): string {
  const ulpin14 = mintUlpin14('AP', 'VSP', 70 + rand() * 20, 10 + rand() * 20);
  const depth = randInt(0, 3);
  const parts: Parameters<typeof encode3D>[0] = { ulpin14 };
  if (depth >= 1) parts.building = randInt(1, 99);
  if (depth >= 2) parts.level = randomLevel();
  if (depth >= 3) parts.unit = { kind: randomUnitKind(), n: randInt(1, 999) };
  return encode3D(parts);
}

test('the check character catches every single-character substitution (1000 samples)', () => {
  for (let i = 0; i < 1000; i++) {
    const id = randomId();
    assert.ok(validate3D(id), id);
    for (let pos = 0; pos < id.length; pos++) {
      if (id[pos] === '-') continue;
      for (const repl of CHK_ALPHABET) {
        if (repl === id[pos]) continue;
        const mutated = id.slice(0, pos) + repl + id.slice(pos + 1);
        assert.equal(validate3D(mutated), false,
          `substitution at ${pos} (${id[pos]}->${repl}) in ${id} was not caught`);
      }
    }
  }
});

test('the check character catches every adjacent transposition (1000 samples)', () => {
  for (let i = 0; i < 1000; i++) {
    const id = randomId();
    for (let pos = 0; pos < id.length - 1; pos++) {
      if (id[pos] === '-' || id[pos + 1] === '-' || id[pos] === id[pos + 1]) continue;
      const mutated = id.slice(0, pos) + id[pos + 1] + id[pos] + id.slice(pos + 2);
      assert.equal(validate3D(mutated), false,
        `transposition at ${pos}-${pos + 1} in ${id} was not caught`);
    }
  }
});

test('decode3D rejects structurally malformed identifiers', () => {
  for (const bad of [
    '', 'not-a-ulpin', 'TSHY4K7Q2M9RXP', 'TSHY4K7Q2M9RXP-B1-M',
    'TSHY4K7Q2M9RXP-B01-F5-M', 'TSHY4K7Q2M9RXP-B01-F05-01-M',
    'TSHY4K7Q2M9RXP-B01-X01-M', // air rights must NOT carry a building
  ]) {
    assert.equal(decode3D(bad), null, `should reject ${JSON.stringify(bad)}`);
  }
});
