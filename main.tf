terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "The GCP project ID"
  type        = string
  default     = "architecture-world-demo"
}

variable "region" {
  description = "The GCP region to deploy resources in"
  type        = string
  default     = "asia-northeast1"
}

variable "github_owner" {
  description = "The GitHub owner/organization"
  type        = string
  default     = "tngldrl"
}

variable "github_repositories" {
  description = "List of GitHub repository names to authorize (without owner)"
  type        = list(string)
  default     = [
    "architecture-world-api",
    "architecture-world-mcp",
    "architecture-world-web",
    "repostory"
  ]
}

variable "mcp_service_url" {
  description = "The URL of the deployed MCP Cloud Run service. Cloud Run URLs cannot be self-referenced during deployment (circular dependency), so this must be set manually after first deployment via terraform.tfvars."
  type        = string
  default     = "https://architecture-world-mcp-ulti3dddka-an.a.run.app"
}

variable "api_base_url" {
  description = "The URL of the deployed API Cloud Run service. Cloud Run URLs cannot be self-referenced during deployment (circular dependency), so this must be set manually after first deployment via terraform.tfvars."
  type        = string
  default     = "https://architecture-world-api-ulti3dddka-an.a.run.app"
}

# ------------------------------------------------------------------------
# Artifact Registry for Container Images
# ------------------------------------------------------------------------
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "architecture-world-repo"
  description   = "Docker repository for Architecture World services"
  format        = "DOCKER"
}

# ------------------------------------------------------------------------
# Google Cloud Storage for Avatars
# ------------------------------------------------------------------------
resource "google_storage_bucket" "avatars_bucket" {
  name                        = "${var.project_id}-avatars"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.avatars_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# ------------------------------------------------------------------------
# Secret Manager for Private Configurations
# ------------------------------------------------------------------------
resource "google_secret_manager_secret" "github_app_key" {
  secret_id = "github-app-private-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "github_webhook_secret" {
  secret_id = "github-webhook-secret"
  replication {
    auto {}
  }
}

# DATABASE_URL is stored as a secret to avoid exposing credentials in Cloud Run env vars
resource "google_secret_manager_secret" "database_url" {
  secret_id = "database-url"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_url" {
  secret      = google_secret_manager_secret.database_url.id
  secret_data = "postgresql://${google_sql_user.db_user.name}:${random_password.db_password.result}@/architecture_world?host=/cloudsql/${google_sql_database_instance.main_db.connection_name}"

  # Prevent Terraform from showing the secret value in plan output
  lifecycle {
    ignore_changes = [secret_data]
  }
}

# ------------------------------------------------------------------------
# Cloud SQL: PostgreSQL Database
# ------------------------------------------------------------------------
resource "google_sql_database_instance" "main_db" {
  name             = "architecture-world-db"
  database_version = "POSTGRES_15"
  region           = var.region
  deletion_protection = false # Set to true for production systems

  settings {
    tier = "db-f1-micro"
  }
}

resource "google_sql_database" "database" {
  name     = "architecture_world"
  instance = google_sql_database_instance.main_db.name
}

# Randomly generated DB password (stored in Secret Manager, never in plain text)
resource "random_password" "db_password" {
  length  = 32
  special = false # Avoid URL-special characters that would break connection string parsing
}

resource "google_sql_user" "db_user" {
  name     = "user"
  instance = google_sql_database_instance.main_db.name
  password = random_password.db_password.result
}

# ------------------------------------------------------------------------
# IAM & Service Accounts
# ------------------------------------------------------------------------

# Cloud Run Runtime Service Account
resource "google_service_account" "run_sa" {
  account_id   = "arch-world-run-sa"
  display_name = "Cloud Run Runtime Service Account"
}

resource "google_project_iam_member" "run_sa_ai" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "run_sa_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "run_sa_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "run_sa_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

# GitHub Actions Deployment Service Account
resource "google_service_account" "deploy_sa" {
  account_id   = "arch-world-deploy-sa"
  display_name = "GitHub Actions Deployment Service Account"
}

resource "google_project_iam_member" "deploy_sa_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${google_service_account.deploy_sa.email}"
}

resource "google_project_iam_member" "deploy_sa_run" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.deploy_sa.email}"
}

resource "google_project_iam_member" "deploy_sa_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.deploy_sa.email}"
}

# ------------------------------------------------------------------------
# Workload Identity Federation (GitHub Actions Integration)
# ------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Workload Identity Pool for GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"
  
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = "assertion.repository_owner == '${var.github_owner}'"
  
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_actions_binding" {
  for_each           = toset(var.github_repositories)
  service_account_id = google_service_account.deploy_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_owner}/${each.value}"
}

# ------------------------------------------------------------------------
# Cloud Run: MCP Context Server
# ------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "mcp_service" {
  name     = "architecture-world-mcp"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.run_sa.email
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}/mcp:latest"
      ports {
        container_port = 8001
      }
      resources {
        cpu_idle = false
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      # MCP_SERVICE_URL: set via var.mcp_service_url in terraform.tfvars (circular ref workaround)
      env {
        name  = "MCP_SERVICE_URL"
        value = var.mcp_service_url
      }
    }
  }
}

# Allow public unauthenticated access to the MCP service internally/externally
resource "google_cloud_run_v2_service_iam_member" "mcp_public" {
  location = var.region
  name     = google_cloud_run_v2_service.mcp_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------------------------------------------------------------
# Cloud Run: API Service
# ------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "api_service" {
  name     = "architecture-world-api"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.run_sa.email
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}/api:latest"
      ports {
        container_port = 8000
      }
      resources {
        cpu_idle = false
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "MCP_URL"
        value = google_cloud_run_v2_service.mcp_service.uri
      }
      # API_BASE_URL: set via var.api_base_url in terraform.tfvars (circular ref workaround)
      env {
        name  = "API_BASE_URL"
        value = var.api_base_url
      }
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main_db.connection_name]
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "api_public" {
  location = var.region
  name     = google_cloud_run_v2_service.api_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------------------------------------------------------------
# Cloud Run: Web Frontend (Next.js)
# ------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "web_service" {
  name     = "architecture-world-web"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.run_sa.email
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}/web:latest"
      ports {
        container_port = 3000
      }
      env {
        name  = "NEXT_PUBLIC_API_URL"
        value = google_cloud_run_v2_service.api_service.uri
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "web_public" {
  location = var.region
  name     = google_cloud_run_v2_service.web_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------
output "web_service_url" {
  value       = google_cloud_run_v2_service.web_service.uri
  description = "The URL of the Web Frontend service"
}

output "api_service_url" {
  value       = google_cloud_run_v2_service.api_service.uri
  description = "The URL of the Backend API service"
}

output "mcp_service_url" {
  value       = google_cloud_run_v2_service.mcp_service.uri
  description = "The URL of the MCP Context Server service"
}

output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github_provider.name
  description = "The full resource name of the Workload Identity Provider"
}

output "deployment_service_account" {
  value       = google_service_account.deploy_sa.email
  description = "The email of the deployment Service Account to be used by GitHub Actions"
}
