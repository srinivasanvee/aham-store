# RAG System on Google Cloud with Terraform

A practical build guide for a Retrieval-Augmented Generation system on GCP, using GKE for the API, Cloud Run for the ingestion pipeline, and Terraform for all infrastructure.

> **API layer alternative:** If you prefer less operational overhead, Cloud Run works equally well for the Spring Boot API — it scales to zero, skips cluster management, and saves ~$13–20/mo when idle. GKE is the right choice if you need sticky sessions, GPU nodes, or sustained high RPS. The guide uses GKE throughout; swap in Cloud Run if the simpler path fits your scale.

---

## Architecture Overview

| Component | Technology | Purpose |
|-----------|-----------|---------|
| API layer | Spring Boot on **GKE** | Handles queries, retrieval, calls the LLM, returns answers |
| Ingestion pipeline | Python on **Cloud Run** | Watches for uploads, parses docs (PDF/DOCX/EPUB/TXT), chunks, embeds, writes vectors |
| Object storage | **Cloud Storage** | Raw document uploads + static UI hosting |
| Vector store | **Firestore** (or Vertex AI Vector Search for >100K vectors) | Stores chunks + embeddings, namespaced per user |
| Embeddings + LLM | **Vertex AI** | `text-embedding-005` + Gemini for generation |
| Secrets | **Secret Manager** | OAuth client secrets, API keys — never in env vars or code |
| Container registry | **Artifact Registry** | Hosts Docker images (replaces deprecated `gcr.io`) |
| Auth | **Google OAuth 2.0** | Protects the UI and API |
| CI/CD | **Cloud Build** | Builds images, runs tests, deploys |
| IaC | **Terraform** | Provisions and version-controls everything |

**Request flow**
1. User signs in via Google OAuth in the frontend (Angular or React).
2. User uploads a file → lands in a Cloud Storage bucket.
3. Upload event triggers the Python Cloud Run service → parse format → chunk → embed (Vertex AI) → store vectors namespaced by `userId`.
4. User asks a question → Spring Boot API (GKE) → embed query → similarity search scoped to that user's vectors → pass context to Gemini → return answer + sources.

---

## Prerequisites

- Google Cloud account with billing enabled
- `gcloud` CLI authenticated (`gcloud auth application-default login`)
- Terraform >= 1.6
- Docker
- Java 17+ / Spring Boot 3.x
- Python 3.11+

**Python ingestion dependencies:**
```
flask
google-cloud-storage
google-cloud-firestore
vertexai
pymupdf          # PDF parsing
python-docx      # Word docs
ebooklib         # EPUB
chardet          # encoding detection
```

---

## Phase 1 — Terraform Foundation

### 1.1 State backend (create the bucket once, manually)

Terraform can't create the bucket that holds its own state, so create it first:

```bash
gcloud storage buckets create gs://<PROJECT>-tf-state \
  --location=us-central1 \
  --uniform-bucket-level-access
gcloud storage buckets update gs://<PROJECT>-tf-state --versioning
```

### 1.2 Provider + backend

```hcl
# versions.tf
terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    bucket = "<PROJECT>-tf-state"
    prefix = "rag-system"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
```

GCS backend gives you state locking and encryption automatically — no separate DynamoDB-style lock table like AWS needs.

### 1.3 Variables

```hcl
# variables.tf
variable "project_id" { type = string }
variable "region"     { type = string  default = "us-central1" }
variable "zone"       { type = string  default = "us-central1-a" }

variable "force_destroy_buckets" {
  type    = bool
  default = false
  # Set to true only in dev/staging. Leaving this false in production
  # prevents terraform destroy from silently deleting all uploaded books.
}
```

---

## Phase 2 — Core Resources

### 2.1 Enable APIs

```hcl
resource "google_project_service" "services" {
  for_each = toset([
    "container.googleapis.com",
    "run.googleapis.com",
    "aiplatform.googleapis.com",
    "cloudbuild.googleapis.com",
    "firestore.googleapis.com",
    "storage.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}
```

### 2.2 Storage buckets

```hcl
resource "google_storage_bucket" "uploads" {
  name                        = "${var.project_id}-uploads"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets
}

resource "google_storage_bucket" "frontend" {
  name                        = "${var.project_id}-frontend"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets
  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"  # SPA fallback
  }
}
```

### 2.3 Artifact Registry (replaces deprecated `gcr.io`)

```hcl
resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "rag-images"
  format        = "DOCKER"
  depends_on    = [google_project_service.services]
}
```

Images are referenced as:
`us-central1-docker.pkg.dev/${var.project_id}/rag-images/<image>:<tag>`

Update your `cloudbuild.yaml` and Kubernetes manifests to use this path — not `gcr.io`.

### 2.4 Service Accounts & IAM

Define dedicated service accounts with least-privilege roles. The Eventarc trigger references `google_service_account.ingest`, so it must be declared here before the trigger.

```hcl
# Ingestion pipeline service account
resource "google_service_account" "ingest" {
  account_id   = "rag-ingest-sa"
  display_name = "RAG Ingest Service Account"
}

resource "google_project_iam_member" "ingest_roles" {
  for_each = toset([
    "roles/datastore.user",
    "roles/storage.objectViewer",
    "roles/aiplatform.user",
    "roles/secretmanager.secretAccessor",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

# GKE API service account (used via Workload Identity — see 2.5)
resource "google_service_account" "api" {
  account_id   = "rag-api-sa"
  display_name = "RAG API Service Account"
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

# Allow the GKE Kubernetes service account to impersonate the GCP service account
resource "google_service_account_iam_member" "api_workload_identity" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/rag-api-ksa]"
}
```

### 2.5 GKE cluster with Workload Identity

```hcl
resource "google_container_cluster" "rag" {
  name                     = "rag-cluster"
  location                 = var.zone        # zonal = cheaper than regional
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "primary" {
  name       = "primary"
  cluster    = google_container_cluster.rag.id
  location   = var.zone
  node_count = 1

  node_config {
    machine_type = "e2-small"   # bump to e2-standard-2 if memory-tight
    disk_size_gb = 30
    # No broad oauth_scopes — Workload Identity handles GCP auth per-pod
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }
}
```

> **Why Workload Identity over oauth_scopes:** The previous `oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]` granted every pod on the node full cloud-platform access. Workload Identity binds specific GCP service accounts to specific Kubernetes service accounts, so each pod only gets the permissions it actually needs.

After deploying the cluster, create the Kubernetes service account and annotate it:

```bash
kubectl create serviceaccount rag-api-ksa
kubectl annotate serviceaccount rag-api-ksa \
  iam.gke.io/gcp-service-account=rag-api-sa@<PROJECT>.iam.gserviceaccount.com
```

Reference it in your deployment manifest (`spec.template.spec.serviceAccountName: rag-api-ksa`).

> **Cost note:** Zonal clusters skip the regional control-plane fee. The GKE free tier ($74.40/mo in credits) generally covers the management fee; you mostly pay for the nodes (~$10–20/mo on `e2-small`). Free-tier credits typically apply for the first 12 months.

### 2.6 Firestore (vector store)

```hcl
resource "google_firestore_database" "vectors" {
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
}
```

Vectors are stored under `users/{userId}/vectors/{chunkId}` to isolate each user's documents. Firestore supports vector similarity search via `find_nearest`. For corpora larger than ~100K vectors, migrate to Vertex AI Vector Search — Firestore's `find_nearest` degrades at scale.

### 2.7 Eventarc IAM (required for GCS triggers)

GCS needs permission to publish Pub/Sub events before Eventarc triggers will fire. This is a common deployment blocker that the Eventarc docs bury:

```hcl
data "google_storage_project_service_account" "gcs_sa" {}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}
```

### 2.8 Secret Manager

Store OAuth client secrets and any API keys here — not in environment variables or source code.

```hcl
resource "google_secret_manager_secret" "oauth_client_secret" {
  secret_id = "oauth-client-secret"
  replication {
    auto {}
  }
}
```

Populate the value via CLI (not Terraform, to avoid secrets in state):
```bash
echo -n "your-secret-value" | gcloud secrets versions add oauth-client-secret --data-file=-
```

---

## Phase 3 — Python Ingestion Pipeline (Cloud Run)

### 3.1 What it does
Triggered by a Cloud Storage upload event → validates file type and size → parses format (PDF, DOCX, EPUB, TXT) → chunks text → embeds via Vertex AI → writes vectors to Firestore under `users/{userId}/vectors`, replacing any existing vectors for that file.

### 3.2 `main.py`

```python
import os
import fitz                          # PyMuPDF — PDF
from docx import Document as DocxDoc # python-docx — Word
from io import BytesIO
import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup
import chardet
from flask import Flask, request
from google.cloud import storage, firestore

import vertexai
from vertexai.language_models import TextEmbeddingModel

app = Flask(__name__)

# Initialize clients once at module level — not inside request handlers
db = firestore.Client()
storage_client = storage.Client()
vertexai.init()
embedder = TextEmbeddingModel.from_pretrained("text-embedding-005")

ALLOWED_EXTENSIONS = {"pdf", "docx", "epub", "txt", "md"}
MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024  # 50 MB


def extract_text(data: bytes, filename: str) -> str:
    ext = filename.lower().rsplit(".", 1)[-1]
    if ext == "pdf":
        doc = fitz.open(stream=data, filetype="pdf")
        return "\n".join(page.get_text() for page in doc)
    elif ext == "docx":
        return "\n".join(p.text for p in DocxDoc(BytesIO(data)).paragraphs)
    elif ext == "epub":
        book = epub.read_epub(BytesIO(data))
        parts = []
        for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
            soup = BeautifulSoup(item.get_content(), "html.parser")
            parts.append(soup.get_text())
        return "\n".join(parts)
    else:  # txt, md — detect encoding
        encoding = chardet.detect(data)["encoding"] or "utf-8"
        return data.decode(encoding)


def chunk(text: str, size: int = 1000, overlap: int = 150) -> list[str]:
    out, i = [], 0
    while i < len(text):
        out.append(text[i : i + size])
        i += size - overlap
    return out


def delete_existing_vectors(user_id: str, source: str):
    col = db.collection("users").document(user_id).collection("vectors")
    old = col.where("source", "==", source).stream()
    batch = db.batch()
    for doc in old:
        batch.delete(doc.reference)
    batch.commit()


@app.route("/", methods=["POST"])
def ingest():
    event = request.get_json()
    bucket_name = event["bucket"]
    name = event["name"]           # expected format: "{userId}/{filename}"
    ext = name.lower().rsplit(".", 1)[-1]

    if ext not in ALLOWED_EXTENSIONS:
        return (f"unsupported file type: {ext}", 400)

    blob = storage_client.bucket(bucket_name).blob(name)
    blob.reload()
    if blob.size > MAX_FILE_SIZE_BYTES:
        return (f"file too large: {blob.size} bytes", 400)

    # Derive userId from the object path
    parts = name.split("/", 1)
    if len(parts) != 2:
        return ("object name must be userId/filename", 400)
    user_id, filename = parts

    # Track document status so the UI can show progress
    doc_ref = db.collection("users").document(user_id).collection("documents").document(filename)
    doc_ref.set({"status": "processing", "source": name})

    try:
        data = blob.download_as_bytes()
        text = extract_text(data, filename)
        chunks = chunk(text)

        # Vertex AI accepts up to 250 texts per request
        embeddings = []
        for i in range(0, len(chunks), 250):
            batch_result = embedder.get_embeddings(chunks[i : i + 250])
            embeddings.extend(batch_result)

        # Replace any previously indexed vectors for this file
        delete_existing_vectors(user_id, name)

        vectors_col = db.collection("users").document(user_id).collection("vectors")
        write_batch = db.batch()
        for c, e in zip(chunks, embeddings):
            ref = vectors_col.document()
            write_batch.set(ref, {
                "text": c,
                "embedding": firestore.Vector(e.values),
                "source": name,
                "user_id": user_id,
            })
        write_batch.commit()

        doc_ref.set({"status": "ready", "source": name, "chunks": len(chunks)})
        return ("ok", 200)

    except Exception as exc:
        doc_ref.set({"status": "failed", "error": str(exc)})
        raise
```

### 3.3 Deploy via Terraform + Eventarc

```hcl
resource "google_cloud_run_v2_service" "ingest" {
  name     = "rag-ingest"
  location = var.region

  template {
    service_account = google_service_account.ingest.email

    containers {
      image = "us-central1-docker.pkg.dev/${var.project_id}/rag-images/rag-ingest:latest"

      resources {
        limits = {
          memory = "1Gi"   # books can be large; default 512Mi is often tight
          cpu    = "1"
        }
      }
    }
  }

  depends_on = [google_project_service.services]
}

resource "google_eventarc_trigger" "on_upload" {
  name     = "on-upload"
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
  depends_on      = [google_project_iam_member.gcs_pubsub_publisher]
}
```

---

## Phase 4 — Spring Boot API (GKE)

### 4.1 Responsibilities
Receive query → validate OAuth token → embed query → similarity search scoped to the requesting user's vectors → assemble context → call Gemini → return answer + sources.

### 4.2 Query endpoint (sketch)

```java
@RestController
@RequestMapping("/api")
public class RagController {

    @PostMapping("/query")
    public ResponseEntity<QueryResponse> query(
            @RequestHeader("Authorization") String authHeader,
            @RequestBody QueryRequest req) {

        // 1. Validate Google OAuth token via Spring Security OAuth2 Resource Server
        //    (configured in application.yml with the Google issuer URI)
        //    The authenticated userId is available from the SecurityContext
        String userId = extractUserId(); // from SecurityContextHolder

        // 2. Embed req.getQuestion() via Vertex AI SDK
        // 3. Firestore findNearest() on users/{userId}/vectors — scoped to this user
        // 4. Build prompt with retrieved chunks
        // 5. Call Gemini, return answer + sources
        return ResponseEntity.ok(answer);
    }
}
```

Scoping the Firestore query to `users/{userId}/vectors` ensures users can only retrieve their own documents.

### 4.3 Kubernetes manifests

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-api
spec:
  replicas: 2
  selector:
    matchLabels: { app: rag-api }
  template:
    metadata:
      labels: { app: rag-api }
    spec:
      serviceAccountName: rag-api-ksa   # Workload Identity KSA
      containers:
        - name: rag-api
          image: us-central1-docker.pkg.dev/PROJECT/rag-images/rag-api:latest
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: "250m", memory: "512Mi" }
            limits:   { cpu: "500m", memory: "1Gi" }
---
apiVersion: v1
kind: Service
metadata:
  name: rag-api
spec:
  type: LoadBalancer   # gets a public IP; or use Ingress + managed cert
  selector: { app: rag-api }
  ports: [{ port: 80, targetPort: 8080 }]
```

A `LoadBalancer` Service or GKE Ingress gives you a public endpoint to start. Add a custom domain later by pointing an A record at the Ingress IP with a Google-managed certificate for HTTPS.

---

## Phase 5 — Authentication (Google OAuth 2.0)

**Setup (Console, one-time):**
1. APIs & Services → Credentials → Create OAuth Client ID (Web application).
2. Add your frontend origin to authorized JS origins and the redirect URI.
3. Store the client secret in Secret Manager (see §2.8) — not in source code or env vars.

**Frontend (Angular/React):** add Google Sign-In, get an ID token after login, attach it as `Authorization: Bearer <token>` on every API call.

**Backend (Spring Boot):** validate the token with Google's token-info / public keys (Spring Security OAuth2 Resource Server handles this with the Google issuer configured in `application.yml`). Reject anything unverified before touching the RAG logic. The validated `sub` claim is the stable `userId` to use for Firestore namespacing.

OAuth setup itself isn't Terraform-managed — you configure it in the Console and reference the Client ID in your frontend env config.

---

## Phase 6 — Frontend Hosting

For a first version, skip the CDN — serve the static SPA straight from the `frontend` bucket:

```bash
ng build   # or: npm run build
gcloud storage cp -r dist/* gs://<PROJECT>-frontend/
```

The frontend should display document status (`processing` / `ready` / `failed`) by polling or listening to the `users/{userId}/documents` Firestore collection in real time.

Add Cloud CDN + a global load balancer later only if you need global low-latency delivery.

---

## Phase 7 — CI/CD with Cloud Build

```yaml
# cloudbuild.yaml
steps:
  # Build API image
  - name: gcr.io/cloud-builders/docker
    args:
      - build
      - -t
      - us-central1-docker.pkg.dev/$PROJECT_ID/rag-images/rag-api:$SHORT_SHA
      - ./api
  - name: gcr.io/cloud-builders/docker
    args:
      - push
      - us-central1-docker.pkg.dev/$PROJECT_ID/rag-images/rag-api:$SHORT_SHA

  # Deploy to GKE
  - name: gcr.io/cloud-builders/gke-deploy
    args:
      - run
      - --image=us-central1-docker.pkg.dev/$PROJECT_ID/rag-images/rag-api:$SHORT_SHA
      - --location=us-central1-a
      - --cluster=rag-cluster

  # Build + deploy ingest service to Cloud Run
  - name: gcr.io/cloud-builders/docker
    args:
      - build
      - -t
      - us-central1-docker.pkg.dev/$PROJECT_ID/rag-images/rag-ingest:$SHORT_SHA
      - ./ingest
  - name: gcr.io/cloud-builders/docker
    args:
      - push
      - us-central1-docker.pkg.dev/$PROJECT_ID/rag-images/rag-ingest:$SHORT_SHA
  - name: gcr.io/google.com/cloudsdktool/cloud-sdk
    entrypoint: gcloud
    args:
      - run
      - deploy
      - rag-ingest
      - --image=us-central1-docker.pkg.dev/$PROJECT_ID/rag-images/rag-ingest:$SHORT_SHA
      - --region=us-central1
```

Wire a Cloud Build trigger to your GitHub/GitLab repo (Terraform `google_cloudbuild_trigger`) so commits to `main` deploy automatically.

---

## Phase 8 — Monitoring & Alerts

Add a Cloud Monitoring alert for ingestion failures so silent errors don't leave users wondering why their books aren't searchable:

```hcl
resource "google_monitoring_alert_policy" "ingest_errors" {
  display_name = "Ingest pipeline errors"
  combiner     = "OR"

  conditions {
    display_name = "Cloud Run error rate"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = []   # add your email/Slack channel ID here
}
```

Also enable Cloud Logging export for both the GKE API and Cloud Run ingest service — structured logs from Python (`import google.cloud.logging`) and Spring Boot (`spring-cloud-gcp-starter-logging`) integrate automatically with Cloud Logging.

---

## Cost Summary (low-traffic, lowest tier)

| Item | Rough monthly cost |
|------|-------------------|
| GKE management fee | Covered by $74.40 free-tier credit (first 12 months) |
| 1× `e2-small` node | ~$13–20 |
| Cloud Run (ingest, scales to zero) | Pennies at low volume |
| Cloud Storage (a few GB) | ~$0.02/GB |
| Vertex AI embeddings | ~$0.000025 / 1K characters |
| Firestore (small) | Likely within free quota |
| Secret Manager | ~$0.06/secret/month |
| Artifact Registry | ~$0.10/GB/month |
| **Total** | **Roughly $15–25/mo at low traffic** |

> Cloud Run scales to zero, so the ingest pipeline costs almost nothing when idle. The GKE node pool is your main fixed cost.

---

## When to migrate from Firestore to Vertex AI Vector Search

Firestore `find_nearest` is a good starting point, but degrades past ~100K vectors. A book with 300 pages generates roughly 1,000–3,000 chunks. At 50 books per user and a handful of users, you're fine on Firestore. As you scale, migrate to Vertex AI Vector Search (Terraform resource: `google_vertex_ai_index`) and keep Firestore for document metadata only.

---

## Realistic Timeline

| Scope | Estimate |
|-------|----------|
| Infra + ingestion (multi-format) + retrieval working end-to-end | 3–4 weeks |
| Same, plus full OAuth on frontend + backend + per-user isolation | 4–5 weeks |

Assumes steady solo work and existing comfort with Spring Boot, GCP basics, and Terraform.

---

## Build Order (suggested)

1. Terraform state bucket + provider + APIs enabled
2. Artifact Registry + service accounts + IAM bindings
3. Storage buckets + Firestore
4. Secret Manager secret (populate OAuth secret via CLI)
5. Python ingest service on Cloud Run + Eventarc trigger (with GCS Pub/Sub IAM) — verify vectors land under `users/{userId}/vectors`
6. Spring Boot API locally → containerize → GKE with Workload Identity
7. Frontend (static, no CDN) + OAuth — verify per-user document isolation
8. Cloud Build triggers for both services
9. Monitoring alert for ingestion errors
10. Custom domain + HTTPS + CDN (optional, last)
