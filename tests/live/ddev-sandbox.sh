#!/usr/bin/env bash
# Builds the throwaway DDEV sandbox that examples/ddev.envpool is live-tested in, at ~/tmp/envlock-sandbox/ddev.
# shellcheck disable=SC2016  # the jq filter names jq variables, and the hook runner's script names positional parameters of its own bash.
# Usage: tests/live/ddev-sandbox.sh [create]
# The sandbox is a git repo with a WordPress site, a DDEV project named sbx-ddev (the seed) and an untracked .envpool copied from the example.
# Its active theme, sage-like, dies without a git-ignored vendor/, as a Sage theme does before its composer install. The seed has the vendor/, so it works, but a worktree of HEAD has none.
# With "create" it then destroys sbx-ddev2, creates it the way envlock does, attaches it to a worktree that has the vendor/ and checks that the site answers 200. It exits non-zero when a step fails.
# Safe to run again: it skips what exists and starts the seed only while it is stopped. It leaves the seed running.
# Tear down with: ddev delete -Oy sbx-ddev sbx-ddev2; git -C ~/tmp/envlock-sandbox/ddev worktree prune; rm -rf ~/tmp/envlock-sandbox/ddev ~/tmp/envlock-sandbox/ddev-wt
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sbx=$HOME/tmp/envlock-sandbox/ddev
wt=$sbx-wt
seed='sbx-ddev'
env=${seed}2
theme=$sbx/wp-content/themes/sage-like

git_sbx() { git -C "$sbx" -c user.name=sandbox -c user.email=sandbox@localhost -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
wp() { (cd "$sbx" && ddev wp --allow-root "$@"); }
# Runs a hook the way envlock does: in a new bash that sources the pool, with set -e on for flags "eu" and off for "u".
hook() {
	local flags=$1 dir=$2
	shift 2
	ENVLOCK_ENV=$env ENVLOCK_WORKTREE=$dir bash -c "set -${flags}o pipefail"'; source "$1" >&2; shift; "$@"' _ "$sbx/.envpool" "$@"
}

mkdir -p "$sbx"
[ -f "$sbx/.ddev/config.yaml" ] || (cd "$sbx" && ddev config --project-name="$seed" --project-type=wordpress)
if [ ! -d "$sbx/.git" ]; then
	git_sbx init -q -b main
	printf '.envpool\n' >>"$sbx/.git/info/exclude"
fi
# DDEV writes the two wp-config files into each worktree it starts.
printf '%s\n' /wp-config.php /wp-config-ddev.php /wp-content/uploads/ /wp-content/themes/sage-like/vendor/ >"$sbx/.gitignore"

# ddev start on a running project can leave the router unable to read its TLS keys on rootless Docker (ddev/ddev#8975).
[ -n "$(ddev list -j | jq -r --arg n "$seed" '.raw[] | select(.name == $n and .status == "running") | .name')" ] || (cd "$sbx" && ddev start)
[ -f "$sbx/wp-load.php" ] || wp core download
wp core is-installed || wp core install --url="https://$seed.ddev.site" --title=sandbox --admin_user=admin --admin_password=admin --admin_email=sandbox@example.com --skip-email

mkdir -p "$theme/vendor"
printf '<?php\n' >"$theme/vendor/autoload.php"
printf '/*\nTheme Name: sage-like\n*/\n' >"$theme/style.css"
printf '<?php\n' >"$theme/index.php"
cat >"$theme/functions.php" <<'PHP'
<?php
if ( ! file_exists( __DIR__ . '/vendor/autoload.php' ) ) {
	wp_die( 'Autoloader not found' );
}
PHP
wp theme is-active sage-like || wp theme activate sage-like

git_sbx add -A
git_sbx diff --cached --quiet || git_sbx commit -q -m "Sandbox state"

# The example's seed, ENVS and prefix are placeholders; the sed fills in the sandbox's.
sed -e "s/^ENVPOOL_SEED=.*/ENVPOOL_SEED=$seed/" -e "s/^ENVS=.*/ENVS=($env)/" -e "s/^ENVPOOL_PREFIX=.*/ENVPOOL_PREFIX=$seed/" "$root/examples/ddev.envpool" >"$sbx/.envpool"
bash -n "$sbx/.envpool"
echo "sandbox ready: $sbx"

[ "${1:-}" = create ] || exit 0
hook u "$sbx" envpool_destroy
rm -rf "$wt"
git_sbx worktree prune
# The same call envlock makes for a missing env.
hook u "$sbx" envpool_create
git_sbx worktree add -q --detach "$wt" HEAD
cp -r "$theme/vendor" "$wt/wp-content/themes/sage-like/"
hook eu "$wt" envpool_attach
code=$(curl -skf -o /dev/null -w '%{http_code}' --max-time 20 "https://$env.ddev.site/")
echo "https://$env.ddev.site/ answers $code"
