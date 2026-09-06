/// The seeded demo venue — one copy of the literals both sides of the seam use.
///
/// These MUST match `DemoVenue` in `lib/core/api/stub/stub_repositories.dart`.
/// They are duplicated rather than generated because the client and the server
/// have no shared build step this week, and a stub whose values drift from the
/// client stub is worse than no stub: C deserialises against one set of literals
/// while curl returns another, and the mismatch surfaces as a rendering bug on
/// the Day-3 swap instead of as a diff anyone thought to look for.
///
/// `hexH3` below is the REAL res-8 cell for (lat, lng), computed by `_shared/h3.ts`
/// and cross-checked against what the live `session-start` route returns. It was
/// fabricated for most of the build, with a note to reconcile it once
/// `session-start` joined `LIVE_ENDPOINTS`; that has happened. The fabricated
/// literal turned out to be resolution 10, not 8 — an invented index does not even
/// land in the resolution you meant, which is the argument for computing one.
///
/// ⚠ STILL DEBT, and only on the client side: `StubTerritoryRepository` in
/// `stub_repositories.dart` invents NEIGHBOURING hex ids by incrementing digits,
/// which is not how H3 addressing works. Those stay placeholders for rectangle
/// rendering until `GET /territory/hexes` ships real boundaries (B-10). This one
/// cell is true; the grid around it is not.

export const VENUE = {
  /** "The north end of the park" (requirements.md §5). */
  lat: 51.5074,
  lng: -0.1278,
  hexH3: "88195da49bfffff",
  spotId: "spot_riverside_rig",
  /** Must match the `active` row seeded by migration 0003. */
  movementConfigVersion: "2026-08-30.1",
  /** A fixed UUID, so a stubbed session id is recognisable in a log. */
  sessionId: "00000000-0000-4000-8000-000000000001",
} as const;
