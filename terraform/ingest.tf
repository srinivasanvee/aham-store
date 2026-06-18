locals {
  ingest_image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/rag-ingest:latest"
}

resource "google_cloud_run_v2_service" "ingest" {
  name     = "rag-ingest"
  location = var.region

  # Only accept traffic from Eventarc — not publicly reachable
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.ingest.email

    containers {
      image = local.ingest_image

      resources {
        limits = {
          memory = "1Gi"
          cpu    = "1"
        }
      }
    }

    # Scale to zero when idle; one instance handles sequential Eventarc deliveries
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    # Allow up to 5 min for large book processing
    timeout = "300s"
  }

  depends_on = [
    google_project_service.services,
    google_project_iam_member.ingest_roles,
  ]
}

# Grant the ingest SA permission to invoke its own Cloud Run service
# (Eventarc uses this SA to deliver events)
resource "google_cloud_run_v2_service_iam_member" "ingest_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.ingest.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_eventarc_trigger" "on_upload" {
  name     = "on-gcs-upload"
  location = var.region

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }
  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.uploads.name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.ingest.name
      region  = var.region
    }
  }

  service_account = google_service_account.ingest.email

  depends_on = [
    google_project_iam_member.gcs_pubsub_publisher,
    google_cloud_run_v2_service_iam_member.ingest_invoker,
  ]
}

output "ingest_service_url" {
  value = google_cloud_run_v2_service.ingest.uri
}
