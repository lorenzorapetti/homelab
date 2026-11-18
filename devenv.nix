{ pkgs, config, ... }:

let
  # topf isn't in nixpkgs: install the pinned upstream release binary.
  # To bump: change `version`, then refresh `hash` with
  #   nix store prefetch-file https://github.com/postfinance/topf/releases/download/v<version>/topf_linux_amd64.tar.gz
  topf = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "topf";
    version = "0.6.2";
    src = pkgs.fetchurl {
      url = "https://github.com/postfinance/topf/releases/download/v${version}/topf_linux_amd64.tar.gz";
      hash = "sha256-eT3IfJemVF/XPbgsNVgwZkTZ5pFAEPJjbRRwz1UnJAU=";
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    installPhase = ''
      runHook preInstall
      install -Dm755 topf $out/bin/topf
      runHook postInstall
    '';
  };
in
{
  packages = with pkgs; [
    terraform
    sops
    gnupg
    age
    just
    talosctl
    topf
    kubectl
    yq-go
  ];

  # Client configs written by `just talos::create` (both gitignored).
  env.TALOSCONFIG = "${config.devenv.root}/talos/talosconfig";
  env.KUBECONFIG = "${config.devenv.root}/kubeconfig";

  enterTest = ''
    terraform version
    sops --version
    gpg --version | head -1
    age --version
    just --version
    talosctl version --client --short
    topf --version
    kubectl version --client
    yq --version
  '';
}
