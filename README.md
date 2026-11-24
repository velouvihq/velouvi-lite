# Velouvi Lite

Velouvi Lite runs a multi-tenant booking pilot with Discover, a studio workspace and a customer visits view. The supplied identity and booking migrations retain their IDs and contents. The app uses Supabase Auth and calls scoped functions in the `api` schema. Internal tables and credentials stay behind the API.

## Run on the existing Windows project

Use Node.js 22.12 or later and start Docker Desktop. Double-click `START_LOCAL_PILOT.cmd`, or run these commands in a terminal at the project root:

```powershell
npm ci
npx supabase start
npx supabase migration up --local
npm run db:setup-demo
npm run dev
```

If Supabase is already running and cannot find the `api` schema after the migration, run `npx supabase stop` and `npx supabase start` so the local API reloads `supabase/config.toml`. These commands leave the existing local migration history in place. The demo setup uses localhost and adds one synthetic studio with three services. It prints the two local-only demo logins and creates `.env.local` with the public browser configuration if the file is absent.

Open [http://127.0.0.1:3000](http://127.0.0.1:3000). In **Discover**, choose **Velouvi Studio**, select a future Monday–Saturday time within 09:00–17:00 Sri Lanka time and submit a request with a synthetic email. In **Studio workspace**, sign in as the printed owner, open **Bookings** and accept the request. The confirmed appointment appears in the calendar. Use the separate platform moderator login to review and publish listings. Owner account management and directory access are organization-scoped. A branch manager can use the assigned branch inbox without acquiring organization-wide client directory access.

**My visits** uses a verified customer login plus a one-time claim code issued by the owner from **Clients**. Local test auth emails appear in [Mailpit](http://127.0.0.1:54324). Give any claim code directly to its intended customer. The API verifies a confirmed matching account email as well as the code before linking records.

An owner can create a branch-specific Manager or Team Member invitation in **Team**. The recipient signs in with the confirmed email and redeems the code in **Join a branch**. The owner can revoke that branch assignment without affecting roles at other locations.

## Verify

```powershell
npm run test:db
npm run test:booking-races
npm run build
```

With Deno installed, run `deno test --allow-env tests/edge-functions.test.ts` to verify the Edge handlers with simulated providers.

The SQL test suites run isolated fixtures inside transactions and roll them back. Race tests create and drop a separate throwaway database on local PostgreSQL and exercise two actual connections. The default connection is the local Supabase PostgreSQL port. Set `VELOUVI_TEST_DB_URL` or `VELOUVI_POSTGRES_ADMIN_URL` to a different **local** connection when needed. The isolated race test database uses a minimal Auth identity stub.

## Pilot scope

- Discover shows only published allowlisted records. A listing edit returns it to moderation. Owners can create a business, add branches, add services and staff profiles, and configure shared weekly opening hours.
- Customers can check availability and submit guest requests. Submission does not reserve a slot. Authorized staff revalidate the slot at acceptance. The database retains the original booking when a reschedule fails.
- Branch resources and staff availability affect assignments, including staff scheduled at different branches. The pilot UI adds a staff profile and applies a shared schedule. Complex rota editing, staff profile linking and multi-service appointments still require product work.
- Free inbox and calendar remain usable after a seven-day Lite trial ends. The entitlement and administrative subscription foundation does not collect subscription fees.
- The database supports restricted contacts, verified one-time claims, consent history, and revocable appointment-only sharing. Duplicate marking records an audited association while keeping original histories attached to their original IDs.
- Bulk CRM merging, full staff and resource management, POS and inventory, advanced paid features and marketing are outside this pilot release.

## Test integration settings

Transactional email and the PayHere sandbox are opt-in. They are disabled until configured. Deploy functions only to the test environment, and expose the `api` schema in the test project's Data API settings. Keep `core`, `ops`, `commerce`, `billing`, `private`, and `marketplace` off the public API.

| Function | Private server settings | Behavior |
| --- | --- | --- |
| `booking-notifications` | `BOOKING_WORKER_TOKEN`, `BOOKING_EMAIL_MODE=send`, `BREVO_API_KEY`, `BOOKING_EMAIL_FROM` | A scheduler can send an authenticated POST with `x-booking-worker-token`. A configured verified Brevo sender is required. Ambiguous sends stay in a review state and are not automatically repeated. |
| `payhere-sandbox` | `PAYHERE_SANDBOX_ENABLED=true`, `PAYHERE_SANDBOX_MERCHANT_ID`, `PAYHERE_SANDBOX_MERCHANT_SECRET` | Owner-authenticated JSON requests prepare sandbox checkout fields. Configure the test checkout form, authorized origin, and public sandbox callback URL against the merchant account. Verified callbacks update only the sandbox ledger. |

Schedule the notification worker and hold cleanup in the target test project after configuring their credentials. For hold cleanup use the service-only `expire_booking_holds` RPC. Sender and merchant verification, recurring billing, refunds, managed settlements and production release are separate integration milestones. Keep provider credentials out of `.env.local` and browser bundles.

## Before a real-data release

Use a separate staging project to verify authentication, public request throttling, secrets, backups and restoration, worker scheduling, monitoring, and the end-to-end provider flows. Confirm privacy, data residency, retention and payment arrangements for the intended launch using the [Sri Lanka Data Protection Authority](https://www.dpa.gov.lk/Background) and [Central Bank of Sri Lanka](https://www.cbsl.gov.lk/en/node/19848) as starting points.

## Release state

Verified using clean PostgreSQL replay, SQL role assertions, multi-connection race tests, and a local browser session backed by the database with simulated Supabase HTTP. Run the verification commands against the intended Supabase test project before deployment. The repository handoff uses the `codex/booking-foundation` branch and includes no environment files or service credentials.
