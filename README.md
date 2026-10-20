# Cross-Region Inference with Amazon EKS Hybrid Nodes

This experimental sample shows how to expand an existing Amazon EKS cluster with capacity from another AWS Region. EC2 instances in the remote Region join the cluster as EKS Hybrid Nodes and run workloads next to the cluster's in-region nodes. The sample launches them On-Demand or into an EC2 Capacity Block.

The pattern suits small, one-off additions of capacity:

- Testing a new instance type or generation that is not yet available in the cluster's Region.
- Expanding a cluster temporarily for a training job.
- Adding inference capacity for a fixed period.

This sample does not provide Karpenter-style scaling into another Region, and **it does not find or obtain capacity for you**. You add a fixed set of nodes by hand: each node registers through a Systems Manager hybrid activation, which keeps the setup manual and prevents further automation. Treat it as a demonstration of feasibility for fixed, one-off deployments.

To stay self-contained, the sample also creates the cluster that stands in for your existing one. Terraform manages both Regions in one root state, while separate modules own the cluster, network connectivity, and repeatable Hybrid Node lifecycle.

To apply this pattern to a cluster and network you already run, rather than to the one created here, see the [EKS Hybrid Nodes architecture advisor skill](https://github.com/aws-samples/sample-aws-solutions-skills/tree/main/eks-hybrid-node-architecture-advisor-skill). It reviews your existing topology and helps you work out the connectivity, CIDR, and DNS decisions this sample makes for you.

> [!WARNING]
> Amazon EKS Hybrid Nodes is designed for customer-managed on-premises and edge infrastructure. This sample intentionally runs Hybrid Nodes on Amazon EC2 in a second AWS Region. This topology is not a supported production architecture. Use it only in a sandbox for demonstrations and technical evaluation.

> [!CAUTION]
> This sample creates billable EKS, EC2, NAT Gateway, and cross-Region data-transfer resources. With the example configuration it costs about **$1.68 per hour** while deployed. See [Cost](#cost), and follow [Cleanup](#cleanup) when you finish.

> [!IMPORTANT]
> This is sample code, for non-production usage. You should work with your security and legal teams to meet your organizational security, regulatory, and compliance requirements before deployment.

## What this sample demonstrates

### Bootstrapping Hybrid Nodes with GPU support

How a remote EC2 GPU instance becomes a schedulable EKS node. Steps 1 to 5.

- One EKS control plane and core managed node group in the cluster Region.
- Private EC2 Hybrid Nodes in a configurable remote capacity Region.
- Inter-Region VPC peering for kubelet and inference traffic.
- NAT egress for private Hybrid Node bootstrap, EKS API registration, and image downloads.
- Systems Manager activation-based Hybrid Node registration.
- Persistent NVIDIA container runtime configuration after `nodeadm` initialization.
- Fleet-wide GPU discovery with Node Feature Discovery (NFD).
- Standard `nvidia.com/gpu` scheduling with the NVIDIA device plugin.
- Optional EC2 Capacity Block placement.

### Running a GPU workload: cross-Region inference

What you can then do with that capacity, as one worked example. Steps 6 and 7.

- vLLM serving a model on the remote Hybrid Node's GPU.
- Direct cross-Region vLLM Service access without a persistent proxy.
- Optional OpenAI-compatible LiteLLM gateway behind an Application Load Balancer.

## Architecture

![Architecture: an Amazon EKS cluster in the cluster Region with a core managed node group, the EKS control plane, an SSM hybrid activation, and an optional ALB with a LiteLLM gateway, connected by inter-Region VPC peering to a dedicated remote VPC where a private EC2 GPU instance runs as an EKS Hybrid Node with Cilium, NFD, the NVIDIA device plugin, and a host-network vLLM endpoint, plus a NAT gateway for bootstrap egress](docs/architecture.drawio.png)

Numbered flows: (1) Hybrid Node to the public EKS API endpoint on TCP 443 through the remote NAT gateway; (2) the control plane to the kubelet on TCP 10250 over VPC peering; (3) bootstrap, Systems Manager registration, and image and model downloads through the same NAT gateway; (4) the optional gateway's inference path.

Flow (1) leaves the remote Region instead of crossing the peering connection, because the private endpoint does not resolve there. See the [FAQ](#how-does-the-hybrid-node-reach-the-eks-api).

The [FAQ](#faq-design-decisions) explains the routing, source NAT, and DNS choices behind this layout.

```text
infra/
├── modules/cluster-region/       EKS, core nodes, cluster VPC, IAM access
├── modules/hybrid-connectivity/  Remote VPC, subnets, peering, routes, activation
└── modules/hybrid-node/          Repeatable EC2 Hybrid Node lifecycle

docs/
├── architecture.drawio.png       Architecture diagram
├── llm-gateway.md                Optional LiteLLM gateway and ALB guide
└── inference-path.drawio.png     Gateway request path

kubernetes/
├── inference-sample.yaml
├── litellm-values.yaml           Optional LiteLLM gateway (Helm values)
├── node-feature-discovery-values.yaml
└── nvidia-device-plugin-values.yaml
```

## Cost

You are responsible for the cost of the AWS services used while running this sample. With the example `terraform.tfvars` (cluster in `us-west-2`, Hybrid Node in `us-east-1`), it costs about **$1.68 per hour**, or $40 per day, at On-Demand list prices in USD at the time of writing. Confirm current prices with the [AWS Pricing Calculator](https://calculator.aws/).

| Resource | Per hour |
|---|---|
| Hybrid Node EC2 instance, `g5.2xlarge` | $1.212 |
| [EKS Hybrid Nodes](https://aws.amazon.com/eks/pricing/) fee, 8 vCPU at $0.02 per vCPU-hour | $0.160 |
| EKS control plane | $0.100 |
| Core managed node, `m6i.large` | $0.096 |
| Two NAT Gateways and their public IPv4 addresses | $0.100 |
| EBS volumes and KMS key | $0.014 |

Every entry you add to `hybrid_nodes` adds its EC2 price plus the per-vCPU Hybrid Nodes fee.

> [!NOTE]
> For instances with more than 32 vCPU, including the P-series such as `p4d.24xlarge`, `p5.48xlarge`, and `p6-b200.48xlarge`, contact your AWS account team for a pricing quote rather than applying the per-vCPU rate above.

Traffic adds small usage charges: $0.045 per GB through the NAT Gateways (the first vLLM start pulls about 9 GB), $0.02 per GB in each direction across the Region boundary, and CloudWatch Logs for the control plane. The optional gateway adds an Application Load Balancer at about $17 per month. A Capacity Block is paid upfront and is not refunded on cleanup.

[Cleanup](#cleanup) removes every hourly charge.

## Prerequisites

- A sandbox AWS account and credentials with wide VPC, EKS, EC2, IAM, KMS, and Systems Manager permissions.
- Terraform 1.9 or later.
- AWS CLI v2.
- `kubectl` and Helm 3.
- Network access to the public EKS API endpoint, or private connectivity to the cluster VPC.
- GPU capacity and a matching EKS-optimized AL2023 NVIDIA AMI in the remote Region for sample app deployment

## 1. Configure Terraform

This repository does not configure a Terraform backend. Local state works for a disposable demonstration, but it contains the Systems Manager activation code and rendered EC2 user data. Configure an encrypted remote backend with restricted access before shared use.

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Update `terraform.tfvars` before deployment:

1. Set `allowed_account_ids` to the intended 12-digit AWS account ID. This guard prevents deployment into another account.
2. Set `cluster_region` and `remote_region` to different Regions.
3. Select non-overlapping cluster VPC, remote VPC, node, pod, and egress-subnet CIDRs. Size `remote_pod_cidrs` for the pods per node you eventually need: it [cannot change after Cilium is installed](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-cni.html#hybrid-nodes-cilium-install), so rebuild rather than widen it. The sample slices a `/25` per node from that pool, for 126 pods each.
4. Set the GPU subnet Availability Zone and choose an NVIDIA instance type with available capacity.
5. Place the NAT Gateway egress subnet in the same Availability Zone when possible to avoid cross-Availability Zone NAT charges.
6. Add a Capacity Block reservation only when using that flow. Set it now if so, following [Optional: Use an EC2 Capacity Block](#optional-use-an-ec2-capacity-block): it is `terraform.tfvars` configuration, so it has to be in place before step 2.
7. Review the EKS endpoint configuration described below.

Resolve the EKS-optimized AL2023 NVIDIA AMI in the remote capacity Region:

```bash
REMOTE_REGION=us-east-1
KUBERNETES_VERSION=1.37
aws ssm get-parameter \
  --region "$REMOTE_REGION" \
  --name "/aws/service/eks/optimized-ami/${KUBERNETES_VERSION}/amazon-linux-2023/x86_64/nvidia/recommended/image_id" \
  --query Parameter.Value \
  --output text
```

Set the returned AMI ID on the GPU node. The AMI, architecture, Kubernetes version, and remote Region must match.

The public EKS API endpoint is always enabled, because the Hybrid Node registers through it. Terraform admits the remote NAT gateway's address itself, so `endpoint_public_access_cidrs` decides only how much further you open the API. Set it in `terraform.tfvars` to the CIDR you reach the API from, as `x.x.x.x/32` or your network's range, or to `0.0.0.0/0` for a throwaway sandbox. Terraform refuses to plan while it is unset. `terraform.tfvars` is in `.gitignore`, so nothing you put there is committed.

## 2. Create the infrastructure

Apply the Terraform:

```bash
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=tfplan
terraform show -no-color tfplan
terraform apply tfplan
```

Review the saved plan before applying it. Terraform creates resources in both configured Regions and may opt into each configured Local Zone group.

Then connect to the cluster and wait for the Hybrid Node to register:

```bash
aws eks update-kubeconfig \
  --region "$(terraform output -raw cluster_region)" \
  --name "$(terraform output -raw cluster_name)"
kubectl wait --for=create node \
  --selector=eks.amazonaws.com/compute-type=hybrid \
  --timeout=15m
```

A newly registered Hybrid Node remains NotReady until Cilium starts. If the node does not register, inspect `/var/log/cloud-init-output.log` through Systems Manager Fleet Manager before installing Kubernetes components.

## 3. Install Cilium

Terraform renders Cilium values from the live cluster endpoint and remote pod pool. The values target Hybrid Nodes, tolerate their taints, retain kube-proxy, and enable local Service traffic distribution.

Install the AWS-maintained Cilium build from ECR Public. For the supported versions, see [Version compatibility](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-cni.html#hybrid-nodes-cilium-version-compatibility).

```bash
terraform output -raw cilium_values > ../kubernetes/cilium-values.generated.yaml
helm upgrade --install cilium \
  oci://public.ecr.aws/eks/cilium/cilium \
  --version 1.18.13-1 \
  --namespace kube-system \
  --values ../kubernetes/cilium-values.generated.yaml \
  --wait \
  --timeout 10m
kubectl wait --for=condition=Ready node \
  --selector=eks.amazonaws.com/compute-type=hybrid \
  --timeout=10m
```

## 4. Install Node Feature Discovery

Install standalone NFD before the NVIDIA device plugin. Its values publish generic PCI vendor labels across compatible NVIDIA fleets.

```bash
helm upgrade --install node-feature-discovery \
  oci://registry.k8s.io/nfd/charts/node-feature-discovery \
  --version 0.19.0 \
  --namespace kube-system \
  --values ../kubernetes/node-feature-discovery-values.yaml \
  --wait \
  --timeout 10m
kubectl get crd \
  nodefeatures.nfd.k8s-sigs.io \
  nodefeaturerules.nfd.k8s-sigs.io \
  nodefeaturegroups.nfd.k8s-sigs.io
kubectl get nodes \
  -l feature.node.kubernetes.io/pci-10de.present=true \
  -o custom-columns='NAME:.metadata.name,NVIDIA-PCI:.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present'
```

Continue only when the GPU node reports `NVIDIA-PCI=true`. If it does not, inspect the NFD worker on that node and verify that the host exposes its NVIDIA PCI device.

## 5. Install the NVIDIA device plugin

The plugin uses NFD's standard label, initializes NVML through containerd's NVIDIA runtime, and advertises usable devices as `nvidia.com/gpu`. Its chart does not install another NFD release.

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update nvdp
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --version 0.20.1 \
  --namespace kube-system \
  --values ../kubernetes/nvidia-device-plugin-values.yaml \
  --wait \
  --timeout 10m
kubectl get daemonset nvidia-device-plugin \
  --namespace kube-system \
  -o custom-columns='DESIRED:.status.desiredNumberScheduled,CURRENT:.status.currentNumberScheduled,READY:.status.numberReady'
kubectl get nodes \
  -l feature.node.kubernetes.io/pci-10de.present=true \
  -o custom-columns='NAME:.metadata.name,NVIDIA-PCI:.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present,GPU:.status.allocatable.nvidia\.com/gpu'
```

Deploy inference only after the DaemonSet reports a ready pod and the GPU column reports a non-zero value.

## 6. Run cross-Region inference

The sample deploys `Qwen/Qwen2.5-0.5B-Instruct` with one vLLM replica. The pod requests one GPU and uses `hostNetwork`, so its Service endpoint is the Hybrid Node's remote VPC address.

The default model is open and downloads anonymously. For gated models, or when anonymous Hugging Face downloads hit rate limits, create an optional token Secret before deploying. The Deployment reads it as `HF_TOKEN` when present and starts without it otherwise:

```bash
kubectl create namespace cross-region-inference --dry-run=client -o yaml | kubectl apply -f -
# Prompt for the token so it stays out of shell history.
read -rs HF_TOKEN
kubectl -n cross-region-inference create secret generic hf-token \
  --from-literal=token="$HF_TOKEN"
unset HF_TOKEN
```

```bash
kubectl apply -f ../kubernetes/inference-sample.yaml
kubectl -n cross-region-inference rollout status deployment/remote-vllm --timeout=20m
kubectl -n cross-region-inference get pod -l app=remote-vllm -o wide
kubectl -n cross-region-inference get endpointslice \
  -l kubernetes.io/service-name=remote-vllm
```

The first deployment downloads an 8 GB or larger container image and the model. Startup can take several minutes.

```bash
kubectl -n cross-region-inference describe pod -l app=remote-vllm
kubectl -n cross-region-inference logs deployment/remote-vllm --tail=200
```

The pod must become Ready on the Hybrid Node. The EndpointSlice must report the remote VPC address.

Test the Service from a temporary client pinned to the core managed node:

```bash
kubectl run inference-client \
  --namespace cross-region-inference \
  --image=curlimages/curl:8.22.0 \
  --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"node-role":"core"}}}' \
  --rm -i \
  -- curl --fail http://remote-vllm:8000/health
```

A successful response proves that traffic from the cluster Region reaches the vLLM host-network endpoint through VPC peering.

To send an OpenAI-compatible request from the administrator workstation, start a temporary tunnel:

```bash
kubectl -n cross-region-inference port-forward service/remote-vllm 8000:8000
```

In another terminal, send a request:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Why use EKS Hybrid Nodes for inference?"}]}'
```

Stop the tunnel with `Ctrl-C`. Step 6 deploys no persistent proxy. The optional
gateway in step 7 replaces the tunnel with a durable endpoint.

## 7. Optional: Serve inference through an ALB and LiteLLM gateway

To publish an OpenAI-compatible endpoint outside the cluster, without exposing the Hybrid Node, deploy the optional LiteLLM gateway behind an Application Load Balancer. See [docs/llm-gateway.md](docs/llm-gateway.md).

## Optional: Use an EC2 Capacity Block

Place the node in the reservation's Availability Zone and set one reservation field:

```hcl
remote_node_subnets = {
  capacity_block = {
    cidr              = "172.16.1.0/24"
    availability_zone = "us-east-1a"
  }
}

hybrid_nodes = {
  capacity_block_gpu = {
    subnet_key                    = "capacity_block"
    instance_type                 = "p5.48xlarge"
    ami_id                        = "ami-replace-with-gpu-ready-image"
    capacity_block_reservation_id = "cr-0123456789abcdef0"
    node_taints                   = ["nvidia.com/gpu=true:NoSchedule"]
  }
}
```

The module sets `market_type = "capacity-block"` and targets the reservation. The subnet Availability Zone, instance type, operating system, and AMI must match the reservation. Capacity Block instances terminate near the reservation end time, so store durable model data elsewhere.

## Cleanup

Run cleanup commands from `infra/`, and stop any active `kubectl port-forward` first.

1. If you deployed the optional gateway, follow its [cleanup](docs/llm-gateway.md#cleanup) first. The load balancer is created by the controller, not Terraform, so it must be deleted while the controller is still running.
2. Destroy everything else. Terraform deletes the cluster with its workloads, so nothing else needs to be uninstalled first:

```bash
CLUSTER_REGION="$(terraform output -raw cluster_region)"
terraform plan -destroy -out=destroy.tfplan
terraform show -no-color destroy.tfplan
terraform apply destroy.tfplan
terraform state list   # prints nothing when everything is gone
rm -f destroy.tfplan tfplan ../kubernetes/cilium-values.generated.yaml
```

Terminating a Hybrid Node leaves its Systems Manager managed-instance record behind. Run this in the same shell as the destroy, or set `CLUSTER_REGION` to your `cluster_region` value: Terraform outputs are empty after destroy. Deregister the `mi-*` records whose IP address falls in `remote_node_cidrs`; their status can take a few minutes to change to `ConnectionLost`:

```bash
aws ssm describe-instance-information --region "$CLUSTER_REGION" \
  --filters Key=ResourceType,Values=ManagedInstance \
  --query 'InstanceInformationList[?PingStatus==`ConnectionLost`].[InstanceId,IPAddress,ComputerName]' \
  --output table
aws ssm deregister-managed-instance --region "$CLUSTER_REGION" --instance-id <mi-id>
```

The KMS key stays visible until its deletion window ends, and any Local Zone group Terraform opted into (`remote_zone_group_names`) returns to `not-opted-in`.

## FAQ: design decisions

### How does traffic reach the remote Region?

Node and pod routing are separate. VPC peering routes the remote VPC and therefore every Hybrid Node IP. Cilium allocates each Hybrid Node a block from `remote_pod_cidrs`. The pod pool must not overlap the cluster VPC, remote VPC, or node CIDR.

General VPC-to-pod traffic requires BGP or the EKS Hybrid Nodes gateway. This inference workload avoids that requirement by using `hostNetwork`. The `remote-vllm` Service therefore publishes the routable Hybrid Node IP as its endpoint. Clients in the cluster Region call that endpoint directly across peering.

The cluster route tables send the remote VPC CIDR through one inter-Region VPC peering connection. That route covers every subnet and node IP in the remote VPC. A Local Zone subnet remains part of its parent Region VPC, so it does not require another peering connection.

Private Hybrid Node subnets send bootstrap, Systems Manager, package, and image-registry traffic through one NAT Gateway. Only the dedicated egress subnet routes directly to the Internet Gateway. Hybrid Nodes receive no public IP addresses.

### How does the Hybrid Node reach the EKS API?

Through the public endpoint, out the remote NAT Gateway, not across the peering connection. EKS publishes the private endpoint through a Route 53 private hosted zone associated with the cluster VPC alone, so the endpoint hostname does not resolve to its private addresses from the remote VPC. The `allow_remote_vpc_dns_resolution` peering option does not change that; it covers only EC2 public DNS hostnames. So everything on the node that calls the API server — `nodeadm`, kubelet, and Cilium — takes the NAT path.

This is the opposite direction from flow (2), and the two do not conflict. Outbound calls *to* the API server leave through the NAT Gateway. Connections the control plane opens *to* the kubelet on TCP 10250, for `kubectl logs`, `exec`, `port-forward`, and metrics, start from the control-plane network interfaces in the cluster VPC and reach the node's routable address over peering.

Terraform appends the NAT Gateway's address to `endpoint_public_access_cidrs`, so a node can register without the endpoint being open to the internet. To move this traffic onto peering instead, add Route 53 Resolver inbound and outbound endpoints and drop the public endpoint — the pattern for Direct Connect or a VPN, and about $0.50 per hour more here.

### Why are the remote networks excluded from source NAT?

Terraform sets `AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS` on the vpc-cni addon, listing the
remote VPC and remote pod CIDRs. Without it, calls to the `remote-vllm` Service
succeed or time out depending on which elastic network interface the calling pod
happened to land on.

By default vpc-cni source-NATs pod traffic leaving the VPC to the node's primary
interface address, while separately binding each pod to a specific interface through
policy routing. A pod on a secondary interface then egresses that interface carrying
an address belonging to the primary one, and EC2 source/destination checking drops
the packet. vpc-cni chooses its routing mark from the destination *before* DNAT, so
a ClusterIP that kube-proxy rewrites to an out-of-VPC endpoint bypasses the
mechanism. Connecting straight to the Hybrid Node IP keeps working throughout, which
makes the failure look intermittent rather than structural.

With those destinations excluded, pods keep their own source address, which is
assigned to the interface they leave through, so the check passes.

`AWS_VPC_K8S_CNI_EXTERNALSNAT=true` fixes the same fault, but disables source NAT for
every destination outside the VPC rather than just the remote networks. Scoping it
leaves internet egress untouched and preserves the caller's address for
NetworkPolicy, flow logs, and applications that inspect it. The remote pod CIDRs are
listed for when they are made routable with Cilium BGP or the EKS Hybrid Nodes
gateway; until then they are unreachable either way. Confirm the setting survives an
addon upgrade:

```bash
kubectl -n kube-system get daemonset aws-node \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS")]}{.name}={.value}{"\n"}{end}'
```

### Why does DNS stay in the cluster Region?

CoreDNS runs only on the cluster-Region managed nodes. Do not move a replica onto a Hybrid Node: it would receive a Cilium overlay address from `remote_pod_cidrs`, which VPC peering does not route, so cluster DNS would become unreachable from the cluster Region. The vLLM Deployment in step 6 sets `dnsPolicy: Default` so the remote pod uses its node's resolver instead.

### How does a GPU Hybrid Node become usable?

A remote EC2 instance needs four layers before Kubernetes can schedule GPU inference:

1. VPC peering makes the node IP routable to the cluster Region.
2. `nodeadm` registers the instance as an EKS Hybrid Node with a Systems Manager activation.
3. Cilium makes the node Ready and supplies pod networking.
4. NFD and the NVIDIA device plugin discover and advertise the GPU.

The Hybrid Node bootstrap runs in this order:

1. `nodeadm install`
2. `nodeadm init`
3. `nvidia-ctk runtime configure --runtime=containerd --set-as-default`
4. `systemctl restart containerd`

`nodeadm init` writes the final containerd configuration. The NVIDIA runtime configuration must therefore run afterward. The module applies this step only when the AMI contains `nvidia-ctk`, so CPU nodes skip it.

The GPU-ready AMI must already contain the NVIDIA driver, NVML, `nvidia-container-toolkit`, and `nvidia-ctk`. Terraform does not install or select driver versions. Standalone NFD then publishes `feature.node.kubernetes.io/pci-10de.present=true` for NVIDIA PCI devices. The NVIDIA device plugin uses that standard label and registers usable devices as `nvidia.com/gpu`.

### Why Systems Manager activations rather than IAM Roles Anywhere?

`nodeadm` takes one of two mutually exclusive credential providers, `hybrid.ssm` or `hybrid.iamRolesAnywhere`. This sample uses Systems Manager because it needs nothing but an IAM role.

IAM Roles Anywhere suits the on-premises case better and would remove three entries from [Current boundaries](#current-boundaries): the activation code in Terraform state, the 24-hour re-registration window, and the leftover `mi-*` records. It needs a certificate authority for the trust anchor and a per-node key pair on each host, which on EC2 means baking it into an AMI or writing it through user data, so it trades one secret in state for another.

The EC2 instance profile is not an option for either provider. `nodeadm` does not read instance metadata for hybrid credentials, since Hybrid Nodes targets hardware without IMDS, and an instance using its own profile would be an ordinary `EC2_LINUX` node needing a node group in the cluster's VPC.

## Current boundaries

- Cross-Region EC2 Hybrid Nodes remains an experimental demonstration.
- The EKS API public endpoint is required, because the private endpoint does not resolve from the remote Region. Putting node traffic on the peering connection instead needs Route 53 Resolver endpoints; see the [FAQ](#how-does-the-hybrid-node-reach-the-eks-api).
- The remote Region uses one NAT Gateway, which incurs hourly and data-processing charges until cleanup.
- A NAT Gateway in another Availability Zone can also incur cross-Availability Zone data charges.
- The sample uses one vLLM replica, although Terraform supports multiple Hybrid Nodes.
- vLLM listens on `0.0.0.0:8000` with `hostNetwork` and no authentication. Anything that can reach the Hybrid Node on that port can use the GPU, which the node security group limits to the cluster VPC CIDR. The optional gateway in step 7 adds a key, but it does not close the direct path.
- General cloud-to-Hybrid-Node pod connectivity needs BGP or the EKS Hybrid Nodes gateway.
- `nodeadm` is pinned by `nodeadm_version` and checked against the `nodeadm.sha256` published with that release.
- Systems Manager hybrid activations expire 24 hours after creation by default, and
  Terraform does not renew them. The provider records `expired = true` and reports no
  change, so a plan stays empty. Already-registered nodes keep working, but adding or
  replacing one after that window fails to register until you recreate the activation
  explicitly:

  ```bash
  terraform apply -replace='module.hybrid_connectivity.aws_ssm_activation.hybrid_nodes'
  ```

  The replacement activation is written into the user data of any node Terraform
  rebuilds in the same apply.
- Cilium runs only on Hybrid Nodes and the VPC CNI only on cluster-Region nodes. The
  two coexist rather than one replacing the other: AWS ships the VPC CNI with
  anti-affinity for `eks.amazonaws.com/compute-type: hybrid`, and AWS does not
  support Cilium on nodes in AWS Cloud.
- The model revision is not pinned; vLLM downloads the current `Qwen/Qwen2.5-0.5B-Instruct` revision from Hugging Face.
- The local Terraform state holds the Systems Manager activation code until the activation expires. Anyone who can read the state or the instance user data before then can register another Hybrid Node.
- The optional gateway adds load balancer charges and sends request and response
  traffic across the Region boundary in both directions.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.

This sample deploys third-party open source software, including vLLM, LiteLLM, Cilium, Node Feature Discovery, the NVIDIA device plugin, and the AWS Load Balancer Controller, and downloads the third-party `Qwen/Qwen2.5-0.5B-Instruct` model from Hugging Face. Each is subject to its own license terms. Review them before use.

## References

- [EKS Hybrid Nodes architecture advisor skill](https://github.com/aws-samples/sample-aws-solutions-skills/tree/main/eks-hybrid-node-architecture-advisor-skill)
- [Amazon EKS Hybrid Nodes prerequisites](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-prereqs.html)
- [Configure a CNI for Hybrid Nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-cni.html)
- [Run GenAI inference across environments with EKS Hybrid Nodes](https://aws.amazon.com/blogs/containers/run-genai-inference-across-environments-with-amazon-eks-hybrid-nodes/)
- [NVIDIA Kubernetes device plugin v0.20.1](https://github.com/NVIDIA/k8s-device-plugin/releases/tag/v0.20.1)
