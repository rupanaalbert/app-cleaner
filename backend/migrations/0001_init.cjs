'use strict';

// 0001 — initial schema.
//
// The DDL lives next door in 0001_init.sql as plain, greppable SQL (it used to
// be db/schema.sql); this migration just executes it. Everything the app needs
// to boot is in there: the PostGIS/pgcrypto/pg_trgm/btree_gist extensions, the
// enums, every table with its CHECK and EXCLUDE constraints and triggers, and
// the service / add-on / pricing-rule catalog rows the pricing engine reads.
//
// CommonJS (`.cjs`) on purpose: the backend package is `"type": "module"`, and
// node-pg-migrate loads migration files with require(), which would choke on an
// ESM `.js`.

const { readFileSync } = require('node:fs');
const { join } = require('node:path');

const sql = readFileSync(join(__dirname, '0001_init.sql'), 'utf8');

exports.up = (pgm) => pgm.sql(sql);

// Init is the floor. There is no meaningful "one step back" from an empty
// database — to undo this you drop the database (or the docker volume), you
// don't reverse forty DDL statements. Declaring it irreversible makes
// `migrate down` fail loudly instead of pretending it rolled anything back.
exports.down = false;
