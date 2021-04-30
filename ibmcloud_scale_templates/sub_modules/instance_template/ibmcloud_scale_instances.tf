/*
    This nested module creates;
    1. Instance security group/rule(s)
    2. {Compute, Storage} instance(s)
    3. Reserve floating ip
*/

locals {
  secondary_private_subnet_ids = []
}

module "instances_security_group" {
  source           = "../../../resources/ibmcloud/security/security_group"
  total_sec_groups = (length(var.compute_private_subnets) > 0 && length(var.storage_private_subnets) > 0) ? 2 : 1
  sec_group_name   = (length(var.compute_private_subnets) > 0 && length(var.storage_private_subnets) > 0) ? ["${var.stack_name}-strg-sg", "${var.stack_name}-comp-sg"] : (length(var.compute_private_subnets) == 0 ? ["${var.stack_name}-strg-sg"] : ["${var.stack_name}-comp-sg"])
  vpc_id           = var.vpc_id
  resource_grp_id  = var.resource_grp_id
}

module "compute_instances_sg_cidr_rule" {
  source = "../../../resources/ibmcloud/security/security_cidr_rule"
  /* num of sec_group_id = 2, both strg, comp exits,
     num of sec_group_id = 1, then only strg exists */
  total_cidr_rules   = length(module.instances_security_group.sec_group_id) == 1 ? 0 : 2
  security_group_ids = module.instances_security_group.sec_group_id.1
  sg_direction       = "inbound"
  remote_cidr        = [var.storage_cidr_block.0, var.compute_cidr_block.0]
}

module "storage_instances_sg_cidr_rule" {
  source             = "../../../resources/ibmcloud/security/security_cidr_rule"
  total_cidr_rules   = length(module.instances_security_group.sec_group_id) == 1 ? 1 : 2
  security_group_ids = module.instances_security_group.sec_group_id.0
  sg_direction       = "inbound"
  remote_cidr        = length(module.instances_security_group.sec_group_id) == 1 ? [var.storage_cidr_block.0] : [var.storage_cidr_block.0, var.compute_cidr_block.0]
}

module "instances_sg_outbound_rule" {
  source             = "../../../resources/ibmcloud/security/security_allow_all"
  security_group_ids = module.instances_security_group.sec_group_id
  sg_direction       = "outbound"
  remote_ip_addr     = "0.0.0.0/0"
}

data "ibm_is_ssh_key" "instance_ssh_key" {
  name = var.instance_ssh_key
}

data "ibm_is_image" "compute_instance_image" {
  name = var.compute_vsi_osimage_name
}

data "ibm_is_image" "storage_instance_image" {
  name = var.storage_vsi_osimage_name
}

module "compute_cluster_ssh_keys" {
  source       = "../../../resources/common/generate_keys"
  invoke_count = var.total_compute_instances > 0 ? 1 : 0
  tf_data_path = format("%s/compute", var.tf_data_path)
}

module "storage_cluster_ssh_keys" {
  source       = "../../../resources/common/generate_keys"
  invoke_count = var.total_storage_instances > 0 ? 1 : 0
  tf_data_path = format("%s/storage", var.tf_data_path)
}

module "compute_vsis" {
  source          = "../../../resources/ibmcloud/compute/scale_vsi_0_vol"
  total_vsis      = var.total_compute_instances
  vsi_name_prefix = format("%s-compute", var.stack_name)
  vpc_id          = var.vpc_id
  zones           = var.zones
  /* dns_service_ids = list(storage dns service id, compute dns service id) */
  dns_service_id          = length(var.dns_service_ids) == 1 ? var.dns_service_ids.0 : var.dns_service_ids.1
  dns_zone_id             = length(var.dns_zone_ids) == 1 ? var.dns_zone_ids.0 : var.dns_zone_ids.1
  resource_grp_id         = var.resource_grp_id
  vsi_primary_subnet_id   = length(var.compute_private_subnets) == 0 ? var.storage_private_subnets : var.compute_private_subnets
  vsi_secondary_subnet_id = length(local.secondary_private_subnet_ids) == 0 ? null : local.secondary_private_subnet_ids
  vsi_security_group      = length(module.instances_security_group.sec_group_id) == 1 ? [module.instances_security_group.sec_group_id[0]] : [module.instances_security_group.sec_group_id[1]]
  vsi_profile             = var.compute_vsi_profile
  vsi_image_id            = data.ibm_is_image.compute_instance_image.id
  vsi_user_public_key     = [data.ibm_is_ssh_key.instance_ssh_key.id]
  vsi_meta_private_key    = module.compute_cluster_ssh_keys.private_key.0
  vsi_meta_public_key     = module.compute_cluster_ssh_keys.public_key.0

  depends_on = [module.compute_instances_sg_cidr_rule, module.storage_instances_sg_cidr_rule]
}

module "create_desc_disk" {
  source             = "../../../resources/ibmcloud/storage"
  total_volumes      = var.block_volumes_per_instance == 0 ? 0 : length(var.zones) >= 3 ? 1 : 0
  zone               = length(var.zones) >= 3 ? var.zones.2 : var.zones.0
  volume_name_prefix = format("%s-desc", var.stack_name)
  volume_profile     = var.volume_profile
  volume_iops        = var.volume_iops
  volume_capacity    = var.volume_capacity
  resource_grp_id    = var.resource_grp_id
}

module "desc_compute_vsi" {
  source                  = "../../../resources/ibmcloud/compute/scale_vsi_multiple_vol"
  total_vsis              = length(var.zones) >= 3 ? 1 : 0
  vsi_name_prefix         = format("%s-tiebreaker-desc", var.stack_name)
  vpc_id                  = var.vpc_id
  resource_grp_id         = var.resource_grp_id
  zone                    = length(var.zones) >= 3 ? var.zones.2 : var.zones.0
  vsi_primary_subnet_id   = var.storage_private_subnets.0
  vsi_secondary_subnet_id = length(local.secondary_private_subnet_ids) == 0 ? false : (length(var.zones) >= 3 ? local.secondary_private_subnet_ids.2 : local.secondary_private_subnet_ids.0)
  dns_service_id          = var.dns_service_ids.0
  dns_zone_id             = var.dns_zone_ids.0
  vsi_security_group      = [module.instances_security_group.sec_group_id[0]]
  vsi_profile             = var.compute_vsi_profile
  vsi_image_id            = data.ibm_is_image.compute_instance_image.id
  vsi_user_public_key     = [data.ibm_is_ssh_key.instance_ssh_key.id]
  vsi_meta_private_key    = module.storage_cluster_ssh_keys.private_key.0
  vsi_meta_public_key     = module.storage_cluster_ssh_keys.public_key.0
  vsi_data_volumes_count  = 1
  vsi_volumes             = module.create_desc_disk.volume_id
  depends_on              = [module.compute_instances_sg_cidr_rule, module.storage_instances_sg_cidr_rule]
}

locals {
  total_nsd_disks = var.block_volumes_per_instance * var.total_storage_instances
}

module "create_data_disks_1A_zone" {
  source             = "../../../resources/ibmcloud/storage"
  total_volumes      = var.block_volumes_per_instance == 0 ? 0 : length(var.zones) == 1 ? local.total_nsd_disks : local.total_nsd_disks / 2
  zone               = var.zones.0
  volume_name_prefix = format("%s-1a", var.stack_name)
  volume_profile     = var.volume_profile
  volume_iops        = var.volume_iops
  volume_capacity    = var.volume_capacity
  resource_grp_id    = var.resource_grp_id
}

module "create_data_disks_2A_zone" {
  source             = "../../../resources/ibmcloud/storage"
  total_volumes      = var.block_volumes_per_instance == 0 ? 0 : length(var.zones) == 1 ? 0 : local.total_nsd_disks / 2
  zone               = length(var.zones) == 1 ? var.zones.0 : var.zones.1
  volume_name_prefix = format("%s-2a", var.stack_name)
  volume_profile     = var.volume_profile
  volume_iops        = var.volume_iops
  volume_capacity    = var.volume_capacity
  resource_grp_id    = var.resource_grp_id
}

module "storage_vsis_1A_zone" {
  source                  = "../../../resources/ibmcloud/compute/scale_vsi_multiple_vol"
  total_vsis              = length(var.zones) > 1 ? var.total_storage_instances / 2 : var.total_storage_instances
  zone                    = var.zones.0
  vsi_name_prefix         = format("%s-storage-1a", var.stack_name)
  vpc_id                  = var.vpc_id
  dns_service_id          = var.dns_service_ids.0
  dns_zone_id             = var.dns_zone_ids.0
  resource_grp_id         = var.resource_grp_id
  vsi_primary_subnet_id   = var.storage_private_subnets.0
  vsi_secondary_subnet_id = length(local.secondary_private_subnet_ids) == 0 ? false : local.secondary_private_subnet_ids.0
  vsi_security_group      = [module.instances_security_group.sec_group_id[0]]
  vsi_profile             = var.storage_vsi_profile
  vsi_image_id            = data.ibm_is_image.storage_instance_image.id
  vsi_user_public_key     = [data.ibm_is_ssh_key.instance_ssh_key.id]
  vsi_meta_private_key    = module.storage_cluster_ssh_keys.private_key.0
  vsi_meta_public_key     = module.storage_cluster_ssh_keys.public_key.0
  vsi_volumes             = module.create_data_disks_1A_zone.volume_id
  vsi_data_volumes_count  = var.block_volumes_per_instance
  depends_on              = [module.compute_instances_sg_cidr_rule, module.storage_instances_sg_cidr_rule]
}

module "storage_vsis_2A_zone" {
  source                  = "../../../resources/ibmcloud/compute/scale_vsi_multiple_vol"
  total_vsis              = length(var.zones) > 1 ? var.total_storage_instances / 2 : 0
  zone                    = length(var.zones) == 1 ? var.zones.0 : var.zones.1
  vsi_name_prefix         = format("%s-storage-2a", var.stack_name)
  vpc_id                  = var.vpc_id
  dns_service_id          = var.dns_service_ids.0
  dns_zone_id             = var.dns_zone_ids.0
  resource_grp_id         = var.resource_grp_id
  vsi_primary_subnet_id   = length(var.zones) >= 3 ? var.storage_private_subnets.1 : var.storage_private_subnets.0
  vsi_secondary_subnet_id = length(local.secondary_private_subnet_ids) == 0 ? false : (length(var.zones) > 1 ? local.secondary_private_subnet_ids.1 : local.secondary_private_subnet_ids.0)
  vsi_security_group      = [module.instances_security_group.sec_group_id[0]]
  vsi_profile             = var.storage_vsi_profile
  vsi_image_id            = data.ibm_is_image.storage_instance_image.id
  vsi_user_public_key     = [data.ibm_is_ssh_key.instance_ssh_key.id]
  vsi_meta_private_key    = module.storage_cluster_ssh_keys.private_key.0
  vsi_meta_public_key     = module.storage_cluster_ssh_keys.public_key.0
  vsi_volumes             = module.create_data_disks_2A_zone.volume_id
  vsi_data_volumes_count  = var.block_volumes_per_instance
  depends_on              = [module.compute_instances_sg_cidr_rule, module.storage_instances_sg_cidr_rule]
}

locals {
  cluster_namespace      = "multi"
  compute_vsi_by_ip      = length(local.secondary_private_subnet_ids) == 0 ? module.compute_vsis.vsi_primary_ips : module.compute_vsis.vsi_secondary_ips
  desc_compute_vsi_by_ip = length(var.zones) == 1 ? (length(local.secondary_private_subnet_ids) == 0 ? module.desc_compute_vsi.vsi_primary_ips : module.desc_compute_vsi.vsi_secondary_ips) : []
  compute_vsi_desc_map = {
    for instance in local.desc_compute_vsi_by_ip :
    instance => module.create_desc_disk.volume_id
  }
  storage_vsis_1A_by_ip = length(local.secondary_private_subnet_ids) == 0 ? module.storage_vsis_1A_zone.vsi_primary_ips : module.storage_vsis_1A_zone.vsi_secondary_ips
  storage_vsis_2A_by_ip = length(local.secondary_private_subnet_ids) == 0 ? module.storage_vsis_2A_zone.vsi_primary_ips : module.storage_vsis_2A_zone.vsi_secondary_ips

  /* Block volumes per instance = 0, defaults to instance storage */
  storage_vsi_ips_with_0_datadisks  = var.block_volumes_per_instance == 0 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_1_datadisks  = var.block_volumes_per_instance == 1 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_2_datadisks  = var.block_volumes_per_instance == 2 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_3_datadisks  = var.block_volumes_per_instance == 3 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_4_datadisks  = var.block_volumes_per_instance == 4 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_5_datadisks  = var.block_volumes_per_instance == 5 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_6_datadisks  = var.block_volumes_per_instance == 6 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_7_datadisks  = var.block_volumes_per_instance == 7 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_8_datadisks  = var.block_volumes_per_instance == 8 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_9_datadisks  = var.block_volumes_per_instance == 9 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_10_datadisks = var.block_volumes_per_instance == 10 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_11_datadisks = var.block_volumes_per_instance == 11 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_12_datadisks = var.block_volumes_per_instance == 12 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_13_datadisks = var.block_volumes_per_instance == 13 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_14_datadisks = var.block_volumes_per_instance == 14 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null
  storage_vsi_ips_with_15_datadisks = var.block_volumes_per_instance == 15 ? (length(var.zones) == 1 ? local.storage_vsis_1A_by_ip : concat(local.storage_vsis_1A_by_ip, local.storage_vsis_2A_by_ip)) : null

  /* Block volumes per instance = 0, defaults to instance storage */
  strg_vsi_ids_0_disks  = var.block_volumes_per_instance == 0 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_1_disks  = var.block_volumes_per_instance == 1 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_2_disks  = var.block_volumes_per_instance == 2 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_3_disks  = var.block_volumes_per_instance == 3 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_4_disks  = var.block_volumes_per_instance == 4 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_5_disks  = var.block_volumes_per_instance == 5 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_6_disks  = var.block_volumes_per_instance == 6 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_7_disks  = var.block_volumes_per_instance == 7 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_8_disks  = var.block_volumes_per_instance == 8 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_9_disks  = var.block_volumes_per_instance == 9 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_10_disks = var.block_volumes_per_instance == 10 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_11_disks = var.block_volumes_per_instance == 11 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_12_disks = var.block_volumes_per_instance == 12 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_13_disks = var.block_volumes_per_instance == 13 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_14_disks = var.block_volumes_per_instance == 14 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []
  strg_vsi_ids_15_disks = var.block_volumes_per_instance == 15 ? (length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_ids : concat(module.storage_vsis_1A_zone.vsi_ids, module.storage_vsis_2A_zone.vsi_ids)) : []

  /* Block volumes per instance = 0, defaults to instance storage */
  strg_vsi_ips_0_disks_dev_map = var.block_volumes_per_instance == 0 ? {
    for instance in local.storage_vsi_ips_with_0_datadisks :
    instance => length(var.zones) == 1 ? module.storage_vsis_1A_zone.vsi_instance_storage_volumes : concat(module.storage_vsis_1A_zone.vsi_instance_storage_volumes, module.storage_vsis_2A_zone.vsi_instance_storage_volumes)
  } : {}
  strg_vsi_ips_1_disks_dev_map = var.block_volumes_per_instance == 1 ? {
    for instance in local.storage_vsi_ips_with_1_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_2_disks_dev_map = var.block_volumes_per_instance == 2 ? {
    for instance in local.storage_vsi_ips_with_2_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_3_disks_dev_map = var.block_volumes_per_instance == 3 ? {
    for instance in local.storage_vsi_ips_with_3_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_4_disks_dev_map = var.block_volumes_per_instance == 4 ? {
    for instance in local.storage_vsi_ips_with_4_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_5_disks_dev_map = var.block_volumes_per_instance == 5 ? {
    for instance in local.storage_vsi_ips_with_5_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_6_disks_dev_map = var.block_volumes_per_instance == 6 ? {
    for instance in local.storage_vsi_ips_with_6_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_7_disks_dev_map = var.block_volumes_per_instance == 7 ? {
    for instance in local.storage_vsi_ips_with_7_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_8_disks_dev_map = var.block_volumes_per_instance == 8 ? {
    for instance in local.storage_vsi_ips_with_8_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_9_disks_dev_map = var.block_volumes_per_instance == 9 ? {
    for instance in local.storage_vsi_ips_with_9_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_10_disks_dev_map = var.block_volumes_per_instance == 10 ? {
    for instance in local.storage_vsi_ips_with_10_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_11_disks_dev_map = var.block_volumes_per_instance == 11 ? {
    for instance in local.storage_vsi_ips_with_11_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_12_disks_dev_map = var.block_volumes_per_instance == 12 ? {
    for instance in local.storage_vsi_ips_with_12_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_13_disks_dev_map = var.block_volumes_per_instance == 13 ? {
    for instance in local.storage_vsi_ips_with_13_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_14_disks_dev_map = var.block_volumes_per_instance == 14 ? {
    for instance in local.storage_vsi_ips_with_14_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
  strg_vsi_ips_15_disks_dev_map = var.block_volumes_per_instance == 15 ? {
    for instance in local.storage_vsi_ips_with_15_datadisks :
    instance => length(var.zones) == 1 ? module.create_data_disks_1A_zone.volume_id : concat(module.create_data_disks_1A_zone.volume_id, module.create_data_disks_2A_zone)
  } : {}
}

module "invoke_compute_playbook" {
  source       = "../../../resources/common/ansible_compute_playbook"
  invoke_count = local.cluster_namespace == "multi" ? 1 : 0
  region       = var.region
  stack_name   = format("%s.%s", var.stack_name, "compute")

  tf_data_path            = var.tf_data_path
  tf_input_json_root_path = var.tf_input_json_root_path == null ? abspath(path.cwd) : var.tf_input_json_root_path
  tf_input_json_file_name = var.tf_input_json_file_name == null ? join(", ", fileset(abspath(path.cwd), "*.tfvars*")) : var.tf_input_json_file_name

  bucket_name               = "None"
  bastion_public_ip         = var.bastion_public_ip
  instances_ssh_private_key = var.instances_ssh_private_key

  scale_infra_repo_clone_path = var.scale_infra_repo_clone_path

  cloud_platform   = "IBMCloud"
  avail_zones      = jsonencode(var.zones)
  notification_arn = "None"

  compute_instances_by_id = module.compute_vsis.vsi_ids == null ? jsonencode([]) : jsonencode(module.compute_vsis.vsi_ids)
  compute_instances_by_ip = local.compute_vsi_by_ip == null ? jsonencode([]) : jsonencode(local.compute_vsi_by_ip)
}

module "invoke_storage_playbook" {
  source       = "../../../resources/common/ansible_storage_playbook"
  invoke_count = local.cluster_namespace == "multi" ? 1 : 0
  region       = var.region
  stack_name   = format("%s.%s", var.stack_name, "compute")

  tf_data_path            = var.tf_data_path
  tf_input_json_root_path = var.tf_input_json_root_path == null ? abspath(path.cwd) : var.tf_input_json_root_path
  tf_input_json_file_name = var.tf_input_json_file_name == null ? join(", ", fileset(abspath(path.cwd), "*.tfvars*")) : var.tf_input_json_file_name

  bucket_name               = "None"
  bastion_public_ip         = var.bastion_public_ip
  instances_ssh_private_key = var.instances_ssh_private_key

  scale_infra_repo_clone_path = var.scale_infra_repo_clone_path
  filesystem_mountpoint       = var.filesystem_mountpoint
  filesystem_block_size       = var.filesystem_block_size

  cloud_platform   = "IBMCloud"
  avail_zones      = jsonencode(var.zones)
  notification_arn = "None"

  compute_instance_desc_map = jsonencode(local.compute_vsi_desc_map)
  compute_instance_desc_id  = jsonencode(module.desc_compute_vsi.vsi_ids)

  storage_instances_by_id = jsonencode(compact(concat(local.strg_vsi_ids_0_disks, local.strg_vsi_ids_1_disks, local.strg_vsi_ids_2_disks, local.strg_vsi_ids_3_disks, local.strg_vsi_ids_4_disks, local.strg_vsi_ids_5_disks, local.strg_vsi_ids_6_disks, local.strg_vsi_ids_7_disks, local.strg_vsi_ids_8_disks, local.strg_vsi_ids_9_disks, local.strg_vsi_ids_10_disks, local.strg_vsi_ids_11_disks, local.strg_vsi_ids_12_disks, local.strg_vsi_ids_13_disks, local.strg_vsi_ids_14_disks, local.strg_vsi_ids_15_disks)))

  storage_instance_disk_map = jsonencode(merge(local.strg_vsi_ips_0_disks_dev_map, local.strg_vsi_ips_1_disks_dev_map, local.strg_vsi_ips_2_disks_dev_map, local.strg_vsi_ips_3_disks_dev_map, local.strg_vsi_ips_4_disks_dev_map, local.strg_vsi_ips_5_disks_dev_map, local.strg_vsi_ips_6_disks_dev_map, local.strg_vsi_ips_7_disks_dev_map, local.strg_vsi_ips_8_disks_dev_map, local.strg_vsi_ips_9_disks_dev_map, local.strg_vsi_ips_10_disks_dev_map, local.strg_vsi_ips_11_disks_dev_map, local.strg_vsi_ips_12_disks_dev_map, local.strg_vsi_ips_13_disks_dev_map, local.strg_vsi_ips_14_disks_dev_map, local.strg_vsi_ips_15_disks_dev_map))
}

module "invoke_scale_playbook" {
  source       = "../../../resources/common/ansible_scale_playbook"
  invoke_count = local.cluster_namespace == "single" ? 1 : 0
  region       = var.region
  stack_name   = var.stack_name

  tf_data_path            = var.tf_data_path
  tf_input_json_root_path = var.tf_input_json_root_path == null ? abspath(path.cwd) : var.tf_input_json_root_path
  tf_input_json_file_name = var.tf_input_json_file_name == null ? join(", ", fileset(abspath(path.cwd), "*.tfvars*")) : var.tf_input_json_file_name

  bucket_name               = "None"
  bastion_public_ip         = var.bastion_public_ip
  instances_ssh_private_key = var.instances_ssh_private_key

  scale_infra_repo_clone_path = var.scale_infra_repo_clone_path
  filesystem_mountpoint       = var.filesystem_mountpoint
  filesystem_block_size       = var.filesystem_block_size

  cloud_platform   = "IBMCloud"
  avail_zones      = jsonencode(var.zones)
  notification_arn = "None"

  compute_instances_by_id = module.compute_vsis.vsi_ids == null ? jsonencode([]) : jsonencode(module.compute_vsis.vsi_ids)
  compute_instances_by_ip = local.compute_vsi_by_ip == null ? jsonencode([]) : jsonencode(local.compute_vsi_by_ip)

  compute_instance_desc_map = jsonencode(local.compute_vsi_desc_map)
  compute_instance_desc_id  = jsonencode(module.desc_compute_vsi.vsi_ids)

  storage_instances_by_id = jsonencode(compact(concat(local.strg_vsi_ids_0_disks, local.strg_vsi_ids_1_disks, local.strg_vsi_ids_2_disks, local.strg_vsi_ids_3_disks, local.strg_vsi_ids_4_disks, local.strg_vsi_ids_5_disks, local.strg_vsi_ids_6_disks, local.strg_vsi_ids_7_disks, local.strg_vsi_ids_8_disks, local.strg_vsi_ids_9_disks, local.strg_vsi_ids_10_disks, local.strg_vsi_ids_11_disks, local.strg_vsi_ids_12_disks, local.strg_vsi_ids_13_disks, local.strg_vsi_ids_14_disks, local.strg_vsi_ids_15_disks)))

  storage_instance_disk_map = jsonencode(merge(local.strg_vsi_ips_0_disks_dev_map, local.strg_vsi_ips_1_disks_dev_map, local.strg_vsi_ips_2_disks_dev_map, local.strg_vsi_ips_3_disks_dev_map, local.strg_vsi_ips_4_disks_dev_map, local.strg_vsi_ips_5_disks_dev_map, local.strg_vsi_ips_6_disks_dev_map, local.strg_vsi_ips_7_disks_dev_map, local.strg_vsi_ips_8_disks_dev_map, local.strg_vsi_ips_9_disks_dev_map, local.strg_vsi_ips_10_disks_dev_map, local.strg_vsi_ips_11_disks_dev_map, local.strg_vsi_ips_12_disks_dev_map, local.strg_vsi_ips_13_disks_dev_map, local.strg_vsi_ips_14_disks_dev_map, local.strg_vsi_ips_15_disks_dev_map))
}
