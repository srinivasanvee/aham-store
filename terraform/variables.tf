variable "project_id" {
  type    = string
  default = "aham-store"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "force_destroy_buckets" {
  type    = bool
  default = false
  # Set to true only in dev/staging. Leaving false prevents terraform destroy
  # from silently deleting all uploaded books.
}
