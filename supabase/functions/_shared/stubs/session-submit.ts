/// The canned `POST /session/submit` response — the C4 everything-response
/// (docs/backend-scaffolding.md §6, api-contract.md §endpoints).
///
/// The values mirror `StubSessionsRepository.submit` in
/// `lib/core/api/stub/stub_repositories.dart` field for field. That is the point:
/// C is building the summary screen against the client stub today, and the Day-3
/// swap to the HTTP repository must not change a single number the screen renders.
///
/// The contract's instruction for stubs is that they be *realistic* — "contested
/// hexes, non-empty boards, a plausible unlock, never empty arrays". Hence a hex
/// whose total power (1240) is double this user's contribution (620), a rank move
/// from 4th to 2nd, and one personal record. A stub returning zeroes would let the
/// summary screen pass its own tests while rendering nothing.

import type { Consequences } from "./consequences.ts";
import { VENUE } from "./venue.ts";

export function stubSubmit(): Consequences {
  return {
    xp: 240,
    level: 3,
    levelUps: [],
    hexResult: {
      h3: VENUE.hexH3,
      captured: true,
      // Contested: the hex holds more power than this user contributed, which is
      // the only way the summary screen's "your share" line has anything to show.
      power: 1240,
      yourPower: 620,
    },
    spotResult: {
      spotId: VENUE.spotId,
      captured: true,
      rank: 1,
    },
    rankChange: { before: 4, after: 2 },
    unlocks: [],
    prs: [{ movementId: "squat", metric: "max_reps", value: 20 }],
    achievements: ["first_capture"],
    voided: false,
  };
}
