locals {
  subnet_router_location = coalesce(
    var.subnet_router_location,
    length(local.control_plane_nodepools) > 0 ? local.control_plane_nodepools[0].location : null
  )

  # Auto-derive subnet/IP from network_ipv4_cidr so flipping the network CIDR
  # (e.g., 10.0.0.0/16 → 10.1.0.0/16 for a second cluster in the same tailnet)
  # is a one-variable change in the consumer.
  subnet_router_subnet_ipv4_cidr = coalesce(
    var.subnet_router_subnet_ipv4_cidr,
    cidrsubnet(var.network_ipv4_cidr, 8, 0)
  )
  subnet_router_ipv4 = coalesce(
    var.subnet_router_ipv4,
    cidrhost(local.subnet_router_subnet_ipv4_cidr, 10)
  )

  # HA pair: a second router at .11 that watches the first (and vice versa).
  subnet_router_count    = var.subnet_router_enabled ? (var.subnet_router_ha_enabled ? 2 : 1) : 0
  subnet_router_ipv4s    = [local.subnet_router_ipv4, cidrhost(local.subnet_router_subnet_ipv4_cidr, 11)]
  subnet_router_names    = ["ts-router-${var.cluster_name}", "ts-router-${var.cluster_name}-b"]
  subnet_router_ha_token = var.subnet_router_ha_enabled ? coalesce(var.subnet_router_ha_hcloud_token, var.hcloud_token) : ""

  # The router runs NixOS, declared in templates/subnet-router.nix.tftpl. Hetzner
  # has no NixOS image, so the VM boots the Ubuntu base image once and
  # nixos-infect (pinned by commit and hash) converts it in place, then
  # reboots into NixOS. cloud-init only drops files and starts the conversion;
  # everything the router does lives in the Nix file.
  subnet_router_nixos_infect_url    = "https://raw.githubusercontent.com/elitak/nixos-infect/40f62a680bb0e8f2f607d79abfaaecd99d59401c/nixos-infect"
  subnet_router_nixos_infect_sha256 = "4354bd68773b41da65c0e815202c43c8549713b3ed3ff6381c71fbc0b0a840ab"

  subnet_router_nix = [for i in range(local.subnet_router_count) : templatefile("${path.module}/templates/subnet-router.nix.tftpl", {
    cidr          = var.network_ipv4_cidr
    hostname      = local.subnet_router_names[i]
    self_ip       = local.subnet_router_ipv4s[i]
    peer_ip       = local.subnet_router_ipv4s[1 - i]
    network_id    = local.hcloud_network_id
    ha            = var.subnet_router_ha_enabled ? "true" : "false"
    node_exporter = var.subnet_router_node_exporter_enabled ? "true" : "false"
  })]

  subnet_router_user_data = [for i in range(local.subnet_router_count) : join("\n", [
    "#cloud-config",
    yamlencode({
      write_files = [
        { path = "/etc/nixos/router.nix", permissions = "0644", content = local.subnet_router_nix[i] },
        { path = "/etc/nixos/secrets/ts-authkey", permissions = "0600", content = coalesce(var.subnet_router_tailscale_authkey, "MISSING") },
        { path = "/etc/nixos/secrets/hcloud-token", permissions = "0600", content = local.subnet_router_ha_token },
      ]
      runcmd = [
        # Our network config is plain DHCP (router.nix); without this file
        # nixos-infect would write a static one that lacks the private route.
        "rm -f /etc/hetzner-build",
        "curl -fsSL -o /root/nixos-infect ${local.subnet_router_nixos_infect_url}",
        # Runs only if the script is exactly the pinned one; reboots into NixOS.
        "echo '${local.subnet_router_nixos_infect_sha256}  /root/nixos-infect' | sha256sum -c - && PROVIDER=hetznercloud-dhcp NIX_CHANNEL=nixos-25.11 NIXOS_IMPORT=./router.nix bash /root/nixos-infect > /var/log/nixos-infect.log 2>&1",
      ]
    })
  ])]
}

resource "hcloud_network_subnet" "subnet_router" {
  count = var.subnet_router_enabled ? 1 : 0

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone
  ip_range     = local.subnet_router_subnet_ipv4_cidr
}

resource "hcloud_server" "subnet_router" {
  count = local.subnet_router_count

  name        = local.subnet_router_names[count.index]
  image       = var.subnet_router_image
  server_type = var.subnet_router_server_type
  location    = local.subnet_router_location
  user_data   = local.subnet_router_user_data[count.index]
  ssh_keys    = [hcloud_ssh_key.this.id]

  network {
    network_id = local.hcloud_network_id
    ip         = local.subnet_router_ipv4s[count.index]
  }

  firewall_ids = [local.firewall_id]

  labels = {
    cluster = var.cluster_name
    role    = "subnet-router"
  }

  depends_on = [hcloud_network_subnet.subnet_router]

  # cloud-init only runs at first boot, so a changed script would do nothing
  # but replace a running router and cut the tailnet path and cluster egress.
  lifecycle {
    ignore_changes = [user_data, image]
  }
}

# Route 0.0.0.0/0 through the subnet router for fully-private clusters. The
# subnet router cloud-init always installs iptables MASQUERADE, so when this
# route exists, cluster nodes (without their own public IPs) egress via the
# router's public NIC.
resource "hcloud_network_route" "egress" {
  count = var.cluster_egress_via_subnet_router ? 1 : 0

  network_id  = local.hcloud_network_id
  destination = "0.0.0.0/0"
  gateway     = local.subnet_router_ipv4

  # With subnet_router_ha_enabled the surviving router moves this route to
  # itself; Terraform must not move it back to a router that may be dead.
  lifecycle {
    ignore_changes = [gateway]
  }

  # Route must be created AFTER all subnets in the network. Hetzner can interpret
  # a 0.0.0.0/0 route as "covering" any subnet range and refuse to create new
  # subnets afterwards. Serialize: all subnets → server → route.
  depends_on = [
    hcloud_server.subnet_router,
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer,
    hcloud_network_subnet.worker_shared,
    hcloud_network_subnet.worker,
    hcloud_network_subnet.cluster_autoscaler_shared,
    hcloud_network_subnet.cluster_autoscaler,
    hcloud_network_subnet.autoscaler,
  ]
}
