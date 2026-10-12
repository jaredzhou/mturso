import { connect } from '@tursodatabase/database';
const db = await connect(':memory:');
console.log('select:', await db.prepare('select 1+41 as answer, sqlite_version() as v').all());
await db.exec('create table t(id integer primary key, name text)');
await db.exec("insert into t(name) values ('alice'), ('bob')");
console.log('rows:', JSON.stringify(await db.prepare('select * from t order by id').all()));
