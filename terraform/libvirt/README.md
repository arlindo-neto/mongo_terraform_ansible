# Deploy VMs using Terraform with Libvirt/KVM

This module creates:

- Libvirt Storage Pool
- OS Images and Resized Disk Volumes
- Cloud-Init ISOs for configuration
- Private Network (NAT mode)
- KVM Domains (VMs)

## Prerequisites

### 1. Install KVM/Libvirt

Requires Ubuntu 24.04 LTS as the virtualization host.

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst genisoimage
sudo usermod -aG libvirt $USER
# log out and back in for group membership to take effect
```

### 2. ARM (aarch64) guests — additional packages

Required only when `arch = "aarch64"`. This enables software emulation of ARM64 guests on an x86_64 host, or native KVM on an ARM64 host.

```bash
sudo apt install -y qemu-system-arm qemu-efi-aarch64
```

Firmware paths (used for the `firmware` and `nvram_template` variables):

| Variable | Path |
|---|---|
| `firmware` | `/usr/share/AAVMF/AAVMF_CODE.fd` |
| `nvram_template` | `/usr/share/AAVMF/AAVMF_VARS.fd` |

### 3. Install OpenTofu or Terraform

[OpenTofu install guide](https://opentofu.org/docs/intro/install/)

## Quick Guide

1. **Change into this directory:**
   ```bash
   cd mongo_terraform_ansible/terraform/libvirt
   ```

2. **Generate SSH Keys:**
   ```bash
   mkdir -p ssh_keys
   ssh-keygen -b 2048 -t rsa -f ./ssh_keys/opentofu -q -N ""
   ```

3. **Download an OS image** into the `sources` directory:

   **Rocky Linux 9 — x86_64:**
   ```bash
   curl --output-dir sources --create-dirs -L -o rocky9.qcow2 \
     https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
   ```

   **Rocky Linux 9 — aarch64:**
   ```bash
   curl --output-dir sources --create-dirs -L -o rocky9-aarch64.qcow2 \
     https://download.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2
   ```

   **Ubuntu 24.04 LTS — x86_64:**
   ```bash
   curl --output-dir sources --create-dirs -L -o ubuntu2404-amd64.img \
     https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
   ```

   **Ubuntu 24.04 LTS — aarch64:**
   ```bash
   curl --output-dir sources --create-dirs -L -o ubuntu2404-arm64.img \
     https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img
   ```

   **Debian 12 (Bookworm) — x86_64:**
   ```bash
   curl --output-dir sources --create-dirs -L -o debian12-amd64.qcow2 \
     https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
   ```

   **Debian 12 (Bookworm) — aarch64:**
   ```bash
   curl --output-dir sources --create-dirs -L -o debian12-arm64.qcow2 \
     https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2
   ```

4. **Initialize and apply:**
   ```bash
   tofu init
   tofu apply
   ```

## Connecting to Instances

```bash
ssh -i ./ssh_keys/opentofu admin@192.168.100.10
```

Default credentials: user `admin`, password `admin`, SSH key from `ssh_keys/opentofu`.

## Variables

| Variable | Default | Description |
|---|---|---|
| `hosts` | `3` | Number of VMs |
| `hostnames` | `["db-1","db-2","db-3"]` | VM hostnames |
| `memory` | `[2048,2048,2048]` | RAM per VM in MB |
| `vcpu` | `2` | vCPUs per VM |
| `ips` | `["192.168.100.10"…]` | Static IPs |
| `source_vm` | `sources/rocky9.qcow2` | Path to cloud image |
| `interface` | `ens01` | Guest network interface name |
| `arch` | `x86_64` | CPU architecture: `x86_64` or `aarch64` |
| `firmware` | `""` | UEFI firmware path (required for `aarch64`) |
| `nvram_template` | `""` | UEFI NVRAM template path (required for `aarch64`) |

## ARM (aarch64) Example

After completing the ARM prerequisites above:

```bash
tofu apply \
  -var 'arch=aarch64' \
  -var 'source_vm=sources/debian12-arm64.qcow2' \
  -var 'firmware=/usr/share/AAVMF/AAVMF_CODE.fd' \
  -var 'nvram_template=/usr/share/AAVMF/AAVMF_VARS.fd'
```

## Shutdown VMs

```bash
tofu apply -var 'vm_condition_poweron=false'
```

## Notes

- This module provisions VMs and base access only. It does not run Ansible automatically.
- After the VMs are reachable, use the playbooks in [`../../ansible`](../../ansible) for the MongoDB stack.

## Credits

This project uses the [terraform-provider-libvirt](https://github.com/dmacvicar/terraform-provider-libvirt) by dmacvicar.
