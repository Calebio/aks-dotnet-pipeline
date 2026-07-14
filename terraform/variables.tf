variable "prefix" {
  type    = string
  default = "calebaks"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v6"
}