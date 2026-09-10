{
  description = "claude-box — run Claude Code confined to the current project directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        claude-box = pkgs.stdenvNoCC.mkDerivation {
          pname = "claude-box";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            install -Dm755 claude-box $out/bin/claude-box
            # bwrap must be on PATH; python3 is only used for first-run seeding.
            wrapProgram $out/bin/claude-box \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap pkgs.python3Minimal ]}
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Run Claude Code confined to the current project directory";
            platforms = platforms.linux;
            mainProgram = "claude-box";
          };
        };
        default = claude-box;
      });

      apps = forAllSystems (pkgs: rec {
        claude-box = {
          type = "app";
          program = "${self.packages.${pkgs.system}.claude-box}/bin/claude-box";
        };
        default = claude-box;
      });
    };
}
