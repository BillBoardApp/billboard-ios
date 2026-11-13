#!/usr/bin/env bash
# Checks the UI rules (R2 spec D 2.3.3, 2.4.1, 5.1 gate 2; Civic Record spec 1.2, 1.3, 2.5, 2.6, 7.7, 9.2) in the
# app's Swift sources.
#
#   ./scripts/check-ui-rules.sh                 # whole app (Billboard/Billboard); exit 1 on any error
#   ./scripts/check-ui-rules.sh FILE_OR_DIR...  # only these paths (a package checks its own files)
#   ./scripts/check-ui-rules.sh --summary       # counts per rule and file only
#
# Every rule is an error. R2's rules:
#   forced-appearance  no `.environment(\.colorScheme, ...)` and no `overrideUserInterfaceStyle = .light`
#   raw-color          no `Color(red:` / `UIColor(red:` outside Theme/
#   neon               no `BillboardColors.neon*` (R1 colours, removed in R2; keeps them from coming back)
#   white-black        no white or black used as a surface or for text (`Color.white`, `.foregroundStyle(.white)`,
#                      `UIColor.black`, ...); scrims and shadows (`Color.black.opacity(x)`) may stay
#   system-color       no system `.red/.green/.orange/.blue/...` colours (use danger, statusPassed, interactive)
#   brand-name         no "BillBoard" in a user-facing string (storage keys such as "BillBoard.readState.v1." are fine)
#   glossary           no term from the "Never use in UI" column of spec D 2.4.1 in a user-facing string
#   prominent-label    a `.borderedProminent` or `.glassProminent` button gives its label `onFill`: the system draws
#                      the label white, which is unreadable on the ink tint (near-white in dark mode)
#
# Civic Record rules (Civic Record spec 9.2 slice 1; errors since the cleanup slice, slice 14):
#   rounded-font       no SF Pro Rounded (`design: .rounded`, `.fontDesign(.rounded)`): use a TextRole
#   raw-font-size      no `.system(size:` outside Theme/, and no literal size through a role or face
#                      (`TextRole.prose.font(size: 30)`, `Face.text.font(size: 9, ...)`): use `.textRole(_:)`; a size
#                      computed from a scaled metric is fine
#   corner-radius      no deprecated `.cornerRadius(`: use a continuous shape with a BillboardStyle.Radius
#   serif-role         New York (`design: .serif`, or `TextRole.Face.serif`) only in the four reading roles, which Theme/
#                      defines
#   brand-teal         `brandTeal` only in the Wordmark and the tab bar (BillboardTabBar)
#   party-colour       party colours only in PartyDisc and PartyBadge (the party is always also a letter)
#   status-colour      `statusUpdated` and `statusPassed` only in StatusStamp (a status is a stamped word)
#   vote-colour-symbol a vote colour, or a split bar (a type named *Split*Bar, drawn in vote colours), only in a type
#                      that also shows `VoteChoice.symbolName`, itself or in a `BallotBox` (a vote is always a symbol
#                      and a word); a split bar's own declaration is a part and is not checked, the row that draws it is
#
# Exceptions: put `// ui-rules:allow <rule>` on the line, or add a line to scripts/ui-rules-allowlist.txt
# (`rule | path relative to Billboard/Billboard (glob) | regex matched against the string or line`).
# Strings that look like identifiers (no spaces, and either dots, underscores, slashes or colons, or a lowercase first
# letter: keys, wire values, symbol names) are not copy and are skipped, and so are key=value diagnostics and strings
# on logging, assertion, accessibility-identifier, storage-key and enum raw-value lines.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export UI_RULES_ROOT="${ROOT}"
exec python3 - "$@" <<'PYTHON'
import fnmatch
import os
import re
import sys
from collections import Counter

ROOT = os.environ["UI_RULES_ROOT"]
APP = os.path.join(ROOT, "Billboard", "Billboard")
ALLOWLIST = os.path.join(ROOT, "scripts", "ui-rules-allowlist.txt")
SKIP_DIRS = {"Contracts"}  # generated contract code

args = [a for a in sys.argv[1:] if not a.startswith("--")]
summary_only = "--summary" in sys.argv[1:]

# ---------------------------------------------------------------- files
def swift_files(paths):
    out = []
    for p in paths:
        p = os.path.abspath(p)
        if os.path.isdir(p):
            for dirpath, dirnames, filenames in os.walk(p):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                out += [os.path.join(dirpath, f) for f in filenames if f.endswith(".swift")]
        elif p.endswith(".swift") and os.path.isfile(p):
            out.append(p)
        else:
            print(f"check-ui-rules: not a Swift file or directory: {p}", file=sys.stderr)
            sys.exit(2)
    return sorted(set(out))

files = swift_files(args or [APP])

def rel(path):
    try:
        return os.path.relpath(path, APP)
    except ValueError:
        return path

# ---------------------------------------------------------------- allowlist
allow = []
if os.path.exists(ALLOWLIST):
    with open(ALLOWLIST, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|", 2)]
            if len(parts) != 3:
                print(f"{ALLOWLIST}:{n}: expected 'rule | path glob | regex'", file=sys.stderr)
                sys.exit(2)
            allow.append((parts[0], parts[1], re.compile(parts[2])))

def allowed(rule, path, text, line_text):
    if re.search(r"ui-rules:allow\b[^\n]*\b" + re.escape(rule) + r"\b", line_text):
        return True
    r = rel(path)
    for a_rule, a_glob, a_re in allow:
        if a_rule in (rule, "*") and fnmatch.fnmatch(r, a_glob) and a_re.search(text):
            return True
    return False

# ---------------------------------------------------------------- Swift lexer
def lex(src):
    """Returns (code, literals): `code` is the source with comments and string contents blanked
    (newlines kept, so line numbers hold); `literals` is [(line, text)] where interpolations
    read as {}."""
    code = []
    literals = []
    i, n, line = 0, len(src), 1
    # frames: ["code", parens, is_interpolation] or ["str", multi, hashes, buf, start_line]
    stack = [["code", 0, False]]

    def emit(ch):
        code.append(ch if ch == "\n" else " ")

    while i < n:
        top = stack[-1]
        c = src[i]
        if top[0] == "code":
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                code.append(" " * (j - i))
                i = j
                continue
            if src.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if src.startswith("/*", j):
                        depth += 1; j += 2
                    elif src.startswith("*/", j):
                        depth -= 1; j += 2
                    else:
                        j += 1
                for ch in src[i:j]:
                    emit(ch)
                    if ch == "\n":
                        line += 1
                i = j
                continue
            m = re.match(r'(#*)("""|")', src[i:i + 12])
            if m:
                hashes = len(m.group(1))
                opener = m.group(2)
                stack.append(["str", opener == '"""', hashes, [], line])
                code.append(" " * (hashes + len(opener)))
                i += hashes + len(opener)
                continue
            if top[2]:  # inside \( ... )
                if c == "(":
                    top[1] += 1
                elif c == ")":
                    if top[1] == 0:
                        stack.pop()
                        stack[-1][3].append("{}")
                        code.append(" ")
                        i += 1
                        continue
                    top[1] -= 1
            code.append(c)
            if c == "\n":
                line += 1
            i += 1
            continue

        # inside a string literal
        _, multi, hashes, buf, start = top
        closing = ('"""' if multi else '"') + "#" * hashes
        if src.startswith(closing, i):
            literals.append((start, "".join(buf)))
            stack.pop()
            code.append(" " * len(closing))
            i += len(closing)
            continue
        escape = "\\" + "#" * hashes
        if src.startswith(escape, i):
            j = i + len(escape)
            if j < n and src[j] == "(":
                stack.append(["code", 0, True])
                code.append(" " * (j + 1 - i))
                i = j + 1
                continue
            if j < n and src[j] == "\n":  # line continuation in a multi-line string
                code.append(" " * (j - i)); code.append("\n"); line += 1
                i = j + 1
                continue
            buf.append(" ")
            code.append(" " * (j + 1 - i))
            i = j + 1
            continue
        if c == "\n":
            line += 1
            code.append("\n")
            buf.append(" ")
            if not multi:  # unterminated; resync
                stack.pop()
            i += 1
            continue
        buf.append(c)
        code.append(" ")
        i += 1
    return "".join(code), literals

# ---------------------------------------------------------------- rules
IDENTIFIER_LIKE = re.compile(r"^[A-Za-z0-9_.\-:/#{}%@+=?&]*$")
NON_COPY_LINE = re.compile(
    r"AppLog\.|Logger\(|logger\.|\blog\.|\.(debug|info|notice|error|fault|warning|trace|critical)\(|"
    r"\bprint\(|debugPrint\(|NSLog\(|os_log\(|assert(ionFailure)?\(|precondition(Failure)?\(|fatalError\(|"
    r"accessibilityIdentifier\(|forKey:|forInfoDictionaryKey:|Notification\.Name\(|@AppStorage\(|"
    r"#Preview\(|^\s*case\s+\w+\s*=\s*\"|UserDefaults|KeychainStore|subsystem:|ProcessInfo|"
    r"URL\(string:|httpMethod|setValue\(|forHTTPHeaderField|queryItems|URLQueryItem\("
)

GLOSSARY = [
    (r"\bQueue\b|\bqueue\b", "queue (say: your bills)"),
    (r"\bHome\b", "Home (say: Bills)"),
    (r"\bAlerts?\b", "Alert(s) (say: Action in Congress / Recent actions / Notifications)"),
    (r"\b[Dd]igests?\b", "digest (say: Weekly Brief)"),
    (r"\bbrief vote\b", "brief vote"),
    (r"\bTrack\b|\bTracking\b|\btrack this\b", "Track (say: Watch)"),
    (r"\b(Un)?[Ss]ubscri(be|bed|bes|ption|ptions|bing)\b|\bunsubscribe\b", "Subscribe (say: Follow / Watch)"),
    (r"\b[Ss]ub-?[Cc]ategor(y|ies)\b", "sub-category (say: Topic)"),
    (r"\bIssue clusters\b", "Issue clusters (say: Topics)"),
    (r"\bEveryday impact\b", "Everyday impact (say: Life area)"),
    (r"\bDismiss(ed)?\b|\bDismiss All\b", "Dismiss (say: Skip on Bills, Clear on Updates)"),
    (r"\b[Cc]onstituents?\b|\brepresentative delivery\b", "constituent (say: verified voter)"),
    (r"\b[Ss]elf-?attested\b|\b[Mm]anual mode\b", "self-attested (say: Not verified, district chosen by you)"),
    (r"\b[Tt]rends\b|\b[Ll]ive comparisons?\b|\blean\b|\bLean\b", "trends/lean (say: Results)"),
    (r"\b[Ll]ow sample\b|\b[Dd]ecision votes?\b|\b[Ss]ignals?\b", "signal/low sample (say: votes, fewer than 5 votes so far)"),
    (r"\b[Ww]eighted evidence\b|\b[Ss]ignal health\b", "weighted evidence (say: votes and bills)"),
    (r"\b[Aa]x(is|es)\b", "axis (say: theme)"),
    (r"\bPolitical Identity\b", "Political Identity (say: Your votes by topic)"),
    (r"\bPriority\b", "Priority (say: In the news)"),
    (r"\bCloakroom Buzz\b|\bOn The Hill Heat\b|\bCapitol Frenzy\b", "vote-count nickname (say: 10+ / 50+ / 150+ votes)"),
    (r"\bDem\b|\bGOP\b|\bInd\b", "party abbreviation (say: D / R / I or Democrat / Republican / Independent)"),
    (r"\b[Hh]istory window\b|\bHome Bill History\b", "history window (say: Show bills from the last ...)"),
]
GLOSSARY = [(re.compile(p), why) for p, why in GLOSSARY]

COLOR_ARG = r"(foregroundStyle|foregroundColor|fill|tint|background|stroke|strokeBorder|border|accentColor)"
SYSTEM_COLOR_DETAIL = "system colour: use a token (danger for errors, statusPassed for Passed, interactive for links and buttons)"
LINE_RULES = [
    ("forced-appearance", re.compile(r"environment\(\s*\\\.colorScheme"), "forced colour scheme"),
    ("forced-appearance", re.compile(r"overrideUserInterfaceStyle\s*=\s*\.light"), "forced light appearance"),
    ("neon", re.compile(r"BillboardColors\.neon[A-Z]\w*"), "deprecated neon colour"),
    ("white-black", re.compile(r"\b(Color|UIColor)\.white\b"), "white: use cardBackground, textOnNavy or onFill"),
    ("white-black", re.compile(r"\b(Color|UIColor)\.black\b(?!\.opacity\()(?!\.withAlphaComponent\()"), "black: use primaryText (scrims and shadows may use black with opacity)"),
    ("white-black", re.compile(r"\." + COLOR_ARG + r"\(\s*\.white\b"), "white: use textOnNavy, onFill or cardBackground"),
    ("white-black", re.compile(r"\." + COLOR_ARG + r"\(\s*\.black\b(?!\.opacity\()"), "black: use primaryText (scrims may use .black.opacity)"),
    ("system-color", re.compile(r"\bColor\.(red|green|orange|blue|yellow|cyan|mint|teal|purple|pink|indigo)\b"), SYSTEM_COLOR_DETAIL),
    ("system-color", re.compile(r"\." + COLOR_ARG + r"\(\s*\.(red|green|orange|blue|yellow|cyan|mint|teal|purple|pink|indigo)\b"), SYSTEM_COLOR_DETAIL),
    ("system-color", re.compile(r"\breturn\s+\.(red|green|orange|blue|yellow|cyan|mint|teal|purple|pink|indigo)\b(?![\w(])"), SYSTEM_COLOR_DETAIL),
    # Civic Record
    ("rounded-font", re.compile(r"design:\s*\.rounded\b|\.fontDesign\(\s*\.rounded\b|withDesign\(\s*\.rounded\b"), "SF Pro Rounded: use a TextRole (SF Pro Text, condensed SF Pro, New York or SF Mono)"),
    ("corner-radius", re.compile(r"\.cornerRadius\("), "deprecated .cornerRadius(): use a continuous shape with BillboardStyle.Radius (mark 4, slip 16, panel 30)"),
]
RAW_COLOR = re.compile(r"\b(Color|UIColor)\(\s*red:")

# Civic Record rules that depend on where the code is. Paths are relative to Billboard/Billboard.
# A literal size through a TextRole or Face (`.font(size: 30)`) is a raw size too; a scaled metric (`.font(size: glyphSize`)
# is not.
RAW_FONT_SIZE = re.compile(r"\.system\(\s*size:|\.font\(\s*size:\s*[0-9.]")
# `TextRole.Face.serif` sets New York at any size, outside the reading roles.
SERIF = re.compile(r"design:\s*\.serif\b|\.fontDesign\(\s*\.serif\b|withDesign\(\s*\.serif\b|\bFace\.serif\b")
PLACED_RULES = [
    # (rule, pattern, allowed files (globs), detail)
    ("brand-teal", re.compile(r"\bbrandTeal\b"), ["Theme/*", "Views/Components/Wordmark.swift", "App/BillboardTabBar.swift"],
     "brand teal outside the Wordmark and the tab bar: teal means only Yea (use interactive, controlOn or textOnNavy)"),
    ("party-colour", re.compile(r"\bparty(Democratic|Republican|Independent)\b|\bBillboardColors\.party\("),
     ["Theme/*", "Views/Components/PartyBadge.swift", "Views/Components/MemberMonogram.swift"],
     "party colour outside PartyDisc and PartyBadge: the party is always also its letter"),
    ("status-colour", re.compile(r"\b(BillboardColors|BillboardUIColors|BillboardPalette)\.status(Updated|Passed)\b"),
     ["Theme/*", "Views/Components/StatusStamp.swift"],
     "status colour outside StatusStamp: a status is a stamped word"),
]
VOTE_COLOUR = re.compile(
    r"\b(BillboardColors|BillboardUIColors)\.vote(Yea|Nay|Abstain)\b|\bVoteChoice\.\w+\.(color|uiColor)\b|\bchoice\??\.(color|uiColor)\b"
)
# A split bar (VoteSplitBar, VoteSplitTendencyBar) draws vote colours with no symbol: a call to one counts as a vote
# colour use in the type that calls it, and the bar's own declaration is skipped.
SPLIT_BAR_CALL = re.compile(r"\b[A-Z]\w*Split\w*Bar\s*\(")
SPLIT_BAR_NAME = re.compile(r"^[A-Z]\w*Split\w*Bar$")
DECLARATION = re.compile(r"\b(struct|class|enum|extension|actor)\s+([A-Za-z_][\w.]*)")
PROMINENT_STYLE = re.compile(
    r"\.buttonStyle\(\s*(\.borderedProminent|\.glassProminent|BorderedProminentButtonStyle\(|GlassProminentButtonStyle\()"
)

def top_level_declarations(code):
    """[(name, start, end)] for each declaration at brace depth 0, `end` just past its closing brace."""
    depth = []
    d = 0
    for ch in code:
        depth.append(d)
        if ch == "{":
            d += 1
        elif ch == "}":
            d = max(0, d - 1)
    out = []
    for m in DECLARATION.finditer(code):
        if depth[m.start()] != 0:
            continue
        open_brace = code.find("{", m.end())
        if open_brace < 0:
            continue
        level, j = 0, open_brace
        while j < len(code):
            if code[j] == "{":
                level += 1
            elif code[j] == "}":
                level -= 1
                if level == 0:
                    break
            j += 1
        out.append((m.group(2), m.start(), j + 1))
    return out

findings = []

def shown(path):
    r = os.path.relpath(path, ROOT)
    return path if r.startswith("..") else r

def report(rule, path, line_no, line_text, detail):
    findings.append((rule, shown(path), line_no, detail, line_text.strip()))

for path in files:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    lines = src.split("\n")
    code, literals = lex(src)
    code_lines = code.split("\n")
    in_theme = rel(path).startswith("Theme" + os.sep)

    for idx, cline in enumerate(code_lines):
        line_no = idx + 1
        original = lines[idx] if idx < len(lines) else ""
        for rule, rx, detail in LINE_RULES:
            m = rx.search(cline)
            if m and not allowed(rule, path, m.group(0), original):
                report(rule, path, line_no, original, detail)
        if not in_theme:
            m = RAW_COLOR.search(cline)
            if m and not allowed("raw-color", path, m.group(0), original):
                report("raw-color", path, line_no, original, "raw colour outside Theme/: add a token")
            m = RAW_FONT_SIZE.search(cline)
            if m and not allowed("raw-font-size", path, m.group(0), original):
                report("raw-font-size", path, line_no, original, "raw font size outside Theme/: use .textRole(_:)")
            m = SERIF.search(cline)
            if m and not allowed("serif-role", path, m.group(0), original):
                report("serif-role", path, line_no, original,
                       "New York outside the reading roles: use .textRole(.lead / .leadStrong / .prose / .officialTitle)")
        for rule, rx, globs, detail in PLACED_RULES:
            if any(fnmatch.fnmatch(rel(path), g) for g in globs):
                continue
            m = rx.search(cline)
            if m and not allowed(rule, path, m.group(0), original):
                report(rule, path, line_no, original, detail)

    # vote-colour-symbol: a type that draws a vote colour, or a split bar, also shows the vote's symbol.
    if not in_theme:
        for name, start, end in top_level_declarations(code):
            if SPLIT_BAR_NAME.match(name.split(".")[-1]):
                continue  # the bar is a part: the type that draws it shows the symbol
            block = code[start:end]
            uses = sorted(list(VOTE_COLOUR.finditer(block)) + list(SPLIT_BAR_CALL.finditer(block)), key=lambda m: m.start())
            # A BallotBox draws the vote's symbol (VoteChoice.symbolName) in its box.
            if not uses or "symbolName" in block or "BallotBox(" in block:
                continue
            line_no = code.count("\n", 0, start + uses[0].start()) + 1
            original = lines[line_no - 1]
            if not allowed("vote-colour-symbol", path, name, original):
                report("vote-colour-symbol", path, line_no, original,
                       f"{len(uses)} vote colour or split bar use(s) in {name} without VoteChoice.symbolName: "
                       "a vote is a symbol and a word")

    # prominent-label: a prominent button's label is onFill, from its `Button` to its `.buttonStyle(...)`.
    for m in PROMINENT_STYLE.finditer(code):
        button = None
        for b in re.finditer(r"\bButton\b", code[:m.start()]):
            button = b
        span = code[button.start() if button else max(0, m.start() - 600):m.start()]
        if "onFill" in span:
            continue
        line_no = code.count("\n", 0, m.start()) + 1
        original = lines[line_no - 1]
        if not allowed("prominent-label", path, m.group(1), original):
            report("prominent-label", path, line_no, original,
                   "prominent button without an onFill label: the system draws it white, unreadable on the ink tint "
                   "(near-white in dark mode); give the label BillboardColors.onFill and tint it interactive")

    for line_no, text in literals:
        original = lines[line_no - 1] if line_no - 1 < len(lines) else ""
        stripped = text.strip()
        if not stripped or NON_COPY_LINE.search(original):
            continue
        if IDENTIFIER_LIKE.match(stripped) and (re.search(r"[._/:]", stripped) or re.match(r"^[a-z]", stripped)):
            continue  # an identifier, key, wire value or symbol name, not copy
        if re.search(r"\w=\{\}", text):
            continue  # key=value diagnostics

        if "BillBoard" in text and not allowed("brand-name", path, text, original):
            report("brand-name", path, line_no, original, f'"BillBoard" in copy (say: Billboard): "{stripped[:80]}"')
        for rx, why in GLOSSARY:
            m = rx.search(text)
            if m and not allowed("glossary", path, text, original):
                report("glossary", path, line_no, original, f'{why}: "{stripped[:80]}"')

if summary_only:
    by_rule = Counter(f[0] for f in findings)
    by_file = Counter(f[1] for f in findings)
    for rule, count in sorted(by_rule.items()):
        print(f"{rule:18s} {count}")
    print()
    for path, count in by_file.most_common():
        print(f"{count:4d}  {path}")
else:
    for rule, path, line_no, detail, text in findings:
        print(f"{path}:{line_no}: [{rule}] {detail}")
        print(f"    {text[:160]}")

if findings:
    print(f"\ncheck-ui-rules: {len(findings)} finding(s) in {len({f[1] for f in findings})} file(s)", file=sys.stderr)
    sys.exit(1)
print(f"check-ui-rules: OK ({len(files)} file(s))", file=sys.stderr)
PYTHON
