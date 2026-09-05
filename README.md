# gitops-delivery-platform

A GitOps delivery platform on Amazon EKS: application code, its Helm chart, the
cluster infrastructure and the Argo CD manifests all live in **one repository**,
reconciled into the cluster by Argo CD.

> **Phase 2 scope.** Cluster + registry + a minimal Spring Boot service + one
> Helm chart that renders in three modes + Argo CD with an app-of-apps root and
> three Applications (`app-dev`, `app-bluegreen`, `app-canary`) + the Argo
> Rollouts controller + a manual rollback workflow. Metric-driven analysis,
> observability and Flux remain deferred — see [Deferred phases](#deferred-phases).

> **This repository is PUBLIC by design.** Argo CD clones it anonymously, so no
> repository-credential Secret and no personal access token exist anywhere in
> the system. See [Repository visibility](#repository-visibility).

---

## Repository layout

| Path | What lives there |
|---|---|
| `infra/` | **All** Terraform: VPC, EKS cluster + managed node group, ECR, IRSA role for the AWS Load Balancer Controller, ACM certificate |
| `app/` | Spring Boot 3.5 / Java 21 service + `Dockerfile` |
| `chart/gitops-delivery-platform/` | The Helm chart Argo CD renders — Deployment **or** Rollout, see [Delivery strategies](#delivery-strategies) |
| `gitops/root-app.yaml` | The app-of-apps root Application |
| `gitops/apps/` | Child Applications, rendered as a chart (`app-dev`, `app-bluegreen`, `app-canary`) |
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
`spec.source.helm.parameters` on each Application with `kubectl patch`. The
repository is left byte-identical by a deploy, so self-heal has nothing to
revert. `chart/…/values.yaml` therefore keeps `image.tag: ""` **permanently** —
the chart's `app.image` helper fails the render if it is ever empty at sync
time, which turns "someone forgot to patch" into a loud error instead of a pod
pulling `repository:`.

**3. No path filters, no `[skip ci]`.**
Conventional monorepo GitOps needs those guards because a CI commit retriggers
CI. UDAP renders `workflow_dispatch`-only workflows triggered by the platform,
so no commit can retrigger anything. The guards would be cargo cult here.

---

## Delivery strategies

One chart renders three different workloads, selected by two mutually exclusive
values. Each Application flips exactly one of them via `helm.values`:

| Application | Namespace | `blueGreen` | `canary` | Workload rendered |
|---|---|---|---|---|
| `app-dev` | `app-dev` | `false` | `false` | `Deployment` + `Service` + `Ingress` (ALB) |
| `app-bluegreen` | `app-bluegreen` | **`true`** | `false` | `Rollout` + active/preview `Service`s |
| `app-canary` | `app-canary` | `false` | **`true`** | `Rollout` with weighted steps |

**Mutual exclusion is enforced at render time**, not by convention. Every
workload template calls the `app.validateStrategy` helper, which `fail`s the
render if both flags are on. The plain `Deployment` is guarded by
`{{- if and (not .Values.blueGreen.enabled) (not .Values.canary.enabled) }}`, so
a Rollout and a Deployment can never both own the same pods.

**Why the strategy flags live in `helm.values` and not `helm.parameters`:** the
configure stage patches `spec.source.helm.parameters` with a **merge** patch to
inject the image tag, and a merge patch *replaces* a list wholesale. Anything
stored in `parameters` would be silently wiped on the next deploy. `values` is a
separate field the patch never touches.

### Blue/green

Two full ReplicaSets exist during a release: the live one behind the **active**
Service, the new one behind **preview**. `autoPromotionEnabled: false`, so the
preview comes up and *waits for a human*:

```
kubectl argo rollouts promote app-bluegreen-gitops-delivery-platform -n app-bluegreen
```

The Rollouts controller does **not** create the active/preview Services — it
mutates the selectors of Services that must already exist. `rollout-services.yaml`
renders both, and the child Application carries an `ignoreDifferences` on
`Service` `/spec/selector` so Argo does not fight the controller's selector
injection mid-promotion.

### Canary

Steps `20% → pause 60s → 50% → pause 60s → 100%`. With no traffic-router
provider configured these weights shift the **proportion of pods**, not a
precise share of requests: at `setWeight: 20` with `replicaCount: 2`, roughly
one pod runs the new version. Precise weighted routing needs an ALB traffic
router (deferred). The pauses are the real control.

Both Rollout Applications ignore `/spec/replicas` — the controller owns the
replica count during a release, and without that exemption self-heal would reset
each intermediate state and collapse the canary before its pause elapsed.

Neither progressive-delivery instance renders an Ingress (`ingress.enabled:
false`): each one would provision its own billable ALB. They are exercised
in-cluster.

---

## Pipeline

`test` and `security` run in parallel → `provision` → `image` → `configure` → `verify`.

| Stage | Does |
|---|---|
| `test` | `mvn verify` — unit + MockMvc tests |
| `security` | Trivy scan of the tree: vuln + secret + misconfig, HIGH/CRITICAL fail the build |
| `provision` | `terraform init -reconfigure` + `apply` over `infra/` — creates the VPC, EKS cluster, **and the ECR repository** |
| `image` | Reads the registry URL from terraform state, builds the jar and image, pushes tagged with the commit SHA |
| `configure` | Argo CD install, **Argo Rollouts install**, ALB controller, anonymous-read check, root app, image-tag patch on all three Applications, repo-server cache refresh |
| `verify` | Polls all four Applications for `Synced` + `Healthy`, checks both Rollouts reached a stable phase, then curls the ALB |

**Every stage that needs an infrastructure value reads it itself** by re-running
`terraform init` with identical `-backend-config` flags and calling
`terraform output -raw`. Nothing is threaded between jobs: GitHub silently drops
job outputs containing a secret substring, and `PROJECT_NAME` is a secret that
appears inside every resource name here.

### Why the Rollouts controller installs before the root Application

`app-bluegreen` and `app-canary` render a `kind: Rollout`. If that CRD is not
registered yet, the API server *rejects* the object and Argo CD reports it as a
sync failure on the child Application — indistinguishable from a broken chart.
Installing the controller first, and `kubectl wait`ing for the CRDs to reach
`Established`, removes the race.

It is installed with `kubectl apply --server-side` from the pinned upstream
release manifest rather than Helm: the CRDs exceed the 262144-byte annotation
limit that client-side apply imposes, so `--server-side` is required, not merely
preferred. `--force-conflicts` lets an upgrade take ownership of fields an
earlier client-side apply wrote.

### The repo-server cache refresh

On a **fresh** cluster the root Application creates each child with an empty
`parameters: []`. Argo renders it immediately, the chart's image guard fails,
and the repo-server **caches that failure**. The image-tag patch then lands, but
Argo keeps serving the stale error once its retry backoff is spent — the
Application sits at `sync=Unknown` with a `ComparisonError` reading `(cached)`.

That state was previously cleared by hand. The configure stage now restarts
`argocd-repo-server` after patching and requests a hard refresh, making the fix
part of the deploy instead of tribal knowledge. A hard-refresh annotation alone
is *not* sufficient — it re-renders but can still be served from the failed-render
cache.

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

## Argo CD UI exposure — accepted risk

The Argo CD console at `https://argocd.rbai.royalbengal.xyz` is reachable from
**every address on the internet** (`ARGOCD_ALLOWED_CIDRS = ["0.0.0.0/0"]`),
guarded by a single shared `admin` password. That account holds **cluster-admin
authority**: it can deploy any workload and read every Secret in the cluster.

This was an explicit operator decision on 2026-09-05, taken after GitHub SSO and
a second allowlisted CIDR were both offered and declined. It is recorded here
because an undocumented open admin console becomes invisible normal within a
month. Two guards previously refused this value — one on the Terraform variable,
one in the configure stage — and both were deliberately removed.

What is still enforced: the configure stage refuses an **empty** allowlist. That
is a different failure — the ALB controller treats a missing `inbound-cidrs`
annotation as "no restriction", so a malformed or unset secret would open the
console with nobody choosing it. Every deploy also prints a `NOTICE` naming the
exposure.

**The durable fix is SSO/OIDC with `admin.enabled: false`** — per-person GitHub
logins, their own 2FA, and revoke-by-removing-from-the-org, instead of one shared
password and no per-person audit trail.

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

## Secrets and variables

| Secret | Source |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Set by the platform |
| `TF_STATE_BUCKET`, `PROJECT_NAME` | Set by the platform |
| `ARGOCD_ALLOWED_CIDRS` | Operator — HCL list syntax, consumed by Terraform *and* the ingress annotation |
| `ARGOCD_ADMIN_PASSWORD` | Operator — alphanumeric, 20+ chars (it passes through `htpasswd` and a JSON patch body) |

| Repository variable | Used by |
|---|---|
| `ROLLBACK_IMAGE_TAG` | The `rollback` workflow — the commit SHA to roll back to |
| `ROLLBACK_APPLICATION` | The `rollback` workflow — optional, defaults to `app-dev` |

ECR authentication reuses the AWS credentials; no GHCR token and no GitOps PAT
exist.

---

## Rollback

Ordered least- to most-disruptive:

**1. The `rollback` workflow** — the supported one-click path.

Set the repository variable, then dispatch the workflow:

```
Settings → Secrets and variables → Actions → Variables
  ROLLBACK_IMAGE_TAG   = <the commit SHA to roll back to>
  ROLLBACK_APPLICATION = app-dev | app-bluegreen | app-canary   (optional)

Actions → rollback → Run workflow
```

It reads the registry URL from Terraform state, **confirms the tag exists in
ECR before touching the cluster** (patching to a tag that was never pushed would
produce `ImagePullBackOff` on every new pod — a broken deployment created *by*
the rollback), patches the Application, and then waits for it to actually
converge on the requested tag rather than reporting success on a patch that
self-heal may have reverted. The run summary records the previous tag so undoing
the rollback is one variable change away.

> **Why a repository variable and not a `workflow_dispatch` input?** The platform
> renders every workflow with a bare `workflow_dispatch: {}` and the pipeline
> spec has no field for declaring `inputs:`. A `${{ inputs.* }}` reference would
> resolve to an empty string on every run.

> **On `app-bluegreen`,** a rollback creates a new *preview* ReplicaSet on the
> old tag and waits for promotion, because `autoPromotionEnabled` is false.
> Promote it to move traffic.

**2. `argocd app rollback <app> <id>`** — reverts to a previous sync revision.

**3. Revert the commit** — for chart or manifest changes, since those *are* Git
state. Argo picks the revert up on its next reconcile.

**4. `terraform` revert + apply** — infrastructure has no undo; roll the commit
back and re-run `provision`.

The pipeline declares `rollback: {strategy: manual}`: nothing rolls back
automatically, because on a GitOps cluster an automatic CI rollback would be a
second writer racing Argo. The `rollback` workflow is manual dispatch for the
same reason — a human decides, the workflow executes.

---

## Teardown

The EKS control plane bills hourly whether or not anything is deployed. Tear the
project down with the platform's **destroy** action (`destroy_infra`), which runs
the rendered destroy workflow with the same backend and credentials.

---

## Deferred phases

| Phase | Item |
|---|---|
| 3 | `AnalysisTemplate` gate on the preview Service / canary steps — needs a metrics provider (Prometheus) |
| 3 | ALB traffic router so canary weights shift **requests**, not pod proportions |
| 3 | Observability: Prometheus, Grafana, Argo CD notifications, Rollouts label-sync |
| 4 | Flux under `flux/` as a second reconciler for comparison |
| — | **SSO/OIDC for Argo CD with `admin.enabled: false`** — the correct fix for the open console |
| — | **Self-hosted runner inside the VPC** → narrow `cluster_public_access_cidrs`, disable the public endpoint, drop both `.trivyignore.yaml` entries |
| — | **Scheduled OWASP Dependency-Check** with a cached NVD directory, off the critical path (removed from `security` on 2026-09-05 for runtime) |
| — | PodSecurity admission, NetworkPolicies |
| — | external-secrets / sealed-secrets |
| — | Autoscaling (Karpenter or Cluster Autoscaler), PodDisruptionBudgets |
| — | Velero backups, ECR cross-region replication |

---

## Cost

Roughly **$190–200/month** in `us-east-1`: EKS control plane $73, 2×`t3.medium`
~$60, ALB ~$17–22, NAT gateway ~$32, plus EBS/ECR/data transfer and ~$1 for the
KMS key. Dropping the NAT gateway (nodes in public subnets) saves ~$32 and
running a single node saves ~$30.

**Phase 2 adds no new billable AWS resources.** The Rollouts controller is one
small pod, and both progressive-delivery Applications set `ingress.enabled:
false` precisely so they do not each provision an ALB. They do add pods: with
`replicaCount: 2` in each of three namespaces, the two `t3.medium` nodes are
now meaningfully loaded — scale `app-bluegreen`/`app-canary` down to 1, or add a
node, if scheduling gets tight.
