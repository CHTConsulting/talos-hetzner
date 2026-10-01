locals {
  # Talos and Kubernetes Certificates
  talos_certificate_san = sort(
    distinct(
      compact(
        concat(
          # Virtual IPs
          var.control_plane_public_vip_ipv4_enabled ? [local.control_plane_public_vip_ipv4] : [],
          [local.control_plane_private_vip_ipv4],
          # Load Balancer IPs
          [
            local.kube_api_load_balancer_private_ipv4,
            local.kube_api_load_balancer_public_ipv4,
            local.kube_api_load_balancer_public_ipv6
          ],
          # Control Plane Node IPs
          local.control_plane_private_ipv4_list,
          local.control_plane_public_ipv4_list,
          local.control_plane_public_ipv6_list,
          # Other Addresses
          [var.kube_api_hostname],
          ["127.0.0.1", "::1", "localhost"],
          # User-supplied extras (e.g., Tailscale IPs, alternate hostnames)
          var.talos_extra_certificate_sans,
          var.kube_api_extra_certificate_sans,
        )
      )
    )
  )

  # Interface Configuration
  talos_public_interface_enabled = var.talos_public_ipv4_enabled || var.talos_public_ipv6_enabled
  talos_public_link_name         = "eth0"
  talos_private_link_name        = local.talos_public_interface_enabled ? "eth1" : "eth0"

  talos_cloud_metadata_ipv4_cidr  = "169.254.169.254/32"
  talos_cloud_public_ipv4_gateway = "172.31.1.1"

  # Routes
  # Note: Default route (0.0.0.0/0) omits the 'network' key per Talos routing config requirements
  # See https://github.com/siderolabs/talos/issues/12521
  # Egress through the subnet router needs a default route via the network
  # gateway; the Hetzner network's own 0.0.0.0/0 route then forwards to the router.
  talos_extra_route_cidrs = distinct(concat(
    var.talos_extra_routes,
    var.cluster_egress_via_subnet_router ? ["0.0.0.0/0"] : []
  ))
  talos_extra_routes = [for cidr in local.talos_extra_route_cidrs : merge(
    {
      gateway = local.network_ipv4_gateway
      metric  = 512
    },
    cidr != "0.0.0.0/0" ? { destination = cidr } : {}
  )]

  # DNS Configuration
  talos_host_dns = {
    enabled              = true
    forwardKubeDNSToHost = false
    resolveMemberNames   = true
  }

  # Kubelet extra mounts
  talos_kubelet_extra_mounts = [
    for mount in var.talos_kubelet_extra_mounts : {
      source      = mount.source
      destination = coalesce(mount.destination, mount.source)
      type        = mount.type
      options     = mount.options
    }
  ]

  # Talos Discovery
  talos_discovery_enabled = var.talos_discovery_kubernetes_enabled || var.talos_discovery_service_enabled

  talos_discovery = {
    enabled = local.talos_discovery_enabled
    registries = {
      kubernetes = { disabled = !var.talos_discovery_kubernetes_enabled }
      service    = { disabled = !var.talos_discovery_service_enabled }
    }
  }

  # CRI Configuration
  talos_cri_config_patches = !var.talos_cri_discard_unpacked_layers ? [
    {
      machine = {
        files = [
          {
            path    = "/etc/cri/conf.d/20-customization.part"
            op      = "create"
            content = <<-EOT
              [plugins."io.containerd.cri.v1.images"]
                discard_unpacked_layers = false
            EOT
          }
        ]
      }
    }
  ] : []

  # Public Network Link Config
  talos_cloud_public_link_config_patches = local.talos_public_interface_enabled ? [
    {
      apiVersion = "v1alpha1"
      kind       = "LinkConfig"
      name       = local.talos_public_link_name
      up         = true
      routes = [
        {
          destination = local.talos_cloud_metadata_ipv4_cidr
          gateway     = local.talos_cloud_public_ipv4_gateway
          metric      = 128
        }
      ]
    }
  ] : []

  talos_cloud_public_dhcp_config_patches = local.talos_public_interface_enabled && var.talos_public_ipv4_enabled ? [
    {
      apiVersion = "v1alpha1"
      kind       = "DHCPv4Config"
      name       = local.talos_public_link_name
    }
  ] : []

  # Private Network Link Config
  talos_cloud_private_link_config_patches = [
    {
      apiVersion = "v1alpha1"
      kind       = "LinkConfig"
      name       = local.talos_private_link_name
      up         = true
      mtu        = local.bare_metal_enabled ? 1400 : 1450
      routes     = local.talos_extra_routes
    }
  ]

  talos_cloud_private_dhcp_config_patches = [
    {
      apiVersion = "v1alpha1"
      kind       = "DHCPv4Config"
      name       = local.talos_private_link_name
    }
  ]

  # System Volume Config
  talos_system_volume_encryption = {
    provider = "luks2"
    options  = ["no_read_workqueue", "no_write_workqueue"]
    keys = [{
      nodeID = {}
      slot   = 0
    }]
  }

  talos_system_volume_config_patches = concat(
    var.talos_state_partition_encryption_enabled ? [
      {
        apiVersion = "v1alpha1"
        kind       = "VolumeConfig"
        name       = "STATE"
        encryption = local.talos_system_volume_encryption
      }
    ] : [],
    var.talos_ephemeral_partition_encryption_enabled ? [
      {
        apiVersion = "v1alpha1"
        kind       = "VolumeConfig"
        name       = "EPHEMERAL"
        encryption = local.talos_system_volume_encryption
      }
    ] : []
  )

  # Nameservers
  talos_nameservers = [
    for ns in var.talos_nameservers : ns
    if var.talos_ipv6_enabled || !strcontains(ns, ":")
  ]

  talos_resolver_config_patch = merge(
    {
      apiVersion = "v1alpha1"
      kind       = "ResolverConfig"
      nameservers = [
        for ns in local.talos_nameservers : {
          address = ns
        }
      ]
    },
    # 1.14: .machine.features.hostDNS lives here
    local.talos_config_documents ? { hostDNS = local.talos_host_dns } : {}
  )

  # Static Hosts (/etc/hosts)
  talos_static_hosts = concat(
    var.kube_api_hostname != null ? [
      {
        ip        = local.kube_api_private_ipv4
        hostnames = [var.kube_api_hostname]
      }
    ] : [],
    var.talos_static_hosts
  )

  talos_static_host_config_patches = [
    for ip in distinct([for entry in local.talos_static_hosts : entry.ip]) : {
      apiVersion = "v1alpha1"
      kind       = "StaticHostConfig"
      name       = ip
      hostnames = sort(distinct(flatten([
        for entry in local.talos_static_hosts :
        entry.ip == ip ? entry.hostnames : []
      ])))
    }
  ]

  # NTP
  talos_time_sync_config_patch = {
    apiVersion = "v1alpha1"
    kind       = "TimeSyncConfig"
    ntp = {
      servers = var.talos_ntp_servers
    }
  }

  # Additional trusted CA certificates
  talos_trusted_certs_config_patches = var.talos_certificates != null ? [
    for name, chain in var.talos_certificates : {
      apiVersion = "v1alpha1"
      kind       = "TrustedRootsConfig"
      name       = name
      certificates = join("\n", [
        for cert in(can(tolist(chain)) ? tolist(chain) : [tostring(chain)]) :
        trimspace(cert) if trimspace(cert) != ""
      ])
    }
  ] : []

  # Boot-time machine configuration
  talos_user_data_config_patches = concat(
    [for p in concat(local.talos_cloud_private_link_config_patches, local.talos_cloud_private_dhcp_config_patches) : p if var.cluster_access == "private"],
  )

  talos_user_data = length(local.talos_user_data_config_patches) > 0 ? join("\n---\n", [
    for patch in local.talos_user_data_config_patches : yamlencode(patch)
  ]) : null

  # Kubelet settings shared by every node, in either config format
  talos_kubelet_extra_args = merge(
    {
      "cloud-provider"             = "external"
      "rotate-server-certificates" = true
    },
    var.kubernetes_kubelet_extra_args
  )
  talos_kubelet_config = {
    shutdownGracePeriod             = "90s"
    shutdownGracePeriodCriticalPods = "15s"
  }
  talos_kubelet_image_url = var.kubernetes_kubelet_image != null ? "${var.kubernetes_kubelet_image}:${var.kubernetes_version}" : null
  talos_proxy_image_url   = var.kubernetes_proxy_image != null ? "${var.kubernetes_proxy_image}:${var.kubernetes_version}" : null

  # Settings that stay in v1alpha1 on every Talos version
  talos_common_machine_config = {
    certSANs = local.talos_certificate_san
    kernel = {
      modules = var.talos_kernel_modules
    }
    sysctls = merge(
      {
        "net.core.somaxconn"                 = "65535"
        "net.core.netdev_max_backlog"        = "4096"
        "net.ipv6.conf.default.disable_ipv6" = "${var.talos_ipv6_enabled ? 0 : 1}"
        "net.ipv6.conf.all.disable_ipv6"     = "${var.talos_ipv6_enabled ? 0 : 1}"
      },
      var.talos_sysctls_extra_args
    )
    registries = var.talos_registries
    logging = {
      destinations = var.talos_logging_destinations
    }
  }

  # Talos < 1.14: everything in the v1alpha1 document
  talos_common_v1alpha1_config_patches = [{
    machine = merge(local.talos_common_machine_config, {
      kubelet = merge(
        {
          extraArgs   = local.talos_kubelet_extra_args
          extraConfig = local.talos_kubelet_config
          extraMounts = local.talos_kubelet_extra_mounts
          nodeIP = {
            validSubnets = [local.network_node_ipv4_cidr]
          }
        },
        local.talos_kubelet_image_url != null ? { image = local.talos_kubelet_image_url } : {}
      )
      features = {
        hostDNS = local.talos_host_dns
      }
    })
    cluster = {
      network = {
        dnsDomain      = var.cluster_domain
        podSubnets     = [local.network_pod_ipv4_cidr]
        serviceSubnets = [local.network_service_ipv4_cidr]
        cni            = { name = "none" }
      }
      proxy = merge(
        {
          disabled = var.cilium_kube_proxy_replacement_enabled
        },
        local.talos_proxy_image_url != null ? { image = local.talos_proxy_image_url } : {}
      )
      discovery = local.talos_discovery
    }
  }]

  # Talos >= 1.14: patch the documents the generator now emits. hostDNS went
  # to ResolverConfig (talos_resolver_config_patch). There is no document for
  # kubelet extraMounts or the Kubernetes discovery registry; the
  # control-plane configuration refuses both up front.
  talos_common_document_config_patches = concat(
    [
      { machine = local.talos_common_machine_config },
      merge(
        {
          apiVersion = "v1alpha1"
          kind       = "KubeletConfig"
          extraArgs  = local.talos_kubelet_extra_args
          config     = local.talos_kubelet_config
        },
        local.talos_kubelet_image_url != null ? { image = local.talos_kubelet_image_url } : {}
      ),
      {
        apiVersion = "v1alpha1"
        kind       = "KubeNodeConfig"
        nodeIP = {
          validSubnets = [local.network_node_ipv4_cidr]
        }
      },
      {
        apiVersion     = "v1alpha1"
        kind           = "KubeNetworkConfig"
        dnsDomain      = var.cluster_domain
        podSubnets     = [local.network_pod_ipv4_cidr]
        serviceSubnets = [local.network_service_ipv4_cidr]
      },
      # Cilium is the CNI — drop the generated Flannel document
      {
        apiVersion = "v1alpha1"
        kind       = "KubeFlannelCNIConfig"
        "$patch"   = "delete"
      }
    ],
    # Cilium kube-proxy replacement: no kube-proxy at all
    var.cilium_kube_proxy_replacement_enabled ? [{
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      "$patch"   = "delete"
    }] : [],
    !var.cilium_kube_proxy_replacement_enabled && local.talos_proxy_image_url != null ? [{
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      image      = local.talos_proxy_image_url
    }] : [],
    var.talos_discovery_service_enabled ? [] : [{
      apiVersion = "v1alpha1"
      kind       = "DiscoveryServiceConfig"
      name       = "default"
      "$patch"   = "delete"
    }]
  )

  # Talos Common Config
  talos_common_config_patches = concat(
    [for p in local.talos_common_document_config_patches : p if local.talos_config_documents],
    [for p in local.talos_common_v1alpha1_config_patches : p if !local.talos_config_documents],
    local.talos_system_volume_config_patches,
    [local.talos_resolver_config_patch],
    [local.talos_time_sync_config_patch],
    local.talos_static_host_config_patches,
    local.talos_trusted_certs_config_patches,
    local.talos_cri_config_patches
  )

  talos_cloud_config_patches = concat(
    local.talos_common_config_patches,
    # 1.14 drops install.extraKernelArgs; the args already ride in the
    # image factory schematic behind the installer URL (image.tf). Patching
    # this document drops the generated disk selector, so it is set again:
    # /dev/sda, the disk the v1alpha1 install defaulted to on Hetzner Cloud.
    [for p in [{
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        image = local.talos_cloud_installer_image_url
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"/dev/sda\""
        }
      }
    }] : p if local.talos_config_documents],
    [for p in [{
      machine = {
        install = {
          image           = local.talos_cloud_installer_image_url
          extraKernelArgs = var.talos_extra_kernel_args
        }
      }
    }] : p if !local.talos_config_documents],
    local.talos_cloud_public_link_config_patches,
    local.talos_cloud_public_dhcp_config_patches,
    local.talos_cloud_private_link_config_patches,
    local.talos_cloud_private_dhcp_config_patches
  )
}
