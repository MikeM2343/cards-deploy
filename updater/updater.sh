#!/bin/sh
# Runs in the updater container (see compose.yaml), with this repository mounted at $CARDS_DIR and
# the host's Docker socket mounted, so the docker compose calls below act on the host's stack. It
# uses only what the stock docker:cli image ships with (busybox sh, wget, sed), so hosts never have
# to build an image.
#   updater.sh listen                      install each newer release announced on the update topic
#   updater.sh deploy <version> [--force]  install a release now; --force allows an older one
#   updater.sh health                      wait until the app answers through the proxy
set -eu

cd "${CARDS_DIR:?CARDS_DIR is not set}"
. lib/config.sh

readonly VersionedServices='proxy next ws'
readonly AppServices='mongodb ws next proxy'
# /health is answered by ws and /auth/login by next, both through the proxy. (wget follows
# redirects, so a page that redirects, like /, is avoided.)
readonly HealthUrls='http://proxy/health http://proxy/auth/login'
readonly HealthTimeoutSeconds=180
readonly LastMessageFile=$StateDir/last-release-message

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

isReleaseVersion() {
	case $1 in
		'' | *[!v0-9.]*) return 1 ;;
	esac
	printf '%s\n' "$1" | grep -Eq "$VersionPattern"
}

waitUntilHealthy() {
	local deadline url
	deadline=$(($(date +%s) + HealthTimeoutSeconds))
	for url in $HealthUrls; do
		until wget -q -T 5 -O /dev/null "$url" 2>/dev/null; do
			if [ "$(date +%s)" -ge "$deadline" ]; then
				log "No healthy response from $url after ${HealthTimeoutSeconds}s"
				return 1
			fi
			sleep 3
		done
	done
}

# Removes Cards images other than the given versions. Docker refuses to remove an image a container
# still uses, so images belonging to another instance on this host are left alone.
removeOtherImages() {
	local prefix image
	prefix=$(getConfig CARDS_IMAGE_PREFIX)
	docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$prefix/cards-*:v*" | while read -r image; do
		case " $* " in
			*" ${image##*:} "*) ;;
			*) if docker image rm "$image" >/dev/null 2>&1; then log "Removed $image"; fi ;;
		esac
	done
}

# The service lists below are deliberately unquoted so they split into one argument per service.
deploy() {
	local version=$1 force=${2:-} current
	current=$(getConfig CARDS_VERSION)
	if ! isReleaseVersion "$version"; then
		log "Ignoring '$version': not a release version (vX.Y.Z)"
		return 1
	fi
	if [ "$force" != --force ] && ! isNewer "$version" "$current"; then
		log "Already on $current; not installing $version"
		return 0
	fi

	log "Installing $version (currently ${current:-none})"
	# shellcheck disable=SC2086
	if ! CARDS_VERSION=$version docker compose pull --quiet $VersionedServices; then
		log "Could not pull $version; staying on $current"
		return 1
	fi
	setConfig CARDS_VERSION "$version"
	# shellcheck disable=SC2086
	if docker compose up -d $AppServices && waitUntilHealthy; then
		log "Now running $version"
		# The version just replaced is kept so a manual rollback does not need a download.
		removeOtherImages "$version" "$current"
		return 0
	fi

	[ -n "$current" ] || return 1
	log "$version is unhealthy; rolling back to $current"
	setConfig CARDS_VERSION "$current"
	# shellcheck disable=SC2086
	docker compose up -d $AppServices
	return 1
}

# One deploy at a time, whether it comes from the listener or from `./cards update`.
deployExclusively() {
	mkdir -p "$StateDir"
	(
		flock 9
		deploy "$@"
	) 9>"$StateDir/deploy.lock"
}

# Streams the topic's events, one JSON object per line. The read timeout is well past ntfy's 45s
# keepalive, so a connection that silently died is noticed.
subscribe() {
	if [ -n "${CARDS_UPDATE_TOKEN:-}" ]; then
		wget -q -T 120 -O - --header "Authorization: Bearer $CARDS_UPDATE_TOKEN" "$1"
	else
		wget -q -T 120 -O - "$1"
	fi
}

# Prints a string field of one ntfy event. A field holding an escaped quote comes back cut short,
# which only matters for message text, and anything that is not a release version is ignored anyway.
jsonField() {
	printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

listen() {
	local url since line id version
	url="${CARDS_UPDATE_SERVER%/}/${CARDS_UPDATE_TOPIC:?Set CARDS_UPDATE_TOPIC in .env}/json"
	mkdir -p "$StateDir"
	log "Running $(getConfig CARDS_VERSION); listening for releases on $url"

	while true; do
		# ntfy keeps recent messages, so resuming after the last one handled also picks up releases
		# announced while this was disconnected or the host was down.
		since=$(cat "$LastMessageFile" 2>/dev/null || true)
		subscribe "$url${since:+?since=$since}" | while IFS= read -r line; do
			[ "$(jsonField "$line" event)" = message ] || continue
			id=$(jsonField "$line" id)
			version=$(jsonField "$line" message)
			log "Release announced: $version"
			# stdin is the release stream, which docker compose must not read from.
			deployExclusively "$version" </dev/null || log "Release $version was not installed"
			echo "$id" >"$LastMessageFile"
		done || true
		log "Disconnected from $url; reconnecting in 15s"
		sleep 15
	done
}

case ${1:-} in
	listen) listen ;;
	deploy) deployExclusively "${2:?Usage: updater.sh deploy <version> [--force]}" "${3:-}" ;;
	health) waitUntilHealthy ;;
	*)
		echo "Usage: updater.sh listen | deploy <version> [--force] | health" >&2
		exit 2
		;;
esac
