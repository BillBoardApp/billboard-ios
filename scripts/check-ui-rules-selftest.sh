#!/usr/bin/env bash
# Self-test for scripts/check-ui-rules.sh: runs it on small Swift fixtures and checks what each rule reports.
#
#   ./scripts/check-ui-rules-selftest.sh
#
# Covers the rules whose matching is subtle: vote-colour-symbol (split bars count at the call site, not in the
# bar's own declaration), brand-teal, status-colour, serif-role and raw-font-size (a scaled size is fine),
# prominent-label, and the exits (every finding is an error; a clean file passes). Fixtures live in a temporary
# directory, outside the app, so no file allowance applies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${ROOT}/scripts/check-ui-rules.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ui-rules-selftest.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

failures=0
expect() {
  # expect <description> <expected count> <pattern> <output>
  local what="$1" want="$2" pattern="$3" output="$4" got
  got="$(printf '%s\n' "${output}" | grep -cE -- "${pattern}" || true)"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${what}: expected ${want} line(s) matching '${pattern}', got ${got}" >&2
    failures=$((failures + 1))
  else
    echo "ok: ${what}"
  fi
}

mkdir -p "${WORK}/votes" "${WORK}/colours" "${WORK}/buttons" "${WORK}/fonts" "${WORK}/clean"

cat > "${WORK}/fonts/Fonts.swift" <<'SWIFT'
import SwiftUI

struct Fonts: View {
    @ScaledMetric(relativeTo: .caption2) private var glyphSize: CGFloat = 12

    var body: some View {
        VStack {
            Text("A").font(TextRole.Face.serif.font(size: glyphSize, weight: .regular))
            Text("B").font(TextRole.Face.text.font(size: 9, weight: .bold))
            Text("C").font(TextRole.prose.font(size: 30))
            Text("D").font(.system(size: 14))
            Text("E").font(TextRole.Face.text.font(size: glyphSize, weight: .medium))
            Text("F").textRole(.prose)
        }
    }
}
SWIFT

cat > "${WORK}/votes/Rows.swift" <<'SWIFT'
import SwiftUI

struct VoteSplitBar: View {
    var body: some View {
        Rectangle().fill(BillboardColors.voteYea)
    }
}

private struct VoteSplitTendencyBar: View {
    var body: some View {
        Rectangle().fill(VoteChoice.nay.color)
    }
}

struct TopicRowWithoutSymbol: View {
    var body: some View {
        VoteSplitTendencyBar(yea: 1, nay: 2)
    }
}

struct ResultsRowWithSymbol: View {
    var body: some View {
        HStack {
            Image(systemName: VoteChoice.yea.symbolName)
            VoteSplitBar(percentages: [:])
        }
    }
}

struct LegendWithoutSymbol: View {
    var body: some View {
        Text("Yea").foregroundStyle(BillboardColors.voteYea)
    }
}
SWIFT

cat > "${WORK}/colours/Colours.swift" <<'SWIFT'
import SwiftUI

struct TealAndStatus: View {
    var body: some View {
        VStack {
            Text("B").foregroundStyle(BillboardColors.brandTeal)
            Text("D").foregroundStyle(BillboardColors.statusPassed)
            Text("E").foregroundStyle(BillboardColors.interactive)
        }
    }
}
SWIFT

cat > "${WORK}/clean/Clean.swift" <<'SWIFT'
import SwiftUI

struct Clean: View {
    var body: some View {
        VStack {
            Text("Why it matters").textRole(.lead).foregroundStyle(BillboardColors.primaryText)
            Text("Yea").foregroundStyle(VoteChoice.yea.color)
            Image(systemName: VoteChoice.yea.symbolName)
        }
    }
}
SWIFT

cat > "${WORK}/buttons/Buttons.swift" <<'SWIFT'
import SwiftUI

struct Buttons: View {
    var body: some View {
        VStack {
            Button {
            } label: {
                Text("White on the tint")
            }
            .buttonStyle(.borderedProminent)
            .tint(BillboardColors.interactive)

            Button(action: {}) {
                Text("Readable")
                    .foregroundStyle(BillboardColors.onFill)
            }
            .buttonStyle(.borderedProminent)
            .tint(BillboardColors.interactive)

            Button("Glass") {}
                .buttonStyle(.glassProminent)

            Button("Plain") {}
                .buttonStyle(.bordered)
        }
    }
}
SWIFT

# The Civic Record rules are errors (since the cleanup slice, spec 9.2 slice 14): listed, exit 1.
out="$("${CHECK}" "${WORK}/votes" "${WORK}/colours" 2>&1)" && status=0 || status=$?
[[ ${status} -eq 1 ]] && echo "ok: a Civic Record finding exits 1" || { echo "FAIL: Civic Record findings exited ${status}" >&2; failures=$((failures + 1)); }
expect "nothing is reported as only a warning" 0 "warning" "${out}"
expect "a split bar call without a symbol is flagged in its row" 1 "\[vote-colour-symbol\].*TopicRowWithoutSymbol" "${out}"
expect "a row with the symbol is not flagged" 0 "ResultsRowWithSymbol" "${out}"
expect "the split bars' own declarations are not flagged" 0 "in VoteSplit(Tendency)?Bar " "${out}"
expect "a vote colour without a symbol is flagged" 1 "\[vote-colour-symbol\].*LegendWithoutSymbol" "${out}"
expect "brand teal is flagged" 1 "\[brand-teal\]" "${out}"
expect "a status colour is flagged" 1 "\[status-colour\]" "${out}"
expect "interactive is not a status or teal colour" 0 "BillboardColors.interactive" "${out}"

# Fonts: New York through a face and literal sizes through a role or face are flagged; scaled sizes are not.
out="$("${CHECK}" "${WORK}/fonts" 2>&1)" || true
expect "Face.serif is New York outside the reading roles" 1 "\[serif-role\]" "${out}"
expect "literal sizes through a face or role and .system(size:) are raw sizes" 3 "\[raw-font-size\]" "${out}"
expect "a size from a scaled metric is not a raw size" 0 "raw-font-size.*Fonts.swift:(8|12):" "${out}"
expect "a text role is fine" 0 "Fonts.swift:13:" "${out}"

# A file that keeps every rule passes, exit 0.
out="$("${CHECK}" "${WORK}/clean" 2>&1)" && status=0 || status=$?
[[ ${status} -eq 0 ]] && echo "ok: a clean file exits 0" || { echo "FAIL: a clean file exited ${status}: ${out}" >&2; failures=$((failures + 1)); }
expect "a clean file is OK" 1 "^check-ui-rules: OK" "${out}"

# Errors: prominent buttons without an onFill label, exit 1.
out="$("${CHECK}" "${WORK}/buttons" 2>&1)" && status=0 || status=$?
[[ ${status} -eq 1 ]] && echo "ok: an error exits 1" || { echo "FAIL: errors exited ${status}" >&2; failures=$((failures + 1)); }
expect "prominent buttons without onFill are flagged" 2 "\[prominent-label\]" "${out}"
expect "the onFill button is not flagged" 0 "Readable" "${out}"

# The inline allowance silences one line.
sed -i '' 's/\.buttonStyle(\.glassProminent)/.buttonStyle(.glassProminent) \/\/ ui-rules:allow prominent-label/' "${WORK}/buttons/Buttons.swift"
out="$("${CHECK}" "${WORK}/buttons" 2>&1)" || true
expect "ui-rules:allow silences a finding" 1 "\[prominent-label\]" "${out}"

if [[ ${failures} -gt 0 ]]; then
  echo "check-ui-rules self-test: ${failures} failure(s)" >&2
  exit 1
fi
echo "check-ui-rules self-test: OK"
