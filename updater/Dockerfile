# The docker CLI and compose plugin come from the base image; the scripts run from the mounted repo.
FROM docker:28-cli
RUN apk add --no-cache bash curl jq
ENTRYPOINT ["bash", "-c", "exec bash \"$CARDS_DIR/updater/updater.sh\" \"$@\"", "updater"]
