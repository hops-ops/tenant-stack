### What's changed in v0.2.1

* ci: validate the with-auth example too (by @patrickleet)

  Adds examples/tenantstacks/with-auth.yaml to the validate matrix on both
  on-pr and on-push-main. The new example exercises the spec.capsule.proxy
  + spec.auth render paths added in v0.2.0 — without it CI was only
  catching schema regressions on the engine-only minimal/standard examples.


See full diff: [v0.2.0...v0.2.1](https://github.com/hops-ops/tenant-stack/compare/v0.2.0...v0.2.1)
