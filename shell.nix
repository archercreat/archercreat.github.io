with import <nixpkgs>{};
let
  # The build environment
  env = pkgs.bundlerEnv rec {
    inherit ruby;
    name     = "jekyll-env";
    gemfile  = ./Gemfile;
    lockfile = ./Gemfile.lock;
    gemset   = ./gemset.nix;
  };
in 
  stdenv.mkDerivation rec {
    name = "blog";
    buildInputs = [ 
      bundler 
      ruby
      env 
    ];

    shellHook = ''
      exec ${env}/bin/jekyll serve --host 0.0.0.0 --watch
    '';
  }
