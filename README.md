# gitops-delivery-platform

A GitOps delivery platform on Amazon EKS: application code, its Helm chart, the
cluster infrastructure and the Argo CD manifests all live in **one repository**,
reconciled into the cluster by Argo CD.

> **Phase 1 scope.** Cluster + registry + a minimal Spring Boot service + one
> Helm chart in plain-Deployment mode + Argo CD with an app-of-apps root and a
> single `app-dev` Application. Argo Rollouts, blue/green, canary, observability
> and Flux are deliberately deferred — see [Deferred phases](#deferred-phases).

---

## Repository layout

| Path | What lives there |
|---|---|
| `infra/` | **All** Terraform: VPC, EKS cluster + managed node group, ECR, IRSA role for the AWS Load Balancer Controller |
| `app/` | Spring Boot 3.4 / Java 21 service + `Dockerfile` |
| `chart/gitops-delivery-platform/` | The Helm chart Argo CD renders |
| `gitops/root-app.yaml` | The app-of-apps root Application |
| `gitops/apps/` | Child Applications, rendered as a chart (`app-dev`) |
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

`test` and `security` run in parallel → `image` → `provision` → `configure` → `verify`.

| Stage | Does |
|---|---|
| `test` | `mvn verify` — unit + MockMvc tests |
| `security` | OWASP Dependency-Check + Trivy filesystem scan (HIGH/CRITICAL fail) |
| `image` | Builds the jar, builds the image, pushes to ECR tagged with the commit SHA |
| `provision` | `terraform init -reconfigure` + `apply` over `infra/` |
| `configure` | Argo CD install, ALB controller, repo credentials, root app, image-tag patch |
| `verify` | Polls `root` and `app-dev` for `Synced` + `Healthy`, then curls the ALB |

**Every stage that needs an infrastructure value reads it itself** by re-running
`terraform init` with identical `-backend-config` flags and calling
`terraform output -raw`. Nothing is threaded between jobs: GitHub silently drops
job outputs containing a secret substring, and `PROJECT_NAME` is a secret that
appears inside every resource name here.

---

## Secrets

| Secret | Source |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Set by the platform |
| `TF_STATE_BUCKET`, `PROJECT_NAME` | Set by the platform |
| `GITOPS_PAT` | **You must supply this** |

`GITOPS_PAT` is a fine-grained PAT with **read-only Contents** on this repo.
Argo CD reconciles from *inside* the cluster, so it cannot use `GITHUB_TOKEN`;
the configure stage turns this PAT into an Argo CD repository-credential Secret.
No GHCR token exists anywhere — ECR authentication reuses the AWS credentials.

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
| 3 | Canary with weighted steps + automated rollback on metric regression |
| 3 | Observability: Prometheus, Grafana, Argo CD notifications, Rollouts label-sync |
| 4 | Flux under `flux/` as a second reconciler for comparison |
| — | Private-only API endpoint, PodSecurity admission, NetworkPolicies |
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
~$60, ALB ~$17–22, NAT gateway ~$32, plus EBS/ECR/data transfer. Dropping the
NAT gateway (nodes in public subnets) saves ~$32 and running a single node saves
~$30.
