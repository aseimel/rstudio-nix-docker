# RStudio Server Nix Docker

Automated Docker builds of RStudio Server with comprehensive R development environment, built with Nix for reproducibility.

## Quick Start

```bash
docker pull ghcr.io/aseimel/rstudio-nix:latest

docker run -d \
  --name rstudio \
  -p 8787:8787 \
  -v $(pwd)/R-library:/home/armin/R/library \
  -v $(pwd)/data:/home/armin/data \
  -v $(pwd)/projects:/home/armin/projects \
  ghcr.io/aseimel/rstudio-nix:latest
