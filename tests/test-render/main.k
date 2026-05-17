import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unit tests for TenantStack XRD
#
# Philosophy: test YOUR API, not the provider's.
# - render/validate already checks provider schema correctness
# - Tests verify XRD spec fields produce the expected composed resources
# ==============================================================================

_items = [
    # ==========================================================================
    # Test 1: minimal claim renders the capsule Helm release + namespace.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "minimal-renders-capsule-release"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "tenant"
                spec.clusterName = "my-cluster"
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "capsule"
                    spec.forProvider = {
                        chart = {
                            name = "capsule"
                            repository = "https://projectcapsule.github.io/charts"
                            version = "0.12.4"
                        }
                        namespace = "capsule-system"
                    }
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "namespace-capsule"
                    spec.forProvider.manifest = {
                        apiVersion = "v1"
                        kind = "Namespace"
                        metadata.name = "capsule-system"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 2: custom labels merge with stack defaults on every composed resource.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-labels-merged-with-defaults"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "labeled-tenant"
                spec = {
                    clusterName = "my-cluster"
                    labels = {team = "platform", environment = "staging"}
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata = {
                        name = "capsule"
                        labels = {
                            "hops.ops.com.ai/managed" = "true"
                            "hops.ops.com.ai/tenantstack" = "labeled-tenant"
                            team = "platform"
                            environment = "staging"
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 3: capsule disabled — no resources render.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "capsule-disabled-skips-release"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "disabled-tenant"
                spec = {
                    clusterName = "my-cluster"
                    capsule = {enabled = False}
                }
            }
            assertResources = []
        }
    }

    # ==========================================================================
    # Test 4: custom chart version propagates to the Helm release.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-chart-version-propagates"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "version-test"
                spec = {
                    clusterName = "my-cluster"
                    capsule = {chartVersion = "0.12.3"}
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "capsule"
                    spec.forProvider.chart.version = "0.12.3"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 5: custom namespace + releaseName propagate.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-namespace-and-release-name-propagate"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "ns-test"
                spec = {
                    clusterName = "my-cluster"
                    capsule = {
                        namespace = "multitenancy"
                        releaseName = "capsule-controller"
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "capsule-controller"
                    spec.forProvider.namespace = "multitenancy"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "namespace-capsule"
                    spec.forProvider.manifest = {
                        apiVersion = "v1"
                        kind = "Namespace"
                        metadata.name = "multitenancy"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 6: helmProviderConfigRef defaults to clusterName.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "helm-provider-config-defaults-to-cluster-name"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "pcr-test"
                spec.clusterName = "prod-cluster"
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "capsule"
                    spec.providerConfigRef = {
                        name = "prod-cluster"
                        kind = "ProviderConfig"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 7: capsule.proxy.enabled renders the capsule-proxy helm Release
    # with usernameClaim wired into chart options.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "capsule-proxy-enabled-renders-release-with-username-claim"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "tenant"
                spec = {
                    clusterName = "my-cluster"
                    capsule = {
                        proxy = {
                            enabled = True
                            usernameClaim = "email"
                            replicas = 2
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "capsule-proxy"
                    spec.forProvider = {
                        chart = {
                            name = "capsule-proxy"
                            repository = "oci://ghcr.io/projectcapsule/charts"
                            version = "0.10.0"
                        }
                        namespace = "capsule-system"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 8: auth.enabled composes Zitadel ProviderConfig + Oidc App MR.
    # The credentials Secret is operator-managed (pre-bootstrapped on the
    # Crossplane cluster) — TenantStack does not auto-compose ESO sync
    # because Crossplane provider-kubernetes Object MRs are bound to a
    # single ProviderConfig context (no clean cross-cluster Secret copy
    # primitive). See README "Auth integration" for the bootstrap step.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "auth-enabled-composes-pc-and-oidc-app"
        spec = {
            compositionPath = "apis/tenantstacks/composition.yaml"
            xrdPath = "apis/tenantstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.TenantStack {
                metadata.name = "tenant"
                metadata.namespace = "pat-local"
                spec = {
                    clusterName = "pat-local"
                    auth = {
                        enabled = True
                        issuerURL = "https://auth.ops.com.ai"
                        zitadelProjectId = "316732890294485506"
                        oidcClient = {
                            name = "capsule-proxy"
                            redirectUris = ["http://localhost:8000", "http://localhost:18000"]
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "zitadel.m.crossplane.io/v1beta1"
                    kind = "ProviderConfig"
                    metadata.name = "zitadel-tenant-stack"
                    spec.credentials = {
                        source = "Secret"
                        secretRef = {
                            name = "zitadel-credentials"
                            namespace = "pat-local"
                            key = "credentials"
                        }
                    }
                }
                {
                    apiVersion = "application.zitadel.m.crossplane.io/v1alpha1"
                    kind = "Oidc"
                    metadata.name = "capsule-proxy"
                    spec.forProvider = {
                        name = "capsule-proxy"
                        projectId = "316732890294485506"
                        appType = "OIDC_APP_TYPE_NATIVE"
                        authMethodType = "OIDC_AUTH_METHOD_TYPE_NONE"
                        redirectUris = ["http://localhost:8000", "http://localhost:18000"]
                    }
                    spec.writeConnectionSecretToRef.name = "capsule-proxy-oidc-client"
                    spec.providerConfigRef = {
                        name = "zitadel-tenant-stack"
                        kind = "ProviderConfig"
                    }
                }
            ]
        }
    }
]

items = _items
