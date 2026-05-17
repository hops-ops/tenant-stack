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

## What's NOT (yet) included

This first iteration is **engine only**. Each of the following lands as a
separate, individually tracked iteration:

- `Tenant` / `Org` claim XRDs (see `tasks/tenant-stack-org-xrd` — Org→Project
  split, namespace-tier isolation v1, vCluster tier v2)
- `capsule-proxy` install (depends on AuthStack / Zitadel OIDC wiring)
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

## CVE class notice

Capsule has had **two** namespace-label-injection CVEs (CVE-2024-39690,
CVE-2025-55205). Both exploited the same class of bug in the namespace
validation webhook. Pinning chart ≥ 0.12.x is necessary but not sufficient.
RBAC + Kyverno defense-in-depth lives in `tasks/tenant-stack-cve-hardening`
and is **not** part of this first pass — operate this install with the
assumption that CVE hardening is still TODO.
