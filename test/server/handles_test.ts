/// Display-name rules for `POST /me`. `_shared/handles.ts` is pure, so this runs
/// under plain Node; the case-insensitive uniqueness check is exercised against a
/// live stack.

import { likeLiteral, normaliseHandle } from "../../supabase/functions/_shared/handles.ts";
import { strictEqual, test } from "./_harness.ts";

test("handles · ordinary names pass through unchanged", () => {
  strictEqual(normaliseHandle("Salik"), "Salik");
  strictEqual(normaliseHandle("rep_king.99"), "rep_king.99");
  strictEqual(normaliseHandle("Mary-Jane"), "Mary-Jane");
});

test("handles · names in any script are allowed", () => {
  strictEqual(normaliseHandle("سالک"), "سالک");
  strictEqual(normaliseHandle("Zoë"), "Zoë");
});

test("handles · whitespace is trimmed and collapsed, not rejected", () => {
  strictEqual(normaliseHandle("  Salik   Khan "), "Salik Khan");
});

test("handles · too short, too long and non-strings are refused", () => {
  strictEqual(normaliseHandle("ab"), null);
  strictEqual(normaliseHandle("   a  "), null);
  strictEqual(normaliseHandle("x".repeat(21)), null);
  strictEqual(normaliseHandle("x".repeat(20)), "x".repeat(20));
  strictEqual(normaliseHandle(42), null);
  strictEqual(normaliseHandle(null), null);
});

test("handles · symbols and punctuation-only names are refused", () => {
  strictEqual(normaliseHandle("<script>"), null);
  strictEqual(normaliseHandle("a@b.com"), null);
  strictEqual(normaliseHandle("..._"), null);
});

test("handles · ilike wildcards are escaped so the match is literal", () => {
  strictEqual(likeLiteral("rep_king"), "rep\\_king");
  strictEqual(likeLiteral("100%"), "100\\%");
  strictEqual(likeLiteral("Salik"), "Salik");
});
