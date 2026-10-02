* Sandboxing for AI agents or similar
* Nix project, please take the flake into account
* If you stumble over something unexpected, take note of it in this file in the CLAUDE NOTES section. Keep additions as brief as possible


[CLAUDE NOTES]
* The agent's own Bash sandbox has a minimal PATH: no coreutils, bash, or nix,
  and no `/usr/bin/env` (so `./claude-box` fails with "bad interpreter").
  Fix: `export PATH=/run/current-system/sw/bin:$PATH`, and run `bash ./claude-box`.
* That sandbox binds /nix/store but not /nix/var, so `nix eval` works while
  `nix build`/`nix run` fall back to a chroot store at ~/.local/share/nix/root
  (grows to ~500MB of fetched sources) — don't build from here.
* `pkgs.claude-code` is unfree; the flake scopes an `allowUnfreePredicate` to it
  so `nix run .` needs no `--impure`.
* Nix passthrough: /nix/var ro + daemon-socket rw. The profile `--symlink` loop
  must skip /nix/var paths or bwrap aborts with EEXIST (relative default-N-link).
* Can't test the daemon from the agent sandbox; simulate with
  `bwrap --dev-bind / / --bind <fake> /nix/var`. That leaves an empty /nix/var
  mountpoint behind, so `test -d /nix/var` afterwards lies — `rmdir` it.
