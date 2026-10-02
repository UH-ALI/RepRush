/// Duel rules — the clock-derived state machine, the one-set-each scoring and the
/// reward. `_shared/duels.ts` is pure, so this runs under plain Node; the SQL half
/// (`duel_sets`, the guarded answer UPDATE) is exercised against a live stack.

import {
  canClaim,
  DUEL_FINISH_XP,
  DUEL_WIN_XP,
  type DuelRow,
  type DuelSet,
  firstSetReps,
  isOpen,
  viewDuel,
} from "../../supabase/functions/_shared/duels.ts";
import { isFresh, PRESENCE_TTL_MS } from "../../supabase/functions/_shared/presence.ts";
import { ok, strictEqual, test } from "./_harness.ts";

const A = "aaaaaaaa-0000-4000-8000-000000000001";
const B = "bbbbbbbb-0000-4000-8000-000000000002";
const T0 = 1_000_000;
const WINDOW = 600_000;

function row(overrides: Partial<DuelRow> = {}): DuelRow {
  return {
    id: "d1",
    challengerId: A,
    opponentId: B,
    movementId: "squat",
    status: "accepted",
    createdAtMs: T0,
    respondByMs: T0 + 300_000,
    acceptedAtMs: T0 + 10_000,
    endsAtMs: T0 + 10_000 + WINDOW,
    ...overrides,
  };
}

function set(userId: string, repCount: number, atMs: number, movementId = "squat"): DuelSet {
  return { userId, movementId, repCount, submittedAtMs: atMs };
}

test("duels · a pending challenge lapses at its deadline, not before", () => {
  const pending = row({ status: "pending", acceptedAtMs: null, endsAtMs: null });
  strictEqual(viewDuel(pending, A, [], T0 + 299_999, "b", false).status, "pending");
  strictEqual(viewDuel(pending, A, [], T0 + 300_000, "b", false).status, "expired");
});

test("duels · the viewer sees their own side: incoming, opponent, reps", () => {
  const sets = [set(A, 18, T0 + 20_000), set(B, 12, T0 + 30_000)];
  const asA = viewDuel(row(), A, sets, T0 + 40_000, "bee", false);
  const asB = viewDuel(row(), B, sets, T0 + 40_000, "ay", false);
  strictEqual(asA.incoming, false);
  strictEqual(asA.opponentId, B);
  strictEqual(asA.myReps, 18);
  strictEqual(asA.theirReps, 12);
  strictEqual(asB.incoming, true);
  strictEqual(asB.opponentId, A);
  strictEqual(asB.myReps, 12);
  strictEqual(asA.result, "won");
  strictEqual(asB.result, "lost");
});

test("duels · finished as soon as both sets are in, active until then", () => {
  const one = [set(A, 18, T0 + 20_000)];
  strictEqual(viewDuel(row(), A, one, T0 + 25_000, "b", false).status, "active");
  const both = [...one, set(B, 9, T0 + 30_000)];
  strictEqual(viewDuel(row(), A, both, T0 + 31_000, "b", false).status, "finished");
});

test("duels · the window closing finishes it; a no-show loses and earns nothing", () => {
  const end = T0 + 10_000 + WINDOW;
  const out = viewDuel(row(), B, [set(A, 5, T0 + 20_000)], end, "a", false);
  strictEqual(out.status, "finished");
  strictEqual(out.result, "lost");
  strictEqual(out.myReps, null);
  strictEqual(out.xpReward, 0);
  ok(!canClaim(out));
});

test("duels · only the FIRST set in the window counts — one shot", () => {
  const sets = [set(A, 9, T0 + 20_000), set(A, 40, T0 + 25_000)];
  strictEqual(firstSetReps(sets, A, "squat", T0 + 10_000, T0 + 10_000 + WINDOW), 9);
});

test("duels · sets outside the window or of another movement do not count", () => {
  const start = T0 + 10_000;
  const end = start + WINDOW;
  strictEqual(firstSetReps([set(A, 9, start - 1)], A, "squat", start, end), null);
  strictEqual(firstSetReps([set(A, 9, end)], A, "squat", start, end), null);
  strictEqual(firstSetReps([set(A, 9, start + 5, "push_up")], A, "squat", start, end), null);
  strictEqual(firstSetReps([set(A, 9, start)], A, "squat", start, end), 9);
});

test("duels · rewards: winner 100, a posted loser or draw 25", () => {
  const draw = viewDuel(
    row(),
    A,
    [set(A, 10, T0 + 20_000), set(B, 10, T0 + 21_000)],
    T0 + 22_000,
    "b",
    false,
  );
  strictEqual(draw.result, "draw");
  strictEqual(draw.xpReward, DUEL_FINISH_XP);
  const won = viewDuel(
    row(),
    A,
    [set(A, 11, T0 + 20_000), set(B, 10, T0 + 21_000)],
    T0 + 22_000,
    "b",
    false,
  );
  strictEqual(won.xpReward, DUEL_WIN_XP);
  ok(canClaim(won));
  ok(!canClaim({ ...won, claimed: true }));
});

test("duels · open while pending or active, closed once answered no or finished", () => {
  ok(
    isOpen(
      viewDuel(
        row({ status: "pending", acceptedAtMs: null, endsAtMs: null }),
        A,
        [],
        T0,
        "b",
        false,
      ),
    ),
  );
  ok(isOpen(viewDuel(row(), A, [], T0 + 20_000, "b", false)));
  ok(!isOpen(viewDuel(row({ status: "declined" }), A, [], T0, "b", false)));
});

test("presence · a heartbeat is visible for the TTL and not a moment longer", () => {
  ok(isFresh(T0, T0 + PRESENCE_TTL_MS - 1));
  ok(!isFresh(T0, T0 + PRESENCE_TTL_MS));
});
