#!/usr/bin/env bash
# Renders the module's Talos machine configurations offline and checks them.
#
#   tests/talos-config/run.sh [BASE_REF]
#
# For every version in TALOS_VERSIONS: render control plane, worker and
# autoscaler configs with the real talos provider (hcloud mocked) and run
# `talosctl validate --mode cloud` on each. Then render the same configs from
# BASE_REF (default: HEAD) for the pre-1.14 version and require them to be
# identical, secrets aside — the v1alpha1 path must not drift while the
# 1.14 document path changes.
#
# Needs terraform >= 1.7, talosctl and git. No cloud credentials, no cost.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE_REF="${1:-HEAD}"
TALOS_VERSIONS="${TALOS_VERSIONS:-v1.13.10 v1.14.1}"
REGRESSION_VERSION="${REGRESSION_VERSION:-v1.13.10}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

prepare() { # prepare <dir> <source: "worktree" | git ref>
	local dir="$1" src="$2" f
	mkdir -p "$dir/tests"
	cp "$HERE/harness.tf" "$dir/"
	cp "$HERE/render.tftest.hcl" "$dir/tests/"
	for f in $(cd "$ROOT" && ls talos_config_*.tf) variables.tf; do
		if [[ "$src" == worktree ]]; then
			cp "$ROOT/$f" "$dir/$f"
		else
			git -C "$ROOT" show "$src:$f" >"$dir/$f"
		fi
	done
	terraform -chdir="$dir" init -backend=false -input=false >/dev/null
}

render() { # render <dir> <version> <out>
	terraform -chdir="$1" test -no-color \
		-var "talos_version=$2" -var "out_dir=$3" >"$3.log" 2>&1 ||
		{ cat "$3.log"; echo "FAIL: render $2 in $1"; exit 1; }
}

# Secrets, tokens and certificates differ on every render.
normalize() {
	sed -E 's/^( *)(token|crt|key|secret|id|clusterID|clusterSecret|aescbcEncryptionSecret|secretboxEncryptionSecret|bootstraptoken): .*/\1\2: X/' "$1" |
		grep -vE '^\s+[A-Za-z0-9+/=]{40,}$'
}

fail=0
prepare "$WORK/new" worktree
for v in $TALOS_VERSIONS; do
	render "$WORK/new" "$v" "$WORK/out-new-$v"
	for f in "$WORK/out-new-$v"/*.yaml; do
		if out="$(talosctl validate --config "$f" --mode cloud 2>&1)"; then
			echo "ok    $v $(basename "$f")"
		else
			echo "FAIL  $v $(basename "$f"): $out"
			fail=1
		fi
	done
done

prepare "$WORK/base" "$BASE_REF"
render "$WORK/base" "$REGRESSION_VERSION" "$WORK/out-base"
for f in "$WORK/out-base"/*.yaml; do
	name="$(basename "$f")"
	if diff -u <(normalize "$f") <(normalize "$WORK/out-new-$REGRESSION_VERSION/$name") >"$WORK/diff"; then
		echo "same  $REGRESSION_VERSION $name vs $BASE_REF"
	else
		echo "DRIFT $REGRESSION_VERSION $name vs $BASE_REF:"
		cat "$WORK/diff"
		fail=1
	fi
done

exit "$fail"
