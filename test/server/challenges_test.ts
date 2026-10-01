/// The daily challenge rules (G1, G3) — template naming, progress clamping and the
/// claim gate. `_shared/challenges.ts` is pure, so this runs under plain Node with
/// no database; the SQL half (the view and the claim insert) is exercised against
/// a live stack.

import {
  clampProgress,
  DAILY_CHALLENGE_XP,
  dailyTemplate,
  isComplete,
} from "../../supabase/functions/_shared/challenges.ts";
import { ok, strictEqual, test } from "./_harness.ts";

test("challenges · the template id carries the UTC day, so each day is a fresh claim", () => {
  strictEqual(dailyTemplate("2026-10-03", "squat", "30").templateId, "daily-2026-10-03");
  ok(
    dailyTemplate("2026-10-03", "squat", "30").templateId !==
      dailyTemplate("2026-10-04", "squat", "30").templateId,
  );
});

test("challenges · the description is athlete-facing, not a movement id", () => {
  strictEqual(dailyTemplate("2026-10-03", "squat", "30").description, "30 squats today");
  strictEqual(dailyTemplate("2026-10-03", "push_up", "20").description, "20 push-ups today");
  // An unlabelled movement still reads as words rather than snake_case.
  strictEqual(
    dailyTemplate("2026-10-03", "archer_push_up", "5").description,
    "5 archer push up reps today",
  );
});

test("challenges · a junk target falls back to the default instead of 0 or NaN", () => {
  strictEqual(dailyTemplate("2026-10-03", "squat", "abc").target, 30);
  strictEqual(dailyTemplate("2026-10-03", "squat", "0").target, 30);
  strictEqual(dailyTemplate("2026-10-03", "squat", "-5").target, 30);
  strictEqual(dailyTemplate("2026-10-03", "squat", "12.9").target, 12);
});

test("challenges · progress is clamped for display; the gate reads the raw total", () => {
  strictEqual(clampProgress(45, 30), 30);
  strictEqual(clampProgress(-1, 30), 0);
  strictEqual(clampProgress(12, 30), 12);
  ok(!isComplete(29, 30));
  ok(isComplete(30, 30));
  ok(isComplete(45, 30));
});

test("challenges · the reward is capped XP", () => {
  strictEqual(DAILY_CHALLENGE_XP, 150);
});
