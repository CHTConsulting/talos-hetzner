# Offline harness for the machine-configuration patches.
#
# run.sh copies the module's talos_config_*.tf and variables.tf next to this
# file. Everything those files reference outside themselves is stubbed here:
# hcloud resources come from a mocked provider, the rest are fixed locals that
# describe a small private cluster (one control plane, one worker, one
# autoscaler pool). The talos provider is real, so the rendered configs are
# exactly what a node would receive.
#
# When the module starts referencing a new local or resource from these
# files, `terraform test` fails with "Reference to undeclared ..." — add a
# stub below.
terraform {
  required_providers {
    talos  = { source = "siderolabs/talos", version = "0.12.0" }
    hcloud = { source = "hetznercloud/hcloud", version = "1.69.0" }
  }
}

resource "hcloud_server" "control_plane" {
  for_each    = toset(["prd-control-1"])
  name        = each.key
  server_type = "cx23"
  labels      = { nodepool = "control" }
}
resource "hcloud_server" "worker" {
  for_each    = toset(["prd-worker-1"])
  name        = each.key
  server_type = "cx43"
  labels      = { nodepool = "worker" }
}
resource "hcloud_network_subnet" "control_plane" {
  network_id   = 1
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.64.0/25"
}
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  talos_version_parts    = regex("^v?(?P<major>[0-9]+)\\.(?P<minor>[0-9]+)\\.(?P<patch>[0-9]+)", var.talos_version)
  talos_config_documents = tonumber(local.talos_version_parts.major) > 1 || tonumber(local.talos_version_parts.minor) >= 14

  control_plane_nodepools_map      = { control = { labels = { pool = "control" }, annotations = {}, taints = [] } }
  worker_nodepools_map             = { worker = { labels = { pool = "worker" }, annotations = { a = "b" }, taints = [{ key = "dedicated", value = "db", effect = "NoSchedule" }] } }
  bare_metal_nodepools_map         = {}
  bare_metal_servers               = {}
  bare_metal_server_public_network = {}
  cluster_autoscaler_nodepools     = [{ name = "auto", labels = { pool = "auto" }, annotations = {}, taints = [] }]
  cluster_autoscaler_max_sum       = 2
  worker_sum                       = 1
  bare_metal_enabled               = false

  kube_api_url_internal                 = "https://10.0.64.126:6443"
  control_plane_private_ipv4_list       = ["10.0.64.1"]
  control_plane_public_ipv4_list        = []
  control_plane_public_ipv6_list        = []
  control_plane_private_vip_ipv4        = "10.0.64.126"
  control_plane_public_vip_ipv4         = null
  control_plane_public_vip_ipv4_enabled = false
  kube_api_load_balancer_private_ipv4   = null
  kube_api_load_balancer_public_ipv4    = null
  kube_api_load_balancer_public_ipv6    = null
  kube_api_private_ipv4                 = "10.0.64.126"

  network_node_ipv4_cidr              = "10.0.64.0/18"
  network_pod_ipv4_cidr               = "10.0.128.0/17"
  network_service_ipv4_cidr           = "10.0.96.0/19"
  network_ipv4_cidr                   = "10.0.0.0/16"
  network_ipv4_gateway                = "10.0.0.1"
  network_public_ipv4_enabled         = false
  network_public_ipv6_enabled         = false
  network_bare_metal_shared_ipv4_cidr = "10.0.200.0/24"
  network_pinned_worker_ipv4_cidrs    = {}
  hcloud_vswitch_vlan_id              = 4000

  talos_cloud_installer_image_url = "factory.talos.dev/hcloud-installer/abc:${var.talos_version}"

  hcloud_secret_manifest        = { name = "hcloud-secret", contents = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: hcloud\n  namespace: kube-system\n" }
  kubelet_csr_approver_manifest = null
  cilium_manifest               = null
  talos_ccm_manifest            = null
  hcloud_ccm_manifest           = null
  hcloud_csi_manifest           = null
  talos_backup_manifest         = null
  metrics_server_manifest       = null
  cluster_autoscaler_manifest   = null
  rbac_manifest                 = null
  oidc_manifest                 = null
}

resource "terraform_data" "cfg" {
  for_each = nonsensitive(toset(concat(
    [for k in keys(data.talos_machine_configuration.control_plane) : "cp-${k}"],
    [for k in keys(data.talos_machine_configuration.worker) : "w-${k}"],
    [for k in keys(data.talos_machine_configuration.cluster_autoscaler) : "as-${k}"],
  )))
  provisioner "local-exec" {
    command = "mkdir -p '${var.out_dir}' && printf '%s' \"$CFG\" > '${var.out_dir}/${each.key}.yaml'"
    environment = {
      CFG = (
        startswith(each.key, "cp-") ? data.talos_machine_configuration.control_plane[trimprefix(each.key, "cp-")].machine_configuration :
        startswith(each.key, "w-") ? data.talos_machine_configuration.worker[trimprefix(each.key, "w-")].machine_configuration :
        data.talos_machine_configuration.cluster_autoscaler[trimprefix(each.key, "as-")].machine_configuration
      )
    }
  }
}
variable "out_dir" { type = string }
