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

  # /etc: passwd/group/shadow, login.defs, NSS, PAM, rserver.conf, R configs
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

    # Allow Unraid-style IDs and set a sane default mail dir & hashing method
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

    # Minimal nsswitch so pam_unix lookups work in a minimal image
    cat > $out/etc/nsswitch.conf <<'EOF'
passwd: files
group:  files
shadow: files
hosts:  files dns
EOF

    # PAM stack for RStudio (absolute Nix paths)
    cat > $out/etc/pam.d/rstudio <<EOF
auth     required       ${pkgs.pam}/lib/security/pam_env.so
auth     required       ${pkgs.pam}/lib/security/pam_unix.so
account  required       ${pkgs.pam}/lib/security/pam_unix.so
session  required       ${pkgs.pam}/lib/security/pam_limits.so
session  required       ${pkgs.pam}/lib/security/pam_unix.so
EOF

    # PAM stack for chpasswd/passwd so plaintext -> shadow via system policy
    cat > $out/etc/pam.d/passwd <<EOF
password required       ${pkgs.pam}/lib/security/pam_unix.so
EOF

    # rserver: listen on all interfaces; use our wrapper (no debug keys)
    cat > $out/etc/rstudio/rserver.conf <<'EOF'
www-address=0.0.0.0
rsession-path=/bin/rsession-wrapper.sh
EOF

    # System-wide R config
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

  # Entrypoint: flexible user + PLAINTEXT chpasswd + dirs + start rserver
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -euo pipefail

    USERNAME="''${USERNAME:-rstudio}"
    UIDV="''${UID:-''${PUID:-1000}}"
    GIDV="''${GID:-''${PGID:-1000}}"
    UMASKV="''${UMASK:-}"
    PORT="''${WWW_PORT:-8787}"

    # Ensure base dirs and silence mailbox warnings
    mkdir -p /etc/R /etc/rstudio /var/lib/rstudio-server /var/run/rstudio-server /var/spool/mail

    # Group (avoid getent)
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
    # create empty mailbox to avoid noisy warning
    touch "/var/spool/mail/''${USERNAME}" || true
    chown "''${UIDV}:''${GIDV}" "/var/spool/mail/''${USERNAME}" || true

    # R env file
    REN="''${HOME_DIR}/.Renviron"
    touch "''${REN}"
    grep -q '^R_LIBS_USER=' "''${REN}" || printf 'R_LIBS_USER=%s\n' "''${HOME_DIR}/R/library" >> "''${REN}"
    chown "''${UIDV}:''${GIDV}" "''${REN}"

    # ----- Password handling via PLAINTEXT -> chpasswd (system hashes) -----
    # NOTE: PASSWORD_HASH is intentionally ignored in this build per request.
    PW=""
    if [ -n "''${PASSWORD_FILE:-}" ] && [ -s "''${PASSWORD_FILE}" ]; then
      PW="$(cat "''${PASSWORD_FILE}")"
    else
      PW="''${PASSWORD:-changeme}"
      if [ -z "''${PASSWORD:-}" ]; then
        echo "WARNING: PASSWORD not provided; defaulting to 'changeme' for user ''${USERNAME}" >&2
      fi
    fi
    # Feed plaintext to chpasswd (uses PAM 'passwd' service and login.defs policy)
    echo "''${USERNAME}:''${PW}" | chpasswd

    # Auto-adjust RStudio's minimum UID to allow low-UID users by default.
    # If AUTH_MINIMUM_USER_ID is set, respect it; else if UID is numeric and <1000, use UID.
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
