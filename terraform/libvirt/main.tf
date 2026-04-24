terraform {
  backend "local" {}

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.7"
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
  target = {
    path = abspath("${path.module}/pool")
  }
}

resource "libvirt_volume" "os_image" {
  name = "os_image"
  pool = libvirt_pool.k8s.name
  create = {
    content = {
      url = "file://${abspath("${path.module}/${var.source_vm}")}"
    }
  }
  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "disk_resized" {
  name          = "disk"
  pool          = libvirt_pool.k8s.name
  capacity      = 20000000000
  capacity_unit = "B"
  backing_store = {
    path = libvirt_volume.os_image.path
    format = {
      type = "qcow2"
    }
  }
  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "worker" {
  count         = var.hosts
  name          = "worker_${count.index}.qcow2"
  pool          = libvirt_pool.k8s.name
  capacity      = 20000000000
  capacity_unit = "B"
  backing_store = {
    path = libvirt_volume.disk_resized.path
    format = {
      type = "qcow2"
    }
  }
  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "commoninit" {
  count   = var.hosts
  name    = "commoninit_${var.hostnames[count.index]}"
  user_data = templatefile("${path.module}/templates/user_data.tpl", {
    host_name = var.hostnames[count.index]
    auth_key  = file("${path.module}/ssh_keys/opentofu.pub")
  })
  meta_data = yamlencode({
    instance-id    = var.hostnames[count.index]
    local-hostname = var.hostnames[count.index]
  })
  network_config = templatefile("${path.module}/templates/network_config.tpl", {
    interface = var.interface
    ip_addr   = var.ips[count.index]
  })
}

resource "libvirt_volume" "cloudinit_vol" {
  count = var.hosts
  name  = "commoninit_${var.hostnames[count.index]}.iso"
  pool  = libvirt_pool.k8s.name
  create = {
    content = {
      url = libvirt_cloudinit_disk.commoninit[count.index].path
    }
  }
}

resource "libvirt_network" "priv" {
  name      = "priv"
  autostart = true
  forward = {
    mode = "nat"
  }
  domain = {
    name       = "default.local"
    local_only = "yes"
  }
  ips = [
    {
      address = "192.168.100.1"
      netmask = "255.255.255.0"
    }
  ]
}

resource "libvirt_domain" "domain-distro" {
  count       = var.hosts
  name        = var.hostnames[count.index]
  memory      = var.memory[count.index]
  memory_unit = "MiB"
  vcpu        = var.vcpu
  type        = var.domain_type

  os = {
    type         = "hvm"
    type_arch    = var.arch
    type_machine = local.machine
    loader       = local.is_arm && var.firmware != "" ? var.firmware : null
  }

  devices = {
    consoles = [
      {
        type = "pty"
        target = {
          type = "serial"
          port = 0
        }
      }
    ]

    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_pool.k8s.name
            volume = libvirt_volume.worker[count.index].name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        source = {
          volume = {
            pool   = libvirt_pool.k8s.name
            volume = libvirt_volume.cloudinit_vol[count.index].name
          }
        }
        target = {
          dev = local.is_arm ? "vdb" : "sda"
          bus = local.is_arm ? "virtio" : "sata"
        }
        readonly = true
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.priv.name
          }
        }
      }
    ]
  }
}

resource "null_resource" "shutdowner" {
  for_each = toset(var.hostnames)
  triggers = {
    trigger = var.vm_condition_poweron
  }

  provisioner "local-exec" {
    command = var.vm_condition_poweron ? "echo 'do nothing'" : "virsh -c qemu:///system shutdown ${each.value}"
  }
}
