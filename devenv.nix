{
  pkgs,
  config,
  ...
}: let
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
    nativeBuildInputs = [pkgs.autoPatchelfHook];
    installPhase = ''
      runHook preInstall
      install -Dm755 topf $out/bin/topf
      runHook postInstall
    '';
  };

  # helm with the helm-diff plugin: `helmfile apply` diffs before upgrading, so
  # re-running `just bootstrap::helmfile` on an unchanged release is a no-op.
  helm = pkgs.wrapHelm pkgs.kubernetes-helm {
    plugins = [pkgs.kubernetes-helmPlugins.helm-diff];
  };
  helmfile = pkgs.helmfile.override {inherit (helm.passthru) pluginsDir;};
in {
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
    helm
    helmfile
    cilium-cli
    fluxcd
    k9s
    renovate # renovate-config-validator, and `renovate --platform=local --dry-run=lookup`
  ];

  # Node for the Docusaurus site in docs/ (package.json engines: >=26).
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_26;
    npm.enable = true;
  };

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
    helm version --short
    helm diff version
    helmfile --version
    cilium version --client
    flux version --client
    node --version
  '';
}
