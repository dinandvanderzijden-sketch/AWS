module "network" {
  source = "./modules/network"

  project_name             = var.project_name
  hub_vpc_cidr              = var.hub_vpc_cidr
  hub_public_subnet_cidrs   = var.hub_public_subnet_cidrs
  hub_mgmt_subnet_cidr      = var.hub_mgmt_subnet_cidr
  spoke_web_vpc_cidr        = var.spoke_web_vpc_cidr
  spoke_web_subnet_cidrs    = var.spoke_web_subnet_cidrs
  spoke_data_vpc_cidr       = var.spoke_data_vpc_cidr
  spoke_data_subnet_cidrs   = var.spoke_data_subnet_cidrs
}

module "security" {
  source = "./modules/security"

  project_name             = var.project_name
  hub_vpc_id                = module.network.hub_vpc_id
  hub_public_subnet_cidrs   = var.hub_public_subnet_cidrs
  hub_mgmt_subnet_cidr      = var.hub_mgmt_subnet_cidr
  spoke_web_vpc_id          = module.network.spoke_web_vpc_id
  spoke_web_vpc_cidr        = var.spoke_web_vpc_cidr
  spoke_data_vpc_id         = module.network.spoke_data_vpc_id
  spoke_data_vpc_cidr       = var.spoke_data_vpc_cidr
  admin_cidr                = var.admin_cidr
}

module "database" {
  source = "./modules/database"

  project_name            = var.project_name
  environment               = var.environment
  spoke_data_subnet_ids    = module.network.spoke_data_subnet_ids
  database_sg_id            = module.security.database_sg_id
  db_engine_version         = var.db_engine_version
  db_instance_class         = var.db_instance_class
  db_name                   = var.db_name
  db_username               = var.db_username
}

module "compute" {
  source = "./modules/compute"

  project_name            = var.project_name
  aws_region                = var.aws_region
  hub_public_subnet_ids    = module.network.hub_public_subnet_ids
  spoke_web_vpc_id         = module.network.spoke_web_vpc_id
  spoke_web_subnet_ids     = module.network.spoke_web_subnet_ids
  alb_sg_id                  = module.security.alb_sg_id
  web_sg_id                  = module.security.web_sg_id
  db_secret_arn              = module.database.db_secret_arn
  container_image            = var.container_image
  ecs_task_cpu                = var.ecs_task_cpu
  ecs_task_memory            = var.ecs_task_memory
  ecs_min_tasks               = var.ecs_min_tasks
  ecs_max_tasks               = var.ecs_max_tasks
}

module "cicd" {
  source = "./modules/cicd"

  project_name           = var.project_name
  hub_mgmt_subnet_id      = module.network.hub_mgmt_subnet_id
  management_sg_id         = module.security.management_sg_id
  runner_instance_type     = var.runner_instance_type
  key_pair_name             = var.key_pair_name
  github_org                = var.github_org
  github_repo               = var.github_repo
  github_runner_token       = var.github_runner_token
}

module "observability" {
  source = "./modules/observability"

  project_name        = var.project_name
  hub_mgmt_subnet_id   = module.network.hub_mgmt_subnet_id
  management_sg_id      = module.security.management_sg_id
  spoke_web_vpc_cidr    = var.spoke_web_vpc_cidr
  spoke_data_vpc_cidr   = var.spoke_data_vpc_cidr
  key_pair_name          = var.key_pair_name
}
