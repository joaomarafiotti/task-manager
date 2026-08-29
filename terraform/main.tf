terraform {
  required_version = ">= 1.5.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "cluster_name" {
  type    = string
  default = "devops-entrega"
}

resource "null_resource" "build_image" {
  triggers = {
    dockerfile = filesha256("${path.module}/../Dockerfile")
    package    = filesha256("${path.module}/../package.json")
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/.."
    interpreter = ["PowerShell", "-Command"]
    command     = "docker build -t task-manager:local ."
  }
}

resource "null_resource" "k3d_cluster" {
  depends_on = [null_resource.build_image]

  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      k3d cluster delete ${var.cluster_name} 2>$null
      k3d cluster create ${var.cluster_name} --servers 1 --agents 1 --wait
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["PowerShell", "-Command"]
    command     = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}

resource "null_resource" "import_image" {
  depends_on = [null_resource.k3d_cluster, null_resource.build_image]

  triggers = {
    image = "task-manager:local"
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "k3d image import task-manager:local -c ${var.cluster_name}"
  }
}

resource "null_resource" "deploy_app" {
  depends_on = [null_resource.import_image]

  triggers = {
    postgres = filesha256("${path.module}/k8s/postgres.yaml")
    app      = filesha256("${path.module}/k8s/task-manager.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      kubectl apply -f "${path.module}/k8s/postgres.yaml"
      kubectl rollout status deployment/postgres --timeout=180s
      kubectl apply -f "${path.module}/k8s/task-manager.yaml"
      kubectl rollout status deployment/task-manager --timeout=240s
    EOT
  }
}

resource "null_resource" "monitoring" {
  depends_on = [null_resource.deploy_app]

  triggers = {
    stack = "prometheus-grafana-loki-promtail-v1"
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"

      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
      helm repo add grafana https://grafana.github.io/helm-charts --force-update
      helm repo update

      helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
        --namespace monitoring --create-namespace `
        --set grafana.adminPassword=admin `
        --set prometheus.prometheusSpec.retention=2h `
        --set prometheus.prometheusSpec.resources.requests.memory=256Mi `
        --set prometheus.prometheusSpec.resources.limits.memory=768Mi `
        --set grafana.resources.requests.memory=128Mi `
        --set grafana.resources.limits.memory=384Mi

      helm upgrade --install loki grafana/loki-stack `
        --namespace monitoring `
        --set grafana.enabled=false `
        --set promtail.enabled=true

      kubectl rollout status deployment/monitoring-grafana -n monitoring --timeout=300s
    EOT
  }
}

output "proximos_passos" {
  value = <<-EOT
    Aplicacao: kubectl port-forward svc/task-manager 3000:3000
    Grafana:   kubectl port-forward svc/monitoring-grafana 3001:80 -n monitoring
    Login Grafana: admin / admin
  EOT
}
