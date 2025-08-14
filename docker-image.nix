# docker-image.nix
{ pkgs ? import <nixpkgs> {} }:

let
  # Minimal, VM-free image build:
  # - Avoids dockerTools runAsRoot (which spins up a 1GiB qcow VM that ran out of space)
  # - Uses copyToRoot + buildEnv to populate /bin and friends

  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -euo pipefail

    # Ensure required dirs exist at runtime
    mkdir -p /etc/R /etc/rstudio /var/lib/rstudio-server /var/run/rstudio-server

    # Start RStudio Server in the foreground (suitable for Docker)
    # Port is fixed to 8787 for now; dynamic users will come later
    exec rserver \
      --server-daemonize=0 \
      --www-port=8787
  '';

  # Put key packages into /bin so we can call `rserver` without Nix store paths
  rootfs = pkgs.buildEnv {
    name = "rstudio-rootfs";
    paths = [
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.rstudio-server
      pkgs.R
      entrypoint
    ];
    # Link typical runtime locations; keeps the image simple and avoids VM build
    pathsToLink = [ "/bin" "/lib" "/share" ];
  };
in
pkgs.dockerTools.buildImage {
  name = "rstudio-nix";
  tag  = "latest";

  # New-style input; avoids deprecated `contents` and avoids runAsRoot/VM
  copyToRoot = rootfs;

  # Keep the container simple; we only expose 8787 and run our entrypoint
  config = {
    Cmd = [ "/bin/entrypoint" ];
    ExposedPorts = {
      "8787/tcp" = {};
    };
    Env = [
      "PATH=/bin"
    ];
    # RStudio Server starts as root in containers (login handled separately)
    User = "root";
  };
}
