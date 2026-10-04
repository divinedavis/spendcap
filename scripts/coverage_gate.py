#!/usr/bin/env python3
"""Keep the tests in step with the app as screens come and go (2026-10-04;
owner: the checks must follow features as they are added and removed).
Two failures, either of which stops a ship:

  * UNTESTED SCREEN: a screen file no test executed a single line of, read
    from the code coverage of ship.sh's test run (unit + XCUITest, collected
    with -enableCodeCoverage YES). The folders ARE the list — every *View /
    *Editor file under Spendcap/ — so a new screen cannot ship without a test
    that opens it, and a deleted one drops out by itself.
  * STALE IDENTIFIER: a UI test queries an accessibility identifier
    ("trends.monthSpend") that no longer appears anywhere in the app, i.e. the
    feature was removed or renamed and its test now waits for something that
    can never appear. A line with XCTAssertFalse is a deliberate "this must be
    gone" check and is left alone.

  python3 scripts/coverage_gate.py build.nosync/gates/Ship.xcresult
"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCREENS = re.compile(r"/Spendcap/((?:App|Auth|Budget|Dashboard|Debt|Link|Statements|Trips)/\w*(?:View|Editor)\w*)\.swift$")

# Screens no test may open, each with the reason. Keep this list short.
EXEMPT = {
    # Presents Plaid Link against PRODUCTION Plaid (no test bank exists there),
    # and finishing it permanently spends one of ten Trial Items.
    "Link/PlaidLinkView": "real Plaid Link; a completed link burns a Trial Item",
}

LITERAL = re.compile(r'"((?:\\\((?:[^()]|\([^()]*\))*\)|\\.|[^"\\])*)"')
SUBSCRIPT = re.compile(r'\["((?:[^"\\]|\\\([^)]*\))*)"\]')
ID_LIKE = re.compile(r"^[a-z][A-Za-z0-9]*\.[A-Za-z0-9.]+$")   # dotted ids: "auth.email"


def stem(s):
    return s.split("\\(")[0]


def untested(xcresult):
    out = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", xcresult],
                         capture_output=True, text=True, check=True).stdout
    files = {}
    for target in json.loads(out).get("targets", []):
        for f in target.get("files", []):
            m = SCREENS.search(f["path"])
            if m:
                files[m.group(1)] = max(files.get(m.group(1), 0), f.get("coveredLines", 0))
    if not files:
        print("coverage gate: no screen files in the coverage report — was -enableCodeCoverage YES set?")
        return None, 0
    cold = sorted(k for k, n in files.items() if n == 0 and k not in EXEMPT)
    return cold, len(files)


def stale():
    app_lits = set()
    for f in glob.glob(os.path.join(ROOT, "Spendcap/**/*.swift"), recursive=True):
        with open(f, encoding="utf-8") as fh:
            app_lits |= {stem(m.group(1)) for line in fh for m in LITERAL.finditer(line)}
    bad = set()
    for f in glob.glob(os.path.join(ROOT, "SpendcapUITests/*.swift")):
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                if "XCTAssertFalse" in line:
                    continue
                for m in SUBSCRIPT.finditer(line):
                    ref = stem(m.group(1))
                    if not ID_LIKE.match(ref.rstrip(".")) and not ref.endswith("."):
                        continue
                    # exact, or the fixed part of an id the app interpolates
                    if ref in app_lits or any(a.startswith(ref) or ref.startswith(a) and a.endswith(".") for a in app_lits):
                        continue
                    bad.add(ref)
    return sorted(bad)


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    cold, total = untested(sys.argv[1])
    if cold is None:
        return 1
    gone = stale()
    print(f"coverage gate: {total - len(cold) - len(EXEMPT)}/{total - len(EXEMPT)} screen files exercised by a test"
          f" ({len(EXEMPT)} exempt: {', '.join(EXEMPT)})")
    if cold:
        print("NO TEST touches these screens (add a UI test that opens each one):")
        for c in cold:
            print(f"  - Spendcap/{c}.swift")
    if gone:
        print("STALE UI-test identifiers (in a test, nowhere in the app — remove or update the test):")
        for r in gone:
            print(f"  - {r}")
    if not cold and not gone:
        print("coverage gate OK: every screen has a test, no test points at a removed identifier")
    return 1 if cold or gone else 0


if __name__ == "__main__":
    sys.exit(main())
