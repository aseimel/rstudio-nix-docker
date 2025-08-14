# docker-image.nix
{ pkgs ? import <nixpkgs> {} }:

let
  lib = pkgs.lib;

  # Toolchain for R package builds (gfortran wrapper provides gcc & g++)
  toolchain = [
    pkgs.gfortran
    pkgs.gnumake
    pkgs.pkg-config
  ];

  # Dev libs commonly needed by CRAN packages
  devLibs = [
    pkgs.curl
    pkgs.openssl
    pkgs.libxml2
    pkgs.zlib
    pkgs.fontconfig
    pkgs.freetype
    pkgs.harfbuzz
    pkgs.fribidi
    pkgs.cairo
    pkgs.pango
    pkgs.sqlite
    pkgs.libjpeg
    pkgs.libtiff
    pkgs.libpng
    pkgs.gdk-pixbuf
  ];

  pcLib   = lib.makeSearchPath "lib/pkgconfig" devLibs;
  pcShare = lib.makeSearchPath "share/pkgconfig" devLibs;
  ldLib   = lib.makeLibraryPath devLibs;

  # /etc: passwd/group/shadow, login.defs, PAM, rserver.conf, R configs
  etcLayer = pkgs.runCommand "rstudio-etc" {} ''
    set -eu
    mkdir -p $out/etc/pam.d $out/etc/rstudio $out/etc/R

    cat > $out/etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

    cat > $out/etc/group <<'EOF'
root:x:0:
users:x:100:
nogroup:x:65534:
EOF

    cat > $out/etc/shadow <<'EOF'
root:*:10933:0:99999:7:::
EOF

    # Allow all IDs
    cat > $out/etc/login.defs <<'EOF'
MAIL_DIR        /var/spool/mail
PASS_MAX_DAYS   99999
PASS_MIN_DAYS   0
PASS_WARN_AGE   7
UID_MIN         99
UID_MAX         60000
GID_MIN         100
GID_MAX         60000
UMASK           022
ENCRYPT_METHOD  SHA512
EOF

    cat > $out/etc/pam.d/rstudio <<EOF
auth     required       ${pkgs.pam}/lib/security/pam_unix.so
account  required       ${pkgs.pam}/lib/security/pam_unix.so
session  required       ${pkgs.pam}/lib/security/pam_unix.so
EOF

    # rserver: listen on all interfaces; use our wrapper
    cat > $out/etc/rstudio/rserver.conf <<'EOF'
www-address=0.0.0.0
rsession-path=/bin/rsession-wrapper.sh
EOF

    cat > $out/etc/R/Rprofile.site <<'EOF'
local({
  rlib <- file.path(Sys.getenv("HOME"), "R", "library")
  if (dir.exists(rlib)) .libPaths(c(rlib, .libPaths()))
  options(
    repos = c(CRAN = "https://cloud.r-project.org"),
    download.file.method = "libcurl"
  )
})
EOF

    # Generic compilers; PATH (from wrapper) selects the right binaries
    cat > $out/etc/R/Makevars.site <<EOF
CC=cc
CXX=c++
CXX11=c++
FC=gfortran
F77=gfortran
PKG_CONFIG=${pkgs.pkg-config}/bin/pkg-config
EOF
  '';

  # rsession wrapper (escape Bash vars so Nix doesn't interpolate)
  rsessionWrapper = pkgs.writeShellScriptBin "rsession-wrapper.sh" ''
    #!/bin/bash
    set -euo pipefail

    export R_LIBS_USER="''${R_LIBS_USER:-$HOME/R/library}"
    export R_MAKEVARS_SITE="/etc/R/Makevars.site"

    export PATH="${lib.makeBinPath toolchain}:$PATH"
    export PKG_CONFIG_PATH="${pcLib}:${pcShare}"
    export LD_LIBRARY_PATH="${ldLib}:''${LD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="${ldLib}:''${LIBRARY_PATH:-}"

    exec ${pkgs.rstudio-server}/bin/rsession "$@"
  '';

  # Entrypoint: flexible user + password handling + dirs + start rserver
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -euo pipefail

    USERNAME="''${USERNAME:-rstudio}"
    UIDV="''${UID:-''${PUID:-1000}}"
    GIDV="''${GID:-''${PGID:-1000}}"
    UMASKV="''${UMASK:-}"
    PORT="''${WWW_PORT:-8787}"

    mkdir -p /etc/R /etc/rstudio /var/lib/rstudio-server /var/run/rstudio-server

    # Group
    if ! grep -qE "^([^:]*:){2}''${GIDV}:" /etc/group; then
      groupadd -g "''${GIDV}" "''${USERNAME}"
    fi

    # User (avoid -m; home may be bind-mounted)
    if id -u "''${USERNAME}" >/dev/null 2>&1; then
      CUR_UID="$(id -u "''${USERNAME}")"
      CUR_GID="$(id -g "''${USERNAME}")"
      if [ "''${CUR_GID}" != "''${GIDV}" ]; then usermod -g "''${GIDV}" "''${USERNAME}"; fi
      if [ "''${CUR_UID}" != "''${UIDV}" ]; then usermod -o -u "''${UIDV}" "''${USERNAME}"; fi
      usermod -d "/home/''${USERNAME}" "''${USERNAME}" || true
    else
      useradd -M -d "/home/''${USERNAME}" -u "''${UIDV}" -g "''${GIDV}" -s /bin/bash "''${USERNAME}"
    fi

    HOME_DIR="/home/''${USERNAME}"
    mkdir -p "''${HOME_DIR}" "''${HOME_DIR}/projects" "''${HOME_DIR}/data" "''${HOME_DIR}/R/library"
    chown -R "''${UIDV}:''${GIDV}" "''${HOME_DIR}"

    REN="''${HOME_DIR}/.Renviron"
    touch "''${REN}"
    grep -q '^R_LIBS_USER=' "''${REN}" || printf 'R_LIBS_USER=%s\n' "''${HOME_DIR}/R/library" >> "''${REN}"
    chown "''${UIDV}:''${GIDV}" "''${REN}"

    # Passwords
    set_password_hash()  { echo "''${USERNAME}:''${1}" | chpasswd -e; }
    set_password_plain() { echo "''${USERNAME}:''${1}" | chpasswd; }

    if [ -n "''${PASSWORD_HASH:-}" ]; then
      set_password_hash "''${PASSWORD_HASH}"
    elif [ -n "''${PASSWORD_FILE:-}" ] && [ -s "''${PASSWORD_FILE}" ]; then
      PW="$(cat "''${PASSWORD_FILE}")"
      case "''${PW}" in
        \$*) set_password_hash "''${PW}" ;;
        *)   set_password_plain "''${PW}" ;;
      esac
    else
      PW="''${PASSWORD:-changeme}"
      if [ -z "''${PASSWORD:-}" ]; then
        echo "WARNING: PASSWORD not provided; defaulting to 'changeme' for user ''${USERNAME}" >&2
      fi
      if command -v openssl >/dev/null 2>&1; then
        HASH="$(openssl passwd -6 "''${PW}")"
        set_password_hash "''${HASH}"
      else
        set_password_plain "''${PW}"
      fi
    fi

    # Auto-adjust RStudio's minimum UID to allow low-UID users by default.
    # If AUTH_MINIMUM_USER_ID is set, respect it; otherwise, if UID is numeric and <1000, use UID.
    FLOOR=""
    if [ -n "''${AUTH_MINIMUM_USER_ID:-}" ]; then
      FLOOR="''${AUTH_MINIMUM_USER_ID}"
    else
      if printf '%s' "''${UIDV}" | grep -Eq '^[0-9]+$'; then
        if [ "''${UIDV}" -lt 1000 ]; then FLOOR="''${UIDV}"; fi
      fi
    fi
    if [ -n "''${FLOOR}" ]; then
      if grep -q '^auth-minimum-user-id=' /etc/rstudio/rserver.conf 2>/dev/null; then
        sed -i "s/^auth-minimum-user-id=.*/auth-minimum-user-id=''${FLOOR}/" /etc/rstudio/rserver.conf
      else
        echo "auth-minimum-user-id=''${FLOOR}" >> /etc/rstudio/rserver.conf
      fi
    fi

    # Optional ownership of mounts
    bool_true() { [ "''${1:-false}" = "true" ] || [ "''${1:-0}" = "1" ]; }
    if bool_true "''${CHOWN_PROJECTS:-false}"; then chown -R "''${UIDV}:''${GIDV}" "''${HOME_DIR}/projects" || true; fi
    if bool_true "''${CHOWN_DATA:-false}";     then chown -R "''${UIDV}:''${GIDV}" "''${HOME_DIR}/data" || true; fi
    if bool_true "''${CHOWN_RLIBS:-false}";    then chown -R "''${UIDV}:''${GIDV}" "''${HOME_DIR}/R/library" || true; fi

    if [ -n "''${UMASKV}" ]; then umask "''${UMASKV}" || true; fi

    exec rserver --server-daemonize=0 --www-port="''${PORT}"
  '';

  # Root filesystem
  rootfs = pkgs.buildEnv {
    name = "rstudio-rootfs";
    paths = [
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.shadow
      pkgs.pam
      pkgs.openssl
      pkgs.R
      pkgs.rstudio-server
      rsessionWrapper
      entrypoint
    ] ++ toolchain ++ devLibs;
    pathsToLink = [ "/bin" "/sbin" "/lib" "/share" ];
  };
in
pkgs.dockerTools.buildImage {
  name = "rstudio-nix";
  tag  = "latest";

  copyToRoot = [ rootfs etcLayer ];

  config = {
    Cmd = [ "/bin/entrypoint" ];
    ExposedPorts = { "8787/tcp" = {}; };
    Env = [ "PATH=/bin:/sbin" ];
    WorkingDir = "/";
    Labels = {
      "org.opencontainers.image.title" = "rstudio-nix";
      "org.opencontainers.image.description" = "RStudio Server (nixpkgs) with VM-parity env and flexible runtime user";
      "org.opencontainers.image.rstudio.version" = pkgs.rstudio-server.version;
    };
  };
}
