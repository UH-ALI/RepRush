/// GET /challenges/daily · POST /challenges/daily/claim (G1, G3).
///
/// One deployed function, two register routes, dispatched on the path tail — the
/// same pattern as `territory`. ALWAYS LIVE, like `movements` and `me`: progress is
/// a read over verified results and the claim is one guarded insert, so there is
/// no risky path worth a LIVE_ENDPOINTS rollback flag.
///
/// Progress counts verified, server-scored results only (api-contract.md
/// §challenges): it is read from `user_daily_movement_reps` (0008), never taken
/// from the client. The claim awards capped XP only — it writes nothing that
/// territory reads (structural rule 4).

import { type Authed, requireUser } from "../_shared/auth.ts";
import {
  clampProgress,
  DAILY_CHALLENGE_XP,
  type DailyTemplate,
  dailyTemplate,
  isComplete,
} from "../_shared/challenges.ts";
import { db } from "../_shared/db.ts";
import { error, ErrorCode, HttpError, json, preflight, respond } from "../_shared/responses.ts";
import { dailyMovementReps, hasClaimed, insertClaim } from "../_shared/repo.ts";
import { utcDay } from "../_shared/validation/session.ts";

interface DailyChallengeOut {
  templateId: string;
  description: string;
  target: number;
  progress: number;
  claimed: boolean;
}

interface ClaimOut {
  claimed: boolean;
  xpAwarded: number;
}

async function readDaily(
  user: Authed,
  template: DailyTemplate,
  day: string,
): Promise<{ reps: number; claimed: boolean }> {
  const client = db();
  const [reps, claimed] = await Promise.all([
    dailyMovementReps(client, user.userId, template.movementId, day),
    hasClaimed(client, user.userId, template.templateId),
  ]);
  return { reps, claimed };
}

async function handleDaily(user: Authed): Promise<DailyChallengeOut> {
  const day = utcDay(Date.now());
  const template = dailyTemplate(day);
  const { reps, claimed } = await readDaily(user, template, day);
  return {
    templateId: template.templateId,
    description: template.description,
    target: template.target,
    progress: clampProgress(reps, template.target),
    claimed,
  };
}

async function handleClaim(user: Authed): Promise<ClaimOut> {
  const day = utcDay(Date.now());
  const template = dailyTemplate(day);
  const { reps, claimed } = await readDaily(user, template, day);

  if (claimed) {
    throw new HttpError(ErrorCode.ALREADY_CLAIMED, 409, "Today's challenge is already claimed.");
  }
  if (!isComplete(reps, template.target)) {
    throw new HttpError(
      ErrorCode.NOT_COMPLETE,
      409,
      `Challenge not complete: ${clampProgress(reps, template.target)}/${template.target}.`,
    );
  }
  // The read above is advisory; the primary key is the real guard against a
  // double tap that slips between the read and this insert.
  const inserted = await insertClaim(db(), {
    userId: user.userId,
    templateId: template.templateId,
    xp: DAILY_CHALLENGE_XP,
  });
  if (!inserted) {
    throw new HttpError(ErrorCode.ALREADY_CLAIMED, 409, "Today's challenge is already claimed.");
  }
  return { claimed: true, xpAwarded: DAILY_CHALLENGE_XP };
}

/** The path tail after the `challenges` function name: ["daily"] or ["daily", "claim"]. */
function routeParts(pathname: string): string[] {
  const parts = pathname.split("/").filter((s) => s.length > 0);
  const idx = parts.indexOf("challenges");
  return idx >= 0 ? parts.slice(idx + 1) : parts;
}

// Not async: dispatches only, `respond` returns the promise (see movements/index.ts).
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    const user = await requireUser(req);
    const route = routeParts(new URL(req.url).pathname).join("/");

    if (route === "daily" && req.method === "GET") return json(await handleDaily(user));
    if (route === "daily/claim" && req.method === "POST") return json(await handleClaim(user));

    return error(
      ErrorCode.MALFORMED_REQUEST,
      `Unknown challenges route: ${req.method} /${route}.`,
      404,
    );
  });
});
