@echo off
setlocal EnableExtensions DisableDelayedExpansion

if "%~1"=="" (
    echo Usage: delaro.bat dev^|prd [/YES] [/DELETE-RG]
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
set "AUTO_CONFIRM=0"
set "DELETE_RG=0"
if /I "%~2"=="/YES" set "AUTO_CONFIRM=1"
if /I "%~3"=="/YES" set "AUTO_CONFIRM=1"
if /I "%~2"=="/DELETE-RG" set "DELETE_RG=1"
if /I "%~3"=="/DELETE-RG" set "DELETE_RG=1"

if /I "%ENVIRONMENT%"=="dev" (
    set "SUBSCRIPTION=%ARO_DEV_SUBSCRIPTION%"
    set "RESOURCE_GROUP=%ARO_DEV_RESOURCE_GROUP%"
    set "ARO_NAME=%ARO_DEV_CLUSTER_NAME%"
) else (
    set "SUBSCRIPTION=%ARO_PRD_SUBSCRIPTION%"
    set "RESOURCE_GROUP=%ARO_PRD_RESOURCE_GROUP%"
    set "ARO_NAME=%ARO_PRD_CLUSTER_NAME%"
)

for %%V in (SUBSCRIPTION RESOURCE_GROUP ARO_NAME) do (
    if not defined %%V (
        echo Error: configure ARO_ environment variables for %ENVIRONMENT% before running this script.
        exit /b 2
    )
)

call az account set --subscription "%SUBSCRIPTION%" --only-show-errors
if errorlevel 1 exit /b 1

if "%AUTO_CONFIRM%"=="0" (
    echo This will permanently delete ARO cluster "%ARO_NAME%".
    if "%DELETE_RG%"=="1" echo It will also delete resource group "%RESOURCE_GROUP%".
    choice /C YN /N /M "Continue with deletion? [Y/N] "
    if errorlevel 2 (
        echo No changes were made.
        exit /b 0
    )
)

call az aro show --name "%ARO_NAME%" --resource-group "%RESOURCE_GROUP%" --only-show-errors -o none >nul 2>&1
if errorlevel 1 (
    echo ARO cluster "%ARO_NAME%" was not found; nothing to delete.
    exit /b 0
)

call az aro delete --name "%ARO_NAME%" --resource-group "%RESOURCE_GROUP%" --yes --only-show-errors
if errorlevel 1 exit /b 1
echo ARO deletion completed.

if "%DELETE_RG%"=="1" (
    echo Deleting resource group "%RESOURCE_GROUP%" as explicitly requested.
    call az group delete --name "%RESOURCE_GROUP%" --yes --only-show-errors
    if errorlevel 1 exit /b 1
)

echo Deletion workflow completed successfully.
exit /b 0
