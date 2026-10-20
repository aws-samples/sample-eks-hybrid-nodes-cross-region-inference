# Optional: LiteLLM gateway behind an Application Load Balancer

This optional extension of the [cross-Region inference sample](../README.md) publishes
the remote vLLM endpoint as an OpenAI-compatible API through a LiteLLM gateway and an
Application Load Balancer in the cluster Region.

Complete steps 1 through 6 of the README first. Run every command from `infra/`, as in
the README.


Step 6 of the README reaches the remote GPU from inside the cluster. This guide publishes an
OpenAI-compatible endpoint outside it, without exposing the Hybrid Node.

A load balancer cannot target the remote GPU directly in `instance` mode: registering
instances by ID is unsupported when they sit in a peered VPC, in the same Region or a
different one. Registering the Hybrid Node by IP is permitted, but it would make the
load balancer depend on the peering path for every health check, and an
internet-facing load balancer in the public subnets has no route to the remote VPC,
because Terraform adds the peering route only to the private and intra route tables.

Placing a gateway in the cluster Region avoids all of that. The load balancer
registers gateway pod IPs, which are ordinary vpc-cni addresses in its own VPC, and
the gateway makes the cross-Region hop itself through the `remote-vllm` Service:

![Request path of the optional gateway: client to an Application Load Balancer that targets LiteLLM pod IPs on the core nodes, LiteLLM to the ClusterIP Service remote-vllm, kube-proxy DNAT to the Hybrid Node IP, and across inter-Region VPC peering to the host-network vLLM pod on the remote GPU node, with notes on why vpc-cni source NAT is excluded for the remote CIDRs and why DNS stays in the cluster Region](inference-path.drawio.png)

The gateway also terminates client connections locally and holds keepalive
connections upstream, so a caller never waits on the peering path to open a fresh
connection.

## Install the AWS Load Balancer Controller

Terraform creates the controller's IAM role and binds it to the
`kube-system/aws-load-balancer-controller` service account with EKS Pod Identity.
Set `enable_lb_controller = true` in `terraform.tfvars` and apply:

```bash
terraform apply
```

Who can call the **inference endpoint** is a separate decision from
`endpoint_public_access_cidrs`, which only governs the EKS API. It is made further
down in [Optional: reach the gateway from outside the VPC](#optional-reach-the-gateway-from-outside-the-vpc).
Until then the load balancer stays internal and no public CIDR is involved.

Install the controller on the cluster Region nodes. It calls AWS APIs and must not
schedule onto a Hybrid Node:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version 3.6.0 \
  --set clusterName="$(terraform output -raw cluster_name)" \
  --set region="$(terraform output -raw cluster_region)" \
  --set vpcId="$(terraform output -raw cluster_vpc_id)" \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-json 'nodeSelector={"node-role":"core"}' \
  --wait --timeout 10m
kubectl get ingressclass alb
```

## Deploy the gateway

The official LiteLLM chart deploys the gateway from
[`kubernetes/litellm-values.yaml`](../kubernetes/litellm-values.yaml). It generates the
master key into the `litellm-masterkey` Secret, so there is nothing to create first.
The load balancer is **internal**, reachable only from inside the VPC and anything
peered to it:

```bash
helm upgrade --install litellm oci://ghcr.io/berriai/litellm-helm \
  --version 1.105.0 \
  --namespace cross-region-inference \
  --values ../kubernetes/litellm-values.yaml \
  --wait --timeout 10m
```

Wait for the load balancer to report an address and for the targets to pass health
checks. Targets sit in `initial` for roughly a minute after creation:

```bash
kubectl -n cross-region-inference get ingress litellm
CLUSTER_REGION="$(terraform output -raw cluster_region)"
TG_ARN="$(aws elbv2 describe-target-groups --region "$CLUSTER_REGION" \
  --query 'TargetGroups[?contains(TargetGroupName,`litellm`)].TargetGroupArn' --output text | head -1)"
aws elbv2 describe-target-health --region "$CLUSTER_REGION" --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

## Optional: reach the gateway from outside the VPC

Switch the load balancer to internet-facing and admit only the sources you call the
inference endpoint from: the public IP of whatever calls the model as `x.x.x.x/32`, or
that network's range. This is the gateway's own exposure, independent of the EKS API
CIDR used by `terraform apply` — the two are frequently different, since the clients
calling the model are not necessarily the people administering the cluster. Set both
annotations in the same upgrade. Without `inbound-cidrs` the controller admits
`0.0.0.0/0`, and anyone who finds the endpoint can consume the remote GPU:

Going internet-facing on plain HTTP would send the master key across the internet in
cleartext, so terminate TLS at the same time. You need an ACM certificate in the
cluster Region for a domain you control, and a DNS record pointing at the load
balancer once it exists:

```bash
# CIDR that reaches the gateway, not the EKS API admin CIDR from step 2.
ALB_INBOUND_CIDRS="<cidr-you-call-the-endpoint-from>"   # comma-separated for several ranges
ACM_CERT_ARN="<arn:aws:acm:...:certificate/...>"
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --version 1.105.0 \
  --namespace cross-region-inference \
  --values ../kubernetes/litellm-values.yaml \
  --set-string 'ingress.annotations.alb\.ingress\.kubernetes\.io/scheme=internet-facing' \
  --set-string "ingress.annotations.alb\.ingress\.kubernetes\.io/inbound-cidrs=${ALB_INBOUND_CIDRS//,/\\,}" \
  --set-string 'ingress.annotations.alb\.ingress\.kubernetes\.io/listen-ports=[{"HTTPS":443}]' \
  --set-string "ingress.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=${ACM_CERT_ARN}" \
  --set-string 'ingress.annotations.alb\.ingress\.kubernetes\.io/ssl-policy=ELBSecurityPolicy-TLS13-1-2-2021-06' \
  --wait --timeout 10m
```

Replacing `listen-ports` rather than adding to it means port 80 stops being served,
so there is no cleartext listener left to reach. Point your DNS name at the load
balancer and call `https://<your-domain>/...` instead of the `http://${ALB}` form in
the next section: the certificate will not match the generated `*.elb.amazonaws.com`
hostname, so `curl` against that address fails TLS verification by design.

To withdraw public access, rerun the install command from the previous section.
Changing the scheme replaces the load balancer, so its DNS name changes and the new
targets pass through `initial` again.

## Call the endpoint

```bash
ALB="$(kubectl -n cross-region-inference get ingress litellm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
KEY="$(kubectl -n cross-region-inference get secret litellm-masterkey \
  -o jsonpath='{.data.masterkey}' | base64 -d)"

# Health, served by the gateway and reachable without a key.
curl --fail "http://${ALB}/health/liveliness"

# Rejected without credentials: prints 401.
curl -o /dev/null -w '%{http_code}\n' "http://${ALB}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

# Served by the remote GPU.
curl "http://${ALB}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","messages":[{"role":"user","content":"Why run inference on a remote GPU?"}],"max_tokens":120}'

# Incremental server-sent events rather than one buffered response.
curl -N "http://${ALB}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","messages":[{"role":"user","content":"Count to 20."}],"max_tokens":200,"stream":true}'
```

> [!CAUTION]
> The default listener serves plain HTTP, so the master key crosses the network in
> cleartext. That is why the load balancer is internal by default. The address
> restriction limits who can reach the endpoint, not who can observe it. If you expose
> the gateway beyond the VPC, terminate TLS as shown in
> [Optional: reach the gateway from outside the VPC](#optional-reach-the-gateway-from-outside-the-vpc).

## Gateway boundaries

- There is no database, so there is no admin UI, no virtual keys, and no per-key rate
  limits or budgets: every caller uses the master key. Add a database through the
  chart's `db` values before sharing the endpoint.
- The load balancer idle timeout is raised to 600 seconds; the default of 60 truncates
  longer generations mid-response.
- `inbound-cidrs` pins the sources you set. Changing networks or connecting to a VPN
  makes the load balancer stop answering, which resembles an outage.
- The cluster does not enable VPC CNI network policy enforcement, so no NetworkPolicy
  restricts which pods reach the gateway.
- Health probes test only the gateway, so the load balancer keeps it in service during
  a remote outage and clients receive a served error rather than a refused connection.
  Alarm on the remote GPU separately.

## Cleanup

Uninstall the chart and confirm the load balancer is gone before destroying the
cluster. The controller deletes the load balancer, so it must still be running:

```bash
helm uninstall litellm --namespace cross-region-inference --ignore-not-found --wait
# Prints nothing once the load balancer is deleted.
aws elbv2 describe-load-balancers \
  --region "$(terraform output -raw cluster_region)" \
  --query 'LoadBalancers[?starts_with(LoadBalancerName,`k8s-crossreg`)].LoadBalancerName' --output text
helm uninstall aws-load-balancer-controller --namespace kube-system --ignore-not-found
```

The controller's IAM role is part of the Terraform state. `terraform destroy` removes
it, or apply with `-var enable_lb_controller=false` to remove only the role.
