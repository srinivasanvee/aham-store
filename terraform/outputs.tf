output "uploads_bucket" {
  value = google_storage_bucket.uploads.name
}

output "frontend_bucket" {
  value = google_storage_bucket.frontend.name
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "gke_cluster_name" {
  value = google_container_cluster.rag.name
}

output "ingest_service_account" {
  value = google_service_account.ingest.email
}

output "api_service_account" {
  value = google_service_account.api.email
}
