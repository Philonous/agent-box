{
  description = "agent-box — run a command confined to the current project directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # claude-code carries an unfree licence, so legacyPackages refuses to
      # evaluate it. Allow that one package by name — a blanket allowUnfree
      # would silently cover anything else added to the toolchain later.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          nixpkgs.lib.getName pkg == "claude-code";
      };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # The toolchain the sandbox gets. agent-box builds the sandbox's PATH by
      # stripping the $HOME entries off the host's, so anything installed under
      # $HOME (npm globals, ~/.local/bin) is *not* there — these store paths are
      # what makes `nix run .` work on a machine with nothing installed.
      #
      # Appended as a suffix, so a tool the user already has still wins.
      toolchain = pkgs: with pkgs; [
        claude-code

        # shell and the POSIX basics the script and any agent lean on
        bashInteractive coreutils findutils gnugrep gnused gawk
        diffutils patch less which procps

        # sudo is deliberately absent: the privilege drop needs the host's
        # setuid one, which a store copy could never be.

        # version control and search
        git gh ripgrep fd jq tree

        # the client half of the Nix daemon passthrough (see --no-nix)
        nix

        # runtimes: python3 also does agent-box's first-run config seeding
        python3 nodejs

        # network and archives (cacert is not listed: it ships no bin/, it is
        # referenced directly for SSL_CERT_FILE below)
        curl gnutar gzip xz unzip
      ];
    in
    {
      packages = forAllSystems (pkgs: rec {
        agent-box = pkgs.stdenvNoCC.mkDerivation {
          pname = "agent-box";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            install -Dm755 agent-box $out/bin/agent-box
            install -Dm755 agent-box-mount $out/bin/agent-box-mount
            patchShebangs $out/bin/agent-box $out/bin/agent-box-mount
            # The helper runs as root, so its PATH is fixed to store paths rather
            # than whatever the host has. Not wrapped: the sudoers rule should
            # name the script itself, not a wrapper around it.
            substituteInPlace $out/bin/agent-box-mount \
              --replace-fail 'PATH=/run/current-system/sw/bin:/usr/bin:/bin' \
                             'PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.getent ]}'
            # bwrap is pinned ahead of the host's: the sandbox depends on its
            # exact flag behaviour. Everything else is a fallback.
            # AGENT_BOX_SELF is the wrapper's own path. The privilege drop
            # re-execs agent-box under sudo, and it has to be this wrapper
            # rather than the wrapped script: sudo resets the environment, so
            # the PATH set up here is what puts bubblewrap and the toolchain
            # back for the second phase.
            wrapProgram $out/bin/agent-box \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap ]} \
              --suffix PATH : ${pkgs.lib.makeBinPath (toolchain pkgs)} \
              --set AGENT_BOX_SELF $out/bin/agent-box \
              --set AGENT_BOX_MOUNT $out/bin/agent-box-mount \
              --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Run a command confined to the current project directory";
            platforms = platforms.linux;
            mainProgram = "agent-box";
          };
        };
        default = agent-box;
      });

      apps = forAllSystems (pkgs: rec {
        agent-box = {
          type = "app";
          program = "${self.packages.${pkgs.system}.agent-box}/bin/agent-box";
        };
        default = agent-box;
      });
    };
}
