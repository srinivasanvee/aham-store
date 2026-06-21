# --- Cloud Build service account ---

resource "google_service_account" "cloudbuild" {
  account_id   = "rag-cloudbuild-sa"
  display_name = "RAG Cloud Build Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "cloudbuild_roles" {
  for_each = toset([
    "roles/artifactregistry.writer",       # push Docker images
    "roles/run.developer",                 # deploy Cloud Run revisions
    "roles/container.developer",           # gke-deploy / kubectl
    "roles/storage.admin",                 # GCS rsync (frontend) + Terraform state
    "roles/iam.serviceAccountUser",        # act as ingest-sa / api-sa during deploy
    "roles/secretmanager.secretAccessor",  # read secrets in pipelines
    "roles/editor",                        # broad resource management for terraform apply
    "roles/resourcemanager.projectIamAdmin", # terraform IAM binding creation
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# --- Secrets used by the frontend pipeline ---
# Populate values via CLI after terraform apply — see CLAUDE.md

resource "google_secret_manager_secret" "vite_google_client_id" {
  secret_id = "vite-google-client-id"
  project   = var.project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret" "vite_api_url" {
  secret_id = "vite-api-url"
  project   = var.project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.services]
}

# --- Cloud Build triggers ---
# Prerequisite: connect the GitHub repo once in the GCP Console:
#   Cloud Build → Triggers → Connect Repository → GitHub app install
#   owner: srinivasanvee / repo: aham-store

resource "google_cloudbuild_trigger" "infra" {
  name            = "infra-deploy"
  project         = var.project_id
  service_account = google_service_account.cloudbuild.id
  filename        = "cloudbuild/infra.yaml"

  github {
    owner = "srinivasanvee"
    name  = "aham-store"
    push { branch = "^main$" }
  }

  included_files = ["terraform/**"]
}

resource "google_cloudbuild_trigger" "ingest" {
  name            = "ingest-deploy"
  project         = var.project_id
  service_account = google_service_account.cloudbuild.id
  filename        = "cloudbuild/ingest.yaml"

  github {
    owner = "srinivasanvee"
    name  = "aham-store"
    push { branch = "^main$" }
  }

  included_files = ["ingest/**"]
}

resource "google_cloudbuild_trigger" "api" {
  name            = "api-deploy"
  project         = var.project_id
  service_account = google_service_account.cloudbuild.id
  filename        = "cloudbuild/api.yaml"

  github {
    owner = "srinivasanvee"
    name  = "aham-store"
    push { branch = "^main$" }
  }

  included_files = ["api/**", "k8s/**"]
}

resource "google_cloudbuild_trigger" "frontend" {
  name            = "frontend-deploy"
  project         = var.project_id
  service_account = google_service_account.cloudbuild.id
  filename        = "cloudbuild/frontend.yaml"

  github {
    owner = "srinivasanvee"
    name  = "aham-store"
    push { branch = "^main$" }
  }

  included_files = ["frontend/**"]
}
