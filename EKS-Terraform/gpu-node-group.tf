# ──────────────────────────────────────────────
#  GPU Node Group — Pilot 2 (self-hosted LLM)
#
#  Instance: g4dn.xlarge — 4 vCPU, 16 GB RAM, 1x NVIDIA T4 (16 GB VRAM)
#  AMI type: AL2_x86_64_GPU — ships NVIDIA drivers + nvidia-container-runtime.
#            Standard AL2 nodes do NOT have GPU drivers.
#  Capacity: SPOT — ~$0.19/hr vs $0.526/hr on-demand.
#
#  Taint nvidia.com/gpu=true:NoSchedule prevents regular workloads from
#  landing on expensive GPU nodes. Only pods that explicitly tolerate it
#  (Ollama, NVIDIA device plugin DaemonSet) are scheduled here.
#
#  Cost control: scale to 0 when not running demos.
#    aws eks update-nodegroup-config \
#      --cluster-name nimbus-cluster --nodegroup-name gpu-nodes \
#      --scaling-config minSize=0,maxSize=2,desiredSize=0
# ──────────────────────────────────────────────

resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "gpu-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  ami_type       = "AL2_x86_64_GPU"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.gpu_node_instance_type]
  disk_size      = 50

  scaling_config {
    desired_size = var.gpu_node_desired_size
    min_size     = 0
    max_size     = var.gpu_node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    workload = "gpu"
    Project  = "nimbus-retail-platform"
  }

  tags = {
    Project = "nimbus-retail-platform"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}

# ──────────────────────────────────────────────
#  NVIDIA Device Plugin
#
#  Runs as a DaemonSet on every GPU node. It registers nvidia.com/gpu as a
#  schedulable Kubernetes resource. Without it, pods cannot request a GPU —
#  the kubelet has no visibility of the hardware.
#
#  Must tolerate the nvidia.com/gpu taint to land on GPU nodes.
# ──────────────────────────────────────────────

resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.17.0"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    yamlencode({
      nodeSelector = {
        workload = "gpu"
      }
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
      # Chart 0.17.0 defaults to NFD-based nodeAffinity (feature.node.kubernetes.io/pci-10de.present).
      # NFD is not deployed in this cluster, so override affinity to match our workload=gpu node label.
      affineToTaintsAndTolerations = false
    })
  ]

  depends_on = [aws_eks_node_group.gpu]
}
