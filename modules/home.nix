# home-manager module for FTS REAPER.
#
# Usage:
#   imports = [ fts-reaper-flake.homeManagerModules.default ];
#   fts.reaper.enable = true;
#
# That's it. Installs rig wrappers (fts-reaper, fts-keys, etc.),
# icons, and desktop entries. Everything is handled by the module.
{ perSystemPackages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.fts.reaper;
  system = pkgs.stdenv.hostPlatform.system;
  ftsPackages = perSystemPackages.${system};
in
{
  options.fts.reaper = {
    enable = lib.mkEnableOption "FTS REAPER production environment";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      ftsPackages.fts-rigs
      ftsPackages.fts-icons
    ];
  };
}
