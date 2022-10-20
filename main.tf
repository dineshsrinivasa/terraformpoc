provider "google" {
  project = var.project
  region  = var.region
}
terraform {
   backend "gcs" {
    bucket  = "dineshterraformbackend"
  }
}

resource "google_compute_network" "dinesh-poc-vpc-network" {
  name                    = "dinesh-poc-vpc-network"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "network-with-private-ip-ranges" {
  name          = "network-with-private-ip-ranges"
  ip_cidr_range = "10.2.0.0/24"
  region        = "us-central1"
  network       = google_compute_network.dinesh-poc-vpc-network.id
}

resource "google_compute_firewall" "firewall" {
  name    = "firewall-externalssh"
  network = "dinesh-poc-vpc-network"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["124.40.247.180"] # white listing the IP
  target_tags   = ["externalssh"]
}
resource "google_compute_firewall" "webserverrule" {
  name    = "demo-webserver"
  network = "dinesh-poc-vpc-network"
  allow {
    protocol = "tcp"
    ports    = ["80","443",]
  }
  source_ranges = ["0.0.0.0/0"] # Not So Secure. Limit the Source Range
  target_tags   = ["webserver"]
}
# We create a public IP address for our google compute instance to utilize
resource "google_compute_address" "static" {
  name = "vm-public-address"
  project = var.project
  region = var.region
  depends_on = [ google_compute_firewall.firewall ]
}


# reserved IP address
resource "google_compute_global_address" "dinesh-poc-vpc-network" {
  provider = google-beta
  name     = "dinesh-xlb-static-ip"
}

# forwarding rule
resource "google_compute_global_forwarding_rule" "dinesh-poc-vpc-network" {
  name                  = "dinesh-xlb-forwarding-rule"
  provider              = google-beta
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.dinesh-poc-vpc-network.id
  ip_address            = google_compute_global_address.dinesh-poc-vpc-network.id
}

# http proxy
resource "google_compute_target_http_proxy" "dinesh-poc-vpc-network" {
  name     = "dinesh-xlb-target-http-proxy"
  provider = google-beta
  url_map  = google_compute_url_map.dinesh-poc-vpc-network.id
}

# url map
resource "google_compute_url_map" "dinesh-poc-vpc-network" {
  name            = "dinesh-xlb-url-map"
  provider        = google-beta
  default_service = google_compute_backend_service.dinesh-poc-vpc-network.id
}

# backend service with custom request and response headers
resource "google_compute_backend_service" "dinesh-poc-vpc-network" {
  name                    = "dinesh-xlb-backend-service"
  provider                = google-beta
  protocol                = "HTTP"
  port_name               = "my-port"
  load_balancing_scheme   = "EXTERNAL"
  timeout_sec             = 10
  enable_cdn              = true
  custom_request_headers  = ["X-Client-Geo-Location: {client_region_subdivision}, {client_city}"]
  custom_response_headers = ["X-Cache-Hit: {cdn_cache_status}"]
  health_checks           = [google_compute_health_check.dinesh-poc-vpc-network.id]
  backend {
    group           = google_compute_instance_group_manager.dinesh-poc-vpc-network.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "dinesh-poc-vpc-network" {
  name         = "dinesh-xlb-mig-template"
  provider     = google-beta
  machine_type = "e2-small"
  tags         = ["allow-health-check"]

  network_interface {
    network    = google_compute_network.dinesh-poc-vpc-network.id
    subnetwork = google_compute_subnetwork.network-with-private-ip-ranges.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_health_check" "dinesh-poc-vpc-network" {
  name     = "dinesh-xlb-hc"
  provider = google-beta
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# MIG
resource "google_compute_instance_group_manager" "dinesh-poc-vpc-network" {
  name     = "dinesh-xlb-mig1"
  provider = google-beta
  zone     = "us-central1-c"
  named_port {
    name = "http"
    port = 8080
  }
  version {
    instance_template = google_compute_instance_template.dinesh-poc-vpc-network.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# allow access from health check ranges
resource "google_compute_firewall" "dinesh-poc-vpc-network" {
  name          = "dinesh-xlb-fw-allow-hc"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.dinesh-poc-vpc-network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
  }
  target_tags = ["allow-health-check"]
}

resource "google_project_iam_custom_role" "dinesh-custom-restart-role" {
  role_id     = "dineshRole"
  title       = "dineshcs"
  description = "A description"
  permissions = ["compute.instances.reset"]
}

resource "google_project_iam_member" "project" {
  project = "internal-interview-candidates"
  role    = "projects/internal-interview-candidates/roles/dineshRole"
  member  = "user:medineshsrinivasa@gmail.com"
}
