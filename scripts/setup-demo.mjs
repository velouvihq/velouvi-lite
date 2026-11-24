import { spawnSync } from "node:child_process";
import { access, writeFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import { Client } from "pg";

const result = spawnSync("npx", ["--no-install", "supabase", "status", "-o", "json"], {
    encoding: "utf8", shell: process.platform === "win32",
});
if (result.status !== 0) {
    throw new Error("Start Docker and run npx supabase start from this project first.");
}
const config = JSON.parse(result.stdout);
const url = config.API_URL ?? config.PROJECT_URL;
const db = config.DB_URL;
const publicKey = config.PUBLISHABLE_KEY ?? config.ANON_KEY;
const secret = config.SERVICE_ROLE_KEY ?? config.SECRET_KEY;
function assertLocal(address, port) {
    const parsed = new URL(address);
    if (parsed.hostname !== "127.0.0.1" && parsed.hostname !== "localhost") throw new Error("Demo setup accepts localhost only.");
    if (parsed.port !== port) throw new Error("Run this demo on the local Supabase ports in config.toml.");
}
assertLocal(url, "54321");
assertLocal(db, "54322");
if (!publicKey || !secret) throw new Error("Local Supabase did not provide the expected API keys.");
const envPath = new URL("../.env.local", import.meta.url);
try {
    await access(envPath);
    console.log("Keeping the existing .env.local. Check it points at your test project.");
} catch (error) {
    if (error.code !== "ENOENT") throw error;
    await writeFile(envPath, `VITE_SUPABASE_URL=${url}\nVITE_SUPABASE_PUBLISHABLE_KEY=${publicKey}\n`, { flag: "wx" });
}

const password = "Velouvi-River-Local-2026";
const emails = ["owner@velouvi.example", "moderator@velouvi.example"];
const auth = createClient(url, secret, { auth: { autoRefreshToken: false, persistSession: false } });
const client = new Client({ connectionString: db });
await client.connect();
try {
    const users = new Map();
    for (const email of emails) {
        const existing = await client.query("select id from auth.users where email=$1", [email]);
        if (existing.rowCount) {
            users.set(email, existing.rows[0].id);
            continue;
        }
        const { data, error } = await auth.auth.admin.createUser({ email, password, email_confirm: true });
        if (error) throw error;
        users.set(email, data.user.id);
    }
    await client.query("begin");
    const org = (await client.query(`
        insert into core.organizations(name,slug,created_by) values ('Velouvi Studio','velouvi-local-demo',$1)
        on conflict(slug) do nothing returning id
    `, [users.get(emails[0])])).rows[0]?.id;
    if (org) {
        const loc = (await client.query(`
            insert into core.locations(organization_id,name,city,is_default)
            values ($1,'Velouvi Studio','Colombo',true) returning id
        `, [org])).rows[0].id;
        const member = (await client.query(`
            insert into core.memberships(organization_id,user_id,status,activated_at)
            values ($1,$2,'active',now()) returning id
        `, [org, users.get(emails[0])])).rows[0].id;
        await client.query(`
            insert into core.role_assignments(organization_id,membership_id,role_id)
            select $1,$2,id from core.roles where code='owner'
        `, [org, member]);
        for (const [name, minutes, price] of [["Haircut", 30, 250000], ["Gel Manicure", 60, 450000], ["Classic Facial", 45, 550000]]) {
            const service = (await client.query(
                "insert into commerce.services(organization_id,name) values ($1,$2) returning id", [org, name]
            )).rows[0].id;
            const variant = (await client.query(`
                insert into commerce.service_variants(organization_id,service_id,name,duration_minutes,price_minor)
                values ($1,$2,'Standard',$3,$4) returning id
            `,[org, service, minutes, price])).rows[0].id;
            await client.query("insert into commerce.service_locations(organization_id,location_id,service_variant_id) values ($1,$2,$3)",
                [org, loc, variant]);
        }
        const staff = (await client.query(
            "insert into core.staff_profiles(organization_id,display_name) values ($1,'Test Stylist') returning id", [org]
        )).rows[0].id;
        await client.query("insert into core.staff_locations(organization_id,staff_profile_id,location_id,is_primary) values ($1,$2,$3,true)", [org, staff, loc]);
        await client.query(`
            insert into ops.location_hours(organization_id,location_id,day_of_week,opens_at,closes_at)
            select $1,$2,d,'09:00','17:00' from generate_series(1,6) d
        `, [org, loc]);
        await client.query(`
            insert into ops.staff_availability(organization_id,location_id,staff_profile_id,day_of_week,starts_at,ends_at)
            select $1,$2,$3,d,'09:00','17:00' from generate_series(1,6) d
        `, [org, loc, staff]);
        await client.query(`
            insert into marketplace.listings(organization_id,location_id,slug,display_name,description,status)
            values($1,$2,'velouvi-local-demo','Velouvi Studio','A local test studio for hair, nails and facials.','published')
        `, [org, loc]);
        const moderator = (await client.query(`
            insert into core.platform_memberships(user_id) values ($1)
            on conflict(user_id) do update set user_id=excluded.user_id returning id
        `, [users.get(emails[1])])).rows[0].id;
        await client.query(`
            insert into core.platform_role_assignments(platform_membership_id,platform_role_id)
            select $1,id from core.platform_roles where code='operations' on conflict do nothing
        `, [moderator]);
    }
    await client.query("commit");
    console.log("Local-only demo is ready. Run npm run dev and open http://127.0.0.1:3000.");
    console.log(`Demo logins: ${emails.join(" and ")}`);
    console.log(`Demo password: ${password} (only for the synthetic local users created by this script).`);
} catch (error) {
    await client.query("rollback");
    throw error;
} finally {
    await client.end();
}
