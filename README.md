# RStudio Server (nixpkgs)

Containerized RStudio Server built from **nixpkgs**. Ships a sane toolchain and headers so `install.packages()` works. Lets you choose the login user and host UID/GID at runtime—no rebuilds.

## Features
- Works out of the box: binds to `0.0.0.0:8787`
- Flexible user: `USERNAME`, `UID/GID` (or `PUID/PGID`)
- Robust auth: use `PASSWORD_HASH` (preferred) or plaintext `PASSWORD` (internally hashed)
- Package builds: includes compilers + common dev libs; wrapper wires `PKG_CONFIG_PATH`, `LD_LIBRARY_PATH`, etc.
- Stable mounts under `/home/$USERNAME/{projects,data,R/library}`

## Quick start
```bash
docker run -d \
  --name rstudio \
  -p 8787:8787 \
  -e USERNAME=armin \
  -e UID=99 -e GID=100 \
  -e PASSWORD_HASH="$(openssl passwd -6 'changeme')" \
  -v /mnt/user/r-projects/:/home/armin/projects \
  -v /mnt/user/data-archive/:/home/armin/data \
  -v /mnt/user/docker/appdata/rstudio/packages:/home/armin/R/library \
  ghcr.io/aseimel/rstudio-nix:latest
