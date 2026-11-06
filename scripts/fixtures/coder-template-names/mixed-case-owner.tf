# ── Coder template: one VLSI engineer's workspace (design §5.1) ─────────────
#
# Pushed from Git by scripts/coder-push-template.sh. NEVER hand-edited in the
# Coder UI: the UI copy is overwritten on the next push, and a manual edit is
# invisible in review.
#
# Shape: one pod in namespace vlsi-ws on the pool=vlsi node, a /home PVC on
# local-path-retain, the qnsc-eda image (digest from E — PLACEHOLDER until it
# reports), TTL 2 h with activity bump. Modules: VS Code (code-server) and
# Surfer web. KasmVNC is deliberately absent (design §3: no desktop).
#
# Sizing matches the ResourceQuota in platform/vlsi-ws: request 0.5 CPU /
# 1.5 GiB, limit 4 CPU / 6 GiB.
terraform {
  required_version = ">= 1.8"
  required_providers {
    coder      = { source = "coder/coder", version = "~> 2.9" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
  }
}

provider "coder" {}

# The workspace agent uses the in-cluster Service, not the WARP-only access URL:
# coder.qnsc.vn is private DNS and does not resolve from inside the cluster.
# Verify this on the pilot (README "Workspace template").
# In-cluster credentials: the template runs in the provisioner inside the Coder
# pod, whose ServiceAccount carries the Role in vlsi-ws (chart value
# workspaceNamespaces). No kubeconfig file is involved.
provider "kubernetes" {
  host                   = "https://kubernetes.default.svc"
  token                  = file("/var/run/secrets/kubernetes.io/serviceaccount/token")
  cluster_ca_certificate = file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

variable "image" {
  type        = string
  description = "qnsc-eda digest from E (ghcr.io/quynhonsemiconductor/qnsc-eda@sha256:...). The image is PUBLIC (OSS tools only; anonymous pull verified 2026-11-06), so NO pull secret is needed. A new digest is a reviewed change to this file."
  # E's build on main, 2026-11-06 (image created 14:08Z): amd64/linux,
  # ubuntu:26.04 base, USER 1001. Digest pin, never a tag.
  default = "ghcr.io/quynhonsemiconductor/qnsc-eda:main@sha256:e3ad00a1f912379fd89a5ff62edbfa57c868ee5871650881128dec33e8650626"
}

variable "home_size" {
  type    = string
  default = "10Gi"
}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  # Activity bump is Coder's default: the agent reports activity and the TTL
  # (2 h, set by the push command's --default-ttl) resets while the engineer
  # works. No Premium autostop requirement is used.
  startup_script = <<-EOT
    set -eu
    # VS Code in the browser: code-server ships in qnsc-eda (E).
    nohup code-server --bind-addr 127.0.0.1:13337 --disable-telemetry --auth none \
      >/tmp/code-server.log 2>&1 &
    # Surfer web: `surver` serves the waveform viewer for large files. The
    # qnsc-eda image (E) must ship it; the app below points at 8080.
    if command -v surver >/dev/null 2>&1; then
      nohup surver --port 8080 >/tmp/surver.log 2>&1 &
    fi
  EOT

  env = {
    # CoreDNS resolves coder.qnsc.vn to coder.coder.svc.cluster.local inside
    # the cluster (platform/vlsi-ws/coredns-coder.yaml), and the wildcard
    # certificate's SAN covers coder.qnsc.vn, so the agent uses the SAME URL
    # with normal TLS verification. No hostname or TLS exception.
    CODER_URL       = "https://coder.qnsc.vn"
    CODER_AGENT_URL = "https://coder.qnsc.vn"
  }
}

# VS Code via code-server (the image's copy), browser only. VS Code Desktop is
# left OFF for the pilot: the browser client is enough for RTL/simulation and
# avoids a second download path (design §3 keeps both options open).
resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code"
  display_name = "VS Code"
  url          = "http://localhost:13337/?folder=/home/coder"
  icon         = "/icon/code.svg"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 10
    threshold = 10
  }
}
resource "coder_app" "surfer" {
  agent_id     = coder_agent.main.id
  slug         = "surfer"
  display_name = "Surfer"
  url          = "http://localhost:8080"
  icon         = "/icon/widgets.svg"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://localhost:8080"
    interval  = 10
    threshold = 10
  }
}

resource "coder_metadata" "workspace" {
  resource_id = coder_agent.main.id
  item {
    key   = "image"
    value = var.image
  }
  item {
    key   = "pool"
    value = "vlsi"
  }
  item {
    key   = "home"
    value = "${var.home_size} local-path-retain"
  }
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}-home"
    namespace = "vlsi-ws"
    labels = {
      "app.kubernetes.io/name" = "coder-workspace"
      "coder"                  = "workspace"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path-retain"
    resources {
      requests = { storage = var.home_size }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    namespace = "vlsi-ws"
    labels = {
      "app.kubernetes.io/name" = "coder-workspace"
      "coder"                  = "workspace"
    }
  }

  spec {
    restart_policy = "Never"
    # The vlsi pool: the node carries qnsc.vn/pool=vlsi:NoSchedule.
    node_selector = { pool = "vlsi" }
    toleration {
      key      = "qnsc.vn/pool"
      operator = "Equal"
      value    = "vlsi"
      effect   = "NoSchedule"
    }
    security_context {
      # 1001 = the qnsc-eda image's declared USER (checked in the pinned image
      # config). Running the pod as a different uid than the image's owner
      # leaves /home/eda-owned files unreadable in the worst case and writes
      # $HOME outside the PVC in the best.
      run_as_user     = 1001
      run_as_group    = 1001
      run_as_non_root = true
      fs_group        = 1001
      seccomp_profile { type = "RuntimeDefault" }
    }
    container {
      name              = "workspace"
      image             = var.image
      image_pull_policy = "IfNotPresent"
      command           = ["sh", "-c", coder_agent.main.init_script]
      security_context {
        run_as_user                = 1001
        run_as_group               = 1001
        run_as_non_root            = true
        allow_privilege_escalation = false
        capabilities { drop = ["ALL"] }
        seccomp_profile { type = "RuntimeDefault" }
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      # The image's own HOME is /home/eda, which the PVC does not back; point it
      # at the mounted home so tool caches (code-server, EDA rc files) persist.
      env {
        name  = "HOME"
        value = "/home/coder"
      }
      # Matches platform/vlsi-ws quota: request 0.5 CPU / 1.5 GiB, limit 4 / 6.
      resources {
        requests = { cpu = "500m", memory = "1536Mi" }
        limits   = { cpu = "4", memory = "6Gi" }
      }
      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }
    }
    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }
  }
}
