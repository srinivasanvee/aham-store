resource "google_container_cluster" "rag" {
  name                     = "rag-cluster"
  location                 = var.zone
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.services]
}

resource "google_container_node_pool" "primary" {
  name       = "primary"
  cluster    = google_container_cluster.rag.id
  location   = var.zone
  node_count = 1

  node_config {
    machine_type = "e2-small"
    disk_size_gb = 30

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }
}
