#!/usr/bin/env bash
# Builds the app's Open-source licenses screen data from THIRD_PARTY_NOTICES.md ("In the app").
#
#   ./scripts/generate-open-source-licenses.sh                  # regenerate from the Swift package checkouts
#   ./scripts/generate-open-source-licenses.sh --packages DIR   # ...from the checkouts in DIR (a SourcePackages folder)
#   ./scripts/generate-open-source-licenses.sh --check          # no checkouts needed: the bundled file is current
#
# It writes Billboard/Billboard/Resources/OpenSourceLicenses.json: for each package in the "In the app" table, its
# NOTICE files, the copyright lines at the top of its linked sources and its licence texts (stored once each), read
# from the package at the revision pinned in Package.resolved, plus the repository's own NOTICE and LICENSE. The file
# is checked in, so a build needs no network and no build script. When a package only points to a licence instead of
# carrying its text (aws-c-cal's APSL 2.0 header), the table links the full text from this repository's licenses/
# folder, and the generator reads it from there.
#
# Regenerating needs the package checkouts, which Xcode makes when it resolves packages (any build). They are found in
# --packages, else SOURCE_PACKAGES_PATH, else DERIVED_DATA_PATH/SourcePackages, else the newest
# ~/Library/Developer/Xcode/DerivedData/BillBoard-*/SourcePackages. Each checkout must be at its pinned revision.
#
# --check (run by scripts/test.sh) reads no checkouts. It fails when THIRD_PARTY_NOTICES.md's package table no longer
# matches Package.resolved, when the bundled file was not regenerated after a change to the "In the app" table, to a
# pin of a package in it, to the package products the app's targets link (project.pbxproj), to NOTICE or LICENSE, or
# to a licence file in licenses/ that the table links, and when the bundled file was edited by hand (it records a hash
# of its own content).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export OSL_ROOT="${ROOT}"
exec python3 -I - "$@" <<'PYTHON'
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.environ["OSL_ROOT"]
NOTICES_MD = os.path.join(ROOT, "THIRD_PARTY_NOTICES.md")
RESOLVED = os.path.join(ROOT, "BillBoard.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
OUT = os.path.join(ROOT, "Billboard", "Billboard", "Resources", "OpenSourceLicenses.json")
OUT_REL = os.path.relpath(OUT, ROOT)
REPO_NOTICE = os.path.join(ROOT, "NOTICE")
REPO_LICENSE = os.path.join(ROOT, "LICENSE")
PROJECT = os.path.join(ROOT, "Billboard", "Billboard.xcodeproj", "project.pbxproj")
# Full licence texts kept in this repository, for parts whose package only points to its licence.
REPO_LICENSES = "licenses"
FORMAT_VERSION = 1
BEGIN, END = "<!-- open-source-licenses:begin -->", "<!-- open-source-licenses:end -->"
SOURCE_EXTENSIONS = (".swift", ".c", ".h", ".m", ".inl", ".def", ".s", ".S")
SKIPPED_DIRS = {"test", "tests", "Test", "Tests", ".git"}
HEADER_LINES = 80


def fail(message):
    print(f"generate-open-source-licenses: {message}", file=sys.stderr)
    sys.exit(1)


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def normalized(text):
    """Unix newlines, no trailing spaces, no blank lines at either end."""
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def read(path):
    with open(path, encoding="utf-8", errors="strict") as handle:
        return handle.read()


# ---------------------------------------------------------------- THIRD_PARTY_NOTICES.md
def cells(line):
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def ticked(cell):
    return re.findall(r"`([^`]+)`", cell)


def linked(cell):
    """The targets of the Markdown links in a cell: files in this repository, as GitHub opens them."""
    return re.findall(r"\[[^\]]*\]\(([^)\s]+)\)", cell)


def repository_licence(path, line):
    """A link in the "Licence text" column: a file directly in this repository's licenses/ folder, which must exist."""
    folder, _, name = path.partition("/")
    if folder != REPO_LICENSES or not name or "/" in name or name.startswith("."):
        fail(f"'In the app' links {path}: a licence text from this repository must be a file in {REPO_LICENSES}/: {line}")
    if not os.path.isfile(os.path.join(ROOT, path)):
        fail(f"'In the app' links {path}, which is not in this repository: {line}")
    return path


def package_table(md):
    """{identity: (version, spdx, source)} from the "Swift packages" table."""
    section = md.split("## Swift packages", 1)
    if len(section) < 2:
        fail("THIRD_PARTY_NOTICES.md has no '## Swift packages' section")
    rows = {}
    for line in section[1].split("\n## ", 1)[0].splitlines():
        if not line.startswith("| `"):
            continue
        name, version, spdx, source = cells(line)[:4]
        rows[ticked(name)[0]] = (version, spdx, source.strip("<>"))
    return rows


def app_table(md):
    """(raw table text, [row]) from the "In the app" table between the markers."""
    if md.count(BEGIN) != 1 or md.count(END) != 1:
        fail(f"THIRD_PARTY_NOTICES.md needs one {BEGIN} ... {END} table")
    raw = md.split(BEGIN, 1)[1].split(END, 1)[0].strip("\n")
    rows = []
    for line in raw.splitlines():
        if not line.startswith("| `"):
            continue
        parts = cells(line)
        if len(parts) != 6:
            fail(f"'In the app' row needs 6 columns: {line}")
        package, part, spdx, notice, licence, copyright_from = parts
        if not spdx:
            fail(f"'In the app' row has no licence: {line}")
        rows.append({
            "package": ticked(package)[0],
            "part": part or ticked(package)[0],
            "spdx": spdx,
            "notices": ticked(notice),
            "licenses": ticked(licence),
            "repositoryLicenses": [repository_licence(path, line) for path in linked(licence)],
            "copyrightFrom": ticked(copyright_from),
        })
    if not rows:
        fail("the 'In the app' table has no rows")
    for row in rows:
        if not row["licenses"] and not row["repositoryLicenses"]:
            fail(f"{row['package']} / {row['part']}: no licence text listed")
    return raw, rows


def repository_licences(rows):
    """{path: text} of the licence files in licenses/ that the table links."""
    paths = sorted({path for row in rows for path in row["repositoryLicenses"]})
    return {path: normalized(read(os.path.join(ROOT, path))) for path in paths}


def pins():
    """{identity: (version, revision)} from Package.resolved."""
    resolved = json.loads(read(RESOLVED))
    out = {}
    for pin in resolved["pins"]:
        state = pin["state"]
        out[pin["identity"]] = (state.get("version") or state.get("branch") or "", state["revision"])
    return out


def ordered_packages(rows):
    seen = []
    for row in rows:
        if row["package"] not in seen:
            seen.append(row["package"])
    return seen


def billboard_copyright(notice):
    lines = [line for line in notice.splitlines() if line.startswith("Copyright ")]
    if len(lines) != 1:
        fail("NOTICE needs exactly one line that starts with 'Copyright '")
    return lines[0]


def inputs(raw_table, rows):
    return {
        "table": sha(raw_table),
        "notice": sha(normalized(read(REPO_NOTICE))),
        "license": sha(normalized(read(REPO_LICENSE))),
        "licenseFiles": {path: sha(text) for path, text in repository_licences(rows).items()},
        "products": linked_products(),
    }


# ---------------------------------------------------------------- project.pbxproj
def openstep(text):
    """The old-style property list Xcode writes project.pbxproj in, as dicts, lists and strings."""
    bare = re.compile(r"[A-Za-z0-9_$+/:.\-]+")
    escapes = {"n": "\n", "t": "\t", "r": "\r"}
    position = 0

    def skip():
        nonlocal position
        while position < len(text):
            if text[position].isspace():
                position += 1
            elif text.startswith("//", position):
                end = text.find("\n", position)
                position = len(text) if end < 0 else end
            elif text.startswith("/*", position):
                end = text.find("*/", position + 2)
                if end < 0:
                    fail("project.pbxproj: a comment is not closed")
                position = end + 2
            else:
                return

    def expect(character):
        nonlocal position
        skip()
        if not text.startswith(character, position):
            fail(f"project.pbxproj: expected '{character}' at offset {position}")
        position += 1

    def value():
        nonlocal position
        skip()
        if position >= len(text):
            fail("project.pbxproj ends early")
        character = text[position]
        if character == "{":
            position += 1
            out = {}
            while True:
                skip()
                if text.startswith("}", position):
                    position += 1
                    return out
                key = value()
                expect("=")
                out[key] = value()
                expect(";")
        if character == "(":
            position += 1
            out = []
            while True:
                skip()
                if text.startswith(")", position):
                    position += 1
                    return out
                out.append(value())
                skip()
                if text.startswith(",", position):
                    position += 1
        if character == '"':
            position += 1
            out = []
            while position < len(text) and text[position] != '"':
                if text[position] == "\\" and position + 1 < len(text):
                    position += 1
                    out.append(escapes.get(text[position], text[position]))
                else:
                    out.append(text[position])
                position += 1
            position += 1
            return "".join(out)
        match = bare.match(text, position)
        if not match:
            fail(f"project.pbxproj: unexpected '{character}' at offset {position}")
        position = match.end()
        return match.group(0)

    return value()


def linked_products():
    """Each Swift package product a target that ships links, as "<target>: <package> <product>", sorted. Test bundles
    are left out: they are not in the app."""
    objects = openstep(read(PROJECT)).get("objects", {})
    out = []
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget" or "test" in target.get("productType", ""):
            continue
        for reference in target.get("packageProductDependencies", []):
            product = objects.get(reference, {})
            package = objects.get(product.get("package", ""), {})
            source = package.get("repositoryURL") or package.get("relativePath") or "(no package)"
            out.append(f"{target.get('name')}: {source} {product.get('productName')}")
    if not out:
        fail("project.pbxproj: no target links a Swift package product")
    return sorted(out)


def content_hash(data):
    """A hash of the bundled file's content: everything but this hash, in a canonical form, so formatting does not
    count but any edited value does."""
    rest = dict(data)
    recorded = data.get("inputs")
    if isinstance(recorded, dict):
        rest["inputs"] = {key: value for key, value in recorded.items() if key != "content"}
    return sha(json.dumps(rest, sort_keys=True, ensure_ascii=False, separators=(",", ":")))


def check_package_table(packages, pinned):
    problems = []
    for identity, (version, _) in sorted(pinned.items()):
        if identity not in packages:
            problems.append(f"{identity} {version} is pinned in Package.resolved but missing from THIRD_PARTY_NOTICES.md")
        elif packages[identity][0] != version:
            problems.append(f"{identity}: THIRD_PARTY_NOTICES.md says {packages[identity][0]}, Package.resolved pins {version}")
    for identity in sorted(set(packages) - set(pinned)):
        problems.append(f"{identity} is in THIRD_PARTY_NOTICES.md but not pinned in Package.resolved")
    return problems


def check_app_rows(rows, packages):
    problems = []
    for package in ordered_packages(rows):
        if package not in packages:
            problems.append(f"'In the app' lists {package}, which is not in the package table")
            continue
        own = [row for row in rows if row["package"] == package and row["part"] == package and row["spdx"] == packages[package][1]]
        if not own:
            problems.append(f"'In the app' has no row for {package} itself under its licence {packages[package][1]}")
    return problems


# ---------------------------------------------------------------- package checkouts
def checkouts_dir(argv):
    candidates = []
    if "--packages" in argv:
        index = argv.index("--packages")
        if index + 1 >= len(argv):
            fail("--packages needs a folder")
        candidates.append(argv[index + 1])
    for variable, suffix in (("SOURCE_PACKAGES_PATH", ""), ("DERIVED_DATA_PATH", "SourcePackages")):
        if os.environ.get(variable):
            candidates.append(os.path.join(os.environ[variable], suffix))
    derived = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
    if os.path.isdir(derived):
        found = [os.path.join(derived, name, "SourcePackages") for name in os.listdir(derived) if name.startswith("BillBoard-")]
        candidates += sorted((path for path in found if os.path.isdir(path)), key=os.path.getmtime, reverse=True)
    for candidate in candidates:
        for path in (candidate, os.path.join(candidate, "..")):
            if os.path.isdir(os.path.join(path, "checkouts")):
                return os.path.abspath(path)
    fail("no Swift package checkouts found: build the app once (Xcode resolves the packages), or pass --packages DIR")


def checkout_paths(source_packages, pinned, needed):
    """{identity: folder}, each checked to be at its pinned revision."""
    state_path = os.path.join(source_packages, "workspace-state.json")
    recorded = {}
    if os.path.isfile(state_path):
        for dependency in json.loads(read(state_path)).get("object", {}).get("dependencies", []):
            identity = dependency["packageRef"]["identity"]
            revision = dependency.get("state", {}).get("checkoutState", {}).get("revision")
            recorded[identity] = (dependency.get("subpath", identity), revision)
    folders = {}
    checkouts = os.path.join(source_packages, "checkouts")
    for identity in needed:
        subpath, revision = recorded.get(identity, (identity, None))
        folder = os.path.join(checkouts, subpath)
        if not os.path.isdir(folder):
            matches = [name for name in os.listdir(checkouts) if name.lower() == identity.lower()]
            if not matches:
                fail(f"no checkout of {identity} in {checkouts}")
            folder = os.path.join(checkouts, matches[0])
        if revision is None:
            revision = subprocess.run(["git", "-C", folder, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if revision != pinned[identity][1]:
            fail(f"{identity} is checked out at {revision or 'an unknown revision'}, not the pinned {pinned[identity][1]}: resolve the packages again")
        folders[identity] = folder
    return folders


# ---------------------------------------------------------------- reading a package
# "Copyright ...", "(c) 2019 ...", "© ...", and "Modifications Copyright ..." or "Portions Copyright ...".
COPYRIGHT = re.compile(r"^[\s/*#;!-]*((?:(?:Modifications|Portions)\s+)?(?:Copyright\b|\(c\)\s*\d|©).*?)\s*(?:\*/)?\s*$")
NOT_A_COPYRIGHT = re.compile(r"[\[{]yyyy|^Copyright\s+(notice|owner|holders?|license|licence|statement)\b")


def copyright_line(line):
    match = COPYRIGHT.match(line)
    if not match or NOT_A_COPYRIGHT.search(match.group(1)):
        return None
    return re.sub(r"\s+", " ", match.group(1)).strip()


def source_files(path):
    if os.path.isfile(path):
        return [path]
    if not os.path.isdir(path):
        fail(f"no such file or folder: {path}")
    out = []
    for folder, subfolders, names in os.walk(path):
        subfolders[:] = sorted(name for name in subfolders if name not in SKIPPED_DIRS)
        out += [os.path.join(folder, name) for name in sorted(names) if name.endswith(SOURCE_EXTENSIONS)]
    return out


def copyright_lines(package_folder, paths):
    """{line: files it heads} from the first lines of the source files under `paths`."""
    counts = {}
    for path in paths:
        for file in source_files(os.path.join(package_folder, path)):
            with open(file, encoding="utf-8", errors="replace") as handle:
                for number, line in enumerate(handle):
                    if number >= HEADER_LINES:
                        break
                    found = copyright_line(line)
                    if found:
                        counts[found] = counts.get(found, 0) + 1
    return counts


def comment_blocks(text):
    """The comment blocks in a source file's first lines, comment markers removed."""
    lines = text.replace("\r\n", "\n").split("\n")[: HEADER_LINES * 2]
    blocks, index = [], 0
    while index < len(lines):
        stripped = lines[index].strip()
        if stripped.startswith("//"):
            block = []
            while index < len(lines) and lines[index].strip().startswith("//"):
                block.append(re.sub(r"^\s*//+ ?", "", lines[index]))
                index += 1
            blocks.append(block)
        elif stripped.startswith("/*"):
            block, first = [], True
            while index < len(lines):
                line = lines[index]
                if first:
                    line = line.split("/*", 1)[1]
                closed = "*/" in line
                line = line.split("*/", 1)[0]
                block.append(re.sub(r"^\s*\*(?: |$)", "", line))
                index += 1
                first = False
                if closed:
                    break
            blocks.append(block)
        else:
            index += 1
    out = []
    for block in blocks:
        text = normalized("\n".join(block))
        body = [line for line in text.split("\n") if line.strip()]
        indent = min((len(line) - len(line.lstrip()) for line in body), default=0)
        out.append("\n".join(line[indent:] for line in text.split("\n")))
    return out


def licence_text(folder, path):
    full = os.path.join(folder, path)
    if not os.path.isfile(full):
        fail(f"no such file: {full}")
    if not path.endswith(SOURCE_EXTENSIONS):
        return normalized(read(full))
    blocks = [
        block for block in comment_blocks(read(full))
        if any(copyright_line(line) for line in block.split("\n")) and "SPDX-License-Identifier" not in block
    ]
    if not blocks:
        fail(f"{full}: no licence comment with a copyright line at the top")
    return "\n\n".join(blocks)


# ---------------------------------------------------------------- the bundled file
def generate(rows, packages, pinned, folders, raw_table):
    texts = {}
    own_licences = repository_licences(rows)

    def store(text):
        key = "sha256:" + sha(text)[:16]
        if texts.get(key, text) != text:
            fail(f"two licence texts share the id {key}")
        texts[key] = text
        return key

    components = []
    for package in ordered_packages(rows):
        folder = folders[package]
        version, spdx, source = packages[package]
        notices, licenses, counts = [], [], {}
        for row in (row for row in rows if row["package"] == package):
            for path in row["notices"]:
                full = os.path.join(folder, path)
                if not os.path.isfile(full):
                    fail(f"no such file: {full}")
                text = normalized(read(full))
                if not text:
                    fail(f"{full} is empty")
                notices.append({"part": row["part"], "file": path, "text": text})
            # The package's own files, then any full text from licenses/ that the package only points to.
            sources = [(path, licence_text(folder, path)) for path in row["licenses"]]
            sources += [(path, own_licences[path]) for path in row["repositoryLicenses"]]
            for path, text in sources:
                if not text:
                    fail(f"{package} / {row['part']}: {path} is empty")
                key = store(text)
                same = next((entry for entry in licenses if entry["text"] == key), None)
                if same is None:
                    licenses.append({"parts": [row["part"]], "spdx": row["spdx"], "files": [path], "text": key})
                else:
                    if row["part"] not in same["parts"]:
                        same["parts"].append(row["part"])
                    if path not in same["files"]:
                        same["files"].append(path)
                    if row["spdx"] != same["spdx"]:
                        fail(f"{package}: one licence text is listed as both {same['spdx']} and {row['spdx']}")
            for line, count in copyright_lines(folder, row["copyrightFrom"]).items():
                counts[line] = counts.get(line, 0) + count
        components.append({
            "name": package,
            "version": version,
            "revision": pinned[package][1],
            "spdx": spdx,
            "source": source,
            "notices": notices,
            "copyrights": [line for line, _ in sorted(counts.items(), key=lambda item: (-item[1], item[0]))],
            "licenses": licenses,
        })

    notice = normalized(read(REPO_NOTICE))
    data = {
        "about": "Generated by scripts/generate-open-source-licenses.sh from THIRD_PARTY_NOTICES.md. Do not edit.",
        "formatVersion": FORMAT_VERSION,
        "inputs": inputs(raw_table, rows),
        "billboard": {
            "copyright": billboard_copyright(notice),
            "notice": notice,
            "license": store(normalized(read(REPO_LICENSE))),
        },
        "components": components,
        "texts": dict(sorted(texts.items())),
    }
    data["inputs"]["content"] = content_hash(data)
    return data


def encoded(data):
    return json.dumps(data, indent=2, ensure_ascii=False, sort_keys=False) + "\n"


def check_bundled(raw_table, rows, pinned):
    problems = []
    if not os.path.isfile(OUT):
        return [f"{OUT_REL} is missing"]
    try:
        data = json.loads(read(OUT))
    except ValueError as error:
        return [f"{OUT_REL} is not valid JSON: {error}"]
    if not isinstance(data, dict):
        return [f"{OUT_REL} is not a JSON object"]
    if data.get("formatVersion") != FORMAT_VERSION:
        problems.append(f"{OUT_REL} has format {data.get('formatVersion')}, not {FORMAT_VERSION}")
    recorded = data.get("inputs", {})
    if not isinstance(recorded, dict):
        recorded = {}
    if recorded.get("content") != content_hash(data):
        problems.append(f"{OUT_REL} was edited by hand (its content no longer matches the hash it was generated with)")
    expected = inputs(raw_table, rows)
    names = {"table": "THIRD_PARTY_NOTICES.md's 'In the app' table", "notice": "NOTICE", "license": "LICENSE"}
    for key, name in names.items():
        if recorded.get(key) != expected[key]:
            problems.append(f"{name} changed since {OUT_REL} was generated")
    was = recorded.get("licenseFiles") if isinstance(recorded.get("licenseFiles"), dict) else {}
    now = expected["licenseFiles"]
    for path in sorted(set(was) | set(now)):
        if path not in now:
            problems.append(f"the table no longer links {path}, which {OUT_REL} was generated with")
        elif path not in was:
            problems.append(f"the table links {path}, which {OUT_REL} was generated without")
        elif was[path] != now[path]:
            problems.append(f"{path} changed since {OUT_REL} was generated")
    if recorded.get("products") != expected["products"]:
        was = set(recorded.get("products") or [])
        now = set(expected["products"])
        change = [f"now links {product}" for product in sorted(now - was)] + [f"no longer links {product}" for product in sorted(was - now)]
        problems.append(f"the app's package products changed since {OUT_REL} was generated ({'; '.join(change) or 'reordered'}): "
                        "check the 'In the app' table covers the targets they need")
    components = data.get("components", [])
    if [component.get("name") for component in components] != ordered_packages(rows):
        problems.append(f"{OUT_REL} lists {[c.get('name') for c in components]}, the table {ordered_packages(rows)}")
    texts = data.get("texts", {})
    used = {data.get("billboard", {}).get("license")}
    for component in components:
        name = component.get("name")
        if name in pinned and (component.get("version"), component.get("revision")) != pinned[name]:
            problems.append(f"{name}: {OUT_REL} has {component.get('version')} ({component.get('revision')}), Package.resolved pins {pinned[name][0]} ({pinned[name][1]})")
        if not component.get("licenses"):
            problems.append(f"{name}: no licence text")
        for entry in component.get("licenses", []):
            used.add(entry.get("text"))
            if not texts.get(entry.get("text")):
                problems.append(f"{name}: licence text {entry.get('text')} is missing")
        for notice in component.get("notices", []):
            if not notice.get("text"):
                problems.append(f"{name}: an empty notice")
    if set(texts) != used:
        problems.append(f"{OUT_REL} has unused or missing licence texts")
    if not texts.get(data.get("billboard", {}).get("license")):
        problems.append("Billboard's own licence text is missing")
    return problems


def main(argv):
    md = read(NOTICES_MD)
    packages = package_table(md)
    raw_table, rows = app_table(md)
    pinned = pins()
    problems = check_package_table(packages, pinned) + check_app_rows(rows, packages)

    if "--check" in argv:
        stale = check_bundled(raw_table, rows, pinned)
        for problem in problems + stale:
            print(f"  {problem}", file=sys.stderr)
        if stale:
            fail(f"{OUT_REL} is out of date: update THIRD_PARTY_NOTICES.md if a pin or a linked product changed, then run "
                 "./scripts/generate-open-source-licenses.sh (it needs the package checkouts: build once first)")
        if problems:
            fail("THIRD_PARTY_NOTICES.md no longer matches Package.resolved: update its package tables")
        print(f"{OUT_REL} matches THIRD_PARTY_NOTICES.md and Package.resolved ({len(ordered_packages(rows))} packages)")
        return

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        fail("fix THIRD_PARTY_NOTICES.md first")
    source_packages = checkouts_dir(argv)
    folders = checkout_paths(source_packages, pinned, ordered_packages(rows))
    output = encoded(generate(rows, packages, pinned, folders, raw_table))
    before = read(OUT) if os.path.isfile(OUT) else None
    if before == output:
        print(f"{OUT_REL} is unchanged ({len(ordered_packages(rows))} packages, from {source_packages})")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(output)
    print(f"Wrote {OUT_REL} ({len(ordered_packages(rows))} packages, from {source_packages})")


main(sys.argv[1:])
PYTHON
