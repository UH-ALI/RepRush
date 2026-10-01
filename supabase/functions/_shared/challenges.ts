/// Daily challenge rules — which challenge is "today's", and when it is complete
/// (G1, G3). Pure, like `territory.ts`: no I/O and no clock (the caller passes the
/// UTC day), so the rules are unit-testable under plain Node.
///
/// ONE SEEDED CHALLENGE, IDENTICAL FOR EVERYONE (Slice 1). The movement and target
/// are env-tunable rather than hardcoded so the demo can be sized to one set on
/// stage — 50 squats is a long time to stand in front of judges — without a
/// redeploy. A non-finite or non-positive target falls back to the default rather
/// than producing a challenge that is complete at zero reps or never completable.

import { envOr } from "./env.ts";

/** XP for completing the daily challenge. Capped XP only — never territory power. */
export const DAILY_CHALLENGE_XP = 150;

const DEFAULT_MOVEMENT = "squat";
const DEFAULT_TARGET = 30;

/** Athlete-facing plural labels for the movements a challenge can name. */
const PLURAL_LABELS: Record<string, string> = {
  squat: "squats",
  push_up: "push-ups",
  pull_up: "pull-ups",
  jumping_jack: "jumping jacks",
};

export interface DailyTemplate {
  /** `daily-<YYYY-MM-DD>` — the claim key, so each UTC day is a fresh challenge. */
  templateId: string;
  movementId: string;
  target: number;
  description: string;
}

/** Today's template for UTC day `day` (`YYYY-MM-DD`). */
export function dailyTemplate(
  day: string,
  movementId: string = envOr("REPRUSH_DAILY_MOVEMENT", DEFAULT_MOVEMENT),
  targetRaw: string = envOr("REPRUSH_DAILY_TARGET", String(DEFAULT_TARGET)),
): DailyTemplate {
  const parsed = Math.floor(Number(targetRaw));
  const target = Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TARGET;
  const label = PLURAL_LABELS[movementId] ?? `${movementId.replaceAll("_", " ")} reps`;
  return {
    templateId: `daily-${day}`,
    movementId,
    target,
    description: `${target} ${label} today`,
  };
}

/** Progress as the GET response reports it: clamped so a bar never overflows. */
export function clampProgress(reps: number, target: number): number {
  return Math.max(0, Math.min(Math.floor(reps), target));
}

/** The claim gate. `reps` is the raw verified total, not the clamped display value. */
export function isComplete(reps: number, target: number): boolean {
  return reps >= target;
}
