# gitops-delivery-platform — working notes

## Status
- Phase: Phase 1 generated, validating. NOT yet pushed.
- Meta approved, design approved, plan approved (Tier 3, explicit user request).

## Key decisions

**Dedicated VPC, not the default one.** probe_cloud found `vpc-08750793f051e477b`
(default, 6 subnets) but all six are public and none carry EKS discovery tags.
The ALB controller finds placement via `kubernetes.io/role/elb=1`, so we build
10.0.0.0/16 with 2 public + 2 private subnets and the tags. Costs one NAT
gateway (~$32/mo). User was offered the cheaper no-NAT variant and did not take it.

**Cluster name is load-bearing.** `substr(project_name, 0, 24)` + `-eks` =
`gitops-delivery-platfor-eks`. UDAP resource discovery, the architecture report
and the Operations Console locate EKS infra by this pattern. Do not "tidy" it.
Every resource also gets `Project=<project_name>` + `ManagedBy=udap` via the
provider's `default_tags`.

**EKS 1.33.** Standard support. 1.30–1.32 are extended support and bill at a
premium — do not downgrade to "be safe".

**Java 21 / Spring Boot 3.4.1.** User raised no objection when flagged.

**ECR is IMMUTABLE-tagged.** Correct for SHA tags, but it means re-running the
pipeline on the *same commit* fails the push (tag already exists). If that bites
during recovery, the fix is a no-op push guard in the image stage — NOT flipping
the repo to MUTABLE, which would let a tag be silently rewritten under a running
Deployment.

## The GitOps discipline (why things look the way they do)
1. Argo CD is the sole writer of `gitops/` + `chart/`. Pipeline never commits to
   either. That is what licenses `prune: true, selfHeal: true`.
2. Image tag is patched onto the Application's `spec.source.helm.parameters` via
   `kubectl patch` = cluster state. Deploys leave the repo byte-identical.
   `chart/*/values.yaml` keeps `image.tag: ""` forever; the `app.image` helper
   `fail`s the render if it is empty at sync time (loud > silent `repo:`).
   `ignoreDifferences` on `/spec/source/helm/parameters` stops selfHeal from
   reverting the patch — without it the configure stage and Argo fight.
3. No path filters / `[skip ci]`: rendered workflows are workflow_dispatch-only,
   so no commit can retrigger CI.

## Gotchas hit while generating (do not regress these)
- **`gitops/apps/` had to become a Helm chart.** First attempt put
  `${GITOPS_REPO_URL}` in `app-dev.yaml`, but the root syncs that directory
  straight from Git and Argo CD does no shell substitution — the literal string
  would have been applied as a repo URL. Second attempt (`PLACEHOLDER_REPO_URL`)
  was worse: an unsyncable manifest in Git. Final design: root is a Helm app over
  `gitops/apps/`, passing `repoURL` down as a Helm parameter. `envsubst` touches
  only `root-app.yaml`, which the pipeline pipes through it at apply time.
- **Dockerfile HEALTHCHECK needed curl installed** — `eclipse-temurin:21-jre-noble`
  does not ship it, so the original healthcheck would have failed permanently.
- **`readOnlyRootFilesystem: true` needs a writable `/tmp`** for the JVM →
  emptyDir volume mounted at /tmp in the Deployment.
- **No CPU limit**, memory limit only: CPU throttling makes JVM startup flap
  readiness on t3.medium.
- `ignore_changes` on node group `scaling_config[0].desired_size` so a future
  autoscaler does not fight terraform.

## Secrets
- `GITOPS_PAT` — **user must supply**. Fine-grained PAT, read-only Contents on
  this repo. Argo CD runs in-cluster and cannot use `GITHUB_TOKEN`. Set it AFTER
  `create_repo_and_push`, BEFORE `deploy`. Never echo the value.
- Everything else (AWS creds, TF_STATE_BUCKET, PROJECT_NAME) is platform-set.
- No GHCR token: ECR auth reuses AWS creds.

## Next steps
1. `validate_project` → fix all errors.
2. `test_project` — expect SKIPPED on most stages (sandbox has no cloud access
   and skips `uses:` steps). SKIPPED is not failure; do NOT weaken steps to go green.
3. Report, stop. Push only on user instruction.
4. After push: `set_pipeline_secret GITOPS_PAT`, then `deploy`.

## Deferred (user-agreed)
Phase 2 Argo Rollouts + blue/green; Phase 3 canary + observability/label-sync;
Phase 4 Flux. Chart values surface already carries `blueGreen`/`canary` blocks
(mutually exclusive, Deployment guarded) so Phase 2 is a flag flip.
