#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/../.."
set -euo pipefail
set -x

workdir="$(mktemp -d --dry-run)"
cp -a "${DIR}" "${workdir}"

name="job${JOBID:-"$(date '+%s')"}"
workdir="$(mktemp -d)"

function az() { time command az "${@}"; }
function cleanup() {
  az group delete --yes --no-wait --name "${name}" || true
  rm -rf "${workdir}"
}

trap cleanup EXIT

function runtest() {
  ssh-keygen -t rsa -N "" -f "${workdir}/id_rsa"
  ssh-keygen -y -f "${workdir}/id_rsa" > "${workdir}/id_rsa.pub"
  sshpubkey="$(cat "${workdir}/id_rsa.pub")"

  location="westus2"
  size="Standard_D2s_v3"

  # generate one random v3 key
  mkp224o-donna -d "${DIR}" -n 1 "az"
  mv "${DIR}"/*.onion/* "${DIR}"
  rmdir "${DIR}"/*.onion
  onion_hostname="$(cat ${DIR}/hostname | awk '{$1=$1};1')"

  az group create -n "${name}" -l "${location}"

  # create keyvault
  az keyvault create \
    --name "${name}" \
    --resource-group "${name}" \
    --location "${location}"
  kvid="$(az keyvault show --name "${name}" -o tsv --query '[id]')"

  # create key
  az keyvault key create \
  --name "${name}" \
  --vault-name "${name}" \
  --protection software \
  --ops encrypt decrypt

  ## Create Azure Identity (to later assign to our VMs)
  if ! az identity show -n "${name}" -g "${name}" &>/dev/null; then
    az identity create --name "${name}" --resource-group "${name}"
  fi
  identity_id="$(az identity show -n "${name}" -g "${name}" -o tsv --query [id])"

  # Get the Identity (via its OID) access to the Key
  oid="$(az identity show --name "${name}" --resource-group "${name}" -o tsv --query "[principalId]")"
  az keyvault set-policy --name "${name}" --object-id "${oid}" --key-permissions encrypt decrypt get
  
  # Grant *ourselves* (via *our* OID) access to the Key
  myoid="$(az ad signed-in-user show -o tsv --query [objectId])"
  az keyvault set-policy --name "${name}" --object-id "${myoid}" --key-permissions encrypt decrypt get

  # Get the Key's full resource id
  kid="$(az keyvault key show \
    --name "${name}" \
    --vault-name "${name}" \
    -o tsv \
    --query key.kid)"

  echo "${kid}"

  # Construct the .sops.yaml file
  cat >"${DIR}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: .*$
    azure_keyvault: ${kid}
EOF

  # encrypt the key with sops
  sops --verbose -e "./hs_ed25519_secret_key" \
    > "./hs_ed25519_secret_key.sops"
  rm "./hs_ed25519_secret_key" # TODO: shred it

  # build and upload the image
  time nix --experimental-features 'nix-command flakes' \
    build \
    --override-input nixpkgs /home/cole/code/nixpkgs/cmpkgs \
    --override-input nixos-azure /home/cole/code/nixos-azure \
    --override-input sops-nix /home/cole/code/sops-nix \
    --out-link /tmp/azout "${ROOT}#examples.demo.azureImage"

  image_id="$(AZURE_GROUP=${name} ../../../nixos-azure/scripts/upload-image.sh /tmp/azout)"

  # boot vm
  echo "**** WORKDIR: ${workdir}"
  echo "**** ONION: ${onion_hostname}"
  az vm create \
    --assign-identity "${identity_id}" \
    --name "${name}" \
    --resource-group "${name}" \
    --size "${size}" \
    --image "${image_id}" \
    --admin-username "azureuser" \
    --location "${location}" \
    --ssh-key-values "${sshpubkey}" \
    --ephemeral-os-disk true

  ip="$(az vm list-ip-addresses -n "${name}" -g "${name}" -o tsv \
    --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress')"

  echo "**** SSH: ssh -i ${workdir}/id_rsa azureuser@${ip}"

  bash

  curl -L "http://${onion_hostname}.to"

  echo "success"
}

time runtest