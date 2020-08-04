# This file generates the contents of nix/generated/. Use
#
#  ( set -e; cp -fv $(nix-build generate.nix --no-link)/* generated/)
#
# to update

{ pkgs ? import ../nix {} }:

let

  # `haskellSrc2nixWithDoc` is used to generate `default.nix` files for
  # Haskell packages which are intended to be stored in the repository.
  #
  # The function generates a directory containing a `default.nix` which
  # is the result of running `cabal2nix` with the `extraCabal2nixOptions`
  # on the provided `src`.
  #
  # A header is added to `default.nix` which contains instructions on
  # how to regenerate that file.
  #
  # Finally the `src` attribute in the `default.nix` will be defined as
  # `src_subst` such that it can be pointed to local or niv-managed
  # sources.
  haskellSrc2nixWithDoc = {name, src, src_subst, extraCabal2nixOptions ? ""}:
    let
      drv = pkgs.haskellPackages.haskellSrc2nix {
        inherit name extraCabal2nixOptions src;
      };
    in drv.overrideAttrs (oldAttrs: {
      message = ''
        # THIS IS AN AUTOMATICALLY GENERATED FILE. DO NOT EDIT MANUALLY!\
        # See ./nix/generate.nix for instructions.\

      '';
      inherit src_subst;
      installPhase = oldAttrs.installPhase + ''
        sed -i "1i$message;s|src = .*|src = $src_subst;|" $out/default.nix
        # Accept `pkgs` as an argument in case the `src_subst` depends on it.
        sed -i "s|{ mkDerivation|{ mkDerivation, pkgs|" $out/default.nix
      '';
    });

  # A variant of `haskellSrc2nixWithDoc` for local Haskell packages.
  localHaskellSrc2nixWithDoc = name: path: extraCabal2nixOptions:
    haskellSrc2nixWithDoc {
      inherit name extraCabal2nixOptions;
      src = import ./gitSource.nix path;
      src_subst = "import ../gitSource.nix \"${path}\"";
    };

  winter = haskellSrc2nixWithDoc {
    name = "winter";
    src = pkgs.sources.winter;
    src_subst = "pkgs.sources.winter";
    extraCabal2nixOptions = "--no-check";
  };
  leb128-cereal = haskellSrc2nixWithDoc {
    name = "leb128-cereal";
    src = pkgs.sources.leb128-cereal;
    src_subst = "pkgs.sources.leb128-cereal";
  };
  candid = haskellSrc2nixWithDoc {
    name = "candid";
    src = pkgs.sources.haskell-candid;
    src_subst = "pkgs.sources.haskell-candid";
  };

  ic-ref = localHaskellSrc2nixWithDoc "ic-ref" "impl" "--no-check -frelease";
  base32 = pkgs.haskellPackages.hackage2nix "base32" "0.1.1.2";
  megaparsec = pkgs.haskellPackages.hackage2nix "megaparsec" "8.0.0";

  allGenerated = pkgs.runCommandNoCC "generated" {} ''
    mkdir -p $out
    cp ${winter}/default.nix $out/winter.nix
    cp ${ic-ref}/default.nix $out/ic-ref.nix
    cp ${leb128-cereal}/default.nix $out/leb128-cereal.nix
    cp ${candid}/default.nix $out/candid.nix
    cp ${base32}/default.nix $out/base32.nix
    cp ${megaparsec}/default.nix $out/megaparsec.nix
  '';
in
allGenerated




