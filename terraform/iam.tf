# --- Ingest service account (Cloud Run) ---

resource "google_service_account" "ingest" {
  account_id   = "rag-ingest-sa"
  display_name = "RAG Ingest Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "ingest_roles" {
  for_each = toset([
    "roles/datastore.user",
    "roles/storage.objectViewer",
    "roles/aiplatform.user",
    "roles/secretmanager.secretAccessor",
    "roles/eventarc.eventReceiver",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

# --- API service account (GKE via Workload Identity) ---

resource "google_service_account" "api" {
  account_id   = "rag-api-sa"
  display_name = "RAG API Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "api_roles" {
  for_each = toset([
    "roles/datastore.user",
    "roles/aiplatform.user",
    "roles/secretmanager.secretAccessor",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.api.email}"
}

# Allows the Kubernetes service account (rag-api-ksa in the default namespace)
# to impersonate the GCP service account via Workload Identity.
resource "google_service_account_iam_member" "api_workload_identity" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/rag-api-ksa]"
}

# --- Eventarc: grant GCS the ability to publish Pub/Sub events ---
# Without this, Cloud Storage upload triggers on Eventarc silently fail.

data "google_storage_project_service_account" "gcs_sa" {
  project = var.project_id
}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}

# Grant the Eventarc service agent its required role so it can validate
# GCS buckets and manage Pub/Sub subscriptions for triggers.
variable "project_number" {
  type    = string
  default = "876779840923"
}

resource "google_project_iam_member" "eventarc_service_agent" {
  project = var.project_id
  role    = "roles/eventarc.serviceAgent"
  member  = "serviceAccount:service-${var.project_number}@gcp-sa-eventarc.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "eventarc_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:service-${var.project_number}@gcp-sa-eventarc.iam.gserviceaccount.com"
}
