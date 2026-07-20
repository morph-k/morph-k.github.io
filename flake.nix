{
  description = "Jekyll toolchain for morph-k.github.io";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    forAllSystems =
      nixpkgs.lib.genAttrs ["aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux"];
  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # `nix develop` then:
      #   bundle install       # once, installs into vendor/bundle
      #   bundle exec jekyll serve
      #
      # Deliberately bundler-based rather than nixpkgs' `jekyll`: this site
      # uses the github-pages gem set, which pins its own Jekyll and plugins.
      # The theme is riggraz/no-style-please, pulled at build time via
      # `remote_theme` — that needs jekyll-remote-theme at the version
      # github-pages pins, which nixpkgs' jekyll does not ship. Using it would
      # not be testing what GitHub Pages actually builds.
      default = pkgs.mkShell {
        packages = with pkgs; [
          # Must be 3.1, not newer. The github-pages gem set pins
          # liquid 4.0.3, which calls Object#untaint — deprecated as a no-op
          # in Ruby 2.7 and *removed* in 3.2. On 3.2 every build dies with
          # "undefined method `untaint' for String". 3.1 still has it.
          ruby_3_1
          bundler
          # Native extensions in the github-pages set need these to compile:
          # eventmachine and http_parser.rb want a C++ toolchain and OpenSSL,
          # nokogiri wants libxml2/libxslt, ffi wants libffi.
          gcc
          gnumake
          pkg-config
          openssl
          libyaml
          zlib
          libffi
          libxml2
          libxslt
        ];

        # Keep gems in the repo rather than in the user profile, so the
        # toolchain stays self-contained and disposable.
        shellHook = ''
          export BUNDLE_PATH="$PWD/vendor/bundle"
          export BUNDLE_BUILD__NOKOGIRI="--use-system-libraries"
          export GEM_HOME="$BUNDLE_PATH"
          export PATH="$BUNDLE_PATH/bin:$PATH"
        '';
      };
    });
  };
}
