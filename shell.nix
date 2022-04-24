let

  myHaskellPackageOverlay = self: super: {

    myHaskellPackages = super.haskell.packages.ghc922.override {
      overrides = hself: hsuper: rec {
        gamma = super.haskell.lib.dontCheck hsuper.gamma;
        Chart = self.haskell.lib.doJailbreak hsuper.Chart;
        size-based = self.haskell.lib.doJailbreak hsuper.size-based;
      };
    };
  };

  pkgs= builtins.fetchGit {
    # Descriptive name to make the store path easier to identify
    name = "nixos-unstable-2018-09-12";
    url = "https://github.com/nixos/nixpkgs/";
    ref = "refs/heads/master";
    rev = "fe237597d151a33b6aab54f1f5a0af6353c74d04";
  };

in

{ nixpkgs ? import pkgs { config.allowBroken = true; overlays = [ myHaskellPackageOverlay ]; }, compiler ? "default", doBenchmark ? false }:

let

  haskellDeps = ps: with ps; [
    base bytestring cassava Chart Chart-diagrams colour containers
    data-default-class gamma Histogram lazyio lens log-domain
    monad-extras mtl random spoon statistics transformers vector
  ];

in

nixpkgs.stdenv.mkDerivation {
  name = "env";
  buildInputs = [
    nixpkgs.cabal-install
    (nixpkgs.myHaskellPackages.ghcWithPackages haskellDeps)
  ];
}
