# Helpers shared by ./cards (bash, on the host) and updater/updater.sh (sh, in the updater
# container), so this file sticks to POSIX sh. Both run with this repository as the working directory.

readonly EnvFile=.env
readonly StateDir=state
# Release tags pushed by the Cards publish workflow. Pre-release tags are deliberately not matched.
readonly VersionPattern='^v[0-9]+\.[0-9]+\.[0-9]+$'

# Prints the value of a key in .env, or nothing when it is unset.
getConfig() {
	[ -f "$EnvFile" ] || return 0
	sed -n "s/^$1=//p" "$EnvFile" | tail -n 1
}

# Sets a key in .env, appending it when missing. The file is rewritten in place rather than
# replaced, so it keeps its owner when the updater (which runs as root) changes it.
setConfig() {
	local updated
	updated=$(key=$1 value=$2 awk '
		index($0, ENVIRON["key"] "=") == 1 { print ENVIRON["key"] "=" ENVIRON["value"]; found = 1; next }
		{ print }
		END { if (!found) print ENVIRON["key"] "=" ENVIRON["value"] }' "$EnvFile")
	printf '%s\n' "$updated" >"$EnvFile"
}

# True when version $1 sorts after version $2 (an empty $2 counts as older than anything).
isNewer() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}
