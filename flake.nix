{
  description = "tracing-nix-build";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        preBuildHook = pkgs.writeShellScript "pre-build-hook" ''
          drv=$1
          name=''${drv#/nix/store/}
          ${pkgs.coreutils}/bin/date +%s.%N > "@TMPDIR@/$name"
        '';
        postBuildHook = pkgs.writeShellScript "post-build-hook" ''
          drv=$DRV_PATH
          name=''${drv#/nix/store/}
          export TRACEPARENT=@TRACEPARENT@
          ${pkgs.otel-cli}/bin/otel-cli span \
          --start $(${pkgs.coreutils}/bin/cat @TMPDIR@/$name) \
          --end $(${pkgs.coreutils}/bin/date +%s.%N) \
          --config @CONFIG_FILE@ \
          -n $name \
          -s nix-build \
          --fail
        '';
        main = pkgs.writeShellApplication {
          name = "main";
          runtimeInputs = [ pkgs.otel-cli pkgs.jq ];
          text = ''
            bash << EOF
            source "${pkgs.stdenv}/setup"
            substitute ${postBuildHook} "$TMPDIR/post-build-hook" \
                --subst-var TMPDIR \
                --subst-var TRACEPARENT \
                --subst-var CONFIG_FILE
            chmod +x $TMPDIR/post-build-hook
            EOF
            export ENVOY_LDS_FILE_TMP="$TMPDIR/tmp.json"
            jq --arg traceparent "$TRACEPARENT" \
              '.resources[0].filter_chains[0].filters[0].typed_config.route_config.request_headers_to_add[0]={"header": {"key": "traceparent","value": $traceparent}}' \
              ${./lds.json} > "$ENVOY_LDS_FILE_TMP"
            rm "$ENVOY_LDS_FILE"
            mv "$ENVOY_LDS_FILE_TMP" "$ENVOY_LDS_FILE"
            otel-cli exec --config "$CONFIG_FILE" -n sleep -s sleep "sleep 1"
            nix build "$1" \
              --option substituters "http://localhost:8081?priority=20" \
              --option pre-build-hook "$TMPDIR/pre-build-hook" \
              --option post-build-hook "$TMPDIR/post-build-hook" \
              --no-link \
              -L
          '';
        };
      in
      rec {
        inherit pkgs;
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.otel-cli
            pkgs.nixpkgs-fmt
            self.packages.${system}.tracing-nix-build
          ];
        };
        packages = {
          tracing-nix-build = pkgs.writeShellApplication {
            name = "tracing-nix-build";
            runtimeInputs = [ pkgs.otel-cli main ];
            text = ''
              export TMPDIR=''${TMPDIR:-$(mktemp -d)}
              echo "TMPDIR:$TMPDIR"
              export CONFIG_FILE="$OTEL_CLI_CONFIG_FILE"
              export noDumpEnvVars=1
              bash << EOF
              source "${pkgs.stdenv}/setup"
              substitute ${preBuildHook} "$TMPDIR/pre-build-hook" --subst-var TMPDIR
              chmod +x $TMPDIR/pre-build-hook

              EOF
              otel-cli exec \
                -n tracing-nix-build \
                -s tracing-nix-build \
                --config "$CONFIG_FILE" \
                "main $1"
            '';
          };
        };
      }
    );
}
