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
  `spec.auth.enabled: true`, TenantStack composes a Zitadel `Oidc`
  Application MR for tenant kubectl users (`kubectl oidc-login`). The
  OIDC client's `client_id` lands in a Crossplane connection Secret
  tenants pull from to build their kubeconfig. **Requires a
  pre-existing Zitadel `ProviderConfig`** in the TenantStack namespace on
  the Crossplane cluster. The default reference is `ProviderConfig/default`.

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

1. A Zitadel `Oidc` Application MR provisioning the OIDC App in Zitadel
   under `spec.auth.zitadelProjectId`.
2. Crossplane writes the issued `client_id` + `client_secret` to the
   Secret named in `status.auth.oidcClientSecretRef`.

TenantStack expects a namespaced Zitadel `ProviderConfig` named
`default` to already exist in the TenantStack namespace on the
**Crossplane cluster**. Override `spec.auth.zitadelProviderConfigRef` when
the ProviderConfig has a different name. The ProviderConfig and any
credentials Secret it references are owned by platform bootstrap, not by
TenantStack.

If that separate ProviderConfig uses a credentials Secret, the JSON shape
is:

```json
{ "access_token": "<iam-admin PAT>", "domain": "auth.ops.com.ai", "port": "443", "insecure": false }
```

**Why TenantStack does NOT auto-compose this ProviderConfig**: AuthStack's
iam-admin PAT Secret lives on the workload cluster; ESO runs there.
Crossplane runs on the control-plane cluster. That cross-cluster
bootstrap is a platform concern outside this stack's scope.

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

1. **The kube-apiserver's OIDC IdP association.** On EKS this is the
   `IdentityProviderConfig` association — **TenantStack composes it for
   you** via `spec.aws.eksIdentityProvider.enabled: true`. On vanilla
   k8s, set `--oidc-issuer-url`, `--oidc-client-id`,
   `--oidc-username-claim`, `--oidc-groups-claim` directly on the
   apiserver.
2. **An oauth2-proxy / authenticating Ingress in front of capsule-proxy.**
   The Ingress validates the JWT and passes through; capsule-proxy
   trusts the inbound header.

Without one of them, tenant kubectl calls reach capsule-proxy but the
apiserver rejects them as unauthenticated.

## EKS apiserver OIDC integration

Set `spec.aws.eksIdentityProvider.enabled: true` and TenantStack
composes an `eks.aws.upbound.io/v1beta2 IdentityProviderConfig` MR that
runs `aws eks associate-identity-provider-config` for you. The MR is
gated on the Zitadel `Oidc` Application's connection secret being
populated — the issued `client_id` is what AWS validates the JWT's `aud`
claim against.

```yaml
spec:
  auth:
    enabled: true
    issuerURL: https://auth.ops.com.ai
    zitadelProjectId: "316732890294485506"
    oidcClient:
      name: capsule-proxy
      redirectUris: [http://localhost:8000, http://localhost:18000]
  aws:
    region: us-east-2
    eksIdentityProvider:
      enabled: true
      identityProviderConfigName: zitadel
      # eksClusterName defaults to spec.clusterName
      # usernameClaim defaults to spec.capsule.proxy.usernameClaim
      # groupsClaim defaults to "groups"
      # usernamePrefix / groupsPrefix default empty (no namespacing)
```

After reconcile, the EKS apiserver will trust JWTs from the Zitadel
issuer and map them via:

| JWT claim | k8s identity |
|---|---|
| `usernameClaim` (default `preferred_username`) | k8s `user` for impersonation |
| `groupsClaim` (default `groups`) | k8s `groups` for RBAC |

**Important caveats:**

- Adding an IdP association **takes ~10 minutes** on EKS — the apiserver
  rotates. Plan migrations accordingly.
- Removing one is **also slow** (~10 min); during removal, JWTs from
  this issuer get rejected. Use `usernamePrefix: zitadel:` to namespace
  the identities so you can phase out without disrupting other auth.
- The IdP config is **cluster-wide** — each Tenant gets its own identity
  via the Zitadel side (Org / User), not via separate IdP configs.
- The provider-aws-eks `IdentityProviderConfig` MR is **cluster-scoped**
  (not namespaced), so two TenantStacks targeting the same EKS cluster
  with the same `identityProviderConfigName` will collide. Use distinct
  `identityProviderConfigName` values per logical IdP per cluster.

### Prerequisites checklist

- [ ] AuthStack installed and Ready
- [ ] AuthStack `status.oidc.issuerURL` known (copy into spec.auth.issuerURL)
- [ ] A Zitadel Project exists for OIDC apps; capture its ID
- [ ] `ProviderConfig/default` exists in the TenantStack namespace on the Crossplane cluster, or `spec.auth.zitadelProviderConfigRef` points at the one you created
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
