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

resource "libvirt_pool" "k8s" {
  name = "k8s"
  type = "dir"
  target = {
    path = abspath("${path.module}/pool")
  }
  destroy = {
    delete = false
  }
}

resource "libvirt_volume" "os_image" {
  name = "os_image-${md5(var.source_vm)}"
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
  name          = "disk-${md5(libvirt_volume.os_image.id)}"
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
  name          = "worker_${count.index}-${md5(libvirt_volume.disk_resized.id)}.qcow2"
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
  name  = "commoninit_${var.hostnames[count.index]}-${md5(libvirt_cloudinit_disk.commoninit[count.index].user_data)}.iso"
  pool  = libvirt_pool.k8s.name
  create = {
    content = {
      url = libvirt_cloudinit_disk.commoninit[count.index].path
    }
  }
  lifecycle {
    # The temp ISO path changes on every run even when content is identical.
    # Volumes are immutable after creation; ignore URL drift to prevent false updates.
    ignore_changes = [create]
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
  dns = {
    host = [
      for i, name in var.hostnames : {
        ip        = var.ips[i]
        hostnames = [{ hostname = name }]
      }
    ]
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

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "pc"
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
        driver = {
          name = "qemu"
          type = "qcow2"
        }
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
          dev = "sda"
          bus = "sata"
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

resource "null_resource" "starter" {
  count = var.hosts
  triggers = {
    domain_id = libvirt_domain.domain-distro[count.index].id
  }

  provisioner "local-exec" {
    command = "virsh -c qemu:///system start ${var.hostnames[count.index]} || true"
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
