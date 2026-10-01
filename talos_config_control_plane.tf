locals {
  talos_allow_scheduling_on_control_planes = coalesce(var.cluster_allow_scheduling_on_control_planes, (local.worker_sum + local.cluster_autoscaler_max_sum) == 0)

  kube_api_oidc_configuration = var.oidc_enabled ? {
    "oidc-issuer-url"     = var.oidc_issuer_url
    "oidc-client-id"      = var.oidc_client_id
    "oidc-username-claim" = var.oidc_username_claim
    "oidc-groups-claim"   = var.oidc_groups_claim
    "oidc-groups-prefix"  = var.oidc_groups_prefix
  } : {}

  # Kubernetes Manifests for Talos
  # kubelet-csr-approver goes early so kubelet serving certs are signed before
  # anything scrapes :10250 (metrics-server, Hubble).
  talos_inline_manifests = concat(
    [local.hcloud_secret_manifest],
    local.kubelet_csr_approver_manifest != null ? [local.kubelet_csr_approver_manifest] : [],
    local.cilium_manifest != null ? [local.cilium_manifest] : [],
    local.talos_ccm_manifest != null ? [local.talos_ccm_manifest] : [],
    local.hcloud_ccm_manifest != null ? [local.hcloud_ccm_manifest] : [],
    local.hcloud_csi_manifest != null ? [local.hcloud_csi_manifest] : [],
    local.talos_backup_manifest != null ? [local.talos_backup_manifest] : [],
    local.metrics_server_manifest != null ? [local.metrics_server_manifest] : [],
    local.cluster_autoscaler_manifest != null ? [local.cluster_autoscaler_manifest] : [],
    var.talos_extra_inline_manifests != null ? var.talos_extra_inline_manifests : [],
    local.rbac_manifest != null ? [local.rbac_manifest] : [],
    local.oidc_manifest != null ? [local.oidc_manifest] : []
  )
  talos_manifests = concat(
    var.prometheus_operator_crds_enabled ? [
      "https://github.com/prometheus-operator/prometheus-operator/releases/download/${var.prometheus_operator_crds_version}/stripped-down-crds.yaml"
    ] : [],
    var.gateway_api_crds_enabled ? [
      "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_crds_version}/${var.gateway_api_crds_release_channel}-install.yaml"
    ] : [],
    var.talos_extra_remote_manifests != null ? var.talos_extra_remote_manifests : []
  )

  # Control-plane component settings, rendered in either config format
  control_plane_kube_api_extra_args = merge(
    { "enable-aggregator-routing" = true },
    local.kube_api_oidc_configuration,
    var.kube_api_extra_args
  )
  control_plane_kube_api_image_url = var.kubernetes_apiserver_image != null ? "${var.kubernetes_apiserver_image}:${var.kubernetes_version}" : null
  control_plane_controller_manager_extra_args = {
    "cloud-provider" = "external"
    "bind-address"   = "0.0.0.0"
  }
  control_plane_controller_manager_image_url = var.kubernetes_controller_manager_image != null ? "${var.kubernetes_controller_manager_image}:${var.kubernetes_version}" : null
  control_plane_scheduler_extra_args = {
    "bind-address" = "0.0.0.0"
  }
  control_plane_scheduler_image_url = var.kubernetes_scheduler_image != null ? "${var.kubernetes_scheduler_image}:${var.kubernetes_version}" : null

  # Settings that stay in v1alpha1 on every Talos version
  control_plane_common_v1alpha1_config = {
    machine = {
      features = {
        kubernetesTalosAPIAccess = {
          enabled = true
          allowedRoles = [
            "os:reader",
            "os:etcd:backup"
          ]
          allowedKubernetesNamespaces = ["kube-system"]
        }
      }
    }
    cluster = {
      etcd = merge(
        {
          advertisedSubnets = [hcloud_network_subnet.control_plane.ip_range]
          extraArgs = {
            "listen-metrics-urls" = "http://0.0.0.0:2381"
          }
        },
        var.kubernetes_etcd_image != null ? {
          image = var.kubernetes_etcd_image
        } : {}
      )
      adminKubeconfig = {
        certLifetime = "87600h"
      }
      inlineManifests = local.talos_inline_manifests
      externalCloudProvider = {
        enabled   = true
        manifests = local.talos_manifests
      }
    }
  }

  # Per-node kubelet registration
  control_plane_node_labels = {
    for name, node in hcloud_server.control_plane : name => merge(
      local.talos_allow_scheduling_on_control_planes ? { "node.kubernetes.io/exclude-from-external-load-balancers" = { "$patch" = "delete" } } : {},
      local.control_plane_nodepools_map[node.labels.nodepool].labels,
      { "nodeid" = tostring(node.id) }
    )
  }
  control_plane_node_taints = {
    for name, node in hcloud_server.control_plane : name => {
      for taint in local.control_plane_nodepools_map[node.labels.nodepool].taints : taint.key => "${taint.value}:${taint.effect}"
    }
  }
  control_plane_kubelet_config = {
    for name, node in hcloud_server.control_plane : name => merge(
      {
        registerWithTaints = local.control_plane_nodepools_map[node.labels.nodepool].taints
        systemReserved = {
          cpu               = "250m"
          memory            = "300Mi"
          ephemeral-storage = "1Gi"
        }
        kubeReserved = {
          cpu               = "250m"
          memory            = "350Mi"
          ephemeral-storage = "1Gi"
        }
      },
      var.kubernetes_kubelet_extra_config
    )
  }

  # Talos < 1.14
  control_plane_v1alpha1_config_patches = {
    for name, node in hcloud_server.control_plane : name => [{
      machine = merge(local.control_plane_common_v1alpha1_config.machine, {
        nodeLabels      = local.control_plane_node_labels[name]
        nodeAnnotations = local.control_plane_nodepools_map[node.labels.nodepool].annotations
        nodeTaints      = local.control_plane_node_taints[name]
        kubelet = {
          extraConfig = local.control_plane_kubelet_config[name]
        }
      })
      cluster = merge(local.control_plane_common_v1alpha1_config.cluster, {
        allowSchedulingOnControlPlanes = local.talos_allow_scheduling_on_control_planes
        coreDNS = {
          disabled = !var.talos_coredns_enabled
        }
        apiServer = merge(
          {
            admissionControl = var.kube_api_admission_control
            certSANs         = local.talos_certificate_san
            extraArgs        = local.control_plane_kube_api_extra_args
          },
          local.control_plane_kube_api_image_url != null ? { image = local.control_plane_kube_api_image_url } : {},
          length(var.kube_api_env) > 0 ? { env = var.kube_api_env } : {}
        )
        controllerManager = merge(
          { extraArgs = local.control_plane_controller_manager_extra_args },
          local.control_plane_controller_manager_image_url != null ? { image = local.control_plane_controller_manager_image_url } : {}
        )
        scheduler = merge(
          { extraArgs = local.control_plane_scheduler_extra_args },
          local.control_plane_scheduler_image_url != null ? { image = local.control_plane_scheduler_image_url } : {}
        )
      })
    }]
  }

  # Talos >= 1.14: the same settings as documents
  control_plane_document_config_patches = {
    for name, node in hcloud_server.control_plane : name => concat(
      [
        local.control_plane_common_v1alpha1_config,
        {
          apiVersion  = "v1alpha1"
          kind        = "KubeNodeConfig"
          labels      = local.control_plane_node_labels[name]
          annotations = local.control_plane_nodepools_map[node.labels.nodepool].annotations
          # The generator lists the control-plane NoSchedule taint here
          # explicitly; allowSchedulingOnControlPlanes becomes deleting it.
          taints = merge(
            local.talos_allow_scheduling_on_control_planes ? { "node-role.kubernetes.io/control-plane" = { "$patch" = "delete" } } : {},
            local.control_plane_node_taints[name]
          )
        },
        {
          apiVersion = "v1alpha1"
          kind       = "KubeletConfig"
          config     = local.control_plane_kubelet_config[name]
        },
        {
          apiVersion = "v1alpha1"
          kind       = "KubeCoreDNSConfig"
          enabled    = var.talos_coredns_enabled
        },
        # Cilium kube-proxy replacement: no kube-proxy. Deleting the document
        # is not enough — Talos then falls back to its default and deploys
        # kube-proxy anyway; `enabled: false` is the switch. Control plane only.
        merge(
          {
            apiVersion = "v1alpha1"
            kind       = "KubeProxyConfig"
            enabled    = !var.cilium_kube_proxy_replacement_enabled
          },
          local.talos_proxy_image_url != null ? { image = local.talos_proxy_image_url } : {}
        ),
        merge(
          {
            apiVersion    = "v1alpha1"
            kind          = "KubeAPIServerConfig"
            certExtraSANs = local.talos_certificate_san
            extraArgs     = local.control_plane_kube_api_extra_args
          },
          local.control_plane_kube_api_image_url != null ? { image = local.control_plane_kube_api_image_url } : {},
          length(var.kube_api_env) > 0 ? { env = var.kube_api_env } : {}
        ),
        merge(
          {
            apiVersion = "v1alpha1"
            kind       = "KubeControllerManagerConfig"
            extraArgs  = local.control_plane_controller_manager_extra_args
          },
          local.control_plane_controller_manager_image_url != null ? { image = local.control_plane_controller_manager_image_url } : {}
        ),
        merge(
          {
            apiVersion = "v1alpha1"
            kind       = "KubeSchedulerConfig"
            extraArgs  = local.control_plane_scheduler_extra_args
          },
          local.control_plane_scheduler_image_url != null ? { image = local.control_plane_scheduler_image_url } : {}
        )
      ],
      # One document per admission plugin, merged by name into the generated ones
      [for plugin in var.kube_api_admission_control : {
        apiVersion    = "v1alpha1"
        kind          = "KubeAdmissionControlConfig"
        name          = plugin.name
        configuration = plugin.configuration
      }]
    )
  }

  # Control Plane Config
  control_plane_talos_config_patches = {
    for name, node in hcloud_server.control_plane : name => concat(
      [for p in local.control_plane_document_config_patches[name] : p if local.talos_config_documents],
      [for p in local.control_plane_v1alpha1_config_patches[name] : p if !local.talos_config_documents],
      [
        {
          apiVersion = "v1alpha1"
          kind       = "HostnameConfig"
          hostname   = name
          auto       = "off"
        }
      ],
      local.control_plane_public_vip_ipv4_enabled ? [{
        apiVersion = "v1alpha1"
        kind       = "HCloudVIPConfig"
        name       = local.control_plane_public_vip_ipv4
        link       = local.talos_public_link_name
        apiToken   = var.hcloud_token
      }] : [],
      var.control_plane_private_vip_ipv4_enabled ? [{
        apiVersion = "v1alpha1"
        kind       = "HCloudVIPConfig"
        name       = local.control_plane_private_vip_ipv4
        link       = local.talos_private_link_name
        apiToken   = var.hcloud_token
      }] : []
    )
  }
}

data "talos_machine_configuration" "control_plane" {
  for_each = toset(keys(hcloud_server.control_plane))

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_internal
  kubernetes_version = var.kubernetes_version
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    [for patch in local.talos_cloud_config_patches : yamlencode(patch)],
    [for patch in local.control_plane_talos_config_patches[each.key] : yamlencode(patch)],
    [for patch in var.control_plane_config_patches : yamlencode(patch)]
  )

  lifecycle {
    precondition {
      condition     = !local.talos_config_documents || length(var.talos_kubelet_extra_mounts) == 0
      error_message = "talos_kubelet_extra_mounts is not supported from Talos 1.14 on: its KubeletConfig document has no extraMounts field. Remove the mounts or stay on Talos 1.13."
    }
    precondition {
      condition     = !local.talos_config_documents || !var.talos_discovery_kubernetes_enabled
      error_message = "talos_discovery_kubernetes_enabled is not supported from Talos 1.14 on: the Kubernetes discovery registry has no DiscoveryServiceConfig equivalent. Use talos_discovery_service_enabled or stay on Talos 1.13."
    }
  }
}
