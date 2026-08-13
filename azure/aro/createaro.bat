@echo off
setlocal EnableExtensions DisableDelayedExpansion

if "%~1"=="" (
    echo Usage: createaro.bat dev^|prd [pull-secret-file]
    exit /b 2
)
if /I not "%~1"=="dev" if /I not "%~1"=="prd" (
    echo Error: environment must be dev or prd.
    exit /b 2
)

where az >nul 2>&1
if errorlevel 1 (
    echo Error: Azure CLI was not found.
    exit /b 1
)
call az account show --only-show-errors >nul 2>&1
if errorlevel 1 (
    echo Error: authenticate with Azure CLI before running this script.
    exit /b 1
)

set "ENVIRONMENT=%~1"
set "PULL_SECRET_FILE=%~2"
if not defined PULL_SECRET_FILE set "PULL_SECRET_FILE=pull-secret.txt"
if not exist "%PULL_SECRET_FILE%" (
    echo Error: pull-secret file not found: "%PULL_SECRET_FILE%"
    exit /b 1
)

if /I "%ENVIRONMENT%"=="dev" (
    set "SUBSCRIPTION=%ARO_DEV_SUBSCRIPTION%"
    set "RESOURCE_GROUP=%ARO_DEV_RESOURCE_GROUP%"
    set "CLUSTER_RESOURCE_GROUP=%ARO_DEV_CLUSTER_RESOURCE_GROUP%"
    set "VNET_RESOURCE_GROUP=%ARO_DEV_VNET_RESOURCE_GROUP%"
    set "VNET_NAME=%ARO_DEV_VNET_NAME%"
    set "MASTER_SUBNET=%ARO_DEV_MASTER_SUBNET%"
    set "WORKER_SUBNET=%ARO_DEV_WORKER_SUBNET%"
    set "ARO_NAME=%ARO_DEV_CLUSTER_NAME%"
    set "ARO_DOMAIN=%ARO_DEV_DOMAIN%"
    set "MASTER_PREFIX=%ARO_DEV_MASTER_PREFIX%"
    set "WORKER_PREFIX=%ARO_DEV_WORKER_PREFIX%"
) else (
    set "SUBSCRIPTION=%ARO_PRD_SUBSCRIPTION%"
    set "RESOURCE_GROUP=%ARO_PRD_RESOURCE_GROUP%"
    set "CLUSTER_RESOURCE_GROUP=%ARO_PRD_CLUSTER_RESOURCE_GROUP%"
    set "VNET_RESOURCE_GROUP=%ARO_PRD_VNET_RESOURCE_GROUP%"
    set "VNET_NAME=%ARO_PRD_VNET_NAME%"
    set "MASTER_SUBNET=%ARO_PRD_MASTER_SUBNET%"
    set "WORKER_SUBNET=%ARO_PRD_WORKER_SUBNET%"
    set "ARO_NAME=%ARO_PRD_CLUSTER_NAME%"
    set "ARO_DOMAIN=%ARO_PRD_DOMAIN%"
    set "MASTER_PREFIX=%ARO_PRD_MASTER_PREFIX%"
    set "WORKER_PREFIX=%ARO_PRD_WORKER_PREFIX%"
)

for %%V in (SUBSCRIPTION RESOURCE_GROUP CLUSTER_RESOURCE_GROUP VNET_RESOURCE_GROUP VNET_NAME MASTER_SUBNET WORKER_SUBNET ARO_NAME ARO_DOMAIN MASTER_PREFIX WORKER_PREFIX) do (
    if not defined %%V (
        echo Error: configure all ARO_ environment variables for %ENVIRONMENT% before running this script.
        exit /b 2
    )
)

call az account set --subscription "%SUBSCRIPTION%" --only-show-errors
if errorlevel 1 (
    echo Error: unable to select the configured subscription.
    exit /b 1
)

for %%P in (Microsoft.RedHatOpenShift Microsoft.Compute Microsoft.Storage Microsoft.Authorization Microsoft.Network) do (
    echo Ensuring resource provider %%P is registered...
    call az provider register --namespace %%P --wait --only-show-errors
    if errorlevel 1 exit /b 1
)

call az group create --name "%RESOURCE_GROUP%" --location canadacentral --only-show-errors -o none
if errorlevel 1 exit /b 1

call az network vnet subnet show --resource-group "%VNET_RESOURCE_GROUP%" --vnet-name "%VNET_NAME%" --name "%MASTER_SUBNET%" --only-show-errors -o none >nul 2>&1
if errorlevel 1 (
    call az network vnet subnet create --resource-group "%VNET_RESOURCE_GROUP%" --vnet-name "%VNET_NAME%" --name "%MASTER_SUBNET%" --address-prefixes "%MASTER_PREFIX%" --service-endpoints Microsoft.ContainerRegistry --only-show-errors -o none
    if errorlevel 1 exit /b 1
) else (
    echo Reusing master subnet "%MASTER_SUBNET%".
)

call az network vnet subnet show --resource-group "%VNET_RESOURCE_GROUP%" --vnet-name "%VNET_NAME%" --name "%WORKER_SUBNET%" --only-show-errors -o none >nul 2>&1
if errorlevel 1 (
    call az network vnet subnet create --resource-group "%VNET_RESOURCE_GROUP%" --vnet-name "%VNET_NAME%" --name "%WORKER_SUBNET%" --address-prefixes "%WORKER_PREFIX%" --service-endpoints Microsoft.ContainerRegistry --only-show-errors -o none
    if errorlevel 1 exit /b 1
) else (
    echo Reusing worker subnet "%WORKER_SUBNET%".
)

call az network vnet subnet update --resource-group "%VNET_RESOURCE_GROUP%" --vnet-name "%VNET_NAME%" --name "%MASTER_SUBNET%" --disable-private-link-service-network-policies true --only-show-errors -o none
if errorlevel 1 exit /b 1

call az aro show --name "%ARO_NAME%" --resource-group "%RESOURCE_GROUP%" --only-show-errors -o none >nul 2>&1
if errorlevel 1 (
    echo Validating ARO creation parameters...
    call az aro validate --resource-group "%RESOURCE_GROUP%" --name "%ARO_NAME%" --cluster-resource-group "%CLUSTER_RESOURCE_GROUP%" --vnet "%VNET_NAME%" --vnet-resource-group "%VNET_RESOURCE_GROUP%" --master-subnet "%MASTER_SUBNET%" --worker-subnet "%WORKER_SUBNET%" --apiserver-visibility Private --ingress-visibility Private --only-show-errors
    if errorlevel 1 exit /b 1

    echo Creating ARO cluster "%ARO_NAME%"...
    call az aro create --resource-group "%RESOURCE_GROUP%" --name "%ARO_NAME%" --cluster-resource-group "%CLUSTER_RESOURCE_GROUP%" --vnet "%VNET_NAME%" --vnet-resource-group "%VNET_RESOURCE_GROUP%" --master-subnet "%MASTER_SUBNET%" --worker-subnet "%WORKER_SUBNET%" --apiserver-visibility Private --ingress-visibility Private --domain "%ARO_DOMAIN%" --outbound-type UserDefinedRouting --worker-vm-disk-size-gb 128 --worker-vm-size Standard_D16s_v5 --pull-secret "%PULL_SECRET_FILE%" --only-show-errors
    if errorlevel 1 exit /b 1
) else (
    echo ARO cluster "%ARO_NAME%" already exists; no create operation was submitted.
)

call az aro show --name "%ARO_NAME%" --resource-group "%RESOURCE_GROUP%" --query "{name:name,state:provisioningState,api:apiserverProfile.url,console:consoleProfile.url}" -o jsonc --only-show-errors
if errorlevel 1 exit /b 1
echo Resource provisioning completed successfully.
exit /b 0
