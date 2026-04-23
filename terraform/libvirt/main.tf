terraform {
  backend "local" {}

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.8.3"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

locals {
  is_arm  = var.arch == "aarch64"
  machine = local.is_arm ? "virt" : "pc"
}

resource "libvirt_pool" "k8s" {
  name = "k8s"
  type = "dir"
  path = abspath("${path.module}/pool")
}

resource "libvirt_volume" "os_image" {
  name   = "os_image"
  pool   = libvirt_pool.k8s.name
  source = "${path.module}/${var.source_vm}"
  format = "qcow2"
}

resource "libvirt_volume" "disk_resized" {
  name           = "disk"
  pool           = libvirt_pool.k8s.name
  base_volume_id = libvirt_volume.os_image.id
  size           = 20000000000 # 20GiB
}

resource "libvirt_volume" "worker" {
  name           = "worker_${count.index}.qcow2"
  pool           = libvirt_pool.k8s.name
  base_volume_id = libvirt_volume.disk_resized.id
  count          = var.hosts
}

resource "libvirt_cloudinit_disk" "commoninit" {
  count = var.hosts
  name  = "commoninit_${var.hostnames[count.index]}.iso"
  pool  = libvirt_pool.k8s.name
  user_data = templatefile("${path.module}/templates/user_data.tpl",
    {
      host_name = var.hostnames[count.index]
      auth_key  = file("${path.module}/ssh_keys/opentofu.pub")
  })
  network_config = templatefile("${path.module}/templates/network_config.tpl", {
    interface = var.interface
    ip_addr   = var.ips[count.index]
  })
}

resource "libvirt_network" "priv" {
  # the name used by libvirt
  name = "priv"

  # mode can be: "nat" (default), "none", "route", "open", "bridge"
  mode = "nat"

  #  the domain used by the DNS server in this network
  domain = "default.local"

  dns {
    enabled    = true
    local_only = true
  }

  # Whether the network should be started automatically when the host boots
  autostart = true

  #  list of subnets the addresses allowed for domains connected
  # also derived to define the host addresses
  # also derived to define the addresses served by the DHCP server
  addresses = ["192.168.100.0/24"]
}

resource "libvirt_domain" "domain-distro" {
  count     = var.hosts
  name      = var.hostnames[count.index]
  memory    = var.memory[count.index]
  vcpu      = var.vcpu
  arch      = var.arch
  type      = var.domain_type
  machine   = local.machine

  firmware = local.is_arm && var.firmware != "" ? var.firmware : null

  dynamic "nvram" {
    for_each = local.is_arm && var.firmware != "" && var.nvram_template != "" ? [1] : []
    content {
      file     = "/var/lib/libvirt/qemu/nvram/${var.hostnames[count.index]}_VARS.fd"
      template = var.nvram_template
    }
  }

  network_interface {
    network_name = "priv"
    addresses    = [var.ips[count.index]]
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  disk {
    volume_id = element(libvirt_volume.worker.*.id, count.index)
  }

  # Use cloudinit attribute again, but we will try to fix it with XSLT if needed
  cloudinit = element(libvirt_cloudinit_disk.commoninit.*.id, count.index)

  # ARM virt machine does not support IDE; convert cloud-init cdrom to virtio disk
  xml {
    xslt = <<EOF
<?xml version="1.0" ?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>
  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices/controller[@type='ide']"/>

  <xsl:template match="/domain/devices/disk[@device='cdrom'][./target[@bus='ide']]">
    <disk type='file' device='disk'>
      <xsl:apply-templates select="driver|source"/>
      <target dev='vdb' bus='virtio'/>
      <readonly/>
    </disk>
  </xsl:template>

  <!-- libvirt defaults aarch64 to cortex-a15 (32-bit ARMv7); inject 64-bit cortex-a57 before libvirt fills the default -->
  <xsl:template match="/domain/cpu">
    <cpu mode='custom' match='exact'>
      <model fallback='allow'>cortex-a57</model>
    </cpu>
  </xsl:template>
</xsl:stylesheet>
EOF
  }
}

resource "null_resource" "shutdowner" {
  # iterate with for_each over Vms list ( my *.tf file creates VMs from list)
  for_each = toset(var.hostnames)
  triggers = {
    trigger = var.vm_condition_poweron
  }

  provisioner "local-exec" {
    command = var.vm_condition_poweron ? "echo 'do nothing'" : "virsh -c qemu:///system shutdown ${each.value}"
  }
}
