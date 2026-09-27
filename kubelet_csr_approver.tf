# Kubelet CSR Approver
#
# Talos sets `rotate-server-certificates = true` on kubelets — every node
# requests a `kubernetes.io/kubelet-serving` cert via CSR. Kubernetes does NOT
# auto-approve those (a malicious node could request a cert for arbitrary
# names), so the CSR sits Pending and the kubelet keeps using a self-signed
# default that nothing else in the cluster trusts. Result: `kubectl logs`,
# `kubectl exec`, metrics-server, Hubble logs etc. all fail with
# `remote error: tls: internal error`.
#
# This deployment validates that:
#   1. The CSR CN matches `providerRegex` (i.e., a node belonging to this
#      cluster), and
#   2. The IP SANs in the CSR fall within `providerIpPrefixes`.
# When both checks pass, the CSR is approved and signed by the cluster CA.
data "helm_template" "kubelet_csr_approver" {
  count = var.kubelet_csr_approver_enabled ? 1 : 0

  name      = "kubelet-csr-approver"
  namespace = "kube-system"

  repository   = var.kubelet_csr_approver_helm_repository
  chart        = var.kubelet_csr_approver_helm_chart
  version      = var.kubelet_csr_approver_helm_version
  kube_version = var.kubernetes_version

  # Exclude the chart's `helm test` connection Pod — Talos tries to apply
  # it during synchronize_manifests and errors with
  # "Pod/kubelet-csr-approver-test-connection namespace not specified".
  skip_tests = true

  values = [
    yamlencode({
      providerRegex       = coalesce(var.kubelet_csr_approver_provider_regex, "^${var.cluster_name}-.+$")
      providerIpPrefixes  = coalesce(var.kubelet_csr_approver_provider_ip_prefixes, [var.network_ipv4_cidr])
      bypassDnsResolution = true

      nodeSelector = {
        "node-role.kubernetes.io/control-plane" = ""
      }
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          effect   = "NoSchedule"
          operator = "Exists"
        }
      ]
    }),
    yamlencode(var.kubelet_csr_approver_helm_values)
  ]
}

locals {
  kubelet_csr_approver_manifest = var.kubelet_csr_approver_enabled ? {
    name     = "kubelet-csr-approver"
    contents = data.helm_template.kubelet_csr_approver[0].manifest
  } : null
}
