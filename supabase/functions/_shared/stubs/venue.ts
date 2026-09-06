/// The seeded demo venue — one copy of the literals both sides of the seam use.
///
/// These MUST match `DemoVenue` in `lib/core/api/stub/stub_repositories.dart`.
/// They are duplicated rather than generated because the client and the server
/// have no shared build step this week, and a stub whose values drift from the
/// client stub is worse than no stub: C deserialises against one set of literals
/// while curl returns another, and the mismatch surfaces as a rendering bug on
/// the Day-3 swap instead of as a diff anyone thought to look for.
///
/// ⚠ KNOWN DEBT — `hexH3`. `8a2a1072b59ffff` is a fabricated index. It has the
/// right shape for a resolution-8 H3 cell but it was not computed from
/// (51.5074, −0.1278), and the Dart stub also invents its neighbours by
/// incrementing the last four digits, which is not how H3 addressing works. The
/// LIVE path in `session-start/index.ts` computes the real index with
/// `_shared/h3.ts`, so the hex WILL change the moment `session-start` is added to
/// `LIVE_ENDPOINTS`. Reconcile both stubs against the computed value at that
/// point; until then the two stubs agreeing matters more than either being true.

export const VENUE = {
  /** "The north end of the park" (requirements.md §5). */
  lat: 51.5074,
  lng: -0.1278,
  hexH3: "8a2a1072b59ffff",
  spotId: "spot_riverside_rig",
  /** Must match the `active` row seeded by migration 0003. */
  movementConfigVersion: "2026-08-30.1",
  /** A fixed UUID, so a stubbed session id is recognisable in a log. */
  sessionId: "00000000-0000-4000-8000-000000000001",
} as const;
