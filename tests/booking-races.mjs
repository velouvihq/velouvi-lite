import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { Client } from "pg";

const connection = new URL(process.env.VELOUVI_POSTGRES_ADMIN_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres");
if (!["127.0.0.1", "localhost", "[::1]"].includes(connection.hostname)) {
    throw new Error("Run race tests against an isolated local PostgreSQL server.");
}
const database = "velouvi_test_" + randomUUID().replaceAll("-", "");
const admin = new Client({ connectionString: connection.href });
await admin.connect();
const testUrl = new URL(connection.href);
testUrl.pathname = "/" + database;
const clients = [];

const connect = async () => {
    const client = new Client({ connectionString: testUrl.href });
    await client.connect();
    clients.push(client);
    return client;
};
const migrations = new URL("../supabase/migrations/", import.meta.url);
const authStub = `
    do $$ begin
      if not exists(select from pg_roles where rolname='anon') then
        raise exception 'Local roles anon, authenticated, service_role are required';
      end if;
    end $$;
    create schema extensions;
    create schema auth;
    create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}',email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    grant usage on schema auth to anon,authenticated,service_role;
    set search_path=public,extensions;
`;
const fixtureId = (id) => "a3000000-0000-4000-8000-" + String(id).padStart(12, "0");
let created = false;
try {
    await admin.query(`create database ${database} template template0`);
    created = true;
    const setup = await connect();
    await setup.query(authStub);
    for (const file of (await readdir(migrations)).filter((file) => file.endsWith(".sql")).sort()) {
        await setup.query(await readFile(new URL(file, migrations), "utf8"));
    }
    const test = await readFile(new URL("./003_booking.sql", import.meta.url), "utf8");
    const fixture = test.slice(test.indexOf("begin;"), test.indexOf("set local role authenticated;"));
    await setup.query(fixture + "\ncommit;");
    await setup.query(`
        insert into marketplace.listings(organization_id,location_id,slug,display_name,status)
        values (pg_temp.bid(10),pg_temp.bid(21),'race-a1','Race A1','published'),
               (pg_temp.bid(10),pg_temp.bid(22),'race-a2','Race A2','published')
    `);

    const firstDb = await connect();
    const secondDb = await connect();
    const { rows: [{ start }] } = await setup.query("select pg_temp.slot(10) as start");
    const add = async (slug, variant, time) => {
        const { rows: [{ id }] } = await setup.query(
            "select api.submit_booking_request($1,$2,$3,'Synthetic guest',$4,$5) as id",
            [slug, fixtureId(variant), time, randomUUID() + "@example.test", randomUUID()]
        );
        return id;
    };
    async function authenticated(client, id) {
        await client.query("begin");
        await client.query("set local role authenticated");
        await client.query("select set_config('request.jwt.claim.sub',$1,true)", [fixtureId(1)]);
        const { rows: [{ result }] } = await client.query("select api.decide_booking_request($1,true) as result", [id]);
        return result.appointment_id;
    }
    async function race(label, winner, other, replay = false) {
        const expected = await authenticated(firstDb, winner);
        const second = authenticated(secondDb, other);
        void second.catch(() => {});
        // Count the second connection as racing only after PostgreSQL shows that it is waiting for a lock.
        const pid = secondDb.processID;
        let waited = false;
        for (let attempt = 0; attempt < 100; attempt++) {
            const { rows: [state] } = await setup.query("select wait_event_type from pg_stat_activity where pid=$1", [pid]);
            if (state?.wait_event_type === "Lock") { waited = true; break; }
            await new Promise((resolve) => setTimeout(resolve, 10));
        }
        assert.ok(waited, "Second connection should wait for the first transaction");
        const check = replay ? second.then((value) => assert.equal(value, expected))
            : assert.rejects(second, (error) => error.code === "23P01");
        await firstDb.query("commit");
        await check;
        await secondDb.query(replay ? "commit" : "rollback");
        console.log("PASS", label);
    }
    const plusHours = (hours) => new Date(new Date(start).getTime() + hours * 3_600_000);
    await race("competing staff requests at different branches",
        await add("race-a1", 71, start), await add("race-a2", 71, start));
    await race("competing requests for one room with different staff",
        await add("race-a1", 71, plusHours(1)), await add("race-a1", 72, plusHours(1)));
    const repeat = await add("race-a1", 71, plusHours(2));
    await race("concurrent acceptance returns a single appointment", repeat, repeat, true);
} finally {
    await Promise.all(clients.map((client) => client.end()));
    if (created) await admin.query(`drop database ${database}`);
    await admin.end();
}
