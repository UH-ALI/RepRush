/// GET /me — handle, level, XP, lifetime RepScore and unlocked movements (A2).
/// POST /me `{ handle }` — rename yourself; answers with the updated profile.
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
///
/// Renaming is the only profile write, and it goes through here rather than a
/// client-side table update because every table is RLS deny-all: the rules in
/// `_shared/handles.ts` are enforced where the client can't skip them. POST, not
/// PATCH, because the client transport speaks GET and POST only.

import { type Authed, requireUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { error, ErrorCode, json, preflight, respond } from "../_shared/responses.ts";
import { HANDLE_MAX, HANDLE_MIN, normaliseHandle } from "../_shared/handles.ts";
import {
  challengeXp,
  lifetimeScore,
  loadProfile,
  loadUnlocked,
  updateHandle,
} from "../_shared/repo.ts";
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

async function handleRename(req: Request, user: Authed): Promise<Response> {
  const raw: unknown = await req.json().catch(() => null);
  const handle = normaliseHandle((raw as { handle?: unknown } | null)?.handle);
  if (handle === null) {
    return error(
      ErrorCode.INVALID_HANDLE,
      `A handle is ${HANDLE_MIN}-${HANDLE_MAX} letters or digits, with spaces, _ . - between.`,
      422,
    );
  }
  if (!(await updateHandle(db(), user.userId, handle))) {
    return error(ErrorCode.HANDLE_TAKEN, `"${handle}" is taken.`, 409);
  }
  return json(await handleMe(user));
}

// Not async: dispatches only, `respond` returns the promise (see movements/index.ts).
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    if (req.method !== "GET" && req.method !== "POST") {
      return error(ErrorCode.MALFORMED_REQUEST, "me is GET or POST only.", 405);
    }
    const user = await requireUser(req);
    if (req.method === "POST") return await handleRename(req, user);
    return json(await handleMe(user));
  });
});
