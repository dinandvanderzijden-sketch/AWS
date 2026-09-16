variable "project_name" {
  type = string
}

variable "hub_mgmt_subnet_id" {
  type = string
}

variable "management_sg_id" {
  type = string
}

variable "runner_instance_type" {
  type = string
}

variable "key_pair_name" {
  type    = string
  default = null
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "github_runner_token" {
  type      = string
  sensitive = true
}
