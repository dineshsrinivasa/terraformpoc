provider "google" {
  project = var.project
  region  = var.region
}
terraform {
   backend "gcs" {
    bucket  = "YOUR BUCKET NAME"
  }
}
resource "google_compute_firewall" "firewall" {
  name    = "demo-firewall-externalssh"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"] # Not So Secure. Limit the Source Range
  target_tags   = ["externalssh"]
}
resource "google_compute_firewall" "webserverrule" {
  name    = "demo-webserver"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["80","443"]
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
resource "google_compute_instance" "dev" {
  name         = "devserver"
  machine_type = "f1-micro"
  zone         = "${var.region}-a"
  tags         = ["externalssh","webserver"]
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }
  metadata_startup_script = file("./apache2.sh")
  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.static.address
    }
  }
}
