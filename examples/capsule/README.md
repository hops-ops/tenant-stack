# Capsule usage examples

These are **reference examples** for the Capsule resources that become
available once the `TenantStack` XR has installed Capsule on the target
cluster (i.e. `capsule-controller-manager` is Running in `capsule-system`).

They are **not** rendered by this stack's Composition — Tenant lifecycle
(Org → Project → Resource XRDs, isolation tier enum, lifecycle states) is
out of scope for the first-pass engine install. See `specs/tenant-stack` in
the hops-ops KB for the full Tenant XRD design.

Apply them directly with `kubectl apply -f <file>` against the cluster
where TenantStack is installed.

## Files

| File | Resource | Purpose |
|---|---|---|
| [`capsule-configuration.yaml`](./capsule-configuration.yaml) | `CapsuleConfiguration` | Cluster-wide Capsule settings — which OIDC groups mark tenant users, which namespaces are reserved for the platform, what node metadata tenants cannot touch. |
| [`tenant.yaml`](./tenant.yaml) | `Tenant` | A realistic tenant with owners, resource quotas, namespace quota, registry allow-list, allowed Ingress/Storage classes, and image pull policy enforcement. |
| [`tenant-resource.yaml`](./tenant-resource.yaml) | `TenantResource` | Replication primitive (replaces deprecated `spec.networkPolicies`) — propagates a default-deny NetworkPolicy into every namespace owned by the matched Tenant. |

## Order of operations

1. **Patch CapsuleConfiguration first.** The Helm chart installs a default
   `default` CapsuleConfiguration. Override it (or `kubectl edit`) before
   onboarding the first tenant — particularly `userGroups` and
   `protectedNamespaceRegex`, which gate the entire admission boundary.

2. **Create the Tenant.** Capsule auto-creates an `additionalRoleBindings`
   surface that grants the listed `spec.owners` the right to create
   namespaces inside this Tenant. Tenant users won't have any namespaces
   yet — they create them themselves (`kubectl create ns acme-prod`) and
   Capsule's mutating webhook stamps the `capsule.clastix.io/tenant=acme-corp`
   label + ownerRef.

3. **Attach replications.** `TenantResource` (and cluster-scoped
   `GlobalTenantResource`) propagate Kubernetes resources into every
   namespace owned by a Tenant. Use this for default-deny NetworkPolicies,
   common LimitRanges, ImagePullSecrets, etc. — the modern replacement for
   `Tenant.spec.networkPolicies` (deprecated).

## Caveats — read before adopting in production

- **CVE class.** Capsule has had two namespace-label-injection CVEs
  (CVE-2024-39690 / CVE-2025-55205, CVSS 9.1). Chart pin ≥ v0.12.x in this
  stack closes the upstream bug. RBAC + Kyverno defense-in-depth — denying
  tenant users `patch namespace` + forbidding mutation of the
  `capsule.clastix.io/tenant` label by non-platform principals — is **not**
  shipped here. Track via the hops-ops KB
  (`tasks/tenant-stack-cve-hardening`) before relying on Capsule for hostile
  multi-tenancy.

- **Identity sourcing.** Capsule reads tenant user identity from
  `--oidc-username-claim` / `--oidc-groups-claim` flags on the kube-apiserver.
  Tenant users authenticate to the apiserver with an OIDC JWT, NOT a
  ServiceAccount. The example below uses a `Group` owner — that group must
  be a claim emitted by your IdP (Zitadel, in the hops-ops design).

- **`networkPolicies` field is deprecated.** `Tenant.spec.networkPolicies` is
  marked deprecated upstream — use `TenantResource` replications instead
  (see `tenant-resource.yaml`).

- **CapsuleConfiguration is cluster-scoped.** Only one `default` instance
  exists per cluster. Editing it changes the admission semantics for every
  Tenant. Treat it like a kube-apiserver flag, not a per-tenant knob.
