### What's changed in v0.1.0

* feat: initial tenant-stack — Capsule v0.12.4 engine install (by @patrickleet)

  First-pass scaffold for the multi-tenancy stack. Installs the Capsule
  controller (https://projectcapsule.dev/) as a Helm release; cluster-wide
  multi-tenancy primitives (Tenant CRD + admission webhook) become available
  for downstream Tenant/Org claim XRDs in subsequent iterations.

  XRD shape mirrors security-stack: clusterName, labels, helm/k8s
  providerConfigRefs, capsule.{enabled,namespace,releaseName,chartVersion,
  values,overrideAllValues}.

  Pin Capsule chart 0.12.4 (app v0.12.4) — the spec-mandated >=v0.12.x
  minimum that closes the CVE-2024-39690 / CVE-2025-55205 namespace-label
  injection CVE class. RBAC + Kyverno defense-in-depth lands in a separate
  iteration (tasks/tenant-stack-cve-hardening); operate this engine install
  with that hardening still TODO.

  First-pass scope deliberately excludes: Tenant/Org claim XRDs,
  capsule-proxy, isolation tier enum, lifecycle states, bootstrap deadlock
  prevention, and PolicyStack/ObserveStack/Istio Ambient integration.

  Verified end-to-end on pat-local EKS: 6/6 KCL render tests pass;
  TenantStack default/pat-local reaches Ready=True ~90s after apply;
  capsule-controller-manager 1/1 Running; 7 Capsule CRDs Established;
  validating + mutating webhooks created.

  Implements [[tasks/tenant-stack-install]]

* fix: ship Capsule manager resource requests + 5s probe timeouts (by @patrickleet)

  Capsule's helm chart leaves manager.resources empty by default, which
  puts the controller Pod in QoS=BestEffort. On busy nodes the manager
  process gets CPU-starved and the chart's default 1s liveness/readiness
  probes time out, sending capsule-controller-manager into CrashLoopBackOff
  within hours of install. With the controller down the webhook service
  loses endpoints, blocking every namespace create that depends on the
  Capsule admission boundary.

  Ship sane defaults:
    - requests 100m CPU / 128Mi memory  (Burstable QoS)
    - limits   500m CPU / 256Mi memory
    - liveness/readiness probe timeoutSeconds: 5

  Tenants can override via spec.capsule.values.manager.

  Implements [[tasks/tenant-stack-install]]

* docs(examples): add Capsule usage examples (Tenant, CapsuleConfiguration, TenantResource) (by @patrickleet)

  Reference examples for the resources Capsule makes available once
  TenantStack is installed. Not rendered by the Composition — Tenant
  lifecycle XRDs (Org -> Project -> Resource, isolation tier enum,
  lifecycle states) remain out of scope for the first-pass engine install.

    - examples/capsule/capsule-configuration.yaml: cluster-scoped defaults
      you typically override before onboarding the first tenant (OIDC user
      groups, forceTenantPrefix, protectedNamespaceRegex, forbidden node
      labels).
    - examples/capsule/tenant.yaml: realistic acme-corp tenant with
      owners, aggregated ResourceQuotas (scope=Tenant), namespace count
      cap, container registry allow-list, allowed Ingress/Gateway/Storage
      classes, image pull policy enforcement, priorityClass restriction.
    - examples/capsule/tenant-resource.yaml: TenantResource replication
      (the supported replacement for deprecated Tenant.spec.networkPolicies)
      propagating a default-deny-cross-tenant NetworkPolicy + baseline
      LimitRange into every namespace owned by the matched tenant.
    - examples/capsule/README.md: order of operations, CVE-class caveat
      pointing at tenant-stack-cve-hardening, networkPolicies -> TenantResource
      migration note, identity sourcing note.

  README.md gets a "Using Capsule after the stack is installed" section
  that walks the onboarding sequence and links the examples.

  Implements [[tasks/tenant-stack-install]]


