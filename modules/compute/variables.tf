variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "hub_public_subnet_ids" {
  type = list(string)
}

variable "spoke_web_vpc_id" {
  type = string
}

variable "spoke_web_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "web_sg_id" {
  type = string
}

variable "db_secret_arn" {
  type = string
}

variable "container_image" {
  type = string
}

variable "ecs_task_cpu" {
  type = number
}

variable "ecs_task_memory" {
  type = number
}

variable "ecs_min_tasks" {
  type = number
}

variable "ecs_max_tasks" {
  type = number
}
