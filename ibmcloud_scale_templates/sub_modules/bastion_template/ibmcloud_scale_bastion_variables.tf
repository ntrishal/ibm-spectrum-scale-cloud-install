variable "region" {
  /* Keep it empty, it will be propagated via command line or via ".tfvars"
       or ".tfvars.json"
    */
  type        = string
  description = "IBM Cloud region where the resources will be created."
}

variable "ibmcloud_api_key" {
  /* Keep it empty, it will be propagated via command line or via ".tfvars"
       or ".tfvars.json"
    */
  type        = string
  description = "IBM Cloud api key."
}

variable "compute_generation" {
  /* Keep it empty, it will be propagated via command line or via ".tfvars"
       or ".tfvars.json"
    */
  type        = string
  default     = 2
  description = "IBM Cloud compute generation."
}

variable "stack_name" {
  /* Keep it empty, it will be propagated via command line or via ".tfvars"
       or ".tfvars.json"
    */
  type        = string
  default     = "spectrum-scale"
  description = "IBM Cloud stack name (keep all lower case)."
}

variable "vpc_id" {
  type        = string
  description = "IBM Cloud VPC ID."
}

variable "bastion_incoming_remote" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Bastion security group inbound remote."
}

variable "bastion_osimage_name" {
  type        = string
  default     = "ibm-ubuntu-18-04-1-minimal-amd64-2"
  description = "Bastion OS image name."
}

variable "bastion_vsi_profile" {
  type        = string
  default     = "cx2-2x4"
  description = "Profile to be used for Bastion virtual server instance."
}

variable "bastion_key_name" {
  type        = string
  description = "SSH key name to be used for Bastion virtual server instance."
}

variable "bastion_subnet_id" {
  type        = list(string)
  description = "Subnet id to be used for Bastion virtual server instance."
}

variable "zones" {
  /* Keep it empty, it will be propagated via command line or via ".tfvars"
       or ".tfvars.json"
    */
  type        = list(string)
  description = "IBM Cloud zone names."
}
