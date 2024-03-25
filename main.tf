// Copyright (c) 2017, 2024, Oracle and/or its affiliates. All rights reserved.
// Licensed under the Mozilla Public License v2.0


provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}

variable "instance_shape" {
  default = "VM.Standard.E2.1.Micro" 
}

variable "instance_ocpus" { default = 4 }

variable "instance_shape_config_memory_in_gbs" { default = 24 }

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = 1
}

/* Network */

resource "oci_core_virtual_network" "alwaysfree_vcn" {
  cidr_block     = "10.1.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "Always Free"
  dns_label      = "alwaysfree"
}

resource "oci_core_subnet" "alwaysfree_subnet" {
  cidr_block        = "10.1.20.0/24"
  display_name      = "Always Free Subnet"
  dns_label         = "alwaysfreesub"
  security_list_ids = [oci_core_security_list.alwaysfree_security_list.id]
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_virtual_network.alwaysfree_vcn.id
  route_table_id    = oci_core_route_table.alwaysfree_route_table.id
  dhcp_options_id   = oci_core_virtual_network.alwaysfree_vcn.default_dhcp_options_id
}

resource "oci_core_internet_gateway" "alwaysfree_internet_gateway" {
  compartment_id = var.compartment_ocid
  display_name   = "testIG"
  vcn_id         = oci_core_virtual_network.alwaysfree_vcn.id
}

resource "oci_core_route_table" "alwaysfree_route_table" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.alwaysfree_vcn.id
  display_name   = "testRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.alwaysfree_internet_gateway.id
  }
}

resource "oci_core_security_list" "alwaysfree_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.alwaysfree_vcn.id
  display_name   = "testSecurityList"

  egress_security_rules {
    protocol    = "6"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "22"
      min = "22"
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "3000"
      min = "3000"
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "3005"
      min = "3005"
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "80"
      min = "80"
    }
  }
}

/* Instances */

resource "oci_core_instance" "alwaysfree_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "Always Free Instance"
  shape               = var.instance_shape

  shape_config {
    ocpus = var.instance_ocpus
    memory_in_gbs = var.instance_shape_config_memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.alwaysfree_subnet.id
    display_name     = "primaryvnic"
    assign_public_ip = true
    hostname_label   = "alwaysfreeinstance"
  }

  source_details {
    source_type = "image"
    source_id   = lookup(data.oci_core_images.alwaysfree_images.images[0], "id")
  }

  metadata = {
    ssh_authorized_keys = (var.ssh_public_key != "") ? var.ssh_public_key : tls_private_key.compute_ssh_key.public_key_openssh
  }
}

resource "tls_private_key" "compute_ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

output "generated_private_key_pem" {
  value     = (var.ssh_public_key != "") ? var.ssh_public_key : tls_private_key.compute_ssh_key.private_key_pem
  sensitive = true
}

resource "tls_private_key" "alwaysfree_private_key" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "alwaysfree_cert" {
  private_key_pem = tls_private_key.alwaysfree_private_key.private_key_pem

  subject {
    organization = "Oracle"
    country = "US"
    locality = "Austin"
    province = "TX"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
    "cert_signing"
  ]

  is_ca_certificate = true
}


data "oci_core_vnic_attachments" "app_vnics" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domain.ad.name
  instance_id         = oci_core_instance.alwaysfree_instance.id
}

data "oci_core_vnic" "app_vnic" {
  vnic_id = data.oci_core_vnic_attachments.app_vnics.vnic_attachments[0]["vnic_id"]
}

# See https://docs.oracle.com/iaas/images/
data "oci_core_images" "alwaysfree_images" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

output "app" {
  value = "http://${data.oci_core_vnic.app_vnic.public_ip_address}"
}
