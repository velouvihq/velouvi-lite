import { createHash, timingSafeEqual } from "node:crypto";

const md5 = (value: string) => createHash("md5").update(value, "utf8").digest("hex").toUpperCase();
const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const AMOUNT = /^\d{1,9}\.\d{2}$/;
const checkoutUrl = "https://sandbox.payhere.lk/pay/checkout";

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (Deno.env.get("PAYHERE_SANDBOX_ENABLED") !== "true") return new Response(null, { status: 404 });
  const merchant = Deno.env.get("PAYHERE_SANDBOX_MERCHANT_ID");
  const secret = Deno.env.get("PAYHERE_SANDBOX_MERCHANT_SECRET");
  const project = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!merchant || !secret || !project || !serviceKey || !anonKey) return new Response(null, { status: 503 });
  const body = await request.text();
  if (body.length > 4096) return new Response(null, { status: 413 });

  async function rpc(name: string, args: unknown, key: string, authorization: string) {
    return await fetch(project + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: { apikey: key, Authorization: authorization, "Content-Profile": "api", "Content-Type": "application/json" },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(8000),
    });
  }

  try {
    const contentType = request.headers.get("content-type") ?? "";
    if (contentType.startsWith("application/json")) {
      const authorization = request.headers.get("Authorization");
      if (!authorization?.startsWith("Bearer ")) return new Response(null, { status: 401 });
      const input = JSON.parse(body);
      if (!UUID.test(input?.appointmentId ?? "")) return new Response(null, { status: 400 });
      const result = await rpc("prepare_payhere_sandbox_order", { p_appointment: input.appointmentId }, anonKey, authorization);
      if (!result.ok) return Response.json({ error: "order_unavailable" }, { status: result.status });
      const order = await result.json();
      if (!UUID.test(order.id) || !AMOUNT.test(order.amount) || order.currency !== "LKR") {
        return Response.json({ error: "invalid_order" }, { status: 502 });
      }
      if (!["created", "pending"].includes(order.status)) return Response.json({ orderId: order.id, status: order.status });
      return Response.json({
        checkoutUrl, orderId: order.id, status: order.status,
        fields: {
          merchant_id: merchant, order_id: order.id, amount: order.amount, currency: order.currency,
          hash: md5(merchant + order.id + order.amount + order.currency + md5(secret)),
        },
      });
    }

    if (!contentType.startsWith("application/x-www-form-urlencoded")) return new Response(null, { status: 415 });
    const form = new URLSearchParams(body);
    const only = (key: string) => form.getAll(key).length === 1 ? form.get(key)! : "";
    const order = only("order_id");
    const amount = only("payhere_amount");
    const currency = only("payhere_currency");
    const status = only("status_code");
    const signature = only("md5sig").toUpperCase();
    if (only("merchant_id") !== merchant || !UUID.test(order) || !AMOUNT.test(amount)
      || currency !== "LKR" || !["2", "0", "-1", "-2", "-3"].includes(status) || !/^[0-9A-F]{32}$/.test(signature)) {
      return new Response(null, { status: 400 });
    }
    const expected = md5(merchant + order + amount + currency + status + md5(secret));
    const encoder = new TextEncoder();
    if (!timingSafeEqual(encoder.encode(signature), encoder.encode(expected))) return new Response(null, { status: 403 });
    const reference = only("payment_id");
    const result = await rpc("record_payhere_sandbox_event", {
      p_order: order, p_amount_minor: Number(amount.replace(".", "")), p_currency: currency, p_status: status,
      p_provider_ref: /^[A-Za-z0-9_-]{1,100}$/.test(reference) ? reference : null,
    }, serviceKey, "Bearer " + serviceKey);
    return new Response(null, { status: result.ok ? 200 : 502 });
  } catch {
    return new Response(null, { status: 502 });
  }
});
