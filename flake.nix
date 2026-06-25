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

      formatter = forAll (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
