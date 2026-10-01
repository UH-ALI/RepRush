/// Display-name rules for `POST /me` — what an athlete may rename themselves to.
///
/// Pure (no database), so the rules are unit-tested under plain Node; uniqueness
/// is the one check that needs the table, and lives in `repo.ts`.
///
/// The handle is what rivals see on the leaderboard and on hexes you hold, so the
/// rules aim at "reads as a name": letters and digits in any script (an Urdu or
/// Arabic name is as valid as a Latin one), with spaces, `_`, `.` and `-` allowed
/// between them. Whitespace is collapsed rather than rejected, because a stray
/// double space from a phone keyboard is not worth an error message.

export const HANDLE_MIN = 3;
export const HANDLE_MAX = 20;

const ALLOWED = /^[\p{L}\p{N}_ .-]+$/u;
const HAS_ALNUM = /[\p{L}\p{N}]/u;

/** The cleaned handle, or null when [raw] can't be one. */
export function normaliseHandle(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const handle = raw.trim().replace(/\s+/gu, " ");
  const length = [...handle].length;
  if (length < HANDLE_MIN || length > HANDLE_MAX) return null;
  if (!ALLOWED.test(handle) || !HAS_ALNUM.test(handle)) return null;
  return handle;
}

/**
 * Escapes `%`, `_` and `\` so a handle can be matched with `ilike` as a literal
 * — `_` is legal in a handle and is a single-character wildcard to `ilike`.
 */
export function likeLiteral(handle: string): string {
  return handle.replace(/[\\%_]/g, (c) => `\\${c}`);
}
