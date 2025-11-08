terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.129.0"
    }
  }
}

provider "yandex" {
  token     = "y0__xDF2J9tGMHdEyCxt7fDFGJzX3alGqL9QMjJ2qVj37ohuqgK"
  folder_id = "b1g5p6ecne1kfv76pai6"
  zone      = "ru-central1-a"
}

# Получаем последний образ Ubuntu 22.04 LTS
data "yandex_compute_image" "ubuntu_2204" {
  family = "ubuntu-2204-lts"
}

# Сеть и подсеть
resource "yandex_vpc_network" "default" {
  name = "otkazoblako-network"
}

resource "yandex_vpc_subnet" "default" {
  zone       = "ru-central1-a"
  network_id = yandex_vpc_network.default.id
  name       = "otkazoblako-subnet"
  v4_cidr_blocks = ["10.130.0.0/24"]
}

# Создаём 2 ВМ с Nginx
resource "yandex_compute_instance" "vm" {
  count = 2
provisioner "remote-exec" {
  inline = [
    "sudo systemctl stop apache2 || true",
    "sudo pkill nginx || true",
    "sudo systemctl restart nginx",
    "sudo systemctl enable nginx"
  ]
  connection {
    type        = "ssh"
    host        = self.network_interface[0].ip_address
    user        = "ubuntu"
    private_key = file("/home/alex/otkazoblako/key.json")
  }
}

  name = "vm-${count.index + 1}"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.default.id
    nat       = true
  }

  metadata = {
    user-data = "#cloud-config\npackages:\n  - nginx\nruncmd:\n  - systemctl restart nginx\n  - systemctl enable nginx"
  }
}

# Таргет‑группа для балансировщика
resource "yandex_lb_target_group" "tg" {
  name = "otkazoblako-tg"

  target {
    subnet_id = yandex_vpc_subnet.default.id
    address   = yandex_compute_instance.vm[0].network_interface[0].ip_address
  }

  target {
    subnet_id = yandex_vpc_subnet.default.id
    address   = yandex_compute_instance.vm[1].network_interface[0].ip_address
  }
}

# Сетевой балансировщик нагрузки (NLB)
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "otkazoblako-nlb"

  listener {
    name        = "http"
    port        = 80
    target_port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.tg.id

    healthcheck {
      name = "http-healthcheck"
      http_options {
        port = 80
        path = "/"
      }
      interval = 10
      timeout  = 5
      healthy_threshold  = 2
      unhealthy_threshold = 2
    }
  }
}
output "balancer_external_ip" {
  description = "Внешний IP сетевого балансировщика"
  value = one(
    [for listener in yandex_lb_network_load_balancer.nlb.listener :
      one([
        for addr_spec in listener.external_address_spec :
          addr_spec.address
      ])
      if listener.name == "http"
    ]
  )
}

output "vm_internal_ips" {
  description = "Внутренние IP-адреса ВМ"
  value = [for vm in yandex_compute_instance.vm : vm.network_interface[0].ip_address]
}

output "balancer_id" {
  description = "ID балансировщика"
  value = yandex_lb_network_load_balancer.nlb.id
}
