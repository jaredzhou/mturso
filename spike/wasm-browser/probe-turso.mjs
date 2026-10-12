import { connect } from '@tursodatabase/database-wasm/bundle';

const db = await connect(':memory:');
const rows = await db.prepare('select 1 + 41 as answer, sqlite_version() as v').all();
console.log('rows:', rows);
await db.exec('create table t(id integer primary key, name text)');
await db.exec("insert into t(name) values ('alice'), ('bob')");
console.log('after insert:', await db.prepare('select * from t').all());
console.log('OK: turso wasm runs in node');
