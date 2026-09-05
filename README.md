# gitops-delivery-platform

A GitOps delivery platform on Amazon EKS: application code, its Helm chart, the
cluster infrastructure and the Argo CD manifests all live in **one repository**,
reconciled into the cluster by Argo CD.

> **Phase 1 scope.** Cluster + registry + a minimal Spring Boot service + one
> Helm chart in plain-Deployment mode + Argo CD with an app-of-apps root and a
> single `app-dev` Application. Argo Rollouts, blue/green, canary, observability
> and Flux are deliberately deferred — see [Deferred phases](#deferred-phases).

> **This repository is PUBLIC by design.** Argo CD clones it anonymously, so no
> repository-credential Secret and no personal access token exist anywhere in
> the system. See [Repository visibility](#repository-visibility).

---

## Repository layout

| Path | What lives there |
|---|---|
| `infra/` | **All** Terraform: VPC, EKS cluster + managed node group, ECR, IRSA role for the AWS Load Balancer Controller |
| `app/` | Spring Boot 3.5 / Java 21 service + `Dockerfile` |
| `chart/gitops-delivery-platform/` | The Helm chart Argo CD renders |
| `gitops/root-app.yaml` | The app-of-apps root Application |
| `gitops/apps/` | Child Applications, rendered as a chart (`app-dev`) |
| `.trivyignore.yaml` | Scoped, justified, **expiring** security exceptions |
| `.udap/architecture.d2` | Architecture source of truth |
| `.udap/pipeline.yaml` | Pipeline spec — CI workflows are **rendered** from this |
| `.udap/notes.md` | Working notes: decisions, gotchas, what's next |

`.github/workflows/` is generated from `.udap/pipeline.yaml`. Never edit it by
hand; edit the spec and let it re-render.

---

## The three GitOps rules this repo is built on

**1. Argo CD is the sole writer of workload state.**
Argo reads `gitops/` and `chart/`. The pipeline *never* writes to either path.
That single-writer property — not the folder layout — is what makes
`automated: {prune: true, selfHeal: true}` safe to run from day one. Two writers
(CI running `kubectl apply` *and* Argo reconciling) would fight forever.

**2. The image tag is cluster state, not Git state.**
CI pushes `…/gitops-delivery-platform:<commit-sha>` to ECR, then patches
`spec.source.helm.parameters` on the `app-dev` Application with `kubectl patch`.
The repository is left byte-identical by a deploy, so self-heal has nothing to
revert. `chart/…/values.yaml` therefore keeps `image.tag: ""` **permanently** —
the chart's `app.image` helper fails the render if it is ever empty at sync
time, which turns "someone forgot to patch" into a loud error instead of a pod
pulling `repository:`.

**3. No path filters, no `[skip ci]`.**
Conventional monorepo GitOps needs those guards because a CI commit retriggers
CI. UDAP renders `workflow_dispatch`-only workflows triggered by the platform,
so no commit can retrigger anything. The guards would be cargo cult here.

---

## Pipeline

`test` and `security` run in parallel → `provision` → `image` → `configure` → `verify`.

| Stage | Does |
|---|---|
| `test` | `mvn verify` — unit + MockMvc tests |
| `security` | Trivy scan of the tree: vuln + secret + misconfig, HIGH/CRITICAL fail the build |
| `provision` | `terraform init -reconfigure` + `apply` over `infra/` — creates the VPC, EKS cluster, **and the ECR repository** |
| `image` | Reads the registry URL from terraform state, builds the jar and image, pushes tagged with the commit SHA |
| `configure` | Argo CD install, ALB controller, anonymous-read check, root app, image-tag patch |
| `verify` | Polls `root` and `app-dev` for `Synced` + `Healthy`, then curls the ALB |

**Every stage that needs an infrastructure value reads it itself** by re-running
`terraform init` with identical `-backend-config` flags and calling
`terraform output -raw`. Nothing is threaded between jobs: GitHub silently drops
job outputs containing a secret substring, and `PROJECT_NAME` is a secret that
appears inside every resource name here.

### Why provision runs before image

Earlier revisions built the image first, which meant the `image` stage had to
create the ECR repository itself with `aws ecr create-repository` — it needed
somewhere to push before any Terraform had run. That gave one AWS resource **two
owners**. The CLI always won the race, so `aws_ecr_repository.app` then failed
its own creation with `RepositoryAlreadyExistsException` on every single run.

Terraform is now the sole owner of the registry, exactly as it is of every other
AWS resource here, and `image` reads `ecr_repository_url` from state. Ordering
`provision` first costs nothing — the cluster must exist before `configure` can
deploy into it regardless.

The `provision` stage carries a one-time **adopt** step that imports a
pre-existing ECR repository into state if one was left behind by the old
CLI-created path. On a clean account it is a no-op.

### What the security stage does and does not cover

Trivy runs from the official `aquasec/trivy` **container image** rather than a
marketplace action. A `uses:` reference is resolved by GitHub *before any step
executes*, so a tag that does not exist kills the entire job during action
resolution with no scan attempted — which is exactly how the first deploy
attempt failed. An image tag is verified by the registry at pull time and fails
loudly inside the step instead.

The scan covers the Maven dependency tree, the container base image, secrets in
the tree, **and `infra/*.tf` misconfiguration** — so Terraform findings block
the deploy before `provision` creates anything, which is the cheap place to find
them. It has already caught two actuator CVEs, missing EKS secret encryption and
public-IP-on-launch subnets, all fixed at their cause before a dollar was spent.

**OWASP Dependency-Check was removed** (2026-09-05). It downloads and unpacks
the full NVD CVE feed on a cold runner cache, routinely costing 5–15 minutes and
occasionally rate-limiting without an NVD API key. Trivy covers the same Maven
dependency tree *and* the container base image — which Dependency-Check never
inspected — in well under a minute. The `--severity HIGH,CRITICAL --exit-code 1`
gate is unchanged; the stage still blocks the rest of the pipeline.

The residual gap is Dependency-Check's NVD-specific CPE matching, which
occasionally flags a Java library Trivy's advisory sources do not. If this stops
being a throwaway exercise, run Dependency-Check on a schedule (an extra
`pipelines:` workflow with a cached NVD data directory) rather than reinstating
it on the critical path.

### Accepted security exceptions

`.trivyignore.yaml` holds exactly **two** entries, both scoped to `infra/eks.tf`
and both expiring `2026-12-31`:

| Check | Finding |
|---|---|
| `AVD-AWS-0040` | EKS public cluster access is enabled |
| `AVD-AWS-0041` | EKS cluster allows access from `0.0.0.0/0` |

These are two Trivy views of **one** structural fact: the `configure` stage
drives `helm` and `kubectl` from a GitHub-hosted runner, which sits outside the
VPC and draws from Azure's public IP ranges with no stable egress address. No
CIDR narrower than `0.0.0.0/0` lets the deploy reach the API server, and turning
the public endpoint off makes the pipeline unrunnable. Both close together in
Phase 2 via a self-hosted runner inside the VPC.

Mitigations in place today: private endpoint access enabled so in-VPC traffic
never leaves the network; IAM authentication in API mode, so *reachability is
not authorization* and an unauthenticated caller gets `401`; API, audit and
authenticator logs shipped to CloudWatch; secrets encrypted at rest with a
customer-managed KMS key.

Nothing else is suppressed. Every other finding was fixed rather than ignored,
and the severity gate itself has never been relaxed.

---

## Repository visibility

Argo CD reconciles from *inside* the cluster, so it cannot use the workflow's
`GITHUB_TOKEN`. There are two ways to give it read access, and this project uses
the second:

1. **A read-only PAT** stored as a `GITOPS_PAT` repo secret, which the configure
   stage turns into an Argo CD repository-credential Secret.
2. **A public repository**, cloned anonymously — no token anywhere. ← *in use*

Because option 2 is a *deployment-blocking* assumption, the configure stage
checks it explicitly with `git ls-remote` before applying the root Application.
If the repository is ever made private, that check fails immediately with
instructions, rather than leaving an Application stuck at `Unknown` for ten
minutes with an opaque authentication error.

**What being public means here:** the Terraform, the pipeline spec and the
application source are world-readable. That is safe *only because* no secret
values live in this repository — every credential is a `${{ secrets.NAME }}`
reference resolved by CI at run time, and the platform's secret scanner gates
each commit. Do not commit a real value on the assumption nobody is looking.

To switch back to a private repository: make it private on GitHub, add a
fine-grained PAT with **Contents: Read-only** as the `GITOPS_PAT` secret, and
restore the repository-credential step in the configure stage.

---

## Secrets

| Secret | Source |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Set by the platform |
| `TF_STATE_BUCKET`, `PROJECT_NAME` | Set by the platform |

No project-specific secrets. ECR authentication reuses the AWS credentials; no
GHCR token and no GitOps PAT exist.

---

## Rollback

Ordered least- to most-disruptive:

1. **Re-patch a previous tag** — set `image.tag` on the `app-dev` Application to
   an earlier SHA. Argo syncs it in seconds. This is the normal undo, and it
   works precisely because images are SHA-tagged and immutable in ECR.
2. **`argocd app rollback app-dev <id>`** — reverts to a previous sync revision.
3. **Revert the commit** — for chart or manifest changes, since those *are* Git
   state. Argo picks the revert up on its next reconcile.
4. **`terraform` revert + apply** — infrastructure has no undo; roll the commit
   back and re-run `provision`.

The pipeline declares `rollback: {strategy: manual}`: nothing rolls back
automatically, because on a GitOps cluster an automatic CI rollback would be a
second writer racing Argo.

---

## Teardown

The EKS control plane bills hourly whether or not anything is deployed. Tear the
project down with the platform's **destroy** action (`destroy_infra`), which runs
the rendered destroy workflow with the same backend and credentials.

---

## Deferred phases

| Phase | Item |
|---|---|
| 2 | Argo Rollouts controller; blue/green via `blueGreen.enabled` |
| 2 | Analysis gate on the preview Service before traffic switches |
| 2 | **Self-hosted runner inside the VPC** → narrow `cluster_public_access_cidrs`, disable the public endpoint, drop both `.trivyignore.yaml` entries |
| 3 | Canary with weighted steps + automated rollback on metric regression |
| 3 | Observability: Prometheus, Grafana, Argo CD notifications, Rollouts label-sync |
| 4 | Flux under `flux/` as a second reconciler for comparison |
| — | **Scheduled OWASP Dependency-Check** with a cached NVD directory, off the critical path (removed from `security` on 2026-09-05 for runtime) |
| — | PodSecurity admission, NetworkPolicies |
| — | HTTPS: ACM certificate + external-dns on a real domain |
| — | external-secrets / sealed-secrets |
| — | Autoscaling (Karpenter or Cluster Autoscaler), PodDisruptionBudgets |
| — | Velero backups, ECR cross-region replication |

The chart's values surface already contains `blueGreen` and `canary` blocks
(both `false`, mutually exclusive, with the plain Deployment guarded by
`{{- if and (not .Values.blueGreen.enabled) (not .Values.canary.enabled) }}`),
so Phase 2 is a flag flip rather than a chart rewrite.

---

## Cost

Roughly **$190–200/month** in `us-east-1`: EKS control plane $73, 2×`t3.medium`
~$60, ALB ~$17–22, NAT gateway ~$32, plus EBS/ECR/data transfer and ~$1 for the
KMS key. Dropping the NAT gateway (nodes in public subnets) saves ~$32 and
running a single node saves ~$30.
