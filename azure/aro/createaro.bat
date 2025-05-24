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
set address-prefix-master=
set address-prefix-worker=
set domain-name=
set env=%1
if "%1"=="dev" (
    set resource-group=rg-cp4d-cc-dev
    set cluster-resource-group=rg-cp4daro-cc-dev
    set vnet-resource-group=rg-ba-cc-nonprod-app-network
    set vnet-name=vnet-ba-cc-nonprod-app
    set master-subnet=snet-cp4d-master-cc-dev
    set worker-subnet=snet-cp4d-worker-cc-dev
    set aro-instance-name=cp4ddev
    set address-prefix-master=10.67.89.0/26
    set address-prefix-worker=10.67.89.64/26
    set domain-name=dev.example.com
) else if "%1"=="prd" (
    set resource-group=rg-cp4d-cc-prd
    set cluster-resource-group=rg-cp4daro-cc-prd        
    set vnet-resource-group=rg-ba-cc-prod-app-network
    set vnet-name=vnet-ba-cc-prod-app
    set master-subnet=snet-cp4d-master-cc-prd
    set worker-subnet=snet-cp4d-worker-cc-prd
    set aro-instance-name=cp4dprd
    set address-prefix-master=10.67.79.0/26
    set address-prefix-worker=10.67.79.64/26
    set domain-name=ca.example.com
) else (
    echo Error: Invalid input parameter. Please specify either "dev" or "prd".
    exit /b 1
)


REM create the resource group
rem echo az group show --name %resource-group%
call az group show --name %resource-group% 2>null
if %errorlevel% equ 3 (
	call az group create --name %resource-group% --location canadacentral  --tags "Application Name"="Cloud Pak for Data (CP4D)" "Application Owner"="Bassem Dabboubi" "AppSupport Team"="example.com" "Business Owner"="Patrick Tessier" "Environment"=%env% "Infra Availability Classification"="Bronze" "InfraSupport Team"="example.com" "Project Name"="Data Governance Foundation - Tool Setup" "Project Number"="61238"  "RPO-RTO"="72h/24h" "Run Cost (Approved Run Budget)-USD"="636.6 K" 2>null
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the resource group %resource-group%.
        exit /b !errorlevel!
	)
) else if !errorlevel! equ 1 (
    echo WARNING:the account does not have read permission! but we will try to create the rest resource, assuming this can be done outside of the script!
) else (
	echo INFO:the resource resource group %resource-group% already exists! It's better to start from clean!
    rem exit /b !errorlevel!
)

REM Create the subnet for %master-subnet%
rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% 2>null
if !errorlevel! equ 3 (
	echo az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% --address-prefix %address-prefix-master%
	call az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% --address-prefix %address-prefix-master%
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the subnet for %master-subnet%. 
        exit /b !errorlevel!
	) 
) else if !errorlevel! equ 1 (
    echo WARNING:the account does not have read permission! but we will try to create the resource.
	echo az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% --address-prefix %address-prefix-master%
	call az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% --address-prefix %address-prefix-master%
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the subnet for %master-subnet%. 
        exit /b !errorlevel!
	)    
) else (
	echo INFO:the resource subnet for %master-subnet% already exists! It's better to start from clean!
    exit /b %errorlevel%
)

REM Create the subnet for %worker-subnet%
rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% 2>null
if !errorlevel! equ 3 (
    echo az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% --address-prefix %address-prefix-worker%
	call az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% --address-prefix %address-prefix-worker%
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the subnet for %worker-subnet%. 
        exit /b !errorlevel!
	)
) else if !errorlevel! equ 1 (
    echo WARNING:the account does not have read permission! but we will try to create the resource.
    echo az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% --address-prefix %address-prefix-worker%
	call az network vnet subnet create -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% --address-prefix %address-prefix-worker%
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the subnet for %worker-subnet%. 
        exit /b !errorlevel!
	)    
) else (
	echo INFO:the resource subnet for %worker-subnet% already exists! It's better to start from clean!
    exit /b !errorlevel!
)

REM Create the ARO instance
rem echo az aro show --name %aro-instance-name% --resource-group %resource-group%
call az aro show --name %aro-instance-name% --resource-group %resource-group% 2>null
if !errorlevel! equ 3 (
	echo az aro create --name %aro-instance-name% --resource-group %resource-group% --cluster-resource-group %cluster-resource-group% --vnet %vnet-name% --vnet-resource-group %vnet-resource-group% --master-subnet %master-subnet% --worker-subnet %worker-subnet% --apiserver-visibility Private --ingress-visibility Private --domain %domain-name% --outbound-type UserDefinedRouting --worker-vm-disk-size-gb 128 --worker-vm-size Standard_D16s_v5 --pull-secret @pull-secret.txt
	call az aro create --name %aro-instance-name% --resource-group %resource-group% --cluster-resource-group %cluster-resource-group% --vnet %vnet-name% --vnet-resource-group %vnet-resource-group% --master-subnet %master-subnet% --worker-subnet %worker-subnet% --apiserver-visibility Private --ingress-visibility Private --domain %domain-name% --outbound-type UserDefinedRouting --worker-vm-disk-size-gb 128 --worker-vm-size Standard_D16s_v5 --pull-secret @pull-secret.txt
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the ARO instance %aro-instance-name%. 
        exit /b !errorlevel!
	)
) else if !errorlevel! equ 1 (
    echo WARNING:the account does not have read permission! but we will try to create the resource.
	echo az aro create --name %aro-instance-name% --resource-group %resource-group% --cluster-resource-group %cluster-resource-group% --vnet %vnet-name% --vnet-resource-group %vnet-resource-group% --master-subnet %master-subnet% --worker-subnet %worker-subnet% --apiserver-visibility Private --ingress-visibility Private --domain %domain-name% --outbound-type UserDefinedRouting --worker-vm-disk-size-gb 128 --worker-vm-size Standard_D16s_v5 --pull-secret @pull-secret.txt
	call az aro create --name %aro-instance-name% --resource-group %resource-group% --cluster-resource-group %cluster-resource-group% --vnet %vnet-name% --vnet-resource-group %vnet-resource-group% --master-subnet %master-subnet% --worker-subnet %worker-subnet% --apiserver-visibility Private --ingress-visibility Private --domain %domain-name% --outbound-type UserDefinedRouting --worker-vm-disk-size-gb 128 --worker-vm-size Standard_D16s_v5 --pull-secret @pull-secret.txt
	if !errorlevel! neq 0 (
	    echo Error: Failed to create the ARO instance %aro-instance-name%. 
        exit /b !errorlevel!
	)    
) else (
	echo INFO:the resource ARO instance %aro-instance-name% already exists!
    exit /b %errorlevel%
)

echo Resource provision completed successfully.



rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %master-subnet% 2>null
if %errorlevel% neq 0 (
    echo Error: Failed to show the Subnet for %master-subnet%.
    exit /b %errorlevel%
)

rem echo az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet%
call az network vnet subnet show -g %vnet-resource-group% --vnet-name %vnet-name% --name %worker-subnet% 2>null
if %errorlevel% neq 0 (
    echo Error: Failed to show the Subnet for %worker-subnet%.
    exit /b %errorlevel%
)


rem echo az group show --name %resource-group%
call az group show --name %resource-group% 2>null
if %errorlevel% neq 0 (
    echo Error: Failed to show the resource group %resource-group%.
    exit /b %errorlevel%
)

rem echo az aro show --name %aro-instance-name% --resource-group %resource-group%
call az aro show --name %aro-instance-name% --resource-group %resource-group% 2>null
if %errorlevel% neq 0 (
	echo Error: Failed to show the resource ARO instance %aro-instance-name%
    exit /b %errorlevel%
)

echo Resource verification completed successfully.
exit /b 0

