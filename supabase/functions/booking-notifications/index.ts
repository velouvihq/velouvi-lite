type Job = {
  event_id: string;
  lease: string;
  kind: string;
  recipient_email: string | null;
  reference: string;
  starts_at: string | null;
  timezone: string | null;
  studio: string;
};

const labels: Record<string, string> = {
  "booking.declined": "Booking request declined",
  "appointment.confirmed": "Appointment confirmed",
  "appointment.rescheduled": "Appointment rescheduled",
  "appointment.cancelled": "Appointment cancelled",
};

async function secureMatch(supplied: string, expected: string) {
  const encode = new TextEncoder();
  const [left, right] = await Promise.all([supplied, expected].map(async (value) =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", encode.encode(value))),
  ));
  let different = 0;
  for (let i = 0; i < left.length; i++) different |= left[i] ^ right[i];
  return different === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const workerToken = Deno.env.get("BOOKING_WORKER_TOKEN");
  if (!workerToken || !(await secureMatch(request.headers.get("x-booking-worker-token") ?? "", workerToken))) {
    return new Response(null, { status: 401 });
  }
  if (Deno.env.get("BOOKING_EMAIL_MODE") !== "send") {
    return Response.json({ enabled: false });
  }
  const brevoKey = Deno.env.get("BREVO_API_KEY");
  const sender = Deno.env.get("BOOKING_EMAIL_FROM");
  const url = Deno.env.get("SUPABASE_URL");
  const databaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!brevoKey || !sender || !url || !databaseKey) return Response.json({ error: "worker_not_configured" }, { status: 503 });

  async function rpc(name: string, args: unknown) {
    const response = await fetch(url + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: {
        apikey: databaseKey!,
        Authorization: "Bearer " + databaseKey,
        "Content-Type": "application/json",
        "Content-Profile": "api",
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error("booking database operation failed");
    return await response.json();
  }

  async function send(job: Job) {
    if (!job.recipient_email || !job.starts_at || !job.timezone || !labels[job.kind]) return { outcome: "skipped" };
    let response: Response;
    try {
      const when = new Intl.DateTimeFormat("en-LK", {
        timeZone: job.timezone, dateStyle: "full", timeStyle: "short",
      }).format(new Date(job.starts_at));
      response = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: { "api-key": brevoKey!, "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          sender: { name: "Velouvi Lite", email: sender },
          to: [{ email: job.recipient_email }],
          subject: labels[job.kind],
          textContent: `${labels[job.kind]} at ${job.studio}.\n\nTime: ${when} (${job.timezone})\nReference: ${job.reference}`,
          headers: { idempotencyKey: job.event_id },
        }),
        signal: AbortSignal.timeout(8000),
      });
    } catch {
      return { outcome: "delivery_unknown" };
    }
    if (response.status === 429) return { outcome: "provider_rate_limited" };
    if (response.status >= 500 || response.status === 409) return { outcome: "delivery_unknown" };
    if (!response.ok) return { outcome: "provider_rejected" };
    const result = await response.json().catch(() => ({}));
    return { outcome: "sent", providerId: typeof result.messageId === "string" ? result.messageId : null };
  }

  try {
    const jobs: Job[] = await rpc("claim_booking_notifications", { p_limit: 5 });
    let complete = 0;
    for (const job of jobs) {
      const result = await send(job);
      if (await rpc("finish_booking_notification", {
        p_event: job.event_id, p_lease: job.lease, p_outcome: result.outcome, p_provider_id: result.providerId ?? null,
      })) complete++;
    }
    return Response.json({ claimed: jobs.length, recorded: complete });
  } catch {
    return Response.json({ error: "booking_worker_failed" }, { status: 502 });
  }
});
