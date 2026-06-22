resource "google_compute_address" "api" {
  name    = "rag-api-ip"
  region  = var.region
  project = var.project_id

  depends_on = [google_project_service.services]
}

output "api_static_ip" {
  value       = google_compute_address.api.address
  description = "Static external IP for the rag-api LoadBalancer — stays the same across kube-down/up cycles."
}
