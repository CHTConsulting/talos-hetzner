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

  # Minimal cloud-init: single shell script with logging so we can debug.
  # No `package_update`, no `iptables-persistent` (debconf hang risk).
  # NAT rule is re-applied on every boot by a systemd oneshot.
  subnet_router_user_data = <<-EOT
    #cloud-config
    write_files:
      # Ubuntu images do not bring up the private-network NIC on their own;
      # without it the router advertises a network it cannot reach.
      - path: /etc/netplan/60-hcloud-private.yaml
        permissions: '0600'
        content: |
          network:
            version: 2
            ethernets:
              hcloud-private:
                match:
                  name: "en*"
                dhcp4: true
      - path: /etc/systemd/system/subnet-router-nat.service
        content: |
          [Unit]
          Description=Configure NAT MASQUERADE for cluster egress
          After=network-online.target
          Wants=network-online.target
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/sbin/iptables -t nat -A POSTROUTING -s ${var.network_ipv4_cidr} ! -d ${var.network_ipv4_cidr} -j MASQUERADE
          ExecStop=/sbin/iptables -t nat -D POSTROUTING -s ${var.network_ipv4_cidr} ! -d ${var.network_ipv4_cidr} -j MASQUERADE
          [Install]
          WantedBy=multi-user.target
      - path: /usr/local/bin/setup-tailscale.sh
        permissions: '0755'
        content: |
          #!/bin/bash
          # Logs to /var/log/setup-tailscale.log — `tail -f` to debug.
          exec > >(tee -a /var/log/setup-tailscale.log) 2>&1
          set -euxo pipefail

          echo "=== $(date -u +%FT%TZ) starting subnet-router bootstrap ==="

          # Private network NIC (netplan file above), then wait for its lease
          netplan apply
          for i in $(seq 1 30); do
            ip -4 addr show | grep -q 'inet ${local.subnet_router_ipv4}/' && break || sleep 1
          done

          # IP forwarding
          cat > /etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
          net.ipv4.ip_forward = 1
          net.ipv6.conf.all.forwarding = 1
          SYSCTL
          sysctl -p /etc/sysctl.d/99-tailscale.conf

          # NAT oneshot
          systemctl daemon-reload
          systemctl enable --now subnet-router-nat.service

          # Install tailscale (idempotent)
          if ! command -v tailscale >/dev/null 2>&1; then
            curl -fsSL https://tailscale.com/install.sh | sh
          fi
          systemctl enable --now tailscaled

          # Wait briefly for the local socket
          for i in $(seq 1 30); do
            tailscale status >/dev/null 2>&1 && break || sleep 1
          done

          tailscale up \
            --auth-key='${coalesce(var.subnet_router_tailscale_authkey, "MISSING")}' \
            --advertise-routes='${var.network_ipv4_cidr}' \
            --hostname='ts-router-${var.cluster_name}' \
            --accept-dns=false \
            --ssh

          tailscale status
          echo "=== $(date -u +%FT%TZ) bootstrap complete ==="
          touch /var/log/setup-tailscale.done
    runcmd:
      - /usr/local/bin/setup-tailscale.sh
  EOT
}

resource "hcloud_network_subnet" "subnet_router" {
  count = var.subnet_router_enabled ? 1 : 0

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone
  ip_range     = local.subnet_router_subnet_ipv4_cidr
}

resource "hcloud_server" "subnet_router" {
  count = var.subnet_router_enabled ? 1 : 0

  name        = "ts-router-${var.cluster_name}"
  image       = var.subnet_router_image
  server_type = var.subnet_router_server_type
  location    = local.subnet_router_location
  user_data   = local.subnet_router_user_data
  ssh_keys    = [hcloud_ssh_key.this.id]

  network {
    network_id = local.hcloud_network_id
    ip         = local.subnet_router_ipv4
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
