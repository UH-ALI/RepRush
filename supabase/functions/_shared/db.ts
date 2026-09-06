/// The service-role Supabase client — and nothing else.
///
/// Every write in this backend goes through `_shared/repo.ts` on top of this
/// client, which is what makes the deny-all RLS posture in 0001 hold: `anon` and
/// `authenticated` have no write policy on any table, so the Edge Functions are
/// the only writers and there is exactly one place to audit them.
///
/// THIS IS THE DENO BOUNDARY. It is the only module under `_shared/` with an
/// `npm:` import, and nothing in `evidence/`, `scoring/`, `validation/`,
/// `catalogue.ts`, `outcome.ts`, `responses.ts` or `env.ts` imports it. That is
/// what keeps the rest of the tree loadable under plain Node, which is how the
/// fixture and golden suite runs without a Deno install. Env reads live in
/// `_shared/env.ts` precisely so they are not trapped behind this import.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { env } from "./env.ts";

export type Db = SupabaseClient;

let cached: Db | null = null;

/**
 * The service-role client. Cached because Edge Function isolates are long-lived
 * and `createClient` is not free.
 *
 * `persistSession: false` and `autoRefreshToken: false` are both required: the
 * service key does not expire, and an isolate that tried to persist or refresh a
 * session would be writing to a storage backend it may not have.
 */
export function db(): Db {
  if (cached) return cached;
  cached = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}
