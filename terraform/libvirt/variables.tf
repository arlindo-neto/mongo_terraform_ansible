variable "hosts" {
  type    = number
  default = 4
}

variable "hostnames" {
  type    = list(any)
  default = ["db-1", "db-2", "db-3", "db-4"]
}

variable "interface" {
  type    = string
  default = "enp0s2"
}

variable "source_vm" {
  type    = string
  default = "sources/debian12-amd64.qcow2"
}

variable "memory" {
  type    = list(any)
  default = [2048, 2048, 2048, 2048]
}

variable "vcpu" {
  type    = number
  default = 2
}

variable "distros" {
  type    = list(any)
  default = ["debian"]
}

variable "ips" {
  type    = list(any)
  default = ["192.168.100.10", "192.168.100.11", "192.168.100.12", "192.168.100.13"]
}

variable "auth_key" {
  type    = string
  default = ""
}

variable "vm_condition_poweron" {
  default = true
}

variable "domain_type" {
  type    = string
  default = "kvm"
}
