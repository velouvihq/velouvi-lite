import { createHash } from "node:crypto";

type Handler = (request: Request) => Response | Promise<Response>;
let webhook: Handler;
let worker: Handler;
const originalServe = Deno.serve;
try {
    Deno.serve = ((handler: Handler) => { webhook = handler; }) as typeof Deno.serve;
    await import("../supabase/functions/payhere-sandbox/index.ts");
    Deno.serve = ((handler: Handler) => { worker = handler; }) as typeof Deno.serve;
    await import("../supabase/functions/booking-notifications/index.ts");
} finally {
    Deno.serve = originalServe;
}

const id = "a4000000-0000-4000-8000-000000000010";
const lucky = "local-synthetic-merchant-secret";
const md5 = (s: string) => createHash("md5").update(s).digest("hex").toUpperCase();
const check = (passed: unknown, name: string) => { if (!passed) throw new Error(name); };
const request = (body: BodyInit, type: string, headers: Record<string, string> = {}) =>
     new Request("https://test.example", { method: "POST", body, headers: { "Content-Type": type, ...headers } });

Deno.test("PayHere sandbox rejects bad signatures and forwards only verified callbacks", async () => {
    const prior = globalThis.fetch;
    const values: Record<string, string> = {
        PAYHERE_SANDBOX_ENABLED: "true", PAYHERE_SANDBOX_MERCHANT_ID: "12345",
        PAYHERE_SANDBOX_MERCHANT_SECRET: lucky, SUPABASE_URL: "https://supabase.example",
        SUPABASE_SERVICE_ROLE_KEY: "test-service-key", SUPABASE_ANON_KEY: "test-publishable",
    };
    for (const [key,value] of Object.entries(values)) Deno.env.set(key,value);
    let calls = 0;
    globalThis.fetch = (input, init) => {
        calls++;
        const payload = JSON.parse(String(init?.body));
        check(String(input).endsWith("record_payhere_sandbox_event"), "only record RPC expected");
        check(payload.p_amount_minor === 125000 && payload.p_order === id, "provider amount or order not parsed correctly");
        return Promise.resolve(Response.json("applied"));
    };
    try {
        const form = new URLSearchParams({ merchant_id: "12345", order_id: id, payhere_amount: "1250.00",
            payhere_currency: "LKR", status_code: "2", payment_id: "sandbox-ref", md5sig: "0".repeat(32) });
        check((await webhook(request(form, "application/x-www-form-urlencoded"))).status === 403, "invalid digest was accepted");
        check(calls === 0, "invalid callback reached database");
        form.set("md5sig", md5("12345" + id + "1250.00" + "LKR" + "2" + md5(lucky)));
        check((await webhook(request(form, "application/x-www-form-urlencoded"))).status === 200, "signed test callback rejected");
        check(calls === 1, "signed callback did not reach database");
    } finally {
        globalThis.fetch = prior;
        for (const key of Object.keys(values)) Deno.env.delete(key);
    }
});

Deno.test("Brevo worker authenticates calls and is inactive until explicitly enabled", async () => {
    const prior = globalThis.fetch;
    Deno.env.set("BOOKING_WORKER_TOKEN","synthetic-token");
    Deno.env.set("BOOKING_EMAIL_MODE","disabled");
    globalThis.fetch = () => { throw new Error("disabled worker attempted delivery"); };
    try {
        check((await worker(request("","application/json"))).status === 401, "anonymous worker request allowed");
        const response = await worker(request("","application/json",{"x-booking-worker-token":"synthetic-token"}));
        check(response.ok && (await response.json()).enabled === false, "worker should be disabled without send mode");
    } finally {
        globalThis.fetch = prior;
        Deno.env.delete("BOOKING_WORKER_TOKEN");
        Deno.env.delete("BOOKING_EMAIL_MODE");
    }
});
