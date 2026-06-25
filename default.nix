# tmux-pane-minimize — traditional-Nix package (also used by flake.nix via callPackage).
#
# Builds the Rust engine (engine-rs/ -> tmux-min-transform) and assembles a self-contained
# plugin output: the scripts + the compiled engine placed at scripts/tmux-min-transform,
# which is FIRST in tmux-min.sh's binary resolution order. So a consumer only has to
#   run-shell ${tmux-pane-minimize}/pane-minimize.tmux
# and the engine is found with no PATH/env wiring.
#
# Usage (non-flake):  pkgs.callPackage ./default.nix {}
{
  lib,
  rustPlatform,
  stdenvNoCC,
}:
let
  engine = rustPlatform.buildRustPackage {
    pname = "tmux-min-transform";
    version = "0.1.0";
    src = ./engine-rs;
    # The engine has ZERO dependencies, so the lockfile vendors nothing — no cargoHash,
    # no network fetch. (Note: Cargo edition = 2024, needs rustc >= 1.85 / recent nixpkgs.)
    cargoLock.lockFile = ./engine-rs/Cargo.lock;
  };
in
stdenvNoCC.mkDerivation {
  pname = "tmux-pane-minimize";
  version = "0.1.0";
  src = ./.;
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r pane-minimize.tmux scripts README.md STATE.md LICENSE "$out/"
    # Place the engine beside the scripts; tmux-min.sh resolves "$_DIR/tmux-min-transform"
    # first, so this needs no PATH or TMUX_MIN_TRANSFORM wiring on the consumer side.
    install -Dm755 ${engine}/bin/tmux-min-transform "$out/scripts/tmux-min-transform"
    runHook postInstall
  '';
  passthru.engine = engine;
  meta = {
    description = "Minimize and restore tmux panes (any nesting), with peek-on-focus and a border marker";
    homepage = "https://github.com/rootschafer/tmux-pane-minimize";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
