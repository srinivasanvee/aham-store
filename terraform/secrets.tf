resource "google_secret_manager_secret" "oauth_client_secret" {
  secret_id = "oauth-client-secret"
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}
