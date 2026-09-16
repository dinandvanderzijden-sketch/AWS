variable "project_name" {
  type = string
}

variable "hub_vpc_cidr" {
  type = string
}

variable "hub_public_subnet_cidrs" {
  type = list(string)
}

variable "hub_mgmt_subnet_cidr" {
  type = string
}

variable "spoke_web_vpc_cidr" {
  type = string
}

variable "spoke_web_subnet_cidrs" {
  type = list(string)
}

variable "spoke_data_vpc_cidr" {
  type = string
}

variable "spoke_data_subnet_cidrs" {
  type = list(string)
}
