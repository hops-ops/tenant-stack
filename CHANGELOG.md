### What's changed in v0.3.0

* feat: EKS apiserver OIDC integration + Zitadel JWT compatibility (by @patrickleet)

  Closes the loop for capsule-proxy on EKS — the apiserver now validates
  tenant Bearer JWTs from Zitadel via an EKS IdentityProviderConfig
  association composed directly from TenantStack.

  XRD additions (spec):
    - spec.aws.{region, awsProviderConfigRef.{name,kind},
      eksIdentityProvider.{enabled, identityProviderConfigName,
      eksClusterName, usernameClaim, groupsClaim, usernamePrefix,
      groupsPrefix, requiredClaims}}

  XRD additions (status):
    - status.aws.eksIdentityProvider.{ready, identityProviderConfigName}

  Render:
    - 500-eks-identity-provider-config.yaml.gotmpl composes the
      NAMESPACED eks.aws.m.upbound.io/v1beta1 IdentityProviderConfig MR
      (cluster-scoped variant won't compose from a namespaced XR per
      Crossplane v2 rules). Uses spec.auth.zitadelProjectId as the
      OIDC clientId — Zitadel always includes the project_id in JWT aud
      regardless of grant type (interactive auth-code OR machine-user
      jwt-bearer), so this works for both human users and ServiceUsers.
      Earlier attempts to source the OIDC App's client_id from the Oidc
      MR connection secret only supported interactive flows.

  Defaults:
    - usernameClaim defaults to "sub" (universal across grant types;
      Zitadel emits preferred_username only on interactive flows).
    - The EKS IdP's usernameClaim defaults to spec.capsule.proxy.usernameClaim
      so the proxy's claim-extraction and the apiserver's RBAC user
      derivation stay in lockstep.

  Zitadel OIDC App: emit JWT access tokens (accessTokenType=JWT) instead
  of the default opaque BEARER — required for the apiserver to verify via
  JWKS and for kubectl-oidc_login to function.

  upbound.yaml: add provider-aws-eks dependency (>=v2) so validate has
  the namespaced IdentityProviderConfig CRD schema.

  Tests: +1 KCL test exercising the AWS EKS IdP composition gate;
  9/9 KCL render tests pass; validate green across all three examples.

  Verified end-to-end on pat-local:
    - aws eks describe-identity-provider-config status ACTIVE,
      clientId=373402117030817773 (Zitadel project_id), usernameClaim=sub
    - tenant-test human user authenticated via kubectl-oidc_login
      (browser flow) -> JWT -> capsule-proxy -> EKS apiserver
    - apiserver maps `sub` -> User "https://auth.ops.com.ai#<sub>"
    - capsule-proxy filtered list/watch returns only the tenant's own
      namespaces (acme-prod)

  Implements [[tasks/tenant-stack-install]]


See full diff: [v0.2.1...v0.3.0](https://github.com/hops-ops/tenant-stack/compare/v0.2.1...v0.3.0)
