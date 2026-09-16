variable "project_name" {
  type = string
}

variable "hub_mgmt_subnet_id" {
  type = string
}

variable "management_sg_id" {
  type = string
}

variable "spoke_web_vpc_cidr" {
  type = string
}

variable "spoke_data_vpc_cidr" {
  type = string
}

variable "key_pair_name" {
  type    = string
  default = null
}
