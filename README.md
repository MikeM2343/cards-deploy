# cards-deploy

Runs a Cards server from the images the [Cards](https://github.com/MikeM2343/Cards) publish workflow pushes to GHCR. It can also install new releases automatically as soon as they are published.

## Requirements

- A Linux or macOS machine (or Windows with WSL) with Docker and the Docker Compose plugin, plus `git`, `bash` and `curl`.
- A user that can run `docker` commands, either root or a member of the `docker` group.
- A Gmail account and an [app password](https://myaccount.google.com/apppasswords) for it. Cards sends sign-in links from this account.
- HTTPS in front of the proxy port, for example Caddy, nginx or a Cloudflare Tunnel. The stack serves plain HTTP on `APP_MAIN_PORT`, and sign-in emails link to `https://<APP_DOMAIN>`.

## Quick start

```sh
git clone git@github.com:MikeM2343/cards-deploy.git
cd cards-deploy
./cards setup
```

Setup does the following:

1. Creates `.env` from [.env.example](.env.example) and generates the database password and the auth secret.
2. Asks for the public hostname and the Gmail details.
3. Picks the newest release and starts the stack.
4. Waits until Cards answers through the proxy.

To set up without prompts (for example from a provisioning script), export the settings first:

```sh
APP_DOMAIN=cards.example.com EmailAccount=me@gmail.com EmailPassword=abcdefghijklmnop \
CARDS_AUTO_UPDATE=true ./cards setup
```

Every setting is described in [.env.example](.env.example). To change one later, edit `.env` and run `./cards up`.

## Commands

| Command                           | What it does                                                                     |
| --------------------------------- | -------------------------------------------------------------------------------- |
| `./cards setup`                   | Create `.env`, asking for anything missing, then start Cards                     |
| `./cards up`                      | Start Cards, or apply changes made to `.env`                                     |
| `./cards down`                    | Stop Cards. The database is kept in the `mongodb_data` volume.                   |
| `./cards update [version]`        | Install the newest release now, or the given one                                 |
| `./cards update <version> --force`| Install an older release (roll back)                                             |
| `./cards status`                  | Show the configured version, auto-update state and containers                    |
| `./cards logs [service]`          | Follow logs for `proxy`, `next`, `ws`, `mongodb` or `updater`                    |

## Automatic updates

Set `CARDS_AUTO_UPDATE=true` in `.env` and run `./cards up`. To turn it off, set it back to `false` and run `./cards up` again.

**How it works:**
1. When a `v*` tag is pushed to Cards, the publish workflow builds the `cards-next`, `cards-ws` and `cards-proxy` images.
2. Once all three are pushed and smoke tested, its `announce` job posts the tag to an [ntfy](https://ntfy.sh) topic.
3. Every host with auto-update on runs an `updater` container that listens on that topic.
4. When an announcement arrives, the updater:
   1. Ignores it unless it is a release tag (`vX.Y.Z`) newer than the version running.
   2. Pulls all three images. If any pull fails, nothing changes.
   3. Restarts the stack on the new version, then waits up to 3 minutes for both `/health` (ws) and `/` (next) to answer through the proxy.
   4. If they don't answer, rolls back to the previous version.
   5. Removes images older than the version it just replaced. Each release is several GB, so this keeps disk use to two releases.
5. The new version is written to `CARDS_VERSION` in `.env`, so `./cards up` and a reboot both keep it.

**Missed announcements:** if the host was off or disconnected, the updater picks up from the last announcement it handled. ntfy.sh keeps messages for 12 hours. After a longer outage, run `./cards update`.

**Security:**
- The updater can control Docker on this host through the Docker socket, so it is effectively root.
- An announcement is only a signal. It can only install a newer version that already exists under `CARDS_IMAGE_PREFIX`. Someone who posts to the topic can at most trigger an upgrade you published yourself.
- To keep the topic private, self-host ntfy with access control. Then set `CARDS_UPDATE_SERVER` and `CARDS_UPDATE_TOKEN` here, and the matching settings in the Cards repo (see below).

**Limitations:**
- Pre-release tags (such as `v1.2.0-rc1`) are never installed.
- The images must stay public. The updater has no registry credentials.

## Releasing from Cards

The publish workflow posts to topic `cards-releases-fc544e0257c4a4b9` on `https://ntfy.sh`, which matches the defaults in `.env.example`. To use a different server or topic, set them in both places:

- **Cards repository:** variables `CARDS_UPDATE_SERVER` and `CARDS_UPDATE_TOPIC`, and secret `CARDS_UPDATE_TOKEN` if the server needs one.
- **Each host's `.env`:** `CARDS_UPDATE_SERVER`, `CARDS_UPDATE_TOPIC` and `CARDS_UPDATE_TOKEN`.

To watch releases arrive, subscribe to the topic in the ntfy phone app or at `https://ntfy.sh/<topic>`.

## Several instances on one host

Clone the repository once per instance, for example `cards-prod` and `cards-staging`. Give each its own `APP_MAIN_PORT` and `MONGODB_HOST_PORT`.

Each instance gets its own containers and database, named after its directory. Every instance with auto-update on installs each release. To update one by hand only, leave auto-update off there and use `./cards update`.

## Troubleshooting

- **See what the updater did:** `./cards logs updater`
- **Roll back:** `./cards update v0.2.3 --force`. Auto-update moves forward again at the next release.
- **Moved this directory:** run `./cards up` so the updater gets the new path.
- **Running the files directly:** `compose.yaml` is the whole stack. `updater/updater.sh` does the installs. `lib/config.sh` reads and writes `.env`.
