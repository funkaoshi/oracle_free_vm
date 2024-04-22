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

variable "instance_ocpus" { default = 1 }

variable "instance_shape_config_memory_in_gbs" { default = 1 }

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
      max = "80"
      min = "80"
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "443"
      min = "443"
    }
  }
}

/* Instances */

data "oci_core_vnic_attachments" "app_vnics" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domain.ad.name
  instance_id         = oci_core_instance.alwaysfree_instance.id
}

data "oci_core_vnic" "app_vnic" {
  vnic_id = data.oci_core_vnic_attachments.app_vnics.vnic_attachments[0]["vnic_id"]
}

# See https://docs.oracle.com/iaas/images/
data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "alwaysfree_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  shape               = var.instance_shape
  display_name        = "Always Free Instance"

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
    source_id   = lookup(data.oci_core_images.ubuntu_images.images[0], "id")
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }
}

resource "oci_core_instance" "strigil_instance" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  shape               = "VM.Standard.A1.Flex"
  display_name        = "Strigil"

  shape_config {
    ocpus = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.alwaysfree_subnet.id
    display_name     = "strigilvnic"
    assign_public_ip = true
    hostname_label   = "strigil"
  }

  source_details {
    source_type = "image"
    source_id   = "ocid1.image.oc1.ca-toronto-1.aaaaaaaaajux5ratvhucoke2kdhjf4awfmhmrbsendcd34lbwjwybmodow6q"
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }
}

output "worker_node_ip" {
    description = "IP of VM Instance"
    value = oci_core_instance.alwaysfree_instance.public_ip
}
output "strigil_node_ip" {
    description = "IP of Ampere Instance"
    value = oci_core_instance.strigil_instance.public_ip
}