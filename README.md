# Running the AKS .NET Pipeline from a Mac (fresh setup)

This runbook stands the project up from scratch on macOS **without touching the .NET/application side**. The container image is built **server-side in Azure Container Registry** (`az acr build`), so you never install the .NET SDK locally — and you sidestep the Apple Silicon (ARM64) vs AKS (amd64) architecture mismatch entirely.

Assumes: the application code, Dockerfile, Terraform, `k8s/` manifests, and `azure-pipelines.yml` are already in the repo. You are provisioning infrastructure and deploying.

---

## 1. Install the tools (Homebrew)

```bash
brew install azure-cli terraform kubernetes-cli
brew install --cask docker      # only needed if you build locally; az acr build makes it optional
```

Verify:
```bash
az version
terraform version
kubectl version --client
```

## 2. Clone the repo

```bash
git clone https://github.com/calebio/aks-dotnet-pipeline.git
cd aks-dotnet-pipeline
```

## 3. Log in to Azure

```bash
az login
az account show --output table     # confirm the right subscription is active
```

If you have more than one subscription:
```bash
az account set --subscription "<subscription-id-or-name>"
```

---

## 4. Provision infrastructure with Terraform

```bash
cd terraform
terraform init
terraform apply        # review the plan, type: yes
```

Takes ~3–5 minutes. When done, note the outputs — especially `acr_login_server`
(e.g. `calebaksacr.azurecr.io`).

### If apply fails on the VM size

New subscriptions often can't use a given node SKU in a region (either not on the
regional allow-list, or the vCPU quota for that family is zero). The node size is
pinned in `terraform/variables.tf` (default `Standard_D2s_v6`). If it's rejected,
find a size that clears **both** filters:

```bash
az vm list-usage --location westeurope --output table   # families with quota headroom (Limit > 0)
az vm list-skus  --location westeurope --output table    # sizes allow-listed in the region
```

Pick a current-generation D-series that appears in both, update the default in
`variables.tf`, commit it, and re-run `terraform apply`. (Note Azure's naming:
it's `D2s_v6` — number before the lowercase `s` — not `DS2_v6`.)

---

## 5. Point kubectl at the cluster

```bash
az aks get-credentials --resource-group calebaks-rg --name calebaks-aks --overwrite-existing
```

`--overwrite-existing` is important: every teardown/rebuild creates a cluster with a
new FQDN, so a stale kubeconfig entry from a previous cluster will fail with
`no such host`. This flag replaces it.

Always verify you're on the right cluster before deploying:
```bash
kubectl config current-context     # should read calebaks-aks
kubectl get nodes                  # should show an aks-... node, STATUS Ready
```

---

## 6. Build the image (server-side, no local .NET or Docker)

```bash
cd ..                              # back to repo root (where the Dockerfile is)
az acr build --registry calebaksacr --image weatherapi:v1 .
```

This uploads the build context and compiles the multi-stage Dockerfile **inside Azure
on amd64** — no local .NET SDK, no local Docker build, no ARM/amd64 mismatch. Wait for
`Run ID: ... was successful`.

> If `az acr build` errors while packing the tar, an editor or process may be holding a
> file open in the build context. Ensure `.dockerignore` excludes `.vs/`, `bin/`, `obj/`,
> `.git/`, and close anything locking those paths.

---

## 7. Deploy manually (validation / backup demo path)

The `k8s/deployment.yaml` in the repo uses placeholders `__ACR_LOGIN_SERVER__` and
`__IMAGE_TAG__`. For a manual deploy, substitute them in place (macOS `sed` needs the
empty-string argument after `-i`):

```bash
sed -i '' "s|__ACR_LOGIN_SERVER__|calebaksacr.azurecr.io|g" k8s/deployment.yaml
sed -i '' "s|__IMAGE_TAG__|v1|g" k8s/deployment.yaml
```

Deploy:
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl get pods -w                # wait for 2 pods, READY 1/1, Running
```

Reach the app **without** provisioning a billed public IP:
```bash
kubectl port-forward svc/weatherapi-svc 8080:80
# browse http://localhost:8080/swagger
```

> After a manual deploy, restore the placeholders before running the pipeline
> (`git checkout k8s/deployment.yaml`) — the pipeline does the substitution itself.

---

## 8. Deploy via the Azure DevOps pipeline

Everything in this section is a one-time setup in the Azure DevOps web UI at
**dev.azure.com**, except the pipeline run itself (which repeats on every push).

### 8a. Create an organization and project

1. Go to **dev.azure.com** and sign in with the same Microsoft account as your Azure
   subscription.
2. If you have no organization yet, create one (**New organization**) — accept the defaults.
3. **New project** → name it e.g. `aks-dotnet-pipeline` → Visibility: Private → **Create**.

### 8b. Connect GitHub (first pipeline creation does this)

You'll authorize GitHub when you create the pipeline in step 8e. If prompted, install the
**Azure Pipelines** GitHub app and grant it access to the `calebio/aks-dotnet-pipeline`
repo. This lets Azure DevOps read the repo and trigger on pushes.

### 8c. Create the two service connections

Go to **Project Settings** (bottom-left gear) → **Service connections** →
**New service connection**.

**ACR connection:**
1. Choose **Docker Registry** → **Next**.
2. Registry type: **Azure Container Registry**.
3. Authentication: **Service Principal** (default).
4. Select your **Subscription**, then your registry **`calebaksacr`** from the dropdown.
5. Service connection name: **`acr-connection`** (exact — the YAML references it).
6. Tick **Grant access permission to all pipelines**.
7. **Save**.

   > If your registry doesn't appear in the dropdown, switch registry type to **Others**,
   > set Docker Registry to `https://calebaksacr.azurecr.io`, and supply an ACR credential.
   > (This requires temporarily enabling the admin user:
   > `az acr update -n calebaksacr --admin-enabled true` then
   > `az acr credential show -n calebaksacr`. Prefer the Azure Container Registry option
   > first — it uses a service principal and keeps `admin_enabled = false`.)

**AKS connection (KubeConfig method):**
1. **New service connection** → **Kubernetes** → **Next**.
2. Authentication method: **KubeConfig**.
3. Get the cluster's admin kubeconfig printed to your terminal:
   ```bash
   az aks get-credentials --resource-group calebaks-rg --name calebaks-aks --admin --file -
   ```
4. Copy the **entire** output (from `apiVersion:` to the end) into the **KubeConfig** box.
5. Cluster context: select `calebaks-aks-admin` if it populates.
6. Tick **Accept untrusted certificates** (the AKS API cert won't chain on the agent).
7. Service connection name: **`aks-connection`** (exact).
8. Tick **Grant access permission to all pipelines**.
9. **Verify and save** (should go green).

   > Why KubeConfig instead of the Azure-subscription method: the Azure dropdown often
   > can't enumerate the cluster when the DevOps org and the subscription sit in different
   > tenants. KubeConfig bypasses enumeration. Why `--admin`: the non-admin kubeconfig
   > delegates token refresh to the Azure CLI, which isn't present on the build agent, so
   > it fails at run time; the admin config carries a self-contained certificate.

### 8d. Create the environment

**Pipelines → Environments → New environment**:
1. Name: **`aks-prod`** (exact — the YAML's `environment:` references it).
2. Resource: **None**.
3. **Create**.

This gives the Deploy stage a deployment-history target and is where you'd later attach
manual approval gates.

### 8e. Create and run the pipeline

1. **Pipelines → Pipelines → New pipeline** (or **Create Pipeline**).
2. Where is your code: **GitHub** → authorize / install the Azure Pipelines app if prompted.
3. Select the repo **`calebio/aks-dotnet-pipeline`**.
4. Azure DevOps auto-detects **`azure-pipelines.yml`** at the repo root and shows it for review.
5. **Run**.
6. First run pauses for permissions — click each **Permit** to authorize the pipeline to use
   `acr-connection`, `aks-connection`, and the `aks-prod` environment.

### 8f. Watch the run

- **Build stage**: Restore → Build → **Test** → Docker push.
  - Expand the **Test** step and confirm it reports **2 passed** — not a silent zero. A green
    step that ran no tests is a false pass (happens if the solution/test wiring is broken).
  - The Docker step builds the image on the agent and pushes to ACR via `acr-connection`.
- **Deploy stage** (runs only if Build succeeded): substitutes the `__ACR_LOGIN_SERVER__` /
  `__IMAGE_TAG__` placeholders and applies the manifests via `aks-connection`.

Verify the real result:
```bash
az aks get-credentials -g calebaks-rg -n calebaks-aks --overwrite-existing
kubectl get pods
# pods should carry the build-NUMBER tag (not v1) — proof the pipeline built and shipped its own image
```

### 8g. Editing the pipeline later

The pipeline runs the version of `azure-pipelines.yml` **in GitHub**, not your local copy.
Any change must be committed and pushed to take effect; the push auto-triggers a new run
(from the `trigger: main` block). You can also re-run just the failed stage from a run's page.

### IMPORTANT: kubeconfig staleness after any rebuild

The `aks-connection` embeds a kubeconfig for a **specific** cluster FQDN. Every
`terraform destroy` + `apply` creates a **new** cluster with a **new** FQDN, which
invalidates that stored kubeconfig — Deploy then fails with `no such host`.

After any rebuild, refresh the connection:
```bash
az aks get-credentials --resource-group calebaks-rg --name calebaks-aks --admin --file -
```
Then in Azure DevOps: **Project Settings → Service connections → `aks-connection` → Edit**,
replace the KubeConfig contents, **Save**, and re-run the pipeline. Your **local** kubeconfig
needs the same refresh via `--overwrite-existing` (step 5).

> The durable fix (production pattern): authenticate the pipeline via the Azure-integrated
> method with **workload identity federation** so it resolves the current cluster
> dynamically, instead of embedding a static kubeconfig that goes stale.

---

## 9. Tear down (stop the meter)

```bash
cd terraform
terraform destroy     # type: yes
```

Everything is code — rebuild in minutes with `terraform apply`. Destroy between
sessions; the node VM and (if the LoadBalancer got a public IP) the load balancer are
the meaningful costs. **Remember to refresh `aks-connection` after the next rebuild.**

---

## Quick reference — full fresh run

```bash
# tools
brew install azure-cli terraform kubernetes-cli

# clone + login
git clone https://github.com/calebio/aks-dotnet-pipeline.git && cd aks-dotnet-pipeline
az login

# infra
cd terraform && terraform init && terraform apply && cd ..

# kubeconfig (fresh)
az aks get-credentials -g calebaks-rg -n calebaks-aks --overwrite-existing
kubectl get nodes

# build image server-side
az acr build --registry calebaksacr --image weatherapi:v1 .

# deploy manually
sed -i '' "s|__ACR_LOGIN_SERVER__|calebaksacr.azurecr.io|g" k8s/deployment.yaml
sed -i '' "s|__IMAGE_TAG__|v1|g" k8s/deployment.yaml
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
kubectl port-forward svc/weatherapi-svc 8080:80

# teardown when done
cd terraform && terraform destroy
```

## macOS-specific notes

- **Apple Silicon**: prefer `az acr build` (server-side, amd64). If you ever build locally
  with `docker build`, add `--platform linux/amd64` so the image runs on the AKS node.
- **`sed -i`**: macOS/BSD `sed` requires an argument after `-i` (use `sed -i ''`), unlike
  GNU `sed` on the Linux CI agent (which uses `sed -i` with no argument — as in the pipeline YAML).
- **No .NET SDK required** for this runbook — the image is built in Azure. Only install the
  .NET SDK if you want to run `dotnet test`/`dotnet run` locally.