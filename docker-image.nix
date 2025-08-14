{ pkgs ? import <nixpkgs> {}
, username ? "armin"
, uid ? "1000" 
, gid ? "1000"
}:

let
  # Your library paths from your original config
  pkgConfigPath = pkgs.lib.concatStringsSep ":" [
    "${pkgs.curl.dev}/lib/pkgconfig"
    "${pkgs.openssl.dev}/lib/pkgconfig"
    "${pkgs.libxml2.dev}/lib/pkgconfig"
    "${pkgs.zlib.dev}/lib/pkgconfig"
    "${pkgs.fontconfig.dev}/lib/pkgconfig"
    "${pkgs.freetype.dev}/lib/pkgconfig"
    "${pkgs.harfbuzz.dev}/lib/pkgconfig"
    "${pkgs.fribidi.dev}/lib/pkgconfig"
    "${pkgs.sqlite.dev}/lib/pkgconfig"
    "${pkgs.cairo.dev}/lib/pkgconfig"
    "${pkgs.pango.dev}/lib/pkgconfig"
    "${pkgs.libjpeg.dev}/lib/pkgconfig"
    "${pkgs.libtiff.dev}/lib/pkgconfig"
    "${pkgs.libpng.dev}/lib/pkgconfig"
  ];

  # Create the wrapper script
  rsessionWrapper = pkgs.writeScriptBin "rsession-wrapper" ''
    #!${pkgs.bashInteractive}/bin/bash
    export PKG_CONFIG_PATH="${pkgConfigPath}"
    export R_LIBS_USER="/home/${username}/R/library"
    export R_MAKEVARS_SITE="/etc/R/Makevars.site"
    exec ${pkgs.rstudio-server}/bin/rsession "$@"
  '';

  # Your Makevars.site content
  makevars = pkgs.writeText "Makevars.site" ''
    CC=${pkgs.gcc}/bin/gcc
    CXX=${pkgs.gcc}/bin/g++
    FC=${pkgs.gfortran}/bin/gfortran
    MAKE=${pkgs.gnumake}/bin/make
    PKG_CONFIG_PATH=${pkgConfigPath}
    CPPFLAGS = -I${pkgs.R}/lib/R/include
    CFLAGS = -fPIC -g -O2
    CXXFLAGS = -fPIC -g -O2
    FCFLAGS = -fPIC -g -O2
    LDFLAGS = ${pkgs.lib.concatStringsSep " " (map (p: "-L${p}/lib") [
      pkgs.curl pkgs.openssl pkgs.libxml2 pkgs.zlib
      pkgs.fontconfig pkgs.freetype pkgs.harfbuzz pkgs.fribidi
      pkgs.sqlite pkgs.cairo pkgs.pango pkgs.libjpeg
      pkgs.libtiff pkgs.libpng
    ])}
  '';

  # Your Rprofile.site
  rprofile = pkgs.writeText "Rprofile.site" ''
    local({
      r <- getOption("repos")
      r["CRAN"] <- "https://cloud.r-project.org"
      options(repos = r)
    })
    .libPaths(c("/home/${username}/R/library", .libPaths()))
    if (Sys.getenv("PKG_CONFIG_PATH") == "") {
      Sys.setenv(PKG_CONFIG_PATH = "${pkgConfigPath}")
    }
  '';

  # Entrypoint script that starts RStudio
  entrypoint = pkgs.writeScriptBin "entrypoint" ''
    #!${pkgs.bashInteractive}/bin/bash
    
    # Ensure directories exist with correct permissions
    mkdir -p /home/${username}/R/library
    chown -R ${uid}:${gid} /home/${username}
    
    # Start RStudio Server
    exec ${pkgs.rstudio-server}/bin/rserver \
      --server-daemonize=0 \
      --www-address=0.0.0.0 \
      --www-port=8787 \
      --rsession-path=${rsessionWrapper}/bin/rsession-wrapper
  '';

in pkgs.dockerTools.buildImage {
  name = "rstudio-nix";
  tag = "latest";
  
  contents = with pkgs; [
    # Core system
    bashInteractive coreutils gnugrep gnused gawk findutils
    
    # R and RStudio
    R rstudio-server
    rPackages.tidyverse
    rPackages.rmarkdown
    rPackages.knitr
    rPackages.cpp11
    
    # Build tools
    gcc gfortran gnumake pkg-config binutils
    autoconf automake libtool
    
    # Development libraries
    curl.dev openssl.dev libxml2.dev zlib.dev
    fontconfig.dev freetype.dev harfbuzz.dev fribidi.dev
    sqlite.dev cairo.dev pango.dev
    libjpeg.dev libtiff.dev libpng.dev
    
    # Additional tools
    cmdstan git vim tmux wget
    
    # Our scripts
    rsessionWrapper
    entrypoint
  ];
  
  runAsRoot = ''
    #!${pkgs.stdenv.shell}
    # Create user and group
    groupadd -g ${gid} ${username}
    useradd -u ${uid} -g ${gid} -m -d /home/${username} -s ${pkgs.bashInteractive}/bin/bash ${username}
    
    # Create directories
    mkdir -p /home/${username}/R/library
    mkdir -p /home/${username}/data
    mkdir -p /home/${username}/projects
    mkdir -p /backup
    mkdir -p /etc/R
    mkdir -p /etc/rstudio
    mkdir -p /var/lib/rstudio-server
    mkdir -p /var/run/rstudio-server
    
    # Copy configuration files
    cp ${makevars} /etc/R/Makevars.site
    cp ${rprofile} /etc/R/Rprofile.site
    
    # Set permissions
    chown -R ${username}:${username} /home/${username}
    chmod 755 /home/${username}/R/library
  '';
  
  config = {
    Cmd = [ "${entrypoint}/bin/entrypoint" ];
    ExposedPorts = {
      "8787/tcp" = {};
    };
    Env = [
      "R_LIBS_USER=/home/${username}/R/library"
      "R_MAKEVARS_SITE=/etc/R/Makevars.site"
      "PKG_CONFIG_PATH=${pkgConfigPath}"
    ];
    User = "root";  # Needs to be root to start RStudio Server
  };
}