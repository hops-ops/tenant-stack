### What's changed in v0.2.0

* feat: capsule-proxy install + AuthStack OIDC integration (by @patrickleet)

  TenantStack now optionally installs capsule-proxy (per-tenant filtered
  list/watch) and auto-provisions a Zitadel OIDC Application for tenant
  kubectl users (kubectl oidc-login).

  XRD additions:
    - spec.capsule.proxy.{enabled, releaseName, chartVersion,
      usernameClaim, replicas, values, overrideAllValues} composes the
      upstream capsule-proxy OCI helm chart
      (oci://ghcr.io/projectcapsule/charts/capsule-proxy, pinned 0.10.0)
    - spec.auth.{enabled, issuerURL, zitadelProjectId, oidcClient.{name,
      redirectUris, postLogoutRedirectUris}} composes a Zitadel
      ProviderConfig + Oidc Application MR
    - status.capsule.proxy.ready + status.auth.{ready, oidcClientSecretRef}

  Architecture decision: capsule-proxy does NOT validate JWTs itself
  (chart values surface confirms — only oidcUsernameClaim configurable).
  JWT validation must be wired UPSTREAM via either the kube-apiserver's
  OIDC IdP association or oauth2-proxy. Documented as external prereq.

  Architecture decision: TenantStack does NOT auto-compose the ESO →
  zitadel-credentials sync. AuthStack publishes its iam-admin PAT to AWS
  SM and ESO runs on the workload cluster; the Zitadel Crossplane
  provider runs on the control-plane cluster. Crossplane
  provider-kubernetes Object MRs are bound to a single ProviderConfig
  context, so cross-cluster Secret copy can't be modeled as a single
  composition step. Documented as one-time operator bootstrap
  ("Auth integration → Bootstrap" in README). Tracked as a future
  iteration if ESO lands on the control-plane cluster.

  Verified end-to-end on pat-local:
    - capsule-proxy 1/1 Running in capsule-system, listening :9001,
      reflecting Tenant + CapsuleConfiguration caches
    - Zitadel Oidc Application created with external name
      373402989966143469 under the manually-pre-created tenant-platform
      project; client_id + client_secret written to connection secret
      capsule-proxy-oidc-client (keys upjet-prefixed: attribute.client_id,
      attribute.client_secret)

  Tests: 8/8 KCL render tests pass; validate green across minimal,
  standard, and new with-auth examples.

  Implements [[tasks/tenant-stack-install]]


See full diff: [v0.1.0...v0.2.0](https://github.com/hops-ops/tenant-stack/compare/v0.1.0...v0.2.0)
