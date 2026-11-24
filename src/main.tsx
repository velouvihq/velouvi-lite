import { createRoot } from "react-dom/client";
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import {
    supabase, rpc, bookingInstant, timeLabel, money,
    type Listing, type Service, type Location, type InboxItem, type Appointment, type Availability, type Plan,
} from "./api";
import "./style.css";

const errorText = (error: unknown) => error instanceof Error ? error.message : "Something went wrong.";
const fields = (event: FormEvent<HTMLFormElement>) => Object.fromEntries(new FormData(event.currentTarget).entries()) as Record<string, string>;

function Status({ error, status }: { error: string; status: string }) {
    if (error) return <p className="status error" role="alert">{error}</p>;
    return status ? <p className="status" role="status">{status}</p> : null;
}

function useAction() {
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState("");
    const [status, setStatus] = useState("");
    const locked = useRef(false);
    async function run(action: () => Promise<string | void>) {
        if (locked.current) return;
        locked.current = true;
        setBusy(true);
        setError("");
        setStatus("");
        try { setStatus((await action()) ?? ""); }
        catch (error) { setError(errorText(error)); }
        finally { locked.current = false; setBusy(false); }
    }
    return { busy, error, status, run };
}

function Discover() {
    const [listings, setListings] = useState<Listing[]>([]);
    const [slug, setSlug] = useState(new URLSearchParams(window.location.search).get("studio") ?? "");
    const [services, setServices] = useState<Service[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");
    const [menuError, setMenuError] = useState("");
    const [menuBusy, setMenuBusy] = useState(false);
    const selected = listings.find((listing) => listing.slug === slug);

    useEffect(() => {
        let active = true;
        rpc<Listing[]>("discover_listings").then((items) => {
            if (!active) return;
            setListings(items);
            setSlug((selection) => items.some((item) => item.slug === selection) ? selection : selection || items[0]?.slug || "");
        }).catch((error) => { if (active) setError(errorText(error)); })
            .finally(() => { if (active) setLoading(false); });
        return () => { active = false; };
    }, []);

    useEffect(() => {
        if (!slug) return;
        let active = true;
        setServices([]);
        setMenuError("");
        setMenuBusy(true);
        rpc<Service[]>("discover_services", { p_slug: slug }).then((items) => { if (active) setServices(items); })
            .catch((error) => { if (active) setMenuError(errorText(error)); })
            .finally(() => { if (active) setMenuBusy(false); });
        return () => { active = false; };
    }, [slug]);

    return <>
        <h1>Find a studio</h1>
        <p className="subtle">Choose a studio and request a time for your next visit.</p>
        <Status error={error} status={loading ? "Loading studios…" : ""} />
        {!loading && !error && !listings.length && <p>No studios are published yet.</p>}
        {!!listings.length && <div className="layout">
            <aside className="card">
                <h2>Studios</h2>
                <div className="studio-list">{listings.map((listing) =>
                    <button key={listing.slug} type="button" aria-pressed={slug === listing.slug} onClick={() => {
                        setSlug(listing.slug);
                        const route = new URL(window.location.href);
                        route.searchParams.set("studio", listing.slug);
                        window.history.replaceState({}, "", route);
                    }}>{listing.display_name}{listing.city && <span>{listing.city}</span>}</button>
                )}</div>
            </aside>
            <section className="card">
                {selected ? <>
                    <h2>{selected.display_name}</h2>
                    {selected.description && <p className="subtle">{selected.description}</p>}
                    <Status error={menuError} status={menuBusy ? "Loading services…" : ""} />
                    {!!services.length && <BookingForm key={selected.slug} listing={selected} services={services} />}
                    {!menuBusy && !menuError && !services.length && <p>This studio has no bookable services yet.</p>}
                </> : <p>This studio is unavailable. Select another studio.</p>}
            </section>
        </div>}
    </>;
}

function BookingForm({ listing, services }: { listing: Listing; services: Service[] }) {
    const task = useAction();
    const [quote, setQuote] = useState<Availability | null>(null);
    const [reference, setReference] = useState("");
    const request = useRef<{ fingerprint: string; key: string } | null>(null);
    function submit(event: FormEvent<HTMLFormElement>) {
        event.preventDefault();
        const f = fields(event);
        const check = (event.nativeEvent as SubmitEvent).submitter?.getAttribute("value") === "check";
        task.run(async () => {
            const args = { p_slug: listing.slug, p_variant: f.service, p_start: bookingInstant(f.time, listing.timezone) };
            if (check) {
                const available = await rpc<Availability>("booking_availability", args);
                setQuote(available);
                return available.available ? "This time is currently available." : "This time is unavailable. Try another time.";
            }
            if (f.name.trim().length < 2 || !f.email) throw new Error("Enter your name and email to send the request.");
            const data = { ...args, p_name: f.name, p_email: f.email };
            const fingerprint = JSON.stringify(data);
            if (request.current?.fingerprint !== fingerprint) request.current = { fingerprint, key: crypto.randomUUID() };
            const id = await rpc<string>("submit_booking_request", { ...data, p_key: request.current.key });
            setReference(id);
        });
    }
    if (reference) return <div className="confirmation">
        <h3>Request received</h3><p>The studio will review your request before the appointment is confirmed.</p>
        <p className="subtle">Reference {reference}</p>
        <button type="button" onClick={() => { request.current = null; setReference(""); setQuote(null); }}>Request another time</button>
    </div>;
    return <form className="form" onSubmit={submit} onChange={() => setQuote(null)}>
        <label>Service<select name="service" required>{services.map((service) => <option key={service.variant_id} value={service.variant_id}>
            {service.service_name} · {service.variant_name} · {service.duration_minutes} min · {money(service.price_minor, service.currency)}
        </option>)}</select></label>
        <label>Preferred time <small>{listing.timezone}</small><input type="datetime-local" name="time" required /></label>
        <div className="fields">
            <label>Name<input name="name" autoComplete="name" maxLength={160} /></label>
            <label>Email<input type="email" name="email" autoComplete="email" maxLength={254} /></label>
        </div>
        <div className="actions">
            <button type="submit" value="check" disabled={task.busy}>Check availability</button>
            <button type="submit" value="send" className="primary" disabled={task.busy}>Send request</button>
        </div>
        <Status error={task.error} status={task.status} />
        {quote?.available && quote.price_minor !== undefined && quote.currency && <p>Quoted price {money(quote.price_minor, quote.currency)}</p>}
    </form>;
}

function SignIn() {
    const task = useAction();
    const [register, setRegister] = useState(false);
    function submit(event: FormEvent<HTMLFormElement>) {
        event.preventDefault();
        const f = fields(event);
        task.run(async () => {
            if (register) {
                const result = await supabase!.auth.signUp({ email: f.email, password: f.password });
                if (result.error) throw result.error;
                return result.data.session ? "Account created." : "Check your inbox and confirm your email.";
            }
            const result = await supabase!.auth.signInWithPassword({ email: f.email, password: f.password });
            if (result.error) throw result.error;
        });
    }
    return <section className="card narrow">
        <h1>{register ? "Create an account" : "Sign in"}</h1>
        <form className="form" onSubmit={submit}>
            <label>Email<input type="email" name="email" autoComplete="email" required /></label>
            <label>Password<input type="password" name="password" minLength={8} autoComplete={register ? "new-password" : "current-password"} required /></label>
            <div className="actions">
                <button className="primary" disabled={task.busy}>{register ? "Create account" : "Sign in"}</button>
                <button type="button" onClick={() => setRegister(!register)}>{register ? "Use existing account" : "Create an account"}</button>
            </div>
        </form>
        <Status error={task.error} status={task.status} />
    </section>;
}

function SetupForm({ title, children, action, submit = "Save" }: {
    title: string; children: ReactNode; action: (f: Record<string, string>) => Promise<string | void>; submit?: string;
}) {
    const task = useAction();
    return <section className="card">
        <h2>{title}</h2>
        <form className="form" onSubmit={(event) => {
            event.preventDefault();
            const f = fields(event);
            task.run(() => action(f));
        }}>{children}<button className="primary" disabled={task.busy}>{submit}</button></form>
        <Status error={task.error} status={task.status} />
    </section>;
}

function Workspace({ session }: { session: Session }) {
    const [locations, setLocations] = useState<Location[]>([]);
    const [locationId, setLocationId] = useState("");
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState("");
    const [pane, setPane] = useState<"bookings" | "setup" | "clients" | "team" | "join" | "moderation">("bookings");
    async function refreshLocations() {
        const list = await rpc<Location[]>("booking_locations");
        setLocations(list);
        setLocationId((current) => list.some((item) => item.id === current) ? current : list[0]?.id ?? "");
    }
    useEffect(() => {
        refreshLocations().catch((error) => setError(errorText(error))).finally(() => setLoading(false));
    }, []);
    const location = locations.find((item) => item.id === locationId);

    return <>
        <div className="heading-row">
            <div><h1>Studio workspace</h1><p className="subtle">{session.user.email}</p></div>
            <button onClick={() => supabase!.auth.signOut().then(({ error }) => { if (error) setError(error.message); })}>Sign out</button>
        </div>
        <Status error={error} status={loading ? "Loading workspace…" : ""} />
        {!loading && <div className="actions tabs">
            <button type="button" aria-pressed={pane === "bookings"} onClick={() => setPane("bookings")}>Bookings</button>
            <button type="button" aria-pressed={pane === "setup"} onClick={() => setPane("setup")}>Setup</button>
            <button type="button" aria-pressed={pane === "clients"} onClick={() => setPane("clients")}>Clients</button>
            <button type="button" aria-pressed={pane === "team"} onClick={() => setPane("team")}>Team</button>
            <button type="button" aria-pressed={pane === "join"} onClick={() => setPane("join")}>Join a branch</button>
            <button type="button" aria-pressed={pane === "moderation"} onClick={() => setPane("moderation")}>Listing review</button>
        </div>}
        {!loading && pane !== "moderation" && pane !== "join" && (location ? <>
            <label className="branch">Branch<select value={locationId} onChange={(event) => setLocationId(event.target.value)}>
                {locations.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
            </select></label>
            {pane === "bookings" ? <Bookings key={location.id} location={location} />
                : pane === "team" ? <Team key={location.id} location={location} />
                  : pane === "clients" ? <ClientDirectory key={location.organization_id} organization={location.organization_id} />
                  : <StudioSetup key={location.id} location={location} refresh={refreshLocations} />}
        </> : <SetupForm title="Set up your business" submit="Create business" action={async (f) => {
            await rpc("create_booking_business", { p_name: f.name, p_slug: f.slug, p_branch: f.branch });
            await refreshLocations();
        }}>
            <label>Business name<input name="name" required /></label>
            <label>Business slug<input name="slug" placeholder="studio-name" pattern="[a-z0-9]+(-[a-z0-9]+)*" required /></label>
            <label>First branch name<input name="branch" required /></label>
        </SetupForm>)}
        {!loading && pane === "join" && <SetupForm title="Join a branch" submit="Accept invitation" action={async (f) => {
            const id = await rpc<string>("accept_team_invitation", { p_token: f.token.trim() });
            await refreshLocations();
            setLocationId(id);
            setPane("bookings");
        }}>
            <label>Invitation code<input name="token" autoComplete="off" required /></label>
        </SetupForm>}
        {!loading && pane === "moderation" && <Moderation />}
    </>;
}

type TeamMember = { assignment_id: string; display_name: string; role: string };

function Team({ location }: { location: Location }) {
    const task = useAction();
    const [invite, setInvite] = useState("");
    const [items, setItems] = useState<TeamMember[]>([]);
    const [error, setError] = useState("");
    const [pending, setPending] = useState("");
    async function refresh() { setItems(await rpc<TeamMember[]>("booking_team", { p_location: location.id })); }
    useEffect(() => { refresh().catch((error) => setError(errorText(error))); }, [location.id]);
    if (error) return <Status error={error} status="" />;
    return <div className="layout">
        <SetupForm title="Invite a teammate" submit="Generate invite" action={async (f) => {
            setInvite(await rpc<string>("issue_team_invitation", { p_location: location.id, p_email: f.email, p_role: f.role }));
            return "Share this code directly with the teammate. It expires in two days.";
        }}>
            <label>Teammate email<input name="email" type="email" required /></label>
            <label>Branch role<select name="role"><option value="team_member">Team member</option><option value="manager">Manager</option></select></label>
            {invite && <label>Invitation code<input readOnly onFocus={(event) => event.currentTarget.select()} value={invite} /></label>}
        </SetupForm>
        <section className="card">
            <h2>Branch access</h2>
            {!items.length && <p className="subtle">No teammates assigned to this branch yet.</p>}
            <Status error={task.error} status={task.status} />
            {items.map((item) => <article className="row" key={item.assignment_id}>
                <h3>{item.display_name}</h3><p>{item.role === "manager" ? "Manager" : "Team member"}</p>
                {pending !== item.assignment_id ? <button onClick={() => setPending(item.assignment_id)}>Remove access</button>
                    : <div className="actions"><button disabled={task.busy} onClick={() => task.run(async () => {
                        await rpc("revoke_booking_team_assignment", { p_assignment: item.assignment_id });
                        await refresh();
                        setPending("");
                        return "Branch access removed.";
                    })}>Confirm removal</button><button onClick={() => setPending("")}>Keep access</button></div>}
            </article>)}
        </section>
    </div>;
}

function Bookings({ location }: { location: Location }) {
    const [inbox, setInbox] = useState<InboxItem[]>([]);
    const [calendar, setCalendar] = useState<Appointment[]>([]);
    const [inboxError, setInboxError] = useState("");
    const [calendarError, setCalendarError] = useState("");
    const [loading, setLoading] = useState(true);
    const task = useAction();
    async function refresh() {
        setInboxError("");
        setCalendarError("");
        setLoading(true);
        const now = new Date();
        const until = new Date(now.getTime() + 60 * 86400000);
        await Promise.all([
            rpc<InboxItem[]>("booking_inbox", { p_location: location.id }).then(setInbox).catch((error) => {
                setInbox([]); setInboxError(errorText(error));
            }),
            rpc<Appointment[]>("booking_calendar", {
                p_location: location.id, p_from: now.toISOString(), p_to: until.toISOString(),
            }).then(setCalendar).catch((error) => { setCalendar([]); setCalendarError(errorText(error)); }),
        ]);
        setLoading(false);
    }
    useEffect(() => { void refresh(); }, [location.id]);

    function decide(id: string, accept: boolean) {
        task.run(async () => {
            await rpc("decide_booking_request", { p_request: id, p_accept: accept });
            await refresh();
            return accept ? "Appointment confirmed." : "Request declined.";
        });
    }
    return <>
        <div className="actions"><button type="button" disabled={task.busy || loading} onClick={() => void refresh()}>Refresh</button></div>
        <Status error={task.error} status={task.status} />
        <div className="layout">
            <section className="card">
                <h2>Booking inbox</h2>
                <Status error={inboxError} status={loading ? "Loading requests…" : ""} />
                {!loading && !inboxError && !inbox.length && <p className="subtle">No requests to review.</p>}
                {inbox.map((item) => <article className="row" key={item.id}>
                    <h3>{item.service}</h3>
                    <p>{timeLabel(item.starts_at, location.timezone)}</p>
                    <p className="subtle">{item.guest_name} · {item.guest_email}</p>
                    <div className="actions">
                        <button disabled={task.busy} onClick={() => decide(item.id, false)}>Decline</button>
                        <button className="primary" disabled={task.busy} onClick={() => decide(item.id, true)}>Accept</button>
                    </div>
                </article>)}
            </section>
            <section className="card">
                <h2>Appointment calendar</h2>
                <Status error={calendarError} status={loading ? "Loading appointments…" : ""} />
                {!loading && !calendarError && !calendar.length && <p className="subtle">No upcoming appointments.</p>}
                {calendar.map((item) => <CalendarRow key={item.id} item={item} timezone={location.timezone}
                    busy={task.busy} act={(action) => task.run(async () => { const status = await action(); await refresh(); return status; })} />)}
            </section>
        </div>
    </>;
}

function CalendarRow({ item, timezone, busy, act }: {
    item: Appointment; timezone: string; busy: boolean; act: (fn: () => Promise<string>) => void;
}) {
    const [moving, setMoving] = useState(false);
    const [cancelling, setCancelling] = useState(false);
    return <article className="row">
        <h3>{item.service ?? "Appointment"}</h3>
        <p>{timeLabel(item.starts_at, timezone)} <span className="tag">{item.status}</span></p>
        {item.status === "confirmed" && <div className="actions">
            <button type="button" onClick={() => setMoving(!moving)}>Reschedule</button>
            <button type="button" onClick={() => setCancelling(!cancelling)}>Cancel appointment</button>
        </div>}
        {moving && <form className="form inline" onSubmit={(event) => {
            event.preventDefault();
            const f = fields(event);
            act(async () => {
                await rpc("reschedule_appointment", { p_appointment: item.id, p_start: bookingInstant(f.time, timezone) });
                setMoving(false);
                return "Appointment rescheduled.";
            });
        }}>
            <label>New time <small>{timezone}</small><input name="time" type="datetime-local" required /></label>
            <button disabled={busy} type="submit">Save new time</button>
        </form>}
        {cancelling && <div className="actions inline">
            <button disabled={busy} type="button" onClick={() => act(async () => {
                await rpc("cancel_appointment", { p_appointment: item.id });
                return "Appointment cancelled.";
            })}>Confirm cancellation</button>
            <button type="button" onClick={() => setCancelling(false)}>Keep appointment</button>
        </div>}
    </article>;
}

function StudioSetup({ location, refresh }: { location: Location; refresh: () => Promise<void> }) {
    return <div className="layout setup">
        <SetupForm title="Add a service" submit="Add service" action={async (f) => {
            await rpc("add_bookable_service", { p_location: location.id, p_name: f.name, p_duration: Number(f.duration),
                p_price_minor: Math.round(Number(f.price) * 100) });
            return "Service added.";
        }}>
            <label>Service name<input name="name" required /></label>
            <div className="fields">
                <label>Minutes<input name="duration" type="number" min={1} max={1440} required /></label>
                <label>Price (LKR)<input name="price" type="number" min="0" max="100000000" step="0.01" required /></label>
            </div>
        </SetupForm>
        <SetupForm title="Add a staff profile" action={async (f) => {
            await rpc("add_booking_staff", { p_location: location.id, p_name: f.name });
            return "Staff profile added. Set weekly hours to include this person in availability.";
        }}>
            <label>Staff name<input name="name" required /></label>
        </SetupForm>
        <SetupForm title="Weekly opening hours" action={async (f) => {
            await rpc("set_booking_week", { p_location: location.id, p_days: f.days === "weekdays" ? [1, 2, 3, 4, 5] : [1, 2, 3, 4, 5, 6],
                p_open: f.open, p_close: f.close });
            return "Branch and staff hours saved.";
        }}>
            <p className="subtle">Applies the same hours to all active staff at this branch.</p>
            <label>Open days<select name="days"><option value="six">Monday–Saturday</option><option value="weekdays">Monday–Friday</option></select></label>
            <div className="fields"><label>Open<input name="open" type="time" defaultValue="09:00" required /></label>
            <label>Close<input name="close" type="time" defaultValue="17:00" required /></label></div>
        </SetupForm>
        <ListingSetup location={location} refresh={refresh} />
        <SetupForm title="Add a branch" action={async (f) => {
            await rpc("add_booking_branch", { p_org: location.organization_id, p_name: f.name });
            await refresh();
            return "Branch added. Select it to set up services and hours.";
        }}>
            <label>Branch name<input name="name" required /></label>
        </SetupForm>
        <PlanDetails organization={location.organization_id} />
    </div>;
}

type ReviewListing = { id: string; slug: string; display_name: string; description: string; status: string };

function ListingSetup({ location, refresh }: { location: Location; refresh: () => Promise<void> }) {
    const [draft, setDraft] = useState<ReviewListing | null>(null);
    const [loaded, setLoaded] = useState(false);
    const [error, setError] = useState("");
    useEffect(() => {
        let active = true;
        rpc<ReviewListing[]>("booking_listing_draft", { p_location: location.id })
            .then((list) => { if (active) setDraft(list[0] ?? null); })
            .catch((error) => { if (active) setError(errorText(error)); })
            .finally(() => { if (active) setLoaded(true); });
        return () => { active = false; };
    }, [location.id]);
    if (!loaded || error) return <section className="card"><h2>Discover listing</h2>
        <Status error={error} status={loaded ? "" : "Loading listing…"} /></section>;
    return <SetupForm title="Discover listing" submit="Save for review" action={async (f) => {
        await rpc("save_listing", { p_location: location.id, p_slug: f.slug, p_name: f.name, p_description: f.description });
        await refresh();
        return "Draft saved for platform review.";
    }}>
        {location.listing_status && <p>Status <span className="tag">{location.listing_status}</span></p>}
        <label>Public name<input name="name" defaultValue={draft?.display_name ?? location.name} maxLength={120} required /></label>
        <label>Listing slug<input name="slug" defaultValue={draft?.slug ?? ""} pattern="[a-z0-9]+(-[a-z0-9]+)*" required /></label>
        <label>Description<textarea name="description" defaultValue={draft?.description ?? ""} maxLength={1000} /></label>
    </SetupForm>;
}

function Moderation() {
    const task = useAction();
    const [items, setItems] = useState<ReviewListing[]>([]);
    const [initial, setInitial] = useState(true);
    const [error, setError] = useState("");
    async function refresh() { setItems(await rpc<ReviewListing[]>("listing_review_queue")); }
    useEffect(() => {
        refresh().catch((error) => setError(errorText(error))).finally(() => setInitial(false));
    }, []);
    return <section className="card">
        <h2>Listing review</h2>
        <Status error={error || task.error} status={initial ? "Loading listings…" : task.status} />
        {!initial && !error && !items.length && <p className="subtle">No listings to review.</p>}
        {items.map((item) => <article className="row" key={item.id}>
            <h3>{item.display_name} <span className="tag">{item.status}</span></h3>
            <p>{item.description || "No public description."}</p>
            <p className="subtle">{item.slug}</p>
            <button disabled={task.busy} onClick={() => task.run(async () => {
                const publish = item.status !== "published";
                await rpc("moderate_listing", { p_listing: item.id, p_publish: publish });
                await refresh();
                return publish ? "Listing published." : "Listing unpublished.";
            })}>{item.status === "published" ? "Unpublish" : "Publish"}</button>
        </article>)}
    </section>;
}

function PlanDetails({ organization }: { organization: string }) {
    const task = useAction();
    const [plan, setPlan] = useState<Plan | null>(null);
    const [checked, setChecked] = useState(false);
    return <section className="card">
        <h2>Plan & trial</h2>
        <div className="actions">
            <button disabled={task.busy} onClick={() => task.run(async () => {
                setPlan(await rpc<Plan>("booking_plan_status", { p_org: organization }));
                setChecked(true);
            })}>View plan</button>
            {checked && plan && !plan.trial_used && plan.plan === "free" && <button disabled={task.busy} onClick={() => task.run(async () => {
                setPlan(await rpc<Plan>("start_lite_trial", { p_org: organization }));
                return "Trial started.";
            })}>Start 7-day trial</button>}
        </div>
        {plan && <p>Current plan <strong>{plan.plan === "lite" ? "Lite" : "Free"}</strong>
            {plan.trial_ends_at && <> · Trial ends {timeLabel(plan.trial_ends_at, "Asia/Colombo")}</>}</p>}
        <Status error={task.error} status={task.status} />
    </section>;
}

type Customer = { id: string; display_name: string; is_linked: boolean };
type CustomerAppointment = Appointment & { studio: string; location: string; timezone: string };

function ClientDirectory({ organization }: { organization: string }) {
    const task = useAction();
    const [clients, setClients] = useState<Customer[]>([]);
    const [claim, setClaim] = useState("");
    const [error, setError] = useState("");
    const [loading, setLoading] = useState(true);
    useEffect(() => {
        let active = true;
        rpc<Customer[]>("booking_clients", { p_org: organization })
            .then((data) => { if (active) setClients(data); })
            .catch((error) => { if (active) setError(errorText(error)); })
            .finally(() => { if (active) setLoading(false); });
        return () => { active = false; };
    }, [organization]);
    return <section className="card">
        <h2>Client directory</h2>
        <Status error={error || task.error} status={loading ? "Loading clients…" : task.status} />
        {!loading && !error && !clients.length && <p className="subtle">Clients appear here after you accept a guest booking.</p>}
        {clients.map((client) => <article className="row" key={client.id}>
            <h3>{client.display_name}</h3>
            {client.is_linked ? <p className="subtle">Account linked</p> :
                <button type="button" disabled={task.busy} onClick={() => task.run(async () => {
                    setClaim(await rpc<string>("issue_client_claim", { p_client: client.id }));
                    return "Share the one-time code directly with the verified client.";
                })}>Generate claim code</button>}
        </article>)}
        {claim && <label>One-time claim code<input readOnly value={claim} onFocus={(event) => event.currentTarget.select()} /></label>}
    </section>;
}

function MyVisits() {
    const [items, setItems] = useState<CustomerAppointment[]>([]);
    const [error, setError] = useState("");
    const [loading, setLoading] = useState(true);
    async function refresh() { setItems(await rpc<CustomerAppointment[]>("my_appointments")); }
    useEffect(() => {
        refresh().catch((error) => setError(errorText(error))).finally(() => setLoading(false));
    }, []);
    return <>
        <div className="heading-row"><h1>My visits</h1><button onClick={() => void supabase!.auth.signOut()}>Sign out</button></div>
        <div className="layout">
            <SetupForm title="Link a booking" submit="Redeem code" action={async (f) => {
                await rpc("redeem_client_claim", { p_token: f.token.trim() });
                await refresh();
                return "Booking history linked to your account.";
            }}>
                <label>Claim code<input name="token" autoComplete="off" required /></label>
            </SetupForm>
            <section className="card"><h2>Appointments</h2>
                <Status error={error} status={loading ? "Loading appointments…" : ""} />
                {!loading && !error && !items.length && <p className="subtle">No appointments are linked to this account.</p>}
                {items.map((item) => <article key={item.id} className="row">
                    <h3>{item.service ?? "Visit"} · {item.studio}</h3>
                    <p>{item.location} · {timeLabel(item.starts_at, item.timezone)}</p>
                    <span className="tag">{item.status}</span>
                </article>)}
            </section>
        </div>
    </>;
}

const getArea = () => window.location.hash === "#workspace" ? "workspace"
    : window.location.hash === "#visits" ? "visits" : "discover";

function App() {
    const [area, setArea] = useState(getArea);
    const [session, setSession] = useState<Session | null>(null);
    const [authReady, setAuthReady] = useState(!supabase);
    useEffect(() => {
        const auth = supabase?.auth.onAuthStateChange((_event, current) => { setSession(current); setAuthReady(true); });
        function navigate() { setArea(getArea()); }
        window.addEventListener("hashchange", navigate);
        return () => { auth?.data.subscription.unsubscribe(); window.removeEventListener("hashchange", navigate); };
    }, []);
    return <>
        <header><div className="header-inner">
            <a className="brand" href="#discover">Velouvi <span>Lite</span></a>
            <nav aria-label="Main">
                <a href="#discover" aria-current={area === "discover" ? "page" : undefined}>Discover</a>
                <a href="#workspace" aria-current={area === "workspace" ? "page" : undefined}>Studio workspace</a>
                <a href="#visits" aria-current={area === "visits" ? "page" : undefined}>My visits</a>
            </nav>
        </div></header>
        <main>
            {!supabase ? <section className="card"><h1>Connect your test project</h1><p>Set the Supabase project URL and publishable key in <code>.env.local</code>, then restart the app.</p></section>
              : area === "discover" ? <Discover />
              : !authReady ? <p role="status">Loading sign-in…</p>
              : session && area === "visits" ? <MyVisits key={session.user.id} />
              : session ? <Workspace key={session.user.id} session={session} />
              : <SignIn />}
        </main>
    </>;
}

createRoot(document.getElementById("root")!).render(<App />);
