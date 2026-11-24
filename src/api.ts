import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
export const supabase = url && key ? createClient(url, key, { db: { schema: "api" } }) : null;

export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
    if (!supabase) throw new Error("Connect a test Supabase project to continue.");
    const { data, error } = await supabase.rpc(name, args);
    if (error) throw new Error(error.message);
    return data as T;
}

export type Listing = { slug: string; display_name: string; description: string; city: string | null; timezone: string };
export type Service = { variant_id: string; service_name: string; variant_name: string; duration_minutes: number; price_minor: number; currency: string };
export type Location = { id: string; organization_id: string; name: string; timezone: string; listing_slug: string | null; listing_status: string | null };
export type InboxItem = { id: string; starts_at: string; ends_at: string; service: string; guest_name: string | null; guest_email: string | null };
export type Appointment = { id: string; starts_at: string; ends_at: string; status: string; service: string | null };
export type Plan = { plan: string; trial_ends_at: string | null; trial_used: boolean; features: string[] };
export type Availability = { available: boolean; ends_at?: string; price_minor?: number; currency?: string };

export function bookingInstant(value: string, timezone: string): string {
    if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d$/.test(value)) throw new Error("Pick a valid date and time.");
    const local = new Date(value + ":00Z").getTime();
    const printer = new Intl.DateTimeFormat("en", {
        timeZone: timezone, year: "numeric", month: "numeric", day: "numeric",
        hour: "numeric", minute: "numeric", second: "numeric", hourCycle: "h23",
    });
    const wallTime = (instant: number) => {
        const fields = Object.fromEntries(printer.formatToParts(instant).map(({ type, value }) => [type, Number(value)]));
        return Date.UTC(fields.year, fields.month - 1, fields.day, fields.hour, fields.minute, fields.second);
    };
    const candidates = new Set([local - 86400000, local + 86400000].map((probe) => local - (wallTime(probe) - probe)));
    const matching = [...candidates].filter((instant) => wallTime(instant) === local);
    if (!matching.length) throw new Error("That time does not exist in the branch time zone. Choose another time.");
    if (matching.length > 1) throw new Error("That time is ambiguous in the branch time zone. Choose another time.");
    return new Date(matching[0]).toISOString();
}

export function timeLabel(instant: string, timezone: string) {
    return new Intl.DateTimeFormat("en-LK", {
        timeZone: timezone, dateStyle: "medium", timeStyle: "short",
    }).format(new Date(instant));
}

export function money(amount: number, currency: string) {
    const formatter = new Intl.NumberFormat("en-LK", { style: "currency", currency });
    return formatter.format(amount / 10 ** formatter.resolvedOptions().maximumFractionDigits!);
}
