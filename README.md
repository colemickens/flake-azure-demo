# flake-azure-demo
*a declarative NixOS-based Azure VM to securely and automatically boot a Tor hidden service*

- [flake-azure-demo](#flake-azure-demo)
  - [Temporary Important WIP Info](#temporary-important-wip-info)
  - [Overview](#overview)
  - [Why this is cool!](#why-this-is-cool)
  - [Walkthrough](#walkthrough)
    - [1. Azure Identity + KeyVault Preparation](#1-azure-identity--keyvault-preparation)
    - [2. Generate our secret key](#2-generate-our-secret-key)
    - [3. Configure Sops & Encrypt our Secret](#3-configure-sops--encrypt-our-secret)
    - [4. Build the Image](#4-build-the-image)
      - [5. Boot the Image](#5-boot-the-image)
    - [The After Party](#the-after-party)

## Temporary Important WIP Info

See `./build.sh`. I'm overriding:
* `flake-azure` (my fork, `dev` branch) (to hide it for now)
* `sops-nix` (my fork, `azure` branch) (to use my fork of `sops` and relax nix constraints)
* `sops` (inside `sops-nix`) (to get Azure MSI convenience fix)
* `nixpkgs` (my fork, `cmpkgs` branch) (to get my Tor module bring-your-own-key improvement)

Note that if you want to look at the new Azure agent ([azure-linux-boot-agent](https://github.com/colemickens/azure-linux-boot-agent)), it's also hiding on a `dev` branch.

You'd basically need to clone those and update `./build.sh` to point at your checkouts of my branches in order to reproduce this. When the `sops` PR merges and `sops-nix` settles this will of course all go away. Hopefully a week at most.

The `./demo/default.nix` includes some hacks that shouldn't be necessary.

## Overview

This repo seeks to demonstrate a few things:
* how to use an experimental new Nix feature, [flakes](#TODO), to compose Nix projects
* a standalone repository building Azure VM images with the Nix modules from  [flake-azure](https://github.com/colemickens/flake-azure)
* Linux booting in Azure using [azure-linux-boot-agent](https://github.com/colemickens/azure-linux-boot-agent) (*a simpler, safer way to boot Linux in Azure*)
* securely shipping encrypted secrets that are transparently decrypted at boot-time thanks to [NixOS](https://nixos.org) + [`sops-nix`](https://github.com/Mic92/sops-nix) (see below, section [awesomeness](#awesomeness))

This demo will walk us through:
* Provisioning an Azure KeyVault with a Key for encryption/decryption
* Provisioning an Azure Identity which will be granted access to the KeyVault Key, and will be assigned to the Azure VMs as a Managed Identity (aka a "User Assigned Identity")
* Encrypting secrets with `sops` (which will delegate to GPG + Azure KeyVault)
* Creating a declarative NixOS image for Azure, with...
  * built-in encrypted secrets that will be decrypted+mounted at boot using KeyVault + MSI using `sops-nix`
  * [a new, lighter, safer Azure Linux agent (look ma, no Python!)](https://github.com/colemickens/azure-linux-boot-agent)
* Booting the VM and watching as a Tor Hidden Service becomes available with **no user interaction** and **no unencrypted secrets in flight, anywhere, ever**.


## Why this is cool!
* Our secrets can be encrypted and  checked in, and yet still seamlessly accessed by applications!
* Owing to `sops` we can have secrets that are easily consumed in integration pipelines (via an ssh keypair), in production systems (via Azure KeyVault+MSI), and developer workstations (via GPG, or Azure KeyVault+CLI)!
* You get to write very small amounts of declarative Nix to produce images that can automatically start any service, with any secret, securely, using the best encryption actor for all of your environments.
* If you don't know, Nix (and flakes) is very cool. If you have Nix and KVM (well, and technically my HS key), you can reproduce this exact demo image. Every single application, compiler flag, file, every single last dependency is hashed. Imagine if Ansible were perfect and actually reliable, or if Dockerfiles were *actually* reproducible and minimized *by default*. (see the `docker` dir in [`flake-azure`](https://github.com/colemickens/flake-azure/tree/main/docker) for an example)


## Walkthrough

There is a video walkthrough of this demo. It largely covers the same information, but also reiterates it in audio+video form, which maybe useful to some: 

[[embed here]]

We're using Nix, so you don't need anything else installed!

### 1. Azure Identity + KeyVault Preparation

```bash
$ nix-shell -p azure-cli

kvrg="sops-keyvault"
kvloc="westus2"
kvname="sops-$(uuidgen | tr -d - | head -c 16)"

keyname="sops-key"

identity_name="tor-vm-ident"
deploy_group="tor-deployment"

# Create the ResourceGroup to hold the KeyVault and Identity resources
az group create \
  --name "${kvrg}" \
  --location "${kvloc}"

# Create the KeyVault:
az keyvault create \
  --name "${kvname}" \
  --resource-group "${kvrg}" \
  --location "${kvloc}"

# Create the Key in our KeyVault (encrypt/decrypt actions allowed)
az keyvault key create \
  --name "${keyname}" \
  --vault-name "${kvname}" \
  --protection software \
  --ops encrypt decrypt

## Create Azure Identity (to later assign to our VMs)
if ! az identity show -n "${identity_name}" -g "${kvrg}" &>/dev/null; then
  az identity create --name "${identity_name}" --resource-group "${kvrg}"
fi

# Get the Identity (via its OID) access to the Key
oid="$(az identity show --name "${identity_name}" --resource-group "${kvrg}" -o tsv --query "[principalId]")"
az keyvault set-policy --name "${kvname}" --object-id "${oid}" --key-permissions encrypt decrypt

# Grant *ourselves* (via *our* OID) access to the Key
myuser="$(az account show -o tsv --query [user.name])"
myoid="$(az ad user show --id ${myuser} -o tsv --query [objectId])"
az keyvault set-policy --name "${kvname}" --object-id "${myoid}" --key-permissions encrypt decrypt

# Print out Key's full resource id
kid="$(az keyvault key show \
  --name "${keyname}" \
  --vault-name "${kvname}" \
  -o tsv \
  --query key.kid)"

echo "${kid}"
```

The final value printed out is a URL that is the Key ID. It uniquely identifies a specific version of a KeyVault Key. This is what we will instruct `sops` to use to encrypt our keys.
### 2. Generate our secret key

Now let's generate our secret key to power our Tor Hidden Service.
Again, all you need is `nix` installed.



```
$ nix-shell -p mkp224o

prefix="nixos" # you must make this short or you will get no matches!
mkp224o-<tab> # literally hit the tab button so you can see what your choices are
```

You'll want to guess and pick the best `mkp224o-[variant]` and a short `prefix`, otherwise you
may never get a match. Hit `ctrl-c` whenever you've got a match you're happy with.

Copy the files from the resulting directory into `./demo` (replace the existing pubkey and hostname files).

### 3. Configure Sops & Encrypt our Secret

First create `.sops.yaml` to direct `sops` on how to encrypt new secrets.

*Be sure to update this with your AKV Key URL from above!*

```yaml
# to encrypt new secrets with Azure KeyVault
creation_rules:
  - path_regex: .*$
    azure_keyvault: https://use-your-key-url-here.vault.azure.net/keys/key-name/6e538f7c6d714d138226082070d1fe99
# to *also* encrypt new secrets with your GPG backup/offline key
... TODO
```

Then, simply invoke `sops` to encrypt the Hidden Service key.

```shell
$ nix-shell -p sops

# encrypt the file 
sops --encrypt "demo/hs_ed25519_secret_key" > "demo/hs_ed25519_secret_key.sops"
```

(Note that our `.gitignore` contains "`hs_ed25519_secret_key`"  to prevent accidentally commiting any secret keys.)

### 4. Build the Image

First, let's build the image (note, this requires KVM):
```shell
nix --experimental-features 'nix-command flakes' \
  build ".#image.azureImage"
```

Next, using another new flake-azure module, we can build a set of scripts to easily upload
the resulting image.

```shell
nix --experimental-features 'nix-command flakes' \
  build ".#image.azureScripts"
```

Then you can upload the image:
```shell
# this will be used to prefix the resource_group and name for the image
AZPREFIX="something"
./result/bin/azutil.sh upload_image
```

#### 5. Boot the Image

And boot a small VM:

```shell
# replace these values using outputs of previous commands
image_id="output from last command, upload_image"
identity_id="azure identity resouce ID from above"
sshpubkey="your own ssh key"

# for example, mine looked like this:
image_id="/subscriptions/.../resourceGroups/images/providers/Microsoft.Compute/images/nixos"
identity_id="/subscriptions/.../resourceGroups/deploy/providers/Microsoft.ManagedIdentity/userAssignedIdentities/tor-vm-ident"
sshpubkey="$(ssh-add -L)"

# you can now copy-n-paste the rest to create a 
name="torvm-$RANDOM"
az group create -n "${name}" -l "westus2"

time az vm create \
  --name "${name}" \
  --resource-group "${name}" \
  --assign-identity "${identity_id}" \
  --size "Standard_D2s_v3" \
  --image "${image_id}" \
  --admin-username "azureuser" \
  --location "westus2" \
  --ssh-key-values "${sshpubkey}"
```

If everything worked, you should be able to open the hidden site in Tor Browser.

[TODO ADD SCREENSHOT]

### The After Party

Now, that was exciting, but let's make sense of what all just happened.
