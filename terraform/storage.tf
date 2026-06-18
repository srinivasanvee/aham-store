resource "google_storage_bucket" "uploads" {
  name                        = "${var.project_id}-uploads"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets

  depends_on = [google_project_service.services]
}

resource "google_storage_bucket" "frontend" {
  name                        = "${var.project_id}-frontend"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets

  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"
  }

  depends_on = [google_project_service.services]
}
