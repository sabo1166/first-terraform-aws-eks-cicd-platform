variable "name" {
  description = "Name prefix for VPC resources."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for Kubernetes subnet discovery tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones; subnet lists are matched to these by index."
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDRs, one per availability zone."
  type        = list(string)

  validation {
    condition     = length(var.public_subnets) == length(var.availability_zones)
    error_message = "public_subnets must have the same number of entries as availability_zones."
  }
}

variable "private_subnets" {
  description = "Private subnet CIDRs, one per availability zone."
  type        = list(string)

  validation {
    condition     = length(var.private_subnets) == length(var.availability_zones)
    error_message = "private_subnets must have the same number of entries as availability_zones."
  }
}
