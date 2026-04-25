{
  description = "Development shell for radar-a-chepers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
            }
          )
        );
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          lib = pkgs.lib;

          beamPackages = pkgs.beam28Packages;

          espup = pkgs.rustPlatform.buildRustPackage rec {
            pname = "espup";
            version = "0.17.1";

            src = pkgs.fetchFromGitHub {
              owner = "esp-rs";
              repo = "espup";
              rev = "v${version}";
              hash = "sha256-Qpn50VbcIibe0B1N5GU2AOFLt3NWjxEVimCrhhdY6EU=";
            };

            cargoHash = "sha256-Apvy+jPA7xyw43Q2RSVc65TNHQMGcCz/I/qadiJkBss=";

            nativeBuildInputs = with pkgs; [
              installShellFiles
              perl
              pkg-config
            ];

            buildInputs = with pkgs; [
              bzip2
              openssl
              xz
              zstd
            ];

            checkFlags = [
              "--skip=env::tests::test_get_export_file"
              "--skip=toolchain::rust::tests::test_xtensa_rust_parse_version"
            ];

            postInstall = ''
              installShellCompletion --cmd espup \
                --bash <($out/bin/espup completions bash) \
                --fish <($out/bin/espup completions fish) \
                --zsh <($out/bin/espup completions zsh)
            '';
          };

          nativeLibs = with pkgs; [
            libffi
            libuv
            libxml2
            openssl
            stdenv.cc.cc
            udev
            zlib
          ];

          nativeLibPath = lib.makeLibraryPath nativeLibs;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              beamPackages.elixir_1_19
              cacert
              cmake
              curl
              espflash
              espup
              flyctl
              gcc
              git
              gnumake
              inotify-tools
              llvmPackages.clang
              llvmPackages.libclang
              ninja
              openssl
              perl
              pkg-config
              python3
              rustup
              sqlite
            ];

            shellHook = ''
              export RUSTUP_HOME="$PWD/.nix/rustup"
              export CARGO_HOME="$PWD/.nix/cargo"
              export ESPUP_EXPORT_FILE="$PWD/.nix/export-esp.sh"
              export ESPUP_HOME_DIR="$PWD/.nix/home"
              export ESP_TOOLCHAIN_VERSION="1.95.0.0"
              export LIBCLANG_PATH="${lib.getLib pkgs.llvmPackages.libclang}/lib"
              export LD_LIBRARY_PATH="${nativeLibPath}:$LD_LIBRARY_PATH"
              export PATH="$CARGO_HOME/bin:$PATH"

              mkdir -p "$RUSTUP_HOME" "$CARGO_HOME" "$ESPUP_HOME_DIR" "$(dirname "$ESPUP_EXPORT_FILE")"

              if ! rustup toolchain list | grep -q '^stable-'; then
                echo "Installing stable Rust toolchain into $RUSTUP_HOME"
                rustup toolchain install stable --profile minimal
                rustup default stable
              elif ! rustup default | grep -q '^stable-'; then
                rustup default stable
              fi

              if [ ! -d "$RUSTUP_HOME/toolchains/esp" ] || [ ! -f "$ESPUP_EXPORT_FILE" ]; then
                echo "Installing ESP Rust toolchain into $RUSTUP_HOME"
                HOME="$ESPUP_HOME_DIR" espup install \
                  --toolchain-version "$ESP_TOOLCHAIN_VERSION" \
                  --skip-version-parse \
                  --targets esp32s3 \
                  --export-file "$ESPUP_EXPORT_FILE" \
                  --disable-timeouts \
                  --default-host "${pkgs.stdenv.hostPlatform.config}" \
                  --name esp \
                  --stable-version stable || {
                  echo "Failed to install the ESP Rust toolchain" >&2
                  return 1 2>/dev/null || exit 1
                }
              fi

              if [ ! -f "$ESPUP_EXPORT_FILE" ]; then
                echo "Missing ESP environment file: $ESPUP_EXPORT_FILE" >&2
                return 1 2>/dev/null || exit 1
              fi

              . "$ESPUP_EXPORT_FILE"
            '';
          };
        }
      );
    };
}
