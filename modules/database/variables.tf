variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "spoke_data_subnet_ids" {
  type = list(string)
}

variable "database_sg_id" {
  type = string
}

variable "db_engine_version" {
  type = string
}

variable "db_instance_class" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}
