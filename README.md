# tenant-stack

Installs **Capsule** — the standard production multi-tenancy framework for
Kubernetes (a `Tenant` CRD plus an admission webhook that enforces
tenant-owns-namespaces and propagates quotas / policies) — on a target cluster
as a Helm release.

Cloud-neutral. Group: `hops.ops.com.ai`.

This is the **engine install** only. Tenant lifecycle (the `Tenant` / `Org`
claim XRDs), `capsule-proxy` for tenant-user list/watch filtering, isolation
tier (namespace / vCluster / sandbox / microvm), lifecycle states (suspend,
archive), and cross-stack wiring (policy, observe, istio, gitops) ship as
separate iterations tracked under GitKB `tasks/tenant-stack-*`.

## What's included

- **Capsule controller** — Helm release of the upstream `capsule` chart
  (`https://projectcapsule.github.io/charts`). Installs `tenants.capsule.clastix.io`,
  `tenantresources.capsule.clastix.io`, `globaltenantresources.capsule.clastix.io`,
  `capsuleconfigurations.capsule.clastix.io` CRDs and the validating / mutating
  webhook server.
- **capsule-proxy** (optional, off by default) — Helm release of the
  upstream `capsule-proxy` OCI chart
  (`oci://ghcr.io/projectcapsule/charts/capsule-proxy`). The
  per-tenant filtered list/watch proxy that sits in front of the
  kube-apiserver. Tenant kubectl users target the proxy URL instead of
  the apiserver directly; the proxy extracts identity from a Bearer JWT
  via `oidcUsernameClaim` and filters list/watch responses to the
  namespaces the user owns as a Tenant. **capsule-proxy itself does NOT
  validate JWTs** — see "Auth integration" below.
- **AuthStack integration** (optional, off by default) — when
  `spec.auth.enabled: true`, TenantStack composes a namespaced Zitadel
  `ProviderConfig` and a Zitadel `Oidc` Application MR for tenant
  kubectl users (`kubectl oidc-login`). The OIDC client's `client_id`
  lands in a Crossplane connection Secret tenants pull from to build
  their kubeconfig. **Requires a one-time `zitadel-credentials` Secret
  bootstrap** on the Crossplane cluster — see "Auth integration" below.

## What's NOT (yet) included

The following each lands as a separate, individually tracked iteration:

- `Tenant` / `Org` claim XRDs — explicit non-goal: Capsule's `Tenant`
  CRD is already a high-level API and a 1:1 hops wrapper adds drift risk
  without functional gain. The cross-stack work happens in
  `gitops-stack` / `aws-secret-stack` / `aws-observe-stack` / `policy-stack`,
  each keying off the `capsule.clastix.io/tenant` namespace label
- CVE hardening — RBAC default + Kyverno guard against the
  `capsule.clastix.io/tenant` label-injection CVE class
  (`tasks/tenant-stack-cve-hardening`)
- Bootstrap-deadlock prevention — mutual Kyverno / Capsule webhook
  `namespaceSelector` exclusion for platform namespaces
  (`tasks/tenant-stack-bootstrap-deadlock-prevention`)
- PolicyStack integration — per-tenant Kyverno ClusterPolicies via
  `namespaceSelector` on `capsule.clastix.io/tenant`
- ObserveStack integration — Capsule ServiceMonitor + Grafana dashboard +
  per-tenant `X-Scope-OrgID` injection via Alloy `stage.tenant`
- Istio Ambient integration — per-tenant waypoint Gateway provisioning
- Lifecycle — `suspended` / `terminating` states, CNPG / ExternalDNS / ESO
  coordinated drain, `TenantArchive` controller for >30-day retention timers
- Isolation tier enum — `tier: namespace | vcluster | sandbox | microvm`

## Minimal usage

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: TenantStack
metadata:
  name: tenant
  namespace: default
spec:
  clusterName: my-cluster
```

## With capsule-proxy + AuthStack integration

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: TenantStack
metadata:
  name: tenant
  namespace: pat-local
spec:
  clusterName: pat-local
  capsule:
    namespace: capsule-system
    proxy:
      enabled: true
      usernameClaim: preferred_username
  auth:
    enabled: true
    # Surfaced in TenantStack status for tenant kubeconfig snippets.
    # Copy from AuthStack status.oidc.issuerURL.
    issuerURL: https://auth.ops.com.ai
    # Pre-existing Zitadel Project ID (Zitadel UI → Projects → details, or
    # `curl POST $issuerURL/management/v1/projects` with the iam-admin PAT).
    zitadelProjectId: "316732890294485506"
    oidcClient:
      name: capsule-proxy
      redirectUris:
        - http://localhost:8000
        - http://localhost:18000
```

## Auth integration

When `spec.auth.enabled: true`, TenantStack composes:

1. A namespaced Zitadel `ProviderConfig` (`zitadel-tenant-stack`) that
   consumes a pre-bootstrapped credentials Secret named
   `zitadel-credentials` (see Bootstrap below).
2. A Zitadel `Oidc` Application MR provisioning the OIDC App in Zitadel
   under `spec.auth.zitadelProjectId`.
3. Crossplane writes the issued `client_id` + `client_secret` to the
   Secret named in `status.auth.oidcClientSecretRef`.

### Bootstrap: the `zitadel-credentials` Secret

The Zitadel provider's ProviderConfig needs a credentials JSON in a K8s
Secret on the **Crossplane cluster** (the cluster running the Zitadel
provider's controllers — `colima` in the hops-ops topology). The shape:

```json
{ "access_token": "<iam-admin PAT>", "domain": "auth.ops.com.ai", "port": "443", "insecure": false }
```

**Why TenantStack does NOT auto-compose this Secret**: AuthStack's
iam-admin PAT Secret lives on the workload cluster; ESO (with AWS SM
read access via IRSA) runs there. Crossplane runs on the control-plane
cluster. Crossplane's provider-kubernetes Object MRs are bound to a
single ProviderConfig context, so cross-cluster Secret sync requires
either ESO on the control-plane cluster OR an out-of-band copy. Both
are operator-managed concerns outside this stack's scope.

The simplest bootstrap (one-time, per cluster):

```sh
# Pull the PAT off the workload cluster, strip trailing newline.
PAT=$(kubectl --context pat-local get secret -n zitadel iam-admin-pat \
  -o jsonpath='{.data.pat}' | base64 -d | tr -d '\n')

# Build the credentials JSON.
CREDS=$(printf '{"access_token":"%s","domain":"auth.ops.com.ai","port":"443","insecure":false}' "$PAT")

# Drop the Secret on the control-plane cluster (where the Zitadel
# provider's controllers run), in the same namespace as the TenantStack.
kubectl --context colima create secret generic zitadel-credentials \
  -n default --from-literal=credentials="$CREDS"
```

After reconcile:

Tenant kubectl users then construct their kubeconfig using `client_id`:

```sh
# upjet writes connection-secret keys with an `attribute.` prefix
CLIENT_ID=$(kubectl get secret capsule-proxy-oidc-client \
  -o jsonpath='{.data.attribute\.client_id}' | base64 -d)

kubectl config set-credentials tenant-user --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://auth.ops.com.ai \
  --exec-arg=--oidc-client-id=$CLIENT_ID \
  --exec-arg=--oidc-extra-scope=email \
  --exec-arg=--oidc-extra-scope=groups
```

### Critical prerequisite — JWT trust

**capsule-proxy does NOT validate JWTs itself.** The Bearer token tenants
present must be validated UPSTREAM by either:

1. **The kube-apiserver's OIDC IdP association.** On EKS, configure via
   `aws eks associate-identity-provider-config` pointing at the AuthStack
   issuer. On vanilla k8s, set `--oidc-issuer-url`, `--oidc-client-id`,
   `--oidc-username-claim`, `--oidc-groups-claim` on the apiserver.
2. **An oauth2-proxy / authenticating Ingress in front of capsule-proxy.**
   The Ingress validates the JWT and passes through; capsule-proxy
   trusts the inbound header.

Neither is composed by this stack — both are operator-managed external
prerequisites. Without one of them, tenant kubectl calls reach
capsule-proxy but the apiserver rejects them as unauthenticated.

### Prerequisites checklist

- [ ] AuthStack installed and Ready
- [ ] AuthStack `status.oidc.issuerURL` known (copy into spec.auth.issuerURL)
- [ ] A Zitadel Project exists for OIDC apps; capture its ID
- [ ] `zitadel-credentials` Secret bootstrapped on the Crossplane cluster (see Bootstrap above)
- [ ] kube-apiserver OIDC IdP association is wired (or oauth2-proxy is deployed)

## Standard usage

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: TenantStack
metadata:
  name: tenant
  namespace: pat-local
spec:
  clusterName: pat-local
  labels:
    team: platform
    environment: dev
  capsule:
    namespace: capsule-system
    chartVersion: "0.12.4"
```

## Defaults of note

- **Capsule chart**: `0.12.4` (app v0.12.4). Pin minimum is **≥ v0.12.x** — the
  webhook refactor that closed the CVE-2024-39690 / CVE-2025-55205 label
  injection CVE class. Override via `spec.capsule.chartVersion`.
- **Namespace**: `capsule-system`.
- **Wait**: `wait: true` for the helm release — Capsule's controller is a
  small Deployment and reaches Ready quickly; we want the readiness signal
  to gate downstream tenant XRs (composition-internal gating per
  `feedback_crossplane_composition_gates`).
- **Capsule-proxy subchart**: disabled. The upstream `capsule` chart bundles
  `capsule-proxy` as an optional dependency under `proxy.enabled`; we keep
  that off here and reserve proxy install for its own iteration once Zitadel
  OIDC integration is in place.

## Using Capsule after the stack is installed

Once the TenantStack is Ready, the cluster has Capsule's `Tenant`,
`CapsuleConfiguration`, `TenantResource` and related CRDs Established.
End-user examples for those resources live under
[`examples/capsule/`](./examples/capsule/) — apply them with `kubectl apply
-f` directly; they are **not** rendered by this stack's Composition.

Typical onboarding sequence:

1. Patch the cluster-scoped `CapsuleConfiguration` `default` to point at
   your OIDC group claim and protect platform namespaces — see
   [`examples/capsule/capsule-configuration.yaml`](./examples/capsule/capsule-configuration.yaml).
2. Create a `Tenant` per onboarded customer / team — see
   [`examples/capsule/tenant.yaml`](./examples/capsule/tenant.yaml) for a
   realistic example with owners, aggregated quotas, namespace count cap,
   registry allow-list, Ingress/Storage class restriction.
3. Replicate baseline hygiene (default-deny NetworkPolicy, LimitRange,
   etc.) into all of that Tenant's namespaces via `TenantResource` — see
   [`examples/capsule/tenant-resource.yaml`](./examples/capsule/tenant-resource.yaml).

The [`examples/capsule/README.md`](./examples/capsule/README.md) covers
order of operations, the CVE-class caveat, and the deprecated
`Tenant.spec.networkPolicies` migration to `TenantResource`.

## CVE class notice

Capsule has had **two** namespace-label-injection CVEs (CVE-2024-39690,
CVE-2025-55205). Both exploited the same class of bug in the namespace
validation webhook. Pinning chart ≥ 0.12.x is necessary but not sufficient.
RBAC + Kyverno defense-in-depth lives in `tasks/tenant-stack-cve-hardening`
and is **not** part of this first pass — operate this install with the
assumption that CVE hardening is still TODO.
