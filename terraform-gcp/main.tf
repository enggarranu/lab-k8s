terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.8.0"
    }
  }
}

provider "google" {
  project = "project-7770b360-47ef-4e14-9f6"
  region  = "asia-southeast2"
  zone    = "asia-southeast2-a"
}

# 1. Gunakan VPC Network yang sudah ada (Auto subnet)
resource "google_compute_network" "vpc_network" {
  name = "terraform-network"
}

# 2. Firewall: Akses SSH dari luar/internet
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh-external"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22","6443"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# 3. Firewall: Port K8s KHUSUS antar Node (Internal Privat)
resource "google_compute_firewall" "allow_k8s_internal" {
  name    = "allow-k8s-internal"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["6443", "2379-2380"] # K8s API Server & etcd
  }

  allow {
    protocol = "udp"
    ports    = ["8472"] # Flannel VXLAN
  }

  source_tags = ["k8s-node"]
  target_tags = ["k8s-node"]
}

# 4. Firewall: ICMP/Ping internal antar Node
resource "google_compute_firewall" "allow_internal_icmp" {
  name    = "allow-internal-icmp"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "icmp"
  }

  source_tags = ["k8s-node"]
  target_tags = ["k8s-node"]
}

# 5. Konfigurasi 3 Instance VPS
resource "google_compute_instance" "vm_instances" {
  count        = 3
  name         = "instance-${count.index + 1}"
  machine_type = "e2-small"
  zone         = "asia-southeast2-a"

  tags = ["k8s-node"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.name

    access_config {
      // Ephemeral Public IP
    }
  }

# PENTING: Perintahkan Terraform untuk mengabaikan perubahan pada metadata ssh-keys
  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
    ]
  }
}
