# talos_version and out_dir come from run.sh (-var).
mock_provider "hcloud" {
  # Fixed ids: they end up in the nodeid label, and the regression diff in
  # run.sh needs two renders to be comparable.
  mock_resource "hcloud_server" {
    defaults = {
      id = "1001"
    }
  }
}

variables {
  cluster_name       = "prd-test"
  hcloud_token       = "test"
  kubernetes_version = "v1.36.3"
  control_plane_nodepools = [
    { name = "control", location = "fsn1", type = "cx23", count = 1 }
  ]
}

run "render" {
  command = apply
}
