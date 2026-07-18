# Full Rebuild Checklist — Everything From Scratch
**Use this the day before the interview.** Work top to bottom; the order matters.
**Total time: ~45–60 min**, most of it waiting on `terraform apply`.

> Why the order matters: service connections can only be created **after** the ACR and AKS exist,
> because they point at real resources. And the pipeline can't run until both connections and the
> environment exist. Don't jump ahead.

---

## PHASE 0 — Before you start (5 min)

- [ ] **Confirm the correct Azure subscription is active.** This has bitten before — a Microsoft
  Learn sandbox can silently become the default.
  ```bash
  az login
  az account show --output table          # must be your real subscription, NOT learn-...
  az account set --subscription "<subscription-id>"
  az account show --output table          # verify it switched
  ```
- [ ] **Confirm the repo is clean and current**
  ```bash
  cd aks-dotnet-pipeline
  git status                              # nothing uncommitted
  git pull                                # latest from GitHub
  ```
- [ ] **Confirm `k8s/deployment.yaml` has PLACEHOLDERS, not hardcoded values.**
  Should contain `__ACR_LOGIN_SERVER__` and `__IMAGE_TAG__`. If a manual deploy left real values in:
  ```bash
  git checkout k8s/deployment.yaml
  ```
- [ ] **Confirm tools are present:** `az version`, `terraform version`, `kubectl version --client`

---

## PHASE 1 — Infrastructure (15–20 min, mostly waiting)

- [ ] **Apply Terraform**
  ```bash
  cd terraform
  terraform init
  terraform apply          # type: yes  — AKS takes 3–5 min
  ```
- [ ] **Record the outputs** (you need these next):
  - `acr_login_server` = ______________________ (e.g. `calebaksacr.azurecr.io`)
  - `aks_cluster_name` = `calebaks-aks`
  - `resource_group_name` = `calebaks-rg`

- [ ] **If apply fails on VM size** — the node SKU must clear BOTH a regional allow-list and a
  per-family vCPU quota:
  ```bash
  az vm list-skus  --location westeurope --output table    # allow-listed sizes
  az vm list-usage --location westeurope --output table    # families with Limit > 0
  ```
  Pick a size in both lists, update `terraform/variables.tf`, re-apply.
  (Naming: `D2s_v6`, not `DS2_v6`.)

- [ ] **Verify infrastructure exists**
  ```bash
  cd ..
  az aks list --output table    # calebaks-aks, ProvisioningState: Succeeded
  az acr list --output table    # calebaksacr
  ```

- [ ] **Point kubectl at the NEW cluster** (the FQDN changes on every rebuild)
  ```bash
  az aks get-credentials -g calebaks-rg -n calebaks-aks --overwrite-existing
  kubectl config current-context     # calebaks-aks
  kubectl get nodes                  # aks-default-... , Ready
  ```

---

## PHASE 2 — Azure DevOps setup (15 min)

> If you deleted the DevOps project, do 2a. If you only tore down Azure, skip to 2b and just
> **refresh** the existing connections.

### 2a. Project (only if starting fresh)
- [ ] dev.azure.com → **New project** → name it → Private → Create

### 2b. ACR service connection
- [ ] Project Settings → Service connections → New → **Docker Registry**
- [ ] Try **Azure Container Registry** first (subscription → `calebaksacr`)
- [ ] **If "No registries found" / auth validation error**, use **Others** instead:
  ```bash
  az acr credential show --name calebaksacr --resource-group calebaks-rg
  ```
  - Docker Registry: `https://calebaksacr.azurecr.io`
  - Docker ID: `calebaksacr`
  - Password: the first password from that command
- [ ] Name it **exactly** `acr-connection`
- [ ] Tick **Grant access permission to all pipelines** → Save

### 2c. AKS service connection  ← **MOST COMMONLY MISSED STEP**
- [ ] Generate a fresh admin kubeconfig for the **new** cluster:
  ```bash
  az aks get-credentials -g calebaks-rg -n calebaks-aks --admin --file -
  ```
- [ ] Service connections → **Kubernetes** → **KubeConfig** method
- [ ] Paste the ENTIRE output (`apiVersion:` to the end)
- [ ] Tick **Accept untrusted certificates**
- [ ] Name it **exactly** `aks-connection` → Grant all pipelines → **Verify and save** (should go green)

> If the connection already exists from before: **Edit it and replace the kubeconfig**. The old one
> points at a destroyed cluster and will fail with `no such host`.

### 2d. Environment
- [ ] Pipelines → Environments → New environment → name **exactly** `aks-prod` → resource **None**

### 2e. Pipeline (only if starting fresh)
- [ ] Pipelines → New pipeline → **GitHub** → authorize → select `calebio/aks-dotnet-pipeline`
- [ ] It detects `azure-pipelines.yaml` → Run
- [ ] Click **Permit** on each authorization prompt

---

## PHASE 3 — Run and verify (10 min)

- [ ] **Confirm `acrLoginServer` in the pipeline matches your ACR** (it should already —
  `calebaksacr.azurecr.io`)
- [ ] **Trigger a run** — push any commit, or Pipelines → Run pipeline
- [ ] **Build stage** — watch each step:
  - Install .NET 10 SDK ✓
  - Install ASP.NET Core 8 runtime (via `dotnet-install.sh` into `/opt/hostedtoolcache/dotnet`) ✓
  - Restore / Build ✓
  - **Test — must show `Passed: 2`, not silence.** A green step that ran zero tests is a false pass.
  - Docker buildAndPush ✓
- [ ] **Deploy stage** — placeholder substitution, then manifests applied
- [ ] **Verify the pods**
  ```bash
  kubectl get pods                              # 2 pods, READY 1/1, Running
  kubectl describe pod <pod-name> | grep Image: # tag = BUILD NUMBER, not v1
  ```
- [ ] **Reach the app — option A: port-forward** (no public IP, no cost — use during development)
  ```bash
  kubectl port-forward svc/weatherapi-svc 8080:80
  ```
  Check: `/swagger`, `/api/weather`, `/healthz`, `/readyz`

- [ ] **Reach the app — option B: public LoadBalancer IP** (the better demo — proves the full
  internet → Azure Load Balancer → Service → pod chain)
  ```bash
  kubectl get svc weatherapi-svc          # EXTERNAL-IP populates in ~1-2 min
  ```
  - EXTERNAL-IP = ______________________  ← **write it down / bookmark it**
  - Open `http://<EXTERNAL-IP>/swagger` — the Service listens on port 80, so no port needed
  - Costs ~$0.025/hr for the public IP + Standard Load Balancer. Fine overnight; destroy after.
  - The IP **changes on every rebuild** — always re-capture it.

- [ ] **THE MONEY DEMO** — change one string in `WeatherController.cs`, commit, push, and watch the
  full pipeline run and redeploy. New pods, new tag. This is the thing to show live.

### Demo prep (do this the night before, while everything works)

- [ ] Screenshot the **green pipeline run** — both stages, and the Test step showing `Passed: 2`
- [ ] Screenshot `kubectl get pods` — 2 pods Running
- [ ] Screenshot the **Swagger UI** at the public IP
- [ ] Bookmark: the GitHub repo, the Azure DevOps run, `http://<EXTERNAL-IP>/swagger`
- [ ] On the day, ~1 hour before the call:
  ```bash
  az account show --output table    # still the right subscription?
  kubectl get pods                  # still connected? if not: az aks get-credentials ... --overwrite-existing
  curl http://<EXTERNAL-IP>/healthz # app still serving?
  ```

> **What to show, in priority order:** (1) the GitHub repo — README and pipeline YAML, the strongest
> and most permanent artifact; (2) the green pipeline run; (3) the live app at the public IP.
> Screenshots cover you if the network misbehaves — for a 45-minute call they're often better than
> fumbling with a terminal.

---

## PHASE 4 — After the interview

- [ ] `cd terraform && terraform destroy`
- [ ] Azure DevOps costs nothing — leave it. (Only the kubeconfig in `aks-connection` goes stale.)

---

# Things you should know if asked

## Why each piece is built the way it is

**Multi-stage Docker build** — compile in the SDK image (~800 MB), ship only the aspnet runtime
image (final ~92 MB). Smaller attack surface, faster pulls, no build tools in production.
The two-step COPY (csproj → restore → then source) keeps the expensive restore layer cached across
code changes.

**Non-root container** — `USER` in the Dockerfile *and* `runAsNonRoot: true` + `runAsUser: 1000` in
the manifest. Belt and braces: if someone removes the Dockerfile line, the pod refuses to start
rather than silently running privileged. The **numeric UID is mandatory** — Kubernetes can't verify
non-root from a username, so `runAsNonRoot` alone fails with `CreateContainerConfigError`.

**Managed-identity ACR pull** — the AKS kubelet identity holds the `AcrPull` role, so pods
authenticate to the registry with no secret, nothing to leak, nothing to rotate. The alternative
(admin user + image-pull secret) puts a long-lived credential in the cluster.

**Liveness vs readiness** — liveness failure **restarts** the pod (process is wedged); readiness
failure **de-routes** it without killing it (not ready for traffic yet). Conflating them is the
classic mistake — e.g. a dependency check in liveness turns a brief database blip into a restart storm.

**Requests vs limits** — requests drive **scheduling** (which node has room); limits cap **runtime**
(OOM-kill on memory, throttle on CPU).

**Two replicas** — availability during node upgrades, and enables rolling updates with no downtime.

**Test gate** — Deploy has `dependsOn: Build` + `condition: succeeded()`. `dotnet test` exits
non-zero on failure → Build fails → Deploy never runs. A failing test physically cannot reach the
cluster.

**Build-ID image tags** — a pod running `weatherapi:47` traces to exactly one pipeline run, one
commit, one set of test results. `latest` tells you nothing.

**Placeholder substitution** — manifests stay environment-agnostic in source control; registry and
tag are injected at deploy time. *"How would you improve this?"* → Helm or Kustomize for real
templating.

**Integration tests over unit tests** — `WebApplicationFactory` boots the whole app in memory and
exercises real routing, model binding, serialization, and middleware. A unit test calling the
controller method directly would pass even with a broken route. And critically: **they need no
infrastructure**, so they run on an ephemeral CI agent with nothing but the SDK.

## Honest limitations (say these before you're asked)

- **Static credentials in CI.** The ACR connection uses an admin credential and the AKS connection
  an admin kubeconfig, because a personal DevOps org can't federate a service principal into the
  subscription. Production answer: **workload identity federation** for both. Note that cluster
  *pulls* still use managed identity — only the CI *push* uses a credential.
- **Local Terraform state.** `backend.tf` is stubbed. A team needs a shared azurerm backend with
  locking; state can contain secrets and must never be committed.
- **Swagger is exposed in all environments** for demo convenience. In production: gate behind
  `IsDevelopment()` or auth — an OpenAPI doc is a map of your attack surface.
- **ACR public network access is on.** Hardened setup: private endpoint.
- **No workload identity for the app itself.** The kubelet identity handles image pulls; if the app
  needed Key Vault or a database, you'd enable the OIDC issuer and federate a service account.
- **No approval gate** on `aks-prod`. The environment is where you'd attach one for controlled
  production releases.

## War stories (proof you actually ran this)

**Two independent Azure constraints.** A VM size must clear both a regional SKU allow-list and a
per-family vCPU quota — they didn't overlap for burstable sizes on a new subscription. Cross-
referenced `vm list-skus` against `vm list-usage` to find a family satisfying both, rather than
waiting on a quota-increase request.

**Ambient context bugs (three variants).** `kubectl` deployed to a local Docker Desktop cluster
because the context pointed there; `az` commands silently ran against an expired Learn sandbox
subscription; and every `terraform destroy`/`apply` invalidated stored kubeconfigs (new cluster =
new FQDN → `no such host`). Lesson: cloud tooling acts on ambient state you must actively verify —
check `kubectl config current-context` and `az account show` before anything destructive.

**Security enforcement needs something verifiable.** `runAsNonRoot: true` blocked the pods because
the image declared a *username*, not a numeric UID. The wrong fix is deleting `runAsNonRoot`; the
right fix is `runAsUser: 1000` so the platform has something concrete to check.

**SDK vs runtime, twice.** The CI agent had .NET 10 but the net8.0 test binary needed the 8.0
runtime; then it needed the **ASP.NET Core** shared framework specifically, because
`WebApplicationFactory` hosts the web stack in-process. Tried `DOTNET_ROLL_FORWARD` to run on 10 —
it worked, but surfaced a behavioural difference that failed a test. Correct answer: **test on the
runtime you ship on** (the container runs `aspnet:8.0`).

**Everything that broke in CI was an implicit dependency on my machine.** The SDK that happened to
be installed, the directory I happened to be in, a `-var` flag I passed by hand, a cached
kubeconfig, and absolute paths baked into a solution file. CI starts from nothing, which is exactly
why it catches these.

**Committed Terraform state and a 237 MB provider binary to git.** GitHub rejected the push.
`.gitignore` doesn't untrack files already in the index (`git rm --cached`), and it doesn't rewrite
history — the object stays in the repo until history is rewritten. If it had been a secret, deleting
it in a later commit would NOT be the fix; you'd rotate the credential.

**Toolchain defects exist too.** The `UseDotNet@2` task's OS-detection script fails on current
Ubuntu agent images. Recognising "this error is below my layer" and switching to the official
install script beat thrashing on my own config. Related: pin agent images — `ubuntu-latest` moving
under you breaks green pipelines with no code change.

**Fail-fast validation.** Azure DevOps validates service connections and environments *before*
running any step — a missing `acr-connection` failed the run in under a second. Better than
discovering a missing credential three minutes in, after build and test.