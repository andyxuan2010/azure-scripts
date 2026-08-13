# Azure Red Hat OpenShift scripts

This directory contains production-oriented Bash and Windows batch utilities
for Azure Red Hat OpenShift (ARO), Azure Container Registry (ACR), Azure Arc,
OpenShift administration, health checks, and CPD offline backups.

These scripts are operational tools, not a replacement for reviewed
Infrastructure as Code. Run them from a controlled administration host with
an approved Azure subscription, an authenticated OpenShift context, and
change-management approval for mutating operations.

## Production baseline

The scripts were normalized around these rules:

- Bash uses /usr/bin/env bash, strict mode, strict quoting, UTC timestamps,
  and consistent error handling.
- Azure resources are queried with structured --query output instead of
  parsing human-readable tables.
- Secrets are not hard-coded, printed, or written to ordinary working files.
- Destructive actions require explicit scope and confirmation.
- Mutating workflows support idempotent reuse, validation, or dry-run behavior.
- Temporary files use private directories and cleanup traps.
- The OpenShift client installer requires an exact version and supports
  SHA-256 verification.
- CPD data-refinery mutation is disabled unless explicitly requested.
- Windows batch workflows use an existing Azure CLI login and do not read
  plaintext .credentials files.

The private-cluster entrypoint now provisions only the ARO network and cluster.
The previous automatic Bastion, jumpbox, public-IP, storage-account, and
password-file workflow was removed from the default path. Provision those
components through separately reviewed IaC when required.

## Prerequisites

- Azure CLI with the ARO command available.
- An authenticated Azure CLI session:

    az login
    az account show

- oc for OpenShift operations and kubectl where required.
- jq, curl, tar, and openssl for the scripts that use them.
- Docker for connect-acr-to-aro.sh.
- A current kubeconfig/OpenShift context.
- A Red Hat pull-secret JSON file for cluster creation or pull-secret updates.

ARO creation also requires appropriate provider registrations, network
permissions, supported VM sizes, and a non-overlapping address plan.

Microsoft references:

- Azure CLI ARO reference:
  https://learn.microsoft.com/en-us/cli/azure/aro?view=azure-cli-latest
- Create an Azure Red Hat OpenShift cluster:
  https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster
- Azure Arc connected Kubernetes CLI reference:
  https://learn.microsoft.com/en-us/cli/azure/connectedk8s?view=azure-cli-latest
- Azure Arc Kubernetes extensions:
  https://learn.microsoft.com/en-us/azure/aks/deploy-extensions-az-cli

Prefer workload identity, managed identity, or short-lived federated
credentials for automation. Do not commit pull secrets, service-principal
secrets, ACR passwords, kubeadmin credentials, or CPD passwords.

## Script catalog

| Script | Purpose | Change profile |
| --- | --- | --- |
| aro-create-cluster.sh | Shared idempotent ARO network and cluster creation core. | Mutating |
| create_cluster.sh | Generic creation entrypoint. | Mutating |
| create-public-aro-cluster.sh | Public API/ingress creation entrypoint. | Mutating |
| create-private-aro-cluster.sh | Private API/ingress creation entrypoint. | Mutating |
| aro4-build.sh | Compatibility builder with environment defaults. | Mutating |
| register-aro-resource-providers.sh | Registers and verifies required providers. | Mutating |
| aro-cluster-login.sh | Logs in without printing the password. | Mutating context |
| aro4-getcreds.sh | Endpoint metadata; credentials require --show-credentials. | Read-only by default |
| aro4-rotatespkey.sh | Appends a service-principal key and updates ARO. | Sensitive mutating |
| aro4-replace-pull-secret.sh | Securely merges and updates the pull secret. | Sensitive mutating |
| aro4-applysc.sh | Validates or applies storage-class manifests. | Mutating |
| aro4-createmachineset.sh | Generates and optionally applies a machine-set manifest. | Mutating with --apply |
| connect-acr-to-aro.sh | Pushes an image and applies a namespaced pull secret. | Mutating |
| connect-aro-as-arc.sh | Connects OpenShift to Arc and optionally installs monitoring. | Mutating |
| delete_cluster.sh | Deletes one ARO cluster; group deletion is opt-in. | Destructive |
| healthcheck.sh | Checks CPD CR, pod, and EDB health with retries. | Read-only |
| offline_backup_script.sh | Runs the CPD offline backup lifecycle. | Mutating |
| oc-cli-install-common.sh | Internal pinned oc/kubectl installer. | Host mutating |
| oc-cli-installation.sh | System OpenShift client wrapper. | Host mutating |
| oc-cli-installation-cloud-shell.sh | Cloud Shell OpenShift client wrapper. | Host mutating |
| jq-ubuntu-installation.sh | Installs jq through Ubuntu APT when absent. | Host mutating |
| aro-extension-wheel-file-installation.sh | Verifies or installs the ARO CLI command. | Host mutating |
| aro-lib.sh | Shared logging, validation, and confirmation helpers. | Source only |
| createaro.bat | Environment-mapped Windows creation workflow. | Mutating |
| delaro.bat | Environment-mapped Windows deletion workflow. | Destructive |

The files aro-lib.sh, aro-create-cluster.sh, and
oc-cli-install-common.sh are implementation files called by entrypoints.

## ARO cluster creation

The shared core requires explicit resource and network inputs. It reuses
existing resources and fails instead of silently changing a subnet whose
address prefix differs from the requested prefix.

Example public cluster:

    ./create-public-aro-cluster.sh \
      --location eastus \
      --resource-group aro-prod-rg \
      --cluster-resource-group aro-prod-mc-rg \
      --cluster-name aro-prod \
      --pull-secret ./pull-secret.txt \
      --vnet-resource-group aro-prod-rg \
      --vnet-name aro-prod-vnet \
      --vnet-prefix 10.20.0.0/22 \
      --master-subnet aro-prod-master \
      --master-prefix 10.20.0.0/23 \
      --worker-subnet aro-prod-worker \
      --worker-prefix 10.20.2.0/23 \
      --worker-count 3 \
      --master-vm-size Standard_D8s_v3 \
      --worker-vm-size Standard_D8s_v3

Example private cluster:

    ./create-private-aro-cluster.sh \
      --location eastus \
      --resource-group aro-private-rg \
      --cluster-resource-group aro-private-mc-rg \
      --cluster-name aro-private \
      --pull-secret ./pull-secret.txt \
      --vnet-resource-group aro-private-rg \
      --vnet-name aro-private-vnet \
      --vnet-prefix 10.30.0.0/22 \
      --master-subnet aro-private-master \
      --master-prefix 10.30.0.0/23 \
      --worker-subnet aro-private-worker \
      --worker-prefix 10.30.2.0/23

aro4-build.sh provides compatibility defaults and accepts an optional first
positional custom domain. For production, set explicit ARO_LOCATION,
ARO_CLUSTER_NAME, ARO_RESOURCE_GROUP, ARO_CLUSTER_RESOURCE_GROUP, and
ARO_PULL_SECRET_FILE values before running it.

The creation core verifies authentication and the pull-secret, registers the
required providers, creates or reuses the network, validates subnets, runs
az aro validate for a new cluster, creates only when absent, and prints
non-secret API and console metadata.

## OpenShift administration

Login and endpoint metadata:

    ./aro-cluster-login.sh --name aro-prod --resource-group aro-prod-rg
    ./aro4-getcreds.sh --name aro-prod --resource-group aro-prod-rg
    ./aro4-getcreds.sh --name aro-prod --resource-group aro-prod-rg --show-credentials

The last command is intentionally noisy and is for a controlled terminal.
The normal metadata command does not retrieve kubeadmin credentials.

Validate storage classes without changing the cluster:

    ./aro4-applysc.sh --dry-run \
      managed-std-hdd.yaml managed-std-ssd.yaml managed-ultra-ssd.yaml

Apply after review:

    ./aro4-applysc.sh managed-std-hdd.yaml managed-std-ssd.yaml managed-ultra-ssd.yaml

Validate and apply a pull-secret merge:

    ./aro4-replace-pull-secret.sh --file ./redhat-pull-secret.json --dry-run
    ./aro4-replace-pull-secret.sh --file ./redhat-pull-secret.json

The current identity must be able to update openshift-config/pull-secret.
Existing secret material is held only in a private temporary directory.

Build a machine-set manifest from an existing ARO machine set:

    ./aro4-createmachineset.sh \
      --name aro-prod-worker-zone2 \
      --zone 2 \
      --replicas 3 \
      --vm-size Standard_D16s_v5 \
      --template ./machineset-template.yaml

Use --apply only after inspecting the generated manifest. Without --apply,
the manifest is server-side validated but not submitted.

Rotate a service-principal credential:

    ./aro4-rotatespkey.sh --name aro-prod --resource-group aro-prod-rg \
      --valid-years 2 --dry-run
    ./aro4-rotatespkey.sh --name aro-prod --resource-group aro-prod-rg \
      --valid-years 2

The rotation appends a new credential instead of replacing every existing
credential, updates ARO to use it, and never prints the generated secret.

## ACR and Azure Arc

The ACR script does not enable the registry admin account by default or write
acrcredential.json. Prefer externally managed credentials:

    export ACR_DOCKER_USERNAME='managed-outside-this-repository'
    export ACR_DOCKER_PASSWORD='managed-outside-this-repository'
    ./connect-acr-to-aro.sh \
      --registry aroprodimages \
      --resource-group aro-prod-rg \
      --location eastus \
      --image nginx:1.27.0 \
      --namespace apps \
      --secret-name aro-pull-secret \
      --create-namespace

Use --enable-admin only as an approved exception. The script does not create
a test workload automatically.

Connect the current OpenShift context to Arc:

    ./connect-aro-as-arc.sh \
      --name aro-prod-arc \
      --resource-group aro-arc-rg \
      --location eastus

Add Azure Monitor by supplying a Log Analytics workspace resource ID:

    ./connect-aro-as-arc.sh \
      --name aro-prod-arc \
      --resource-group aro-arc-rg \
      --location eastus \
      --workspace-resource-id /subscriptions/SUBSCRIPTION/resourceGroups/monitoring-rg/providers/Microsoft.OperationalInsights/workspaces/prod

## Health and backup operations

The CPD health check has no default usernames, passwords, SMTP hosts, or fake
API endpoints. It uses the existing oc context or environment authentication:

    export OCP_URL='https://api.example.invalid:6443'
    export OCP_TOKEN='provided-by-your-secret-manager'
    export PROJECT_CPD_INST_OPERANDS='cpd-operands'
    export PROJECT_CPD_INST_OPERATORS='cpd-operators'
    export CPD_CLI_DIR='/opt/cp4d/cpd-cli'
    ./healthcheck.sh --attempts 5 --retry-delay 120

Set EDB_CLUSTER_NAME when the metastore cluster has a different name.
Notification is disabled unless NOTIFY_EMAILS and SMTP_SERVER are provided.

The offline backup workflow requires explicit configuration:

    export OCP_URL='https://api.example.invalid:6443'
    export OCP_TOKEN='provided-by-your-secret-manager'
    export PROJECT_CPD_INST_OPERANDS='cpd-operands'
    export PROJECT_CPD_INST_OPERATORS='cpd-operators'
    export CPD_CLI_DIR='/opt/cp4d/cpd-cli'
    export CPD_OPERATORS_BACKUP_CMD='/opt/cp4d/cpd-operators.sh'
    export BACKUP_DIR_PATH='/var/lib/aro-offline-backup'
    ./offline_backup_script.sh --skip-mail

The backup verifies authentication and cluster health, captures an inventory,
runs CPD backups and hooks, attempts recovery on failure, restores recorded
deployment replica counts, and checks health again.

--allow-data-refinery-mutation enables the legacy workflow that deletes
resources labeled type=shaper and scales wdp-shaper/wdp-dataprep to zero.
Use it only with an approved workload runbook. Deleted resources cannot be
restored by this script; only recorded deployment replica counts are restored.

## OpenShift client and jq installation

The client installer requires an exact OpenShift version instead of tracking
latest:

    ./oc-cli-installation.sh \
      --version 4.16.33 \
      --sha256 SHA256_FROM_THE_APPROVED_RELEASE

Cloud Shell uses a home-directory installation:

    ./oc-cli-installation-cloud-shell.sh --version 4.16.33

The installer avoids duplicate PATH lines. jq-ubuntu-installation.sh installs
jq through the system package manager and exits when jq is already present.

## Windows batch workflows

createaro.bat and delaro.bat require an existing Azure CLI login. They do not
read .credentials files or perform service-principal login.

The creation script reads these development variables:

    ARO_DEV_SUBSCRIPTION
    ARO_DEV_RESOURCE_GROUP
    ARO_DEV_CLUSTER_RESOURCE_GROUP
    ARO_DEV_VNET_RESOURCE_GROUP
    ARO_DEV_VNET_NAME
    ARO_DEV_MASTER_SUBNET
    ARO_DEV_WORKER_SUBNET
    ARO_DEV_CLUSTER_NAME
    ARO_DEV_DOMAIN
    ARO_DEV_MASTER_PREFIX
    ARO_DEV_WORKER_PREFIX

Production variables use the same names with ARO_PRD_ instead of ARO_DEV_.
Then run:

    createaro.bat dev C:\secure\pull-secret.txt
    delaro.bat dev
    delaro.bat dev /YES /DELETE-RG

DELETE-RG is separate from cluster deletion. Review the scope before using it.

## Destructive-operation checklist

1. Confirm the Azure subscription with az account show.
2. Confirm the OpenShift context with oc whoami and oc config current-context.
3. Review the exact resource group, cluster, VNet, subnet, namespace, or secret.
4. Run dry-run or validation mode where available.
5. Keep pull secrets and credentials outside Git and protected by policy.
6. Capture generated manifests or reports as auditable artifacts.
7. Monitor ARO and OpenShift health after the operation.

## Validation

Static, non-destructive validation:

    for script in azure/aro/*.sh; do
      bash -n "$script" || exit 1
    done

If available:

    shellcheck azure/aro/*.sh

Live Azure, Docker, OpenShift, CPD, and deletion operations are intentionally
not run locally. They require a target subscription, cluster context,
credentials, and change approval.
