# aham-store

A RAG (Retrieval-Augmented Generation) system that lets users upload books and documents, then ask questions across them. Built on Google Cloud Platform.

Full build guide: [`rag-gcp-terraform-guide.md`](./rag-gcp-terraform-guide.md)

---

## Architecture

```
User → Google OAuth → Frontend (GCS static hosting)
                          │
              ┌───────────┴────────────┐
              │ Upload file            │ Ask question
              ▼                        ▼
     GCS uploads bucket        Spring Boot API (GKE)
              │                        │
     Eventarc trigger          embed query (Vertex AI)
              │                        │
     Cloud Run (ingest)        Firestore findNearest
              │                (users/{userId}/vectors)
     parse → chunk → embed             │
     Vertex AI text-embedding   Gemini generation
              │                        │
     Firestore vectors          answer + sources
     (users/{userId}/vectors)
```

| Component | Technology |
|-----------|-----------|
| API | Spring Boot 3.3 on GKE (Workload Identity) |
| Ingestion | FastAPI + uvicorn on Cloud Run (scales to zero) |
| Object storage | Cloud Storage — uploads + frontend hosting |
| Vector store | Firestore native (`users/{userId}/vectors`) |
| Embeddings | Vertex AI `text-embedding-005` |
| Generation | Vertex AI Gemini `gemini-1.5-pro-001` |
| Auth | Google OAuth 2.0 ID tokens (Spring Security RS) |
| IaC | Terraform with GCS remote state |
| Registry | Artifact Registry (`us-central1-docker.pkg.dev`) |
| Secrets | Secret Manager (OAuth client secret) |

---

## Repository layout

```
aham-store/
├── terraform/          # All GCP infrastructure
│   ├── versions.tf     # GCS backend (aham-store-tf-state) + provider
│   ├── variables.tf    # project_id, region, zone, force_destroy_buckets
│   ├── apis.tf         # Enable 10 GCP APIs
│   ├── storage.tf      # uploads + frontend GCS buckets
│   ├── registry.tf     # Artifact Registry (rag-images)
│   ├── iam.tf          # Service accounts, IAM bindings, Eventarc publisher
│   ├── gke.tf          # GKE cluster + node pool (Workload Identity)
│   ├── firestore.tf    # Firestore native database
│   ├── secrets.tf      # Secret Manager secret (oauth-client-secret)
│   ├── ingest.tf       # Cloud Run service + Eventarc trigger
│   └── outputs.tf      # Bucket names, registry URL, cluster name
│
├── ingest/             # Python ingestion pipeline (Cloud Run)
│   ├── main.py         # FastAPI app — parse, chunk, embed, write vectors
│   ├── requirements.txt
│   └── Dockerfile      # python:3.11-slim + uvicorn
│
├── api/                # Spring Boot query API (GKE)
│   ├── pom.xml         # Spring Boot 3.3 + GCP libraries-bom
│   ├── Dockerfile      # Multi-stage Maven build → JRE runtime
│   └── src/main/
│       ├── resources/application.yml
│       └── java/com/ahamstore/api/
│           ├── AhamStoreApplication.java
│           ├── config/SecurityConfig.java        # OAuth2 resource server
│           ├── controller/RagController.java     # POST /api/query
│           ├── model/{QueryRequest,QueryResponse}.java
│           └── service/
│               ├── EmbeddingService.java         # Vertex AI embeddings
│               ├── VectorSearchService.java      # Firestore findNearest
│               └── GenerationService.java        # Gemini generation
│
├── frontend/           # React SPA (auth layer — UI expanded in Phase 6)
│   ├── package.json
│   ├── vite.config.js  # Dev proxy: /api → Spring Boot; prod uses VITE_API_URL
│   ├── index.html
│   ├── .env.example    # VITE_GOOGLE_CLIENT_ID, VITE_API_URL
│   └── src/
│       ├── main.jsx             # GoogleOAuthProvider + AuthProvider root
│       ├── App.jsx              # ProtectedRoute wrapper + Dashboard shell
│       ├── api/client.js        # Axios instance — injects Bearer token, handles 401
│       └── auth/
│           ├── AuthProvider.jsx # Context: user, token, login(), logout()
│           ├── ProtectedRoute.jsx
│           └── LoginPage.jsx    # GoogleLogin button + One Tap
│
├── k8s/
│   ├── deployment.yaml  # 2 replicas, rag-api-ksa, health probes
│   └── service.yaml     # LoadBalancer port 80 → 8080
│
└── rag-gcp-terraform-guide.md   # Full build guide with rationale
```

---

## GCP project

- **Project ID:** `aham-store`
- **Region:** `us-central1`
- **Zone:** `us-central1-a`
- **Terraform state bucket:** `aham-store-tf-state`

---

## Implementation status

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Terraform foundation (backend, provider, variables) | Done |
| 2 | Core resources (APIs, buckets, GKE, Firestore, IAM, Artifact Registry, Secrets) | Done |
| 3 | Python ingestion pipeline (FastAPI + Cloud Run + Eventarc) | Done |
| 4 | Spring Boot query API (GKE + Vertex AI + Gemini) | Done |
| 5 | Authentication (Google OAuth 2.0 on frontend) | Done |
| 6 | Frontend hosting (SPA on GCS) | Pending |
| 7 | CI/CD (Cloud Build triggers) | Pending |
| 8 | Monitoring (Cloud Monitoring alert for ingest errors) | Pending |

---

## Key design decisions

### Per-user data isolation
All Firestore data is namespaced under `users/{userId}/` — vectors at `users/{userId}/vectors` and document status at `users/{userId}/documents`. The `userId` is the `sub` claim from the Google ID token. Uploads must follow the `{userId}/{filename}` path convention in the GCS bucket so the ingest service can derive the owner.

### Workload Identity over oauth_scopes
The GKE node pool uses `GKE_METADATA` mode and the `rag-api-ksa` Kubernetes service account is annotated with `iam.gke.io/gcp-service-account=rag-api-sa@aham-store.iam.gserviceaccount.com`. This restricts each pod to only the permissions it actually needs, rather than granting full `cloud-platform` scope to every workload on the node.

### Ingestion deduplication
Before writing new vectors, `delete_existing_vectors()` removes all Firestore documents where `source == objectPath`. This means re-uploading a file replaces its vectors rather than duplicating them.

### Eventarc GCS publisher IAM
`data.google_storage_project_service_account` + `roles/pubsub.publisher` on the GCS SA must exist before the Eventarc trigger. Without it, the trigger is created but events are never delivered (a silent failure with no error in the GCS console).

### `force_destroy_buckets = false` by default
Setting this to `true` in `variables.tf` (or via `-var`) would delete all user-uploaded books on `terraform destroy`. It defaults to `false` to prevent accidental data loss in production.

### FastAPI over Flask for ingest
The ingest service uses FastAPI + uvicorn. GCP clients (`storage.Client`, `firestore.Client`, `TextEmbeddingModel`) are initialised once in the FastAPI `lifespan` context manager and reused across requests, rather than being created per-request.

### Auth token storage
ID tokens are kept in React module/state memory only — never in `localStorage`. On a hard refresh the user sees the Google One Tap prompt, which silently re-authenticates if they're still signed into Google. On 401, the axios interceptor fires an `auth:expired` window event that `AuthProvider` listens to and calls `logout()`.

### CORS
`CorsConfig.java` reads `CORS_ALLOWED_ORIGINS` (comma-separated). Defaults to `http://localhost:5173` in dev. Set to the GCS frontend bucket URL (or custom domain) in production via the K8s env var.

### Artifact Registry over Container Registry
All images use `us-central1-docker.pkg.dev/aham-store/rag-images/` — `gcr.io` is deprecated.

---

## Supported document formats

The ingestion pipeline handles:

| Format | Parser |
|--------|--------|
| PDF | PyMuPDF (`fitz`) |
| Word (.docx) | python-docx |
| EPUB | ebooklib + BeautifulSoup |
| Plain text / Markdown | chardet (encoding detection) |

Files must be ≤ 50 MB. Unsupported extensions are rejected with HTTP 400 before downloading.

---

## Local development

### Ingest service

```bash
cd ingest
pip install -r requirements.txt
export GOOGLE_APPLICATION_CREDENTIALS=<path-to-service-account-key>
uvicorn main:app --reload --port 8080
```

### API service

```bash
cd api
export GCP_PROJECT_ID=aham-store
export GOOGLE_APPLICATION_CREDENTIALS=<path-to-service-account-key>
./mvnw spring-boot:run
```

---

## Deploy

### Prerequisites

```bash
brew install terraform
gcloud auth configure-docker us-central1-docker.pkg.dev
gcloud container clusters get-credentials rag-cluster \
  --zone us-central1-a --project aham-store
```

### Infrastructure

```bash
cd terraform
terraform init       # connects to aham-store-tf-state backend
terraform plan
terraform apply
```

### After first apply — Workload Identity setup

```bash
kubectl create serviceaccount rag-api-ksa
kubectl annotate serviceaccount rag-api-ksa \
  iam.gke.io/gcp-service-account=rag-api-sa@aham-store.iam.gserviceaccount.com
```

### Ingest service

```bash
cd ingest
docker build -t us-central1-docker.pkg.dev/aham-store/rag-images/rag-ingest:latest .
docker push us-central1-docker.pkg.dev/aham-store/rag-images/rag-ingest:latest
cd ../terraform && terraform apply   # updates Cloud Run with new image
```

### API service

```bash
cd api
docker build -t us-central1-docker.pkg.dev/aham-store/rag-images/rag-api:latest .
docker push us-central1-docker.pkg.dev/aham-store/rag-images/rag-api:latest
kubectl apply -f ../k8s/
kubectl rollout status deployment/rag-api
kubectl get service rag-api   # shows public IP
```

### Populate OAuth secret (one-time)

```bash
echo -n "<your-oauth-client-secret>" | \
  gcloud secrets versions add oauth-client-secret --data-file=-
```

### Test the query endpoint

```bash
# Upload a test file (path must be userId/filename)
echo "The Iliad is an ancient Greek epic poem." | \
  gcloud storage cp - gs://aham-store-uploads/user123/iliad.txt

# Wait ~30s for ingestion, then query
curl -X POST http://<EXTERNAL-IP>/api/query \
  -H "Authorization: Bearer <GOOGLE-ID-TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"question": "What is the Iliad?"}'
```

---

## Cost (low-traffic estimate)

| Item | ~Monthly cost |
|------|--------------|
| 1× `e2-small` GKE node | $13–20 |
| Cloud Run ingest (scales to zero) | Pennies |
| Cloud Storage (few GB) | ~$0.02/GB |
| Vertex AI embeddings | ~$0.000025/1K chars |
| Firestore | Within free quota at low volume |
| Secret Manager | ~$0.06/secret |
| Artifact Registry | ~$0.10/GB |
| **Total** | **~$15–25/mo** |
