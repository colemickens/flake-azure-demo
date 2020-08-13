#!/usr/bin/env bash
set -x
set -e

remote="azureuser@13.66.201.252"

git add -A .

if [[ "${1}" == "update" ]]; then
  nix --experimental-features 'nix-command flakes' \
    build \
    --override-input nixpkgs /home/cole/code/nixpkgs/cmpkgs \
    --override-input azure /home/cole/code/nixos-azure \
    --override-input sops-nix /home/cole/code/sops-nix \
    ".#demo.toplevel"

  out="$(readlink ./result)"

  echo "${out}" | cachix push colemickens

  ssh "${remote}" "sudo nix-store \
    --option 'narinfo-cache-negative-ttl' '0' \
    --option 'extra-binary-caches' 'https://cache.nixos.org https://colemickens.cachix.org https://nixpkgs-wayland.cachix.org' \
    --option 'trusted-public-keys' 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= colemickens.cachix.org-1:bNrJ6FfMREB4bd4BOjEN85Niu8VcPdQe4F4KxVsb/I4= nixpkgs-wayland.cachix.org-1:3lwxaILxMRkVhehr5StQprHdEo4IrE8sRho9R9HOLYA=' \
    -r '${out}'"

  ssh "${remote}" "\
    sudo bash -c \"\
      nix-env --set --profile /nix/var/nix/profiles/system ${out} \
      && ${out}/bin/switch-to-configuration switch\""
else
  nix --experimental-features 'nix-command flakes' \
    build \
    --option 'substituters' 'https://cache.nixos.org' \
    --override-input nixpkgs /home/cole/code/nixpkgs/cmpkgs \
    --override-input azure /home/cole/code/nixos-azure \
    --override-input sops-nix /home/cole/code/sops-nix \
    ".#demo.azureScripts"
fi

