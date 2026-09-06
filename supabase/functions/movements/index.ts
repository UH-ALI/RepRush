/// GET /movements — the catalogue plus per-user state (A configs, C-7 tree).
///
/// ALWAYS LIVE, and deliberately outside the `LIVE_ENDPOINTS` mechanism that the
/// other two routes sit behind. backend-scaffolding.md §6 already calls this one
/// out: "this one can be live today — it's a seed-table read". There is no
/// interesting failure mode to roll back from, and a stub for it would have to
/// duplicate all 18 seeded movements by hand — a copy that would go stale the
/// first time a difficulty multiplier is tuned, silently, in a place nobody would
/// think to look.
///
/// `repsTowardNextTier` is the one field that is real data standing in for an
/// unimplemented rule. It reports reps EARNED in submitted, non-voided sessions;
/// the threshold that converts that total into a tier unlock is B-14's and does
/// not exist yet, so the client can render progress but must not render a
/// denominator it invents.

import { type Authed, requireUser } from "../_shared/auth.ts";
import { toMovementRow } from "../_shared/catalogue.ts";
import { db } from "../_shared/db.ts";
import { error, ErrorCode, json, preflight, respond } from "../_shared/responses.ts";
import { loadMovements, loadUnlocked, repsByMovement } from "../_shared/repo.ts";

export interface MovementResponse {
  id: string;
  family: string;
  tier: number;
  difficulty: number;
  measurementType: string;
  unlocked: boolean;
  repsTowardNextTier: number;
}

async function handleMovements(user: Authed): Promise<MovementResponse[]> {
  const client = db();

  const [rows, unlocked, reps] = await Promise.all([
    loadMovements(client),
    loadUnlocked(client, user.userId),
    repsByMovement(client, user.userId),
  ]);

  return rows.map((row) => {
    // Through `toMovementRow` rather than reading the columns directly: it is the
    // same coercion the scorer uses, so a `numeric`-as-string surprise breaks here
    // and in scoring identically instead of only in one of them.
    const movement = toMovementRow(row);
    return {
      id: movement.id,
      family: movement.family,
      tier: movement.tier,
      difficulty: movement.difficulty,
      measurementType: movement.measurementType,
      unlocked: unlocked.has(movement.id),
      repsTowardNextTier: reps.get(movement.id) ?? 0,
    };
  });
}

// Not async: this handler only dispatches, and `respond` already returns the
// promise. An `async` that never awaits is what require-await flags.
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    if (req.method !== "GET") {
      return error(ErrorCode.MALFORMED_REQUEST, "movements is GET only.", 405);
    }
    const user = await requireUser(req);
    return json(await handleMovements(user));
  });
});
