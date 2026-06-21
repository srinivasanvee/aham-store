# Deployment Guide

Complete step-by-step guide to deploy the aham-store RAG system to GCP from scratch.

After the initial deployment (Steps 1–12), all future code changes auto-deploy on push to `main` via Cloud Build — no manual steps needed.

---

## Prerequisites

- Google Cloud account with billing enabled on project `aham-store`
- GCP Console access to create OAuth credentials and connect GitHub
- Docker Desktop installed and running
- Node.js 22+
- Java 17+

---

## Step 1 — Install CLI tools

```bash
# Terraform
brew install terraform

# kubectl
brew install kubectl

# Verify gcloud is installed
gcloud --version

# Verify Docker is running
docker info
```

---

## Step 2 — Authenticate gcloud

```bash
# Log in (opens browser)
gcloud auth login

# Set the active project
gcloud config set project aham-store

# Authenticate for API calls — Terraform uses this
gcloud auth application-default login

# Verify
gcloud config get-value project
# Expected: aham-store
```

---

## Step 3 — Bootstrap infrastructure with Terraform

This is the **only manual `terraform apply`**. After Step 11, Cloud Build handles all future applies automatically.

```bash
cd terraform

# Connect Terraform to the GCS state bucket
terraform init
# Expected: "Backend "gcs" initialized!" + "Terraform has been successfully initialized!"

# Preview what will be created (~25 resources)
terraform plan

# Create all infrastructure — takes ~8-10 min (GKE cluster is the slowest)
terraform apply
# Type "yes" when prompted

# Review the outputs — save these values for later steps
terraform output
```

**Resources created by this apply:**

| Resource | Name |
|---|---|
| GKE cluster | `rag-cluster` (1× e2-small node, us-central1-a) |
| Cloud Run service | `rag-ingest` (placeholder — no image yet) |
| Firestore database | `(default)` |
| GCS bucket | `aham-store-uploads` |
| GCS bucket | `aham-store-frontend` |
| Artifact Registry | `rag-images` |
| Service accounts | `rag-ingest-sa`, `rag-api-sa`, `rag-cloudbuild-sa` |
| IAM bindings | All role assignments for the above SAs |
| Secret Manager secrets | `oauth-client-secret`, `vite-google-client-id`, `vite-api-url` (empty) |
| Cloud Build triggers | `infra-deploy`, `ingest-deploy`, `api-deploy`, `frontend-deploy` (inactive until Step 11) |

---

## Step 4 — Connect kubectl to the GKE cluster

```bash
gcloud container clusters get-credentials rag-cluster \
  --zone us-central1-a \
  --project aham-store

# Verify the connection
kubectl get nodes
# Expected: one node listed with STATUS = Ready
```

---

## Step 5 — Set up Workload Identity for the API

Workload Identity lets the Spring Boot API pods authenticate to GCP services without a key file. The Kubernetes service account (KSA) maps to the GCP service account (GSA) created in Step 3.

```bash
# Create the Kubernetes service account
kubectl create serviceaccount rag-api-ksa

# Annotate it with the corresponding GCP service account
kubectl annotate serviceaccount rag-api-ksa \
  iam.gke.io/gcp-service-account=rag-api-sa@aham-store.iam.gserviceaccount.com

# Verify
kubectl describe serviceaccount rag-api-ksa
# Look for:
# Annotations: iam.gke.io/gcp-service-account=rag-api-sa@aham-store.iam.gserviceaccount.com
```

---

## Step 6 — Authenticate Docker with Artifact Registry

Required before pushing or pulling images from `us-central1-docker.pkg.dev`.

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
# Expected: "Docker configuration file updated."
```

---

## Step 7 — Build and deploy the ingest service

```bash
cd ingest

# Build the image (~3-5 min first time — downloads Python base image and installs deps)
docker build -t us-central1-docker.pkg.dev/aham-store/rag-images/rag-ingest:latest .

# Push to Artifact Registry
docker push us-central1-docker.pkg.dev/aham-store/rag-images/rag-ingest:latest
# Expected: layer push progress ending with a sha256 digest

# Deploy to Cloud Run (updates the placeholder created in Step 3)
gcloud run deploy rag-ingest \
  --image=us-central1-docker.pkg.dev/aham-store/rag-images/rag-ingest:latest \
  --region=us-central1 \
  --project=aham-store
# Expected: "Service [rag-ingest] revision [...] has been deployed and is serving 100% of traffic."
```

---

## Step 8 — Build and deploy the API

```bash
cd api

# Build the image — Maven downloads deps and compiles Java (~5-8 min first time)
docker build -t us-central1-docker.pkg.dev/aham-store/rag-images/rag-api:latest .

# Push to Artifact Registry
docker push us-central1-docker.pkg.dev/aham-store/rag-images/rag-api:latest

# Deploy to GKE
kubectl apply -f ../k8s/
# Expected:
#   deployment.apps/rag-api created
#   service/rag-api created

# Wait for pods to become ready (~40s — Spring Boot takes time to start)
kubectl rollout status deployment/rag-api
# Expected: "deployment "rag-api" successfully rolled out"

# Get the public IP — may show <pending> for 1-2 min while GCP provisions the load balancer
kubectl get service rag-api
# Look for the EXTERNAL-IP column — save this value for Steps 9 and 10
```

---

## Step 9 — Populate secrets

These secrets are used by the application at runtime and by the Cloud Build frontend pipeline.

```bash
# 1. OAuth client secret
#    Get this from: GCP Console → APIs & Services → Credentials → your OAuth 2.0 Client ID
echo -n "your-oauth-client-secret" | \
  gcloud secrets versions add oauth-client-secret --data-file=-

# 2. Google OAuth Client ID (the public client ID, not the secret)
#    Same value as VITE_GOOGLE_CLIENT_ID in frontend/.env
echo -n "<YOUR-GOOGLE-CLIENT-ID>.apps.googleusercontent.com" | \
  gcloud secrets versions add vite-google-client-id --data-file=-

# 3. API public URL — use the EXTERNAL-IP from Step 8
echo -n "http://<EXTERNAL-IP>" | \
  gcloud secrets versions add vite-api-url --data-file=-
```

---

## Step 10 — Build and deploy the frontend

```bash
cd frontend

# Build with production values injected as environment variables
VITE_GOOGLE_CLIENT_ID=<YOUR-GOOGLE-CLIENT-ID>.apps.googleusercontent.com \
VITE_API_URL=http://<EXTERNAL-IP-FROM-STEP-8> \
npm run build
# Creates frontend/dist/

# Upload to GCS
gcloud storage rsync -r \
  --delete-unmatched-destination-objects \
  dist/ \
  gs://aham-store-frontend/

# Make the bucket publicly readable so browsers can load the SPA
gcloud storage buckets add-iam-policy-binding gs://aham-store-frontend \
  --member=allUsers \
  --role=roles/storage.objectViewer
```

The frontend is now live at:
```
https://storage.googleapis.com/aham-store-frontend/index.html
```

Update the API's CORS config to accept requests from that origin:

```bash
kubectl set env deployment/rag-api \
  CORS_ALLOWED_ORIGINS=https://storage.googleapis.com

kubectl rollout status deployment/rag-api
# Expected: "deployment "rag-api" successfully rolled out"
```

---

## Step 11 — Connect GitHub to Cloud Build (activates CI/CD)

Terraform creates the trigger resources but can't install the GitHub app — that requires OAuth consent in the Console. Do this once.

**In the GCP Console:**
1. Go to **Cloud Build → Triggers**
2. Click **Connect Repository**
3. Select source: **GitHub (Cloud Build GitHub App)**
4. Click **Install Google Cloud Build** → authenticate with GitHub → select `aham-store` repo → click **Install**
5. Back in GCP, select the repo and click **Connect**

**Then re-run Terraform** to register the triggers against the now-connected repository:

```bash
cd terraform
terraform apply
# Only the 4 Cloud Build triggers will show changes
```

Verify the triggers are active:

```bash
gcloud builds triggers list --project=aham-store
# Expected: 4 triggers listed — infra-deploy, ingest-deploy, api-deploy, frontend-deploy
```

From this point forward, pushing to `main` automatically deploys only the affected service.

---

## Step 12 — Smoke test end-to-end

### Test ingestion

```bash
# Upload a test document — path format must be userId/filename
echo "The Iliad is an ancient Greek epic poem attributed to Homer." | \
  gcloud storage cp - gs://aham-store-uploads/user123/iliad.txt

# Wait ~30 seconds for Eventarc to trigger the ingest pipeline, then check status
gcloud firestore documents get \
  'projects/aham-store/databases/(default)/documents/users/user123/documents/iliad.txt'
# Look for: status: "ready" and chunks: <number>
```

### Test the query API

Get a Google ID token: open the frontend at `https://storage.googleapis.com/aham-store-frontend/index.html`, sign in, then open DevTools → Network tab → find a request to `/api/` → copy the `Authorization` header value (everything after `Bearer `).

```bash
curl -X POST http://<EXTERNAL-IP>/api/query \
  -H "Authorization: Bearer <ID-TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"question": "What is the Iliad?"}'

# Expected response:
# {
#   "answer": "The Iliad is an ancient Greek epic poem attributed to Homer.",
#   "sources": ["user123/iliad.txt"]
# }
```

### Test CI/CD

Make a trivial change and push — Cloud Build should fire automatically:

```bash
# Make a visible but harmless change
echo "" >> ingest/main.py
git add ingest/main.py
git commit -m "test: verify ingest pipeline trigger"
git push

# Watch the build start within ~30 seconds
gcloud builds list --project=aham-store --limit=5

# Stream the logs of the running build
gcloud builds log $(gcloud builds list --project=aham-store --limit=1 --format="value(id)") \
  --project=aham-store
```

---

## Deployment sequence at a glance

```
Step 1   Install Terraform, kubectl
Step 2   gcloud auth login + application-default login
Step 3   terraform init + terraform apply          → all GCP infra created
Step 4   gcloud container clusters get-credentials → kubectl connected
Step 5   kubectl create serviceaccount + annotate  → Workload Identity wired
Step 6   gcloud auth configure-docker              → Docker can push to Artifact Registry
Step 7   docker build/push rag-ingest + gcloud run deploy
Step 8   docker build/push rag-api + kubectl apply → API live, save EXTERNAL-IP
Step 9   Populate 3 secrets in Secret Manager
Step 10  npm run build + gcloud storage rsync      → frontend live on GCS
Step 11  Connect GitHub in Console + terraform apply → CI/CD active
Step 12  Smoke test ingestion, query API, CI/CD trigger
```

---

## Ongoing operations

### Manually trigger a pipeline without a git push

```bash
gcloud builds triggers run infra-deploy    --branch=main --project=aham-store
gcloud builds triggers run ingest-deploy   --branch=main --project=aham-store
gcloud builds triggers run api-deploy      --branch=main --project=aham-store
gcloud builds triggers run frontend-deploy --branch=main --project=aham-store
```

### Check build status and logs

```bash
# List recent builds
gcloud builds list --project=aham-store --limit=10

# Stream logs for the most recent build
gcloud builds log \
  $(gcloud builds list --project=aham-store --limit=1 --format="value(id)") \
  --project=aham-store
```

### Check what's deployed

```bash
# Ingest service — current revision and image
gcloud run services describe rag-ingest --region=us-central1 --project=aham-store

# API — pod status and image
kubectl get pods
kubectl describe deployment rag-api

# Frontend — list files with timestamps
gcloud storage ls -l gs://aham-store-frontend/
```

### Roll back the API to a previous image

```bash
# List available image tags
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/aham-store/rag-images/rag-api

# Roll back kubectl to the previous revision
kubectl rollout undo deployment/rag-api

# Or pin to a specific SHA tag
kubectl set image deployment/rag-api \
  rag-api=us-central1-docker.pkg.dev/aham-store/rag-images/rag-api:<SHA>
```

### Roll back the ingest service to a previous revision

```bash
# List Cloud Run revisions
gcloud run revisions list --service=rag-ingest --region=us-central1

# Route all traffic to a specific revision
gcloud run services update-traffic rag-ingest \
  --to-revisions=<REVISION-NAME>=100 \
  --region=us-central1
```
