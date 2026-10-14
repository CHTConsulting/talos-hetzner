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

  # Minimal cloud-init: single shell script with logging so we can debug.
  # No `package_update`, no `iptables-persistent` (debconf hang risk).
  # NAT rule is re-applied on every boot by a systemd oneshot.
  subnet_router_user_data = [for i in range(local.subnet_router_count) : <<-EOT
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
      # HA pair only: the token lets the survivor move the egress route.
      - path: /etc/router-failover/token
        permissions: '0600'
        content: "${local.subnet_router_ha_token}"
      - path: /usr/local/bin/router-failover.sh
        permissions: '0755'
        content: |
          #!/bin/bash
          # Keeps the cluster's 0.0.0.0/0 route on a live router. Each router of
          # the HA pair pings the other; when the one the route points at stops
          # answering, the survivor moves the route to itself through the
          # Hetzner API. No automatic fail-back: the route stays where it works.
          set -u
          SELF='${local.subnet_router_ipv4s[i]}'
          PEER='${local.subnet_router_ipv4s[1 - i]}'
          API='https://api.hetzner.cloud/v1/networks/${local.hcloud_network_id}'
          TOKEN="$(cat /etc/router-failover/token)"
          FAILS=0
          log() { echo "$(date -u +%FT%TZ) $*"; }
          gateway() {
            curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" "$API" |
              python3 -c 'import json,sys; r=[x["gateway"] for x in json.load(sys.stdin)["network"]["routes"] if x["destination"]=="0.0.0.0/0"]; print(r[0] if r else "-")'
          }
          route() { # route <add_route|delete_route> <gateway>, retried while the network is locked
            for _ in 1 2 3 4 5 6 7 8 9 10; do
              curl -fsS --max-time 10 -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
                -d "{\"destination\":\"0.0.0.0/0\",\"gateway\":\"$2\"}" "$API/actions/$1" >/dev/null && return 0
              sleep 3
            done
            return 1
          }
          log "watching $PEER from $SELF"
          while true; do
            if ping -c1 -W2 "$PEER" >/dev/null 2>&1; then FAILS=0; sleep 5; continue; fi
            FAILS=$((FAILS + 1))
            log "peer $PEER missed a ping ($FAILS/3)"
            if [ "$FAILS" -lt 3 ]; then sleep 5; continue; fi
            if ! GW="$(gateway)"; then log "cannot read the network from the API"; sleep 10; continue; fi
            if [ "$GW" = "$PEER" ] || [ "$GW" = "-" ]; then
              log "taking over 0.0.0.0/0 (was: $GW)"
              { [ "$GW" = "-" ] || route delete_route "$PEER"; } && route add_route "$SELF" &&
                log "egress route now points at $SELF" || log "takeover failed, will retry"
            fi
            # Already ours: the peer is dead but nothing to do — ask the API less often.
            if [ "$GW" = "$SELF" ]; then sleep 30; else sleep 10; fi
          done
      - path: /etc/systemd/system/router-failover.service
        content: |
          [Unit]
          Description=Move the cluster egress route to this router when its peer dies
          After=network-online.target
          Wants=network-online.target
          [Service]
          ExecStart=/usr/local/bin/router-failover.sh
          Restart=always
          RestartSec=10
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
            ip -4 addr show | grep -q 'inet ${local.subnet_router_ipv4s[i]}/' && break || sleep 1
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
            --hostname='${local.subnet_router_names[i]}' \
            --accept-dns=false \
            --ssh

          tailscale status

          # node_exporter on the private IP only — the cluster scrapes it over
          # the Hetzner network. Best effort: a failed install must not take
          # down routing, which is already up at this point.
          if [ "${var.subnet_router_node_exporter_enabled}" != "true" ]; then
            echo "node_exporter disabled (subnet_router_node_exporter_enabled = false)"
          elif DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update &&
             DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y prometheus-node-exporter; then
            echo 'ARGS="--web.listen-address=${local.subnet_router_ipv4s[i]}:9100"' > /etc/default/prometheus-node-exporter
            mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
            printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n[Service]\nRestart=always\nRestartSec=5\n' \
              > /etc/systemd/system/prometheus-node-exporter.service.d/override.conf
            systemctl daemon-reload
            systemctl restart prometheus-node-exporter
          else
            echo "WARN: prometheus-node-exporter install failed; routing is unaffected"
          fi
          if [ "${var.subnet_router_ha_enabled}" = "true" ]; then
            systemctl daemon-reload
            systemctl enable --now router-failover.service
          fi
          echo "=== $(date -u +%FT%TZ) bootstrap complete ==="
          touch /var/log/setup-tailscale.done
    runcmd:
      - /usr/local/bin/setup-tailscale.sh
  EOT
  ]
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
