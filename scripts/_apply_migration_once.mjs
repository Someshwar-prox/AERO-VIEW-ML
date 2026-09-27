// One-off runner: apply db/migrations/002_ulpin3d.sql + db/02_functions.sql
// against DATABASE_URL using node-postgres directly (no psql client
// available in this environment). Strips psql-only backslash meta-commands
// (\set, \echo), which pg's simple query protocol does not understand;
// everything else is plain SQL and multi-statement strings are supported by
// pg.Client.query() when called with no parameters.
import { readFileSync } from 'node:fs';
import { Client } from 'pg';

const files = process.argv.slice(2);
if (!files.length) {
  console.error('usage: node scripts/_apply_migration_once.mjs <file.sql> [file2.sql ...]');
  process.exit(1);
}

const url = process.env.DATABASE_URL;
if (!url) {
  console.error('DATABASE_URL not set in this process env.');
  process.exit(1);
}

const client = new Client({ connectionString: url });
await client.connect();
try {
  for (const f of files) {
    const raw = readFileSync(f, 'utf-8');
    // Minimal psql-variable support: `\set name 'value'` then `:'name'` in
    // the body, since only pg.Client (no psql binary) is available here.
    const vars = {};
    for (const m of raw.matchAll(/^\\set\s+(\w+)\s+'([^']*)'/gm)) vars[m[1]] = m[2];
    let sql = raw
      .split('\n')
      .filter((line) => !line.trim().startsWith('\\'))
      .join('\n');
    for (const [k, v] of Object.entries(vars)) {
      sql = sql.replaceAll(`:'${k}'`, `'${v}'`).replaceAll(`:${k}`, v);
    }
    console.log(`--- applying ${f} ---`);
    const res = await client.query(sql);
    const results = Array.isArray(res) ? res : [res];
    for (const r of results) {
      if (r?.rows?.length) console.log(r.rows);
    }
    console.log(`--- ${f} applied OK ---`);
  }
} finally {
  await client.end();
}
