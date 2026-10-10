# agent-box

Run Claude Code, or any command, confined to one project directory with
[bubblewrap](https://github.com/containers/bubblewrap).

The project is the only writable host path. The sandbox runs as a separate
unprivileged user.

## Usage

```sh
nix run .                                    # via the flake
./agent-box                                  # confine to $PWD, resume claude
./agent-box --new                            # start a fresh conversation
./agent-box -d ~/src/foo                     # confine to another directory
./agent-box -- claude -p 'run the tests'     # explicit command
./agent-box bash                             # shell inside the sandbox
./agent-box --dry-run                        # print the commands, don't run
```

The default command is `claude --continue` (plain `claude` if the project has no
conversation yet), with `--append-system-prompt` telling it that it runs in a
sandbox. An explicit command runs verbatim. A command starting with `-` is
rejected.

| Flag | Effect |
|---|---|
| `-d, --dir PATH` | Project root (default: `$PWD`) |
| `--ro` | Bind the project read-only |
| `--offline` | No network (breaks the API). Also disables Nix |
| `--no-nix` | Don't pass the Nix daemon socket through |
| `--share-claude` | Bind the real `~/.claude` and `~/.claude.json` read-write |
| `--bind PATH` | Also bind `PATH` read-write (repeatable) |
| `--ro-bind PATH` | Also bind `PATH` read-only (repeatable) |
| `--env VAR` | Pass `VAR` through the environment scrub (repeatable) |
| `--new` | Don't pass `--continue` to the default `claude` |
| `--dry-run` | Print the command and exit (stops at the user switch, which is runnable as printed) |

## What is confined

| | |
|---|---|
| **Filesystem** | `$HOME`, `/tmp`, `/var/tmp` are tmpfs. Project read-write; `/nix/store` and `/etc` read-only. |
| **Processes** | Private PID namespace. |
| **IPC / UTS / cgroup** | Separate namespaces; hostname `agent-box`. |
| **User** | Separate unprivileged user (`agents`). Files it creates are still owned by you. |
| **Capabilities** | All dropped, plus `no_new_privs`. |
| **Environment** | Cleared, then an allowlist (locale, terminal, `ANTHROPIC_*`) is restored. |
| **Lifetime** | `--die-with-parent`. |

Binding a nested path only creates its empty parent directories, not their
other contents.

## Running as a separate user

`agent-box` re-execs itself through `sudo agent-box-mount`, which drops to the
box user before the sandbox is built. The user is set by `box_user=` in
`agent-box-mount`.

Why: the Nix daemon decides trust from the peer uid (`SO_PEERCRED`), which a
user namespace can't change. A trusted client can set `build-hook`,
`post-build-hook`, `substituters` or `extra-sandbox-paths`, which is
root-equivalent. `agent-box` refuses to start if the daemon reports
`"trusted":true` (check with `nix store info --json`).

The switch is printed before it runs:

```
agent-box: Switching to box user
agent-box: + sudo -- /nix/store/...-agent-box/bin/agent-box-mount \
    rw /home/you/src/foo rw /home/you/.local/state/agent-box/home%you%src%foo-123 \
    rw /home/you/.claude/.credentials.json \
    -- /nix/store/...-agent-box/bin/agent-box \
    --internal-switched --internal-user you --internal-home /home/you \
    --internal-handoff /tmp/agent-box-handoff.Ab3kR9
```

The handoff file carries phase 1's results (paths, `$PATH`, Nix profile links,
scrubbed `NIX_CONFIG`) to phase 2. It is world-readable and holds no secrets:
`ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are not carried across.

### File ownership: idmapped mounts

In a private mount namespace, `agent-box-mount` bind-mounts each path under
`/run/agent-box/N` with an
[idmapping](https://docs.kernel.org/filesystems/idmappings.html) that makes
your uid and primary gid read as the box user's, then drops to the box user.
bwrap binds those back to their real paths.

- Inside, the project reads as the box user's own.
- New files land on disk owned by you.
- Your `0700` directories stay `0700`; the box reaches the copies via
  `/run/agent-box`.
- Outside that namespace, `agents` still can't reach your files.

`agent-box-mount` is the only part running as root:

- Only your uid and primary gid are mapped; anything else reads as `nobody`.
- `ro` paths are remounted read-only.
- It drops privileges with `no_new_privs` set.

`--bind`/`--ro-bind` paths you don't own are bound without idmapping and must be
reachable by the box user. Binds are not recursive. Requires a filesystem with
idmapped-mount support (ext4, btrfs, xfs, tmpfs, overlayfs).

## Per-project Claude state

Each project gets its own `.claude/` and `.claude.json` under
`~/.local/state/agent-box/<slug>`.

- `.claude.json` is seeded from yours minus `projects` and `githubRepoPaths`,
  so there's no re-onboarding.
- `~/.claude/.credentials.json` is bind-mounted, not copied, so OAuth token
  rotation stays in sync with the host.

`--share-claude` uses your real `~/.claude` and `~/.claude.json` instead.

## Nix

The flake bundles Claude Code and a toolchain, appended to `PATH` so host tools
win: `claude-code`, `bashInteractive`, `coreutils`, `findutils`, `gnugrep`,
`gnused`, `gawk`, `diffutils`, `patch`, `less`, `which`, `procps`, `git`, `gh`,
`ripgrep`, `fd`, `jq`, `tree`, `nix`, `python3`, `nodejs`, `curl`, `gnutar`,
`gzip`, `xz`, `unzip`.

The sandbox `PATH` is the host's minus `$HOME` entries, so tools installed under
`$HOME` (e.g. `~/.local/bin`) are not visible inside. `bubblewrap` is prepended
to `PATH`. `SSL_CERT_FILE` defaults to the `cacert` bundle. Claude Code is
allowed via a scoped `allowUnfreePredicate`, so no `--impure` is needed.

### Builds

`nix build`, `nix develop`, `nix-shell` and `direnv` work inside, via the
daemon socket:

- `/nix/store` and `/nix/var` are read-only; the daemon socket is bound on top.
  The read-only bind wouldn't block `connect()` anyway; the uid is what makes
  the connection untrusted.
- `NIX_PATH` and `NIX_REMOTE` are passed through.
- `~/.config/nix/nix.conf` is not bound; it is passed as `NIX_CONFIG` without
  `access-tokens`, `netrc-file` and `secret-key-files`.
- Disabled by `--no-nix` and `--offline`. Without a daemon socket (single-user
  Nix), builds fail on the read-only store.

### Profiles

Profile links like `~/.nix-profile` live in the tmpfs `$HOME`, so they are
resolved to store paths and recreated with `--symlink`. `/etc` and
`/run/current-system` are bound for NixOS; NixOS-specific paths are optional.

`--unshare-user` is not passed, since it breaks Claude Code's nested bwrap.

## Limitations

- **Network egress is unrestricted.** The agent can exfiltrate the project.
  `--offline` is the only mitigation, and it disables the agent.
- **The Nix daemon is reachable.** Untrusted-client settings are ignored, but
  building and substituting still work, so CPU/disk abuse is possible.
  Evaluation-time fetches use the sandbox's network. `--no-nix` closes this.
- **No git identity.** Use `--ro-bind ~/.gitconfig`.
- **Not a hard security boundary.** No seccomp filter; it won't stop a kernel
  exploit.

## Requirements

- Unprivileged user namespaces (`/proc/sys/user/max_user_namespaces` > 0).
- **The box user**: an unprivileged account not in `trusted-users`. No home,
  shell or group needed.
- **A sudo rule** for `agent-box-mount` (or type your password each start).
  On NixOS:

  ```nix
  security.sudo.extraRules = [{
    users = [ "you" ];
    commands = [{
      command = "${agent-box}/bin/agent-box-mount";
      options = [ "NOPASSWD" ];
    }];
  }];
  ```

  `sudo` must be the host's setuid binary, so the flake doesn't provide it.
- **Idmapped-mount support** for the project and state paths.

The flake provides everything else. Without Nix, install `bubblewrap` and
util-linux, and keep `agent-box-mount` next to `agent-box`.
