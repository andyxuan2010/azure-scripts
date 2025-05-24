@echo off
SETLOCAL EnableDelayedExpansion
REM Specify the path to your .credentials file
set "credentialsFile=.credentials"
REM Check if the .credentials file exists
if not exist "%credentialsFile%" (
    echo Error: .credentials file not found.
    exit /b 1
)
REM Set the Azure subscription based on the input parameter
set username=
set password=
set tenantid=
set subscriptionid=
set subscription=
set cluster-resource-group=

REM Read credentials from file
if "%1"=="dev" (
    for /f "tokens=1,* delims==" %%a in (%credentialsFile%) do (
        if "%%a"=="dev-username" set "username=%%b"
        if "%%a"=="dev-password" set "password=%%b"
        if "%%a"=="dev-tenantid" set "tenantid=%%b"
        if "%%a"=="dev-subscriptionid" set "subscriptionid=%%b"
        if "%%a"=="dev-subscription" set "subscription=%%b"
        if "%%a"=="dev-account" set "account=%%b"
    )
) else (
    for /f "tokens=1,* delims==" %%a in (%credentialsFile%) do (
        if "%%a"=="prd-username" set "username=%%b"
        if "%%a"=="prd-password" set "password=%%b"
        if "%%a"=="prd-tenantid" set "tenantid=%%b"
        if "%%a"=="prd-subscriptionid" set "subscriptionid=%%b"
        if "%%a"=="prd-subscription" set "subscription=%%b"
        if "%%a"=="prd-account" set "account=%%b"
    )    
)

REM az login
echo az login --service-principal --username %username% --password=%password% --tenant %tenantid% 2>null
call az login --service-principal --username %username% --password=%password% --tenant %tenantid% 2>null
if %errorlevel% neq 0 (
    echo Error: Failed to do az login with the service principal.
    exit /b %errorlevel%
)



REM Set the Azure subscription
rem echo az account set --subscription %subscription%
call az account set --subscription %subscription%

if %errorlevel% neq 0 (
    echo Error: Failed to set the Azure subscription.
    exit /b %errorlevel%
)

REM Set the resource group name and network-related values based on the input parameter
set resource-group=
set vnet-resource-group=
set vnet-name=
set master-subnet=
set worker-subnet=
set aro-instance-name=
if "%1"=="dev" (
    set resource-group=rg-cp4d-cc-dev
    set vnet-resource-group=rg-ba-cc-nonprod-app-network
    set vnet-name=vnet-ba-cc-nonprod-app
    set master-subnet=snet-cp4d-master-cc-dev
    set worker-subnet=snet-cp4d-worker-cc-dev
    set aro-instance-name=cp4ddev
) else if "%1"=="prd" (
    set resource-group=rg-cp4d-cc-prd
    set vnet-resource-group=rg-ba-cc-prod-app-network
    set vnet-name=vnet-ba-cc-prod-app
    set master-subnet=snet-cp4d-master-cc-prd
    set worker-subnet=snet-cp4d-worker-cc-prd
    set aro-instance-name=cp4dprd    
) else (
    echo Error: Invalid input parameter. Please specify either "dev" or "prd".
    exit /b 1
)


REM Delete the ARO instance
rem echo az aro show --name %aro-instance-name% --resource-group %resource-group%
call az aro show --name %aro-instance-name% --resource-group %resource-group% 2>null
if !errorlevel! equ 0 (
	echo az aro delete --name %aro-instance-name% --resource-group %resource-group%
	call az aro delete --name %aro-instance-name% --resource-group %resource-group% -y
	if !errorlevel! neq 0 (
	    echo Error: Failed to delete the ARO instance %aro-instance-name%. but we will retry.
	)
) else if !errorlevel! equ 1 (
    echo WARNING:the account does not have read permission on ARO instance %aro-instance-name%
) else (
	echo INFO:the resource ARO instance %aro-instance-name% no longer exists!
)

REM Delete the subnet for %master-subnet%
rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% 2>null
if !errorlevel! equ 0 (
	echo az network vnet subnet delete -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet%
	call az network vnet subnet delete -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet%
	if !errorlevel! neq 0 (
	    echo Error: Failed to delete the subnet for %master-subnet%. but we will retry.
	)
) else (
	echo INFO:the resource subnet for %master-subnet% no longer exists!
)



REM Delete the subnet for %worker-subnet%
rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% 2>null
if %errorlevel% equ 0 (
	call az network vnet subnet delete -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet%
	if %errorlevel% neq 0 (
	    echo Error: Failed to delete the subnet for %worker-subnet%. but we will retry.
	)
) else (
	echo INFO:the resource subnet for %worker-subnet% no longer exists!
)

REM Delete the resource group
rem echo az group show --name %resource-group%
call az group show --name %resource-group% 2>null
if %errorlevel% equ 0 (
	call az group delete --name %resource-group% --yes --no-wait 2>null
	if %errorlevel% neq 0 (
	    echo Error: Failed to delete the resource group %resource-group%. but we will retry.
	)
) else if %errorlevel% equ 1 (
    echo WARNING:the account does not have read permission on resource group %resource-group%
) else (
	echo INFO:the resource resource group %resource-group% no longer exists!
)



REM Verify resource deletion
:verify_deletion
echo Start to verify resouce ...
rem echo az aro show --name %aro-instance-name% --resource-group %resource-group%
call az aro show --name %aro-instance-name% --resource-group %resource-group% 2>null
if %errorlevel% equ 0 (
    echo ARO instance %aro-instance-name% still exists. Retrying deletion...
    timeout /t 5 >nul
    goto :retry_deletion
) else if %errorlevel% equ 3 (
    echo VERIFICATION: ARO instance %aro-instance-name% no longer exists!
) else if %errorlevel% equ 1 (
    echo WARNING:the account does not have read permission on ARO instance %aro-instance-name%
) else (
    echo Error: Failed to show the ARO instance %aro-instance-name%.
    exit /b %errorlevel%
)

rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% 2>null
if %errorlevel% equ 0 (
    echo Subnet for %master-subnet% still exists. Retrying deletion...
    timeout /t 5 >nul
    goto :retry_deletion
) else if %errorlevel% equ 3 (
    echo VERIFICATION: Subnet for %master-subnet% no longer exists!
) else if %errorlevel% equ 1 (
    echo WARNING:the account does not have read permission on Subnet for %master-subnet%
) else (
    echo Error: Failed to show the Subnet for %master-subnet%.
    exit /b %errorlevel%
)

rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% 2>null
if %errorlevel% equ 0 (
    echo Subnet for %worker-subnet% still exists. Retrying deletion...
    timeout /t 5 >nul
    goto :retry_deletion
) else if %errorlevel% equ 3 (
    echo VERIFICATION: Subnet for %worker-subnet% no longer exists!
) else if %errorlevel% equ 1 (
    echo WARNING:the account does not have read permission on Subnet for %worker-subnet% 
) else (
    echo Error: Failed to show the Subnet for %worker-subnet%.
    exit /b %errorlevel%
)


rem echo az group show --name %resource-group%
call az group show --name %resource-group% 2>null
if %errorlevel% equ 0 (
    echo Resource group %resource-group% still exists. Retrying deletion...
    timeout /t 5 >nul
    goto :retry_deletion
) else if %errorlevel% equ 3 (
    echo VERIFICATION: Resource group %resource-group% no longer exists!
) else if %errorlevel% equ 1 (
    echo WARNING:the account does not have read permission on resource group %resource-group%  
) else (
    echo Error: Failed to show the resource group %resource-group%.
    exit /b %errorlevel%
)


echo Resource deletion verification completed successfully.
exit /b 0

:retry_deletion
REM Attempt deletion again
echo "Attempt deletion again"
call az aro delete --name %aro-instance-name% --resource-group %resource-group% -y  2>null
call az network vnet subnet delete -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% 2>null
call az network vnet subnet delete -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% 2>null
call az group delete --name %resource-group% --yes 2>null

goto :verify_deletion