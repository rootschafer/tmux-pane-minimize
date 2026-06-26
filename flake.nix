{
  description = "tmux-pane-minimize — minimize and restore tmux panes (any nesting)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
    in
    {
      # packages.<system>.default = the self-contained plugin (scripts + engine beside them).
      # Consume it with:  run-shell ${inputs.tmux-pane-minimize.packages.${system}.default}/pane-minimize.tmux
      # packages.<system>.tmux-min-transform = just the Rust engine binary.
      packages = forAll (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          plugin = pkgs.callPackage ./default.nix { };
        in
        {
          default = plugin;
          tmux-pane-minimize = plugin;
          tmux-min-transform = plugin.engine;
        }
      );

      # `nix flake check` builds these. The engine is a buildRustPackage, so its checkPhase
      # runs `cargo test` — the pure oracle suite in engine-rs/src/lib.rs (no tmux needed) —
      # and `plugin` assembles the full output. (CI is intentionally not wired; this is the
      # local/`nix flake check` gate.)
      checks = forAll (system: {
        engine = self.packages.${system}.tmux-min-transform;
        plugin = self.packages.${system}.tmux-pane-minimize;
      });

      formatter = forAll (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
