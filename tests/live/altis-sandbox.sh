#!/usr/bin/env bash
# Builds the throwaway Altis sandbox that examples/altis.envpool is live-tested in, at ~/tmp/envlock-sandbox/altis.
# shellcheck disable=SC2016  # the jq filters name jq variables, not shell ones.
# Usage: tests/live/altis-sandbox.sh [PATH-TO-altis-local-server-CHECKOUT]
# With a path, the sandbox installs that checkout instead of the released altis/local-server, and its .envpool starts envs with ALTIS_LOCAL_SERVER_NAME instead of editing composer.json.
# Safe to run again: it skips what exists, and installs only while vendor/ is missing. It never starts a container.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sbx=$HOME/tmp/envlock-sandbox/altis
seed=my-project
ls_path=${1:-}

git_sbx() { git -C "$sbx" -c user.name=sandbox -c user.email=sandbox@localhost -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
set_json() { local tmp; tmp=$(mktemp) && jq "$@" "$sbx/composer.json" >"$tmp" && cat "$tmp" >"$sbx/composer.json" && rm "$tmp"; }

if [ -n "$ls_path" ]; then
	ls_path=$(realpath "$ls_path")
	[ "$(jq -r .name "$ls_path/composer.json")" = altis/local-server ] || { echo "$ls_path is not an altis/local-server checkout" >&2; exit 1; }
	base=$(git -C "$ls_path" describe --tags --abbrev=0)
fi

if [ ! -d "$sbx/.git" ]; then
	mkdir -p "$sbx"
	tmp=$(mktemp -d)
	git clone -q --depth 1 --branch 28.0.1 https://github.com/humanmade/altis-skeleton.git "$tmp"
	cp -r "$tmp/composer.json" "$tmp/content" "$sbx/"
	rm -rf "$tmp"
	# Everything but vendor/ here is what install copies out of vendor/ into the project root or into content/.
	printf '%s\n' /vendor/ /index.php /wp-config.php /.build-script /.config/ /.travis.yml /content/plugins/ /content/mu-plugins/ >"$sbx/.gitignore"
	cat >"$sbx/devbox.json" <<'JSON'
{
  "packages": ["php@8.4", "php84Packages.composer@latest"]
}
JSON
	git_sbx init -q -b main
	printf '.envpool\n' >>"$sbx/.git/info/exclude"
fi

# The sandbox needs no search. Its Elasticsearch container asks for an unlimited memlock, which a rootless dockerd with a lower hard limit refuses, and every stack would start one.
set_json --arg n "$seed" '.extra.altis.modules."local-server".name = $n | .extra.altis.modules.search.enabled = false'
# options.versions gives the checkout the released version, so the skeleton's ^28 constraint accepts it. An alias on the branch would not work: Composer and viv name a feature branch after the branch it forked from (dev-master), not after itself.
# symlink=false copies the files, because containers mount the project root and cannot follow a link to another directory.
[ -z "$ls_path" ] || set_json --arg p "$ls_path" --arg v "$base" \
	'.repositories = [{type: "path", url: $p, options: {symlink: false, versions: {"altis/local-server": $v}}}]'

(cd "$sbx" && devbox install)
# The lock is committed, so every worktree's viv install reads it. viv finds no php outside devbox, so it would fail the lock's first solve on ext-dom, which phpunit requires.
[ -d "$sbx/vendor" ] || viv install -d "$sbx" --ignore-platform-reqs

git_sbx add -A
git_sbx diff --cached --quiet || git_sbx commit -q -m "Sandbox state"

# The example's seed, ENVS and prefix are already the sandbox's values; the sed makes that explicit.
sed -e "s/^ENVPOOL_SEED=.*/ENVPOOL_SEED=$seed/" -e "s/^ENVS=.*/ENVS=(${seed}2)/" -e "s/^ENVPOOL_PREFIX=.*/ENVPOOL_PREFIX=$seed/" "$root/examples/altis.envpool" >"$sbx/.envpool"
if [ -n "$ls_path" ]; then
	# Swaps envpool_start's subshell, trap and jq block for the one-line start.
	tmp=$(mktemp)
	awk '
		/^envpool_start\(\)/ { in_start = 1 }
		in_start && /^\t\($/ { skip = 1; print "\trm -f \"$dir/vendor/host\" && ALTIS_LOCAL_SERVER_NAME=\"$env\" composer -d \"$dir\" server start && envpool_wait_up \"$env\""; next }
		skip && /^\t\) && envpool_wait_up/ { skip = 0; in_start = 0; next }
		!skip
	' "$sbx/.envpool" >"$tmp" && mv "$tmp" "$sbx/.envpool"
fi
bash -n "$sbx/.envpool"
echo "sandbox ready: $sbx"
