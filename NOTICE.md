# Provenance

This module is a modified fork of
[hcloud-k8s/terraform-hcloud-kubernetes](https://github.com/hcloud-k8s/terraform-hcloud-kubernetes)
(MIT license — see `LICENSE`), branched from upstream **5.10.0** with the
upstream history kept, so later upstream releases merge in with `git merge`.
It is trimmed down to the features we use and extended where our setup
demanded it. It is the exact module the book *Talos, Flux and Two Clusters*
deploys with.

Removed relative to upstream:

- Longhorn, ingress-nginx (with its ingress load balancers and their rDNS),
  cert-manager and the cert-manager Hetzner DNS webhook.
- Sponsor workflow, funding file and issue templates.

Added or changed relative to upstream:

- **Tailscale subnet router** (`subnet_router.tf`) — an optional Hetzner VM
  that joins the tailnet, advertises the cluster's private CIDR, and provides
  outbound NAT for fully-private clusters (`subnet_router_enabled`,
  `cluster_egress_via_subnet_router`), with its firewall rules (Tailscale
  UDP/41641, optional SSH) and output.
- Fully-private nodes (`talos_public_ipv4_enabled = false`): egress via the
  subnet router adds a default route through the network gateway to
  upstream's private-mode boot configuration.
- `kubelet-csr-approver`, `kube_api_env`, `kube_api_extra_certificate_sans`,
  `talos_extra_certificate_sans`, `talos_endpoint_override`,
  `talos_synchronize_manifests_enabled`, hcloud-csi metrics with a
  ServiceMonitor, and the `kube_api_host` / `kube_api_url` outputs.
- Inline manifests are joined without empty documents, so a disabled part
  never renders a literal `null` YAML document that crashes
  `talosctl upgrade-k8s`.
- Talos 1.14 support: from `talos_version` 1.14 on, the machine configuration
  patches target the new per-component documents (`KubeletConfig`,
  `KubeNodeConfig`, `KubeNetworkConfig`, `KubeAPIServerConfig`,
  `UnattendedInstallConfig`, ...) instead of the deprecated `v1alpha1` fields;
  1.13 keeps the `v1alpha1` patches unchanged.
- Defaults: Talos v1.13.10 (talos provider 0.12.0), Kubernetes v1.36.3 with a
  matching Cluster Autoscaler, Cilium Gateway API enabled.

The upstream README (`README.md`) documents the module's full surface; the
book's chapter 2 documents the subset this package actually uses.

Canonical home of this fork (updates land there first):
<https://github.com/CHTConsulting/talos-hetzner>.
