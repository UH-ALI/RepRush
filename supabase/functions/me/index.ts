/// GET /me — handle, level, XP, lifetime RepScore and unlocked movements (A2).
///
/// ALWAYS LIVE, like `movements`: it is a read over tables that already exist, so
/// there is no interesting failure mode to roll back from and no reason to keep a
/// canned profile in front of real accounts. The client's stub `me()` remains the
/// stub-mode answer.
///
/// XP = round(lifetime RepScore) + claimed challenge XP. That is the same number
/// session-submit uses as `priorLifetimeXp`, so the level shown on the profile and
/// the level a submission reports can never disagree. The curve itself is the
/// placeholder in `stubs/consequences.ts` (B-15 owns the real one).

import { type Authed, requireUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { error, ErrorCode, json, preflight, respond } from "../_shared/responses.ts";
import { challengeXp, lifetimeScore, loadProfile, loadUnlocked } from "../_shared/repo.ts";
import { levelForXp } from "../_shared/stubs/consequences.ts";

export interface MeResponse {
  handle: string;
  avatarUrl: string | null;
  level: number;
  xp: number;
  lifetimeRepScore: number;
  homeSpotId: string | null;
  unlockedTiers: string[];
}

async function handleMe(user: Authed): Promise<MeResponse> {
  const client = db();
  const [profile, score, bonusXp, unlocked] = await Promise.all([
    loadProfile(client, user.userId),
    lifetimeScore(client, user.userId),
    challengeXp(client, user.userId),
    loadUnlocked(client, user.userId),
  ]);
  const xp = Math.round(score) + bonusXp;
  return {
    handle: profile.handle,
    avatarUrl: profile.avatarUrl,
    level: levelForXp(xp),
    xp,
    lifetimeRepScore: score,
    // Spots have no table yet (B-12), so there is no home spot to report. Null,
    // not a fabricated id — the same rule consequences.ts follows.
    homeSpotId: null,
    unlockedTiers: [...unlocked].sort(),
  };
}

// Not async: dispatches only, `respond` returns the promise (see movements/index.ts).
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    if (req.method !== "GET") {
      return error(ErrorCode.MALFORMED_REQUEST, "me is GET only.", 405);
    }
    const user = await requireUser(req);
    return json(await handleMe(user));
  });
});
