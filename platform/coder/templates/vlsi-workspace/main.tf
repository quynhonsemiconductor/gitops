# ── Coder template: one VLSI engineer's workspace (design §5.1) ─────────────
#
# Pushed from Git by scripts/coder-push-template.sh. NEVER hand-edited in the
# Coder UI: the UI copy is overwritten on the next push, and a manual edit is
# invisible in review.
#
# Shape: one pod in namespace vlsi-ws on the qnsc.vn/pool=vlsi node, a /home PVC on
# local-path-retain, the qnsc-eda image (digest pinned below), TTL 2 h with
# activity bump. Modules: VS Code (code-server) and
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

locals {
  # Kubernetes object NAMES use the workspace's immutable id (a UUID): lower
  # case by construction. Entra usernames are mixed case (NghiaVT, SinhHPT), and
  # a name built from them fails with "a lowercase RFC 1123 subdomain must
  # consist of lower case alphanumeric characters" — the first workspace build
  # failed exactly there (2026-11-07). The id also survives a user/workspace
  # rename, so the /home PVC is never orphaned.
  workspace_id = data.coder_workspace.me.id

  # Human-readable names belong in labels/annotations, not object names. Label
  # values are lower case, restricted to [a-z0-9_.-] and <=63 chars.
  owner_label     = trim(substr(lower(replace(data.coder_workspace_owner.me.name, "/[^A-Za-z0-9_.-]/", "-")), 0, 63), "-.")
  workspace_label = trim(substr(lower(replace(data.coder_workspace.me.name, "/[^A-Za-z0-9_.-]/", "-")), 0, 63), "-.")
}

variable "image" {
  type        = string
  description = "qnsc-eda digest from E (ghcr.io/quynhonsemiconductor/qnsc-eda@sha256:...). The image is PUBLIC (OSS tools only; anonymous pull verified 2026-11-06), so NO pull secret is needed. A new digest is a reviewed change to this file."
  # E's main build of 2026-11-07 (after qnsc-eda#4): amd64/linux, ubuntu:26.04
  # base, code-server 4.145.0 and the static Surfer bundle at /opt/surfer-web.
  # USER 1001:1001 (`coder`), HOME=/home/coder. Digest pin, never a tag.
  default = "ghcr.io/quynhonsemiconductor/qnsc-eda:main@sha256:97480692c237c5558e862596a8f94e561bab9efd58c09029cd0e3a36254c80da"
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
    # VS Code in the browser: code-server ships in qnsc-eda (E) on PATH.
    nohup code-server --bind-addr 127.0.0.1:13337 --disable-telemetry --auth none \
      >/tmp/code-server.log 2>&1 &

    # Surfer is the project's STATIC WEB BUILD (WASM) served as files, not
    # `surver`: that binary is a waveform server that REQUIRES file arguments
    # and is not a web UI (2026-11-07, E's image note). Serve a private copy of
    # the bundle plus a `waves` symlink to $HOME, so a user opens
    #   ?load_url=waves/sim/foo.fst
    # from the Surfer app and the browser loads ~/sim/foo.fst. Only this copy is
    # served — the rest of $HOME stays off the proxy except through `waves`.
    if [ -d /opt/surfer-web ]; then
      www="$HOME/.surfer-www"
      rm -rf "$www"
      mkdir -p "$www"
      cp -a /opt/surfer-web/. "$www/"
      ln -sfn "$HOME" "$www/waves"
      nohup python3 -m http.server --bind 127.0.0.1 --directory "$www" 8080 \
        >/tmp/surfer-web.log 2>&1 &
    else
      echo "surfer-web missing from the image (/opt/surfer-web)" >/tmp/surfer-web.log
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
    name      = "coder-${local.workspace_id}-home"
    namespace = "vlsi-ws"
    labels = {
      "app.kubernetes.io/name"   = "coder-workspace"
      "coder"                    = "workspace"
      "com.coder.user.username"  = local.owner_label
      "com.coder.workspace.name" = local.workspace_label
    }
    annotations = {
      "com.coder.user.username"  = data.coder_workspace_owner.me.name
      "com.coder.workspace.name" = data.coder_workspace.me.name
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
    name      = "coder-${local.workspace_id}"
    namespace = "vlsi-ws"
    labels = {
      "app.kubernetes.io/name"   = "coder-workspace"
      "coder"                    = "workspace"
      "com.coder.user.username"  = local.owner_label
      "com.coder.workspace.name" = local.workspace_label
    }
    annotations = {
      "com.coder.user.username"  = data.coder_workspace_owner.me.name
      "com.coder.workspace.name" = data.coder_workspace.me.name
    }
  }

  spec {
    restart_policy = "Never"
    # The vlsi pool: the node carries qnsc.vn/pool=vlsi:NoSchedule.
    node_selector = { "qnsc.vn/pool" = "vlsi" }
    toleration {
      key      = "qnsc.vn/pool"
      operator = "Equal"
      value    = "vlsi"
      effect   = "NoSchedule"
    }
    security_context {
      # 1001 = the qnsc-eda image's declared USER (checked in the pinned image
      # config: uid=gid=1001, `coder`). Running the pod as a different uid than
      # the image's owner leaves /home/coder-owned files unreadable in the worst
      # case and writes $HOME outside the PVC in the best.
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
      # The image's own HOME is /home/coder, the same path the PVC mounts and the
      # code-server `?folder=` uses. Set it explicitly so a future image that
      # moves HOME cannot silently write tool caches outside the PVC.
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
