# docker-image.nix
{ pkgs ? import <nixpkgs> {} }:

let
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -euo pipefail
    mkdir -p /etc/R /etc/rstudio /var/lib/rstudio-server /var/run/rstudio-server
    exec rserver --server-daemonize=0 --www-port=8787
  '';

  rootfs = pkgs.buildEnv {
    name = "rstudio-rootfs";
    paths = [
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.rstudio-server
      pkgs.R
      entrypoint
    ];
    pathsToLink = [ "/bin" "/lib" "/share" ];
  };
in
pkgs.dockerTools.buildImage {
  name = "rstudio-nix";
  tag  = "latest";

  copyToRoot = rootfs;

  config = {
    Cmd = [ "/bin/entrypoint" ];
    ExposedPorts = { "8787/tcp" = {}; };
    Env = [ "PATH=/bin" ];
    User = "root";
    Labels = {
      "org.opencontainers.image.title" = "rstudio-nix";
      "org.opencontainers.image.description" = "RStudio Server built from nixpkgs";
      "org.opencontainers.image.rstudio.version" = pkgs.rstudio-server.version;
    };
  };
}
