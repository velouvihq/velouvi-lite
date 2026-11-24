import { readFile } from "node:fs/promises";
import { Client } from "pg";

const connection = new URL(process.env.VELOUVI_TEST_DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres");
if (!["127.0.0.1", "localhost", "[::1]"].includes(connection.hostname)) {
    throw new Error("Use a local test database. These fixture tests are intended for development.");
}

const suites = ["002_authorization.sql", "003_booking.sql", "004_to_006_integrations.sql"];
const client = new Client({ connectionString: connection.href });
await client.connect();
client.on("notice", ({ message }) => console.log(message));
try {
    for (const suite of suites) {
        const file = new URL("../tests/" + suite, import.meta.url);
        const sql = (await readFile(file, "utf8")).replace(/^\\set ON_ERROR_STOP on\r?$/m, "");
        const results = await client.query(sql);
        for (const result of Array.isArray(results) ? results : [results]) {
            for (const row of result.rows) if (row.actor) console.log(row.actor, row.visible.join(" / "));
        }
        console.log("Verified " + suite);
    }
} finally {
    await client.query("rollback").catch(() => {});
    await client.end();
}
