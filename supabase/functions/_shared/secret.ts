// Constant-time comparison for the shared secrets that gate the edge functions
// deployed with `--no-verify-jwt` (cron secrets, push secrets, payment webhook
// secrets).
//
// `a !== b` on strings short-circuits at the first differing byte, so how long
// the check takes leaks how many leading bytes were correct. These secrets are
// high-entropy, so that is a narrow signal rather than an open door — but the
// fix costs nothing and removes the class of bug entirely.
//
// Also fails closed on an unset expected value: comparing against `undefined`
// must never succeed.
export function secretEquals(got: string | null | undefined, expected: string | undefined): boolean {
  if (!expected) return false;
  const a = got ?? "";
  // Length is not secret (these are fixed-length configured values), so an
  // early return here leaks nothing useful.
  if (a.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
