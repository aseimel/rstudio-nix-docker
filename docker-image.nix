# docker-image.nix
{ pkgs ? import <nixpkgs> {} }:

let
  # Minimal /etc with root user + PAM config for RStudio
  etcLayer = pkgs.runCommand "rstudio-etc" {} ''
    set -eu
    mkdir -p $out/etc/pam.d $out/etc/rstudio

    cat > $out/etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

    cat > $out/etc/group <<'EOF'
root:x:0:
users:x:100:
nogroup:x:65534:
EOF

    # Lock root password by default (login via PAM user we'll create at runtime)
    cat > $out/etc/shadow <<'EOF'
root:*:10933:0:99999:7:::
EOF

    # PAM service used by RStudio Server (auth-pam-service=rstudio by default)
    cat > $out/etc/pam.d/rstudio <<EOF
auth     required       ${pkgs.pam}/lib/security/pam_unix.so
account  required       ${pkgs.pam}/lib/security/pam_unix.so
session  required       ${pkgs.pam}/lib/security/pam_unix.so
EOF

    # Minimal rserver config (leave most defaults; we set port/daemonize in entrypoint)
    cat > $out/etc/rstudio/rserver.conf <<'EOF'
auth-pam-service=rstudio
EOF
  '';

  # Robust entrypoint: creates user from env (USERNAME/UID/GID or PUID/PGID),
  # sets password (hash/file/plain), prepares dirs, and starts rserver.
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -euo pipefail

    # ---- env with defaults ----
    USERNAME="${USERNAME:-rstudio}"
    UIDV="${UID:-${PUID:-1000}}"
    GIDV="${GID:-${PGID:-1000}}"
    UMASKV="${UMASK:-}"
    PORT="${WWW_PORT:-8787}"

    # optional TZ passthrough (best-effort; tzdata not strictly required)
    if [ -n "${TZ:-}" ]; then
      mkdir -p /etc
      echo "$TZ" > /etc/timezone || true
    fi

    # Ensure base dirs
    mkdir -p /etc/R /etc/rstudio /var/lib/rstudio-server /var/run/rstudio-server

    # ---- group ----
    if ! grep -qE "^([^:]*:){2}${GIDV}:" /etc/group; then
      groupadd -g "$GIDV" "$USERNAME"
      GROUPNAME="$USERNAME"
    else
      GROUPNAME="$(grep -E "^([^:]*:){2}${GIDV}:" /etc/group | head -n1 | cut -d: -f1)"
    fi

    # ---- user ----
    if id -u "$USERNAME" >/dev/null 2>&1; then
      CUR_UID="$(id -u "$USERNAME")"
      CUR_GID="$(id -g "$USERNAME")"
      if [ "$CUR_GID" != "$GIDV" ]; then usermod -g "$GIDV" "$USERNAME"; fi
      if [ "$CUR_UID" != "$UIDV" ]; then usermod -o -u "$UIDV" "$USERNAME"; fi
    else
      useradd -m -u "$UIDV" -g "$GIDV" -s /bin/bash "$USERNAME"
    fi

    # ---- password ----
    set_password_plain() { echo "${USERNAME}:${1}" | chpasswd; }
    set_password_hash()  { echo "${USERNAME}:${1}" | chpasswd -e; }

    PASS_SET=0
    if [ -n "${PASSWORD_HASH:-}" ]; then
      set_password_hash "$PASSWORD_HASH"; PASS_SET=1
    fi

    if [ "$PASS_SET" -eq 0 ] && [ -n "${PASSWORD_FILE:-}" ] && [ -s "$PASSWORD_FILE" ]; then
      PW="$(cat "$PASSWORD_FILE")"
      case "$PW" in
        \$*) set_password_hash "$PW" ;;  # looks like a crypt hash
        *)   set_password_plain "$PW" ;;
      esac
      PASS_SET=1
    fi

    if [ "$PASS_SET" -eq 0 ]; then
      PW="${PASSWORD:-changeme}"
      if [ -z "${PASSWORD:-}" ]; then
        echo "WARNING: PASSWORD not provided; defaulting to 'changeme' for user $USERNAME" >&2
      fi
      set_password_plain "$PW"
    fi

    # ---- home + R libs ----
    HOME_DIR="/home/$USERNAME"
    mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/R/library"
    chown -R "$UIDV:$GIDV" "$HOME_DIR"

    REN="$HOME_DIR/.Renviron"
    touch "$REN"
    grep -q '^R_LIBS_USER=' "$REN" || printf 'R_LIBS_USER=%s\n' "$HOME_DIR/R/library" >> "$REN"
    chown "$UIDV:$GIDV" "$REN"

    # optional chown of mounted trees (off by default to avoid slow startups)
    bool_true() { [ "${1:-false}" = "true" ] || [ "${1:-0}" = "1" ]; }
    if bool_true "${CHOWN_PROJECTS:-false}"; then chown -R "$UIDV:$GIDV" "$HOME_DIR/projects" || true; fi
    if bool_true "${CHOWN_DATA:-false}";     then chown -R "$UIDV:$GIDV" "$HOME_DIR/data" || true; fi
    if bool_true "${CHOWN_RLIBS:-false}";    then chown -R "$UIDV:$GIDV" "$HOME_DIR/R/library" || true; fi

    # umask if set
    if [ -n "$UMASKV" ]; then umask "$UMASKV" || true; fi

    # ---- run RStudio Server ----
    exec rserver --server-daemonize=0 --www-port="$PORT"
  '';

  # Root filesystem: add tools needed by the entrypoint + RStudio + PAM
  rootfs = pkgs.buildEnv {
    name = "rstudio-rootfs";
    paths = [
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.shadow          # useradd, groupadd, chpasswd, usermod
      pkgs.pam             # linux-pam for pam_unix.so referenced in /etc/pam.d/rstudio
      pkgs.R
      pkgs.rstudio-server
      entrypoint
    ];
    pathsToLink = [ "/bin" "/sbin" "/lib" "/share" ];
  };
in
pkgs.dockerTools.buildImage {
  name = "rstudio-nix";
  tag  = "latest";

  # VM-free image build; avoid deprecated 'contents'
  copyToRoot = [
    rootfs
    etcLayer
  ];

  config = {
    # No explicit User: let Docker start as uid 0 (fixes "no root in passwd" issues)
    Cmd = [ "/bin/entrypoint" ];
    ExposedPorts = { "8787/tcp" = {}; };
    Env = [ "PATH=/bin:/sbin" ];
    WorkingDir = "/"
    ;
    Labels = {
      "org.opencontainers.image.title" = "rstudio-nix";
      "org.opencontainers.image.description" = "RStudio Server from nixpkgs with flexible runtime user setup";
      "org.opencontainers.image.rstudio.version" = pkgs.rstudio-server.version;
    };
  };
}
