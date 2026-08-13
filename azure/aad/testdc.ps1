<#
.SYNOPSIS
    Active Directory Domain Controller Connectivity, Site Awareness,
    and Domain-Join Readiness Diagnostic Tool.

.DESCRIPTION
    Performs parallel connectivity and service validation against Domain
    Controllers dynamically discovered through Active Directory DNS SRV records.

    The tool is intended for troubleshooting intermittent domain joins,
    inconsistent DC Locator behavior, Active Directory site topology,
    firewall/routing differences, and DC-specific connectivity problems.

    Domain Controllers are prioritized:

        Priority 0 - DC currently selected by Windows DC Locator
        Priority 1 - Other DCs in the current Active Directory site
        Priority 2 - Remaining Domain Controllers

    Local/current-site DC results are submitted first and displayed as soon
    as they complete while other DC tests continue in parallel.

    Result semantics:

        PASS
            Test positively succeeded.

        FAIL
            A required network/service prerequisite failed.

        WARN
            Non-critical test failed. Example: ICMP/PING may legitimately
            be blocked by firewall policy.

        ACCESS
            Network/service connectivity exists, but access to a resource
            such as SYSVOL or NETLOGON could not be verified using the
            current user/security context.

        READY
            Core network prerequisites required for domain join passed and
            SYSVOL/NETLOGON access was verified.

        CHECK
            Core network prerequisites passed, but one or more authenticated
            share-access checks could not be verified.

    The script does NOT execute Add-Computer against each DC.

.PURPOSE
    - Troubleshoot intermittent Add-Computer/domain-join failures.
    - Compare connectivity to multiple Domain Controllers.
    - Identify inconsistent connectivity between DCs in the same AD site.
    - Validate DC Locator behavior.
    - Detect incorrect site/subnet/DC topology.
    - Identify firewall/routing differences.
    - Produce reusable TXT and CSV diagnostic evidence.

.FEATURES
    - No hard-coded Domain Controller names.
    - Automatic computer/VM detection.
    - Automatic IPv4 detection.
    - Automatic current user detection.
    - Automatic AD domain discovery where possible.
    - Automatic Primary DNS Suffix detection.
    - Automatic AD site detection.
    - Automatic current DC Locator selection.
    - DNS SRV-based DC discovery.
    - Site-specific DC discovery.
    - Current/local/remote DC classification.
    - Local-site-first scheduling.
    - Runspace-based parallel execution.
    - Configurable concurrency.
    - Short configurable network timeouts.
    - Live result streaming.
    - Color-coded console output.
    - ICMP/PING test.
    - DNS test.
    - Kerberos TCP/88 test.
    - RPC Endpoint Mapper TCP/135 test.
    - LDAP TCP/389 test.
    - SMB TCP/445 test.
    - SYSVOL accessibility test.
    - NETLOGON accessibility test.
    - Normalized JOIN readiness assessment.
    - Paginated DC matrices.
    - Automatic TXT report.
    - Automatic CSV report.
    - Optional PassThru pipeline output.
    - Windows PowerShell 5.1 compatible.

.USAGE
    Default:

        .\Test-ADDomainControllers.ps1

    Explicit domain:

        .\Test-ADDomainControllers.ps1 `
            -DomainName "example.contoso.com"

    Faster scan:

        .\Test-ADDomainControllers.ps1 `
            -TimeoutMs 1000 `
            -ThrottleLimit 30

    Custom report location:

        .\Test-ADDomainControllers.ps1 `
            -ReportDirectory "C:\Temp\AD-Diagnostics"

    No report:

        .\Test-ADDomainControllers.ps1 -NoReport

    Return structured result objects:

        $Results = .\Test-ADDomainControllers.ps1 -PassThru

.OUTPUT
    Console:
        - VM/environment information
        - AD site
        - Current DC Locator DC
        - Local and remote DC inventory
        - Live parallel results
        - Final results
        - Paginated DC matrices
        - Current-site summary
        - Failure/warning analysis
        - Report file paths
        - Final execution status

    Files:
        DC_Test_<ComputerName>_<Timestamp>.txt
        DC_Test_<ComputerName>_<Timestamp>.csv

.LIMITATIONS
    This script does not perform an actual domain join.

    READY means that the core network prerequisites tested by this tool
    passed and SYSVOL/NETLOGON access was verified using the current
    security context.

    SYSVOL and NETLOGON results depend partly on authentication/security
    context. Failure to access these shares does not automatically prove
    that the Domain Controller itself is defective.

    ICMP/PING is not required for Active Directory domain joins and is
    informational only.

    Additional domain-join dependencies include:
        - Dynamic RPC ports
        - Account permissions
        - Existing computer-object state
        - AD replication
        - Kerberos/time synchronization
        - DNS dynamic registration
        - Group/security policy
        - Authentication policy

    For an actual failed domain join also inspect:

        C:\Windows\Debug\NetSetup.log

.AUTHOR
    AndyXuan@CCoE

.CREATED
    2026-08-12

.LASTUPDATED
    2026-08-12

.VERSION
    2.2.0

.CHANGELOG
    2.2.0 - 2026-08-12 - AndyXuan@CCoE
        - Added optional PassThru output.
        - Suppressed default post-report object dump to keep console output clean.
        - Kept full structured results in TXT/CSV reports.
        - Added final concise execution status.

    2.1.0 - 2026-08-12 - AndyXuan@CCoE
        - Added standardized console color scheme.
        - Added ICMP/PING test after DNS.
        - Added ACCESS result state for authenticated share validation.
        - Replaced misleading PASS/FAIL JoinPrereq logic with READY/CHECK/FAIL.
        - PING failure generates WARN and does not affect JOIN readiness.
        - Improved live output readability and matrix reporting.

    2.0.0 - 2026-08-12 - AndyXuan@CCoE
        - Production-standardized implementation.

#>

[CmdletBinding()]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    [Parameter()]
    [ValidateRange(250, 30000)]
    [int]$TimeoutMs = 1500,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 20,

    [Parameter()]
    [ValidateRange(3, 15)]
    [int]$MatrixPageSize = 8,

    [Parameter()]
    [string]$ReportDirectory,

    [Parameter()]
    [switch]$NoReport,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ======================================================================
# Metadata
# ======================================================================

$ScriptMetadata = [ordered]@{
    Name        = "AD Domain Controller Connectivity Tester"
    Version     = "2.2.0"
    Author      = "AndyXuan@CCoE"
    Created     = "2026-08-12"
    LastUpdated = "2026-08-12"
}

$ScriptStartTime = Get-Date

# ======================================================================
# Color Schema
# ======================================================================

$Colors = @{
    Title   = "Cyan"
    Info    = "White"
    Muted   = "DarkGray"
    Current = "Magenta"
    Local   = "Cyan"
    Remote  = "Gray"
    Pass    = "Green"
    Ready   = "Green"
    Warn    = "Yellow"
    Access  = "Yellow"
    Check   = "Yellow"
    Fail    = "Red"
    Error   = "Red"
}

# ======================================================================
# Console Functions
# ======================================================================

function Write-Section {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ""
    Write-Host ("=" * 100) -ForegroundColor $Colors.Title
    Write-Host (" {0}" -f $Title) -ForegroundColor $Colors.Title
    Write-Host ("=" * 100) -ForegroundColor $Colors.Title
}

function Get-StatusColor {
    [CmdletBinding()]
    param(
        [string]$Status
    )

    switch ($Status) {
        "PASS"   { return $Colors.Pass }
        "READY"  { return $Colors.Ready }
        "WARN"   { return $Colors.Warn }
        "ACCESS" { return $Colors.Access }
        "CHECK"  { return $Colors.Check }
        "FAIL"   { return $Colors.Fail }
        "ERROR"  { return $Colors.Error }
        default  { return $Colors.Info }
    }
}

function Write-LiveResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Result
    )

    $ScopeColor = switch ($Result.Classification) {
        "CURRENT" { $Colors.Current }
        "LOCAL"   { $Colors.Local }
        default   { $Colors.Remote }
    }

    Write-Host ("{0,-20} " -f $Result.ShortName) -NoNewline
    Write-Host ("{0,-8} " -f $Result.Classification) -ForegroundColor $ScopeColor -NoNewline

    foreach ($Property in @(
        "DNS",
        "PING",
        "Kerberos88",
        "RPC135",
        "LDAP389",
        "SMB445",
        "SYSVOL",
        "NETLOGON",
        "JoinStatus"
    )) {
        $Value = $Result.$Property
        $Color = Get-StatusColor $Value

        Write-Host ("{0,-8} " -f $Value) `
            -ForegroundColor $Color `
            -NoNewline
    }

    Write-Host ("{0,6:N2}" -f $Result.ElapsedSec)
}

# ======================================================================
# Environment Discovery Functions
# ======================================================================

function Get-CurrentIPv4Address {
    [CmdletBinding()]
    param()

    try {
        return @(
            Get-NetIPAddress `
                -AddressFamily IPv4 `
                -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -ne "127.0.0.1" -and
                $_.IPAddress -notlike "169.254.*" -and
                $_.AddressState -eq "Preferred"
            } |
            Select-Object -ExpandProperty IPAddress -Unique
        )
    }
    catch {
        return @()
    }
}

function Get-PrimaryDnsSuffix {
    [CmdletBinding()]
    param()

    try {
        $Parameters = Get-ItemProperty `
            -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
            -ErrorAction Stop

        if ($Parameters.Domain) {
            return [string]$Parameters.Domain
        }

        if ($Parameters.'NV Domain') {
            return [string]$Parameters.'NV Domain'
        }
    }
    catch {
    }

    return $null
}

function Resolve-DefaultDomainName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $ComputerSystem,

        [string]$PrimaryDnsSuffix
    )

    if ($env:USERDNSDOMAIN) {
        return $env:USERDNSDOMAIN
    }

    if ($ComputerSystem.PartOfDomain -and $ComputerSystem.Domain) {
        return [string]$ComputerSystem.Domain
    }

    if ($PrimaryDnsSuffix) {
        return $PrimaryDnsSuffix
    }

    return $null
}

function Get-AdSiteName {
    [CmdletBinding()]
    param()

    try {
        $Output = & nltest.exe /dsgetsite 2>&1

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        return (
            $Output |
            Where-Object {
                $_ -and
                $_ -notmatch "command completed"
            } |
            Select-Object -First 1
        ).Trim()
    }
    catch {
        return $null
    }
}

function Get-DcLocatorResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain
    )

    $Result = [ordered]@{
        SelectedDC = $null
        DcSiteName = $null
        ClientSite = $null
    }

    try {
        $Output = @(
            & nltest.exe "/dsgetdc:$Domain" /WRITABLE 2>&1
        )

        foreach ($Line in $Output) {
            if ($Line -match "DC:\s+\\\\([^\s]+)") {
                $Result.SelectedDC = $Matches[1].TrimEnd(".")
            }
            elseif ($Line -match "Dc Site Name:\s+(.+)$") {
                $Result.DcSiteName = $Matches[1].Trim()
            }
            elseif ($Line -match "Our Site Name:\s+(.+)$") {
                $Result.ClientSite = $Matches[1].Trim()
            }
        }
    }
    catch {
    }

    return [PSCustomObject]$Result
}

# ======================================================================
# DC Discovery
# ======================================================================

function Get-DomainControllersFromDns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [string]$SiteName
    )

    $AllDCs = @(
        Resolve-DnsName `
            -Name "_ldap._tcp.dc._msdcs.$Domain" `
            -Type SRV `
            -ErrorAction Stop |
        Where-Object {
            $_.Type -eq "SRV" -and
            $_.NameTarget
        } |
        ForEach-Object {
            $_.NameTarget.TrimEnd(".")
        } |
        Sort-Object -Unique
    )

    $SiteDCs = @()

    if ($SiteName) {
        try {
            $SiteDCs = @(
                Resolve-DnsName `
                    -Name "_ldap._tcp.$SiteName._sites.dc._msdcs.$Domain" `
                    -Type SRV `
                    -ErrorAction Stop |
                Where-Object {
                    $_.Type -eq "SRV" -and
                    $_.NameTarget
                } |
                ForEach-Object {
                    $_.NameTarget.TrimEnd(".")
                } |
                Sort-Object -Unique
            )
        }
        catch {
            $SiteDCs = @()
        }
    }

    return [PSCustomObject]@{
        AllDCs  = $AllDCs
        SiteDCs = $SiteDCs
    }
}

# ======================================================================
# Environment
# ======================================================================

try {
    $ComputerSystem = Get-CimInstance Win32_ComputerSystem
}
catch {
    throw "Unable to query Win32_ComputerSystem. $($_.Exception.Message)"
}

$ComputerName = $env:COMPUTERNAME

$CurrentUser = if ($env:USERDOMAIN) {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
}
else {
    $env:USERNAME
}

$IPv4Addresses = @(Get-CurrentIPv4Address)

$IPv4Display = if ($IPv4Addresses.Count) {
    $IPv4Addresses -join ", "
}
else {
    "Unavailable"
}

$PrimaryDnsSuffix = Get-PrimaryDnsSuffix

if (-not $DomainName) {
    $DomainName = Resolve-DefaultDomainName `
        -ComputerSystem $ComputerSystem `
        -PrimaryDnsSuffix $PrimaryDnsSuffix
}

if (-not $DomainName -and [Environment]::UserInteractive) {
    $DomainName = Read-Host "AD domain to test"
}

if ([string]::IsNullOrWhiteSpace($DomainName)) {
    throw "AD domain could not be determined. Specify -DomainName."
}

$DomainName = $DomainName.Trim().TrimEnd(".")

# ======================================================================
# Reporting
# ======================================================================

if (-not $NoReport) {
    if (-not $ReportDirectory) {
        if ($PSScriptRoot) {
            $ReportDirectory = $PSScriptRoot
        }
        else {
            $ReportDirectory = (Get-Location).Path
        }
    }

    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item `
            -Path $ReportDirectory `
            -ItemType Directory `
            -Force |
        Out-Null
    }

    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ReportBaseName = "DC_Test_${ComputerName}_${Timestamp}"

    $TextReportPath = Join-Path $ReportDirectory "$ReportBaseName.txt"
    $CsvReportPath = Join-Path $ReportDirectory "$ReportBaseName.csv"
}

# ======================================================================
# Header
# ======================================================================

Write-Section $ScriptMetadata.Name

Write-Host "Version             : $($ScriptMetadata.Version)"
Write-Host "Author              : $($ScriptMetadata.Author)"
Write-Host "Computer            : $ComputerName"
Write-Host "IPv4                : $IPv4Display"
Write-Host "Current User        : $CurrentUser"
Write-Host "Domain Joined       : $($ComputerSystem.PartOfDomain)"
Write-Host "Computer Domain     : $($ComputerSystem.Domain)"
Write-Host "Primary DNS Suffix  : $PrimaryDnsSuffix"
Write-Host "Domain Tested       : $DomainName"
Write-Host "Timeout             : $TimeoutMs ms"
Write-Host "Parallel Workers    : $ThrottleLimit"
Write-Host "Matrix Page Size    : $MatrixPageSize"

if (-not $NoReport) {
    Write-Host "Report Directory    : $ReportDirectory"
}

# ======================================================================
# Site / Locator
# ======================================================================

$SiteName = Get-AdSiteName
$DcLocator = Get-DcLocatorResult -Domain $DomainName

if (-not $SiteName -and $DcLocator.ClientSite) {
    $SiteName = $DcLocator.ClientSite
}

$SelectedDC = $DcLocator.SelectedDC

Write-Section "AD SITE / DC LOCATOR"

Write-Host "Client AD Site      : " -NoNewline
Write-Host $(if ($SiteName) { $SiteName } else { "Unknown" }) -ForegroundColor $Colors.Local

Write-Host "Selected DC         : " -NoNewline
Write-Host $(if ($SelectedDC) { $SelectedDC } else { "Unknown" }) -ForegroundColor $Colors.Current

Write-Host "Selected DC Site    : $(if ($DcLocator.DcSiteName) { $DcLocator.DcSiteName } else { 'Unknown' })"

# ======================================================================
# Discover DCs
# ======================================================================

Write-Section "DOMAIN CONTROLLER DISCOVERY"

try {
    $Discovery = Get-DomainControllersFromDns `
        -Domain $DomainName `
        -SiteName $SiteName
}
catch {
    throw "Unable to discover Domain Controllers from DNS. $($_.Exception.Message)"
}

$DCs = @($Discovery.AllDCs)
$SiteDCs = @($Discovery.SiteDCs)

if ($DCs.Count -eq 0) {
    throw "No Domain Controllers discovered for $DomainName."
}

# ======================================================================
# Priority Queue
# ======================================================================

$DCQueue = foreach ($DC in $DCs) {
    $Selected = $SelectedDC -and ($DC -ieq $SelectedDC)
    $Local = $SiteDCs -icontains $DC

    $Priority = if ($Selected) {
        0
    }
    elseif ($Local) {
        1
    }
    else {
        2
    }

    [PSCustomObject]@{
        DC        = $DC
        Priority  = $Priority
        Selected  = [bool]$Selected
        LocalSite = [bool]$Local
    }
}

$DCQueue = @(
    $DCQueue |
    Sort-Object Priority, DC
)

Write-Host "Total DCs           : $($DCQueue.Count)"
Write-Host "Current-site DCs    : $($SiteDCs.Count)"
Write-Host ""

foreach ($Item in $DCQueue) {
    if ($Item.Selected) {
        Write-Host ("[CURRENT] {0}" -f $Item.DC) -ForegroundColor $Colors.Current
    }
    elseif ($Item.LocalSite) {
        Write-Host ("[LOCAL]   {0}" -f $Item.DC) -ForegroundColor $Colors.Local
    }
    else {
        Write-Host ("[REMOTE]  {0}" -f $Item.DC) -ForegroundColor $Colors.Remote
    }
}

# ======================================================================
# Parallel Worker
# ======================================================================

$WorkerScript = {
    param(
        [string]$DC,
        [int]$TimeoutMs,
        [bool]$Selected,
        [bool]$LocalSite,
        [int]$Priority
    )

    function Test-Tcp {
        param(
            [string]$HostName,
            [int]$Port,
            [int]$Timeout
        )

        $Client = New-Object System.Net.Sockets.TcpClient

        try {
            $Task = $Client.ConnectAsync($HostName, $Port)

            if (-not $Task.Wait($Timeout)) {
                return "FAIL"
            }

            if ($Client.Connected) {
                return "PASS"
            }

            return "FAIL"
        }
        catch {
            return "FAIL"
        }
        finally {
            try {
                $Client.Close()
                $Client.Dispose()
            }
            catch {
            }
        }
    }

    function Test-Dns {
        param(
            [string]$HostName,
            [int]$Timeout
        )

        try {
            $Task = [System.Net.Dns]::GetHostAddressesAsync($HostName)

            if (-not $Task.Wait($Timeout)) {
                return "FAIL"
            }

            if ($Task.Result.Count -gt 0) {
                return "PASS"
            }

            return "FAIL"
        }
        catch {
            return "FAIL"
        }
    }

    function Test-Icmp {
        param(
            [string]$HostName,
            [int]$Timeout
        )

        $Ping = New-Object System.Net.NetworkInformation.Ping

        try {
            $Reply = $Ping.Send($HostName, $Timeout)

            if (
                $Reply.Status -eq
                [System.Net.NetworkInformation.IPStatus]::Success
            ) {
                return "PASS"
            }

            return "WARN"
        }
        catch {
            return "WARN"
        }
        finally {
            try {
                $Ping.Dispose()
            }
            catch {
            }
        }
    }

    function Test-Share {
        param(
            [string]$HostName,
            [string]$Share,
            [int]$Timeout
        )

        $UNC = "\\$HostName\$Share"
        $Process = New-Object System.Diagnostics.Process

        $Process.StartInfo.FileName = "cmd.exe"
        $Process.StartInfo.Arguments = "/d /c dir `"$UNC`" /b >nul 2>&1"
        $Process.StartInfo.UseShellExecute = $false
        $Process.StartInfo.CreateNoWindow = $true

        try {
            $null = $Process.Start()

            if (-not $Process.WaitForExit($Timeout)) {
                try {
                    $Process.Kill()
                }
                catch {
                }

                return "ACCESS"
            }

            if ($Process.ExitCode -eq 0) {
                return "PASS"
            }

            return "ACCESS"
        }
        catch {
            return "ACCESS"
        }
        finally {
            try {
                $Process.Dispose()
            }
            catch {
            }
        }
    }

    $StartTime = Get-Date

    $DNS = Test-Dns $DC $TimeoutMs
    $PING = Test-Icmp $DC $TimeoutMs
    $Kerberos = Test-Tcp $DC 88 $TimeoutMs
    $RPC = Test-Tcp $DC 135 $TimeoutMs
    $LDAP = Test-Tcp $DC 389 $TimeoutMs
    $SMB = Test-Tcp $DC 445 $TimeoutMs

    if ($SMB -eq "PASS") {
        $SYSVOL = Test-Share $DC "SYSVOL" $TimeoutMs
        $NETLOGON = Test-Share $DC "NETLOGON" $TimeoutMs
    }
    else {
        $SYSVOL = "FAIL"
        $NETLOGON = "FAIL"
    }

    $CoreTests = @(
        $DNS,
        $Kerberos,
        $RPC,
        $LDAP,
        $SMB
    )

    if ($CoreTests -contains "FAIL") {
        $JoinStatus = "FAIL"
    }
    elseif (
        $SYSVOL -eq "ACCESS" -or
        $NETLOGON -eq "ACCESS"
    ) {
        $JoinStatus = "CHECK"
    }
    elseif (
        $SYSVOL -eq "PASS" -and
        $NETLOGON -eq "PASS"
    ) {
        $JoinStatus = "READY"
    }
    else {
        $JoinStatus = "CHECK"
    }

    $Classification = if ($Selected) {
        "CURRENT"
    }
    elseif ($LocalSite) {
        "LOCAL"
    }
    else {
        "REMOTE"
    }

    [PSCustomObject][ordered]@{
        DC             = $DC
        ShortName      = $DC.Split(".")[0]
        Classification = $Classification
        Priority       = $Priority
        Selected       = if ($Selected) { "YES" } else { "NO" }
        LocalSite      = if ($LocalSite) { "YES" } else { "NO" }
        DNS            = $DNS
        PING           = $PING
        Kerberos88     = $Kerberos
        RPC135         = $RPC
        LDAP389        = $LDAP
        SMB445         = $SMB
        SYSVOL         = $SYSVOL
        NETLOGON       = $NETLOGON
        JoinStatus     = $JoinStatus
        ElapsedSec     = [math]::Round(
            ((Get-Date) - $StartTime).TotalSeconds,
            2
        )
    }
}

# ======================================================================
# Parallel Execution
# ======================================================================

Write-Section "LIVE DOMAIN CONTROLLER RESULTS"

Write-Host (
    "{0,-20} {1,-8} {2,-8} {3,-8} {4,-8} {5,-8} {6,-8} {7,-8} {8,-8} {9,-8} {10,-8} {11,6}" -f
    "DC",
    "SCOPE",
    "DNS",
    "PING",
    "KRB/88",
    "RPC/135",
    "LDAP389",
    "SMB445",
    "SYSVOL",
    "NETLOGON",
    "JOIN",
    "SEC"
)

Write-Host ("-" * 120) -ForegroundColor $Colors.Muted

$RunspacePool = $null
$Jobs = @()
$Results = @()

try {
    $RunspacePool = [RunspaceFactory]::CreateRunspacePool(
        1,
        $ThrottleLimit
    )

    $RunspacePool.Open()

    foreach ($Item in $DCQueue) {
        $PowerShell = [PowerShell]::Create()
        $PowerShell.RunspacePool = $RunspacePool

        $null = $PowerShell.AddScript($WorkerScript)
        $null = $PowerShell.AddArgument($Item.DC)
        $null = $PowerShell.AddArgument($TimeoutMs)
        $null = $PowerShell.AddArgument($Item.Selected)
        $null = $PowerShell.AddArgument($Item.LocalSite)
        $null = $PowerShell.AddArgument($Item.Priority)

        $Jobs += [PSCustomObject]@{
            DC         = $Item.DC
            PowerShell = $PowerShell
            Handle     = $PowerShell.BeginInvoke()
            Completed  = $false
        }
    }

    $CompletedCount = 0
    $TotalCount = $Jobs.Count

    while ($CompletedCount -lt $TotalCount) {
        $ActivityDetected = $false

        foreach ($Job in $Jobs) {
            if ($Job.Completed -or -not $Job.Handle.IsCompleted) {
                continue
            }

            $ActivityDetected = $true
            $Job.Completed = $true

            try {
                $JobResult = @(
                    $Job.PowerShell.EndInvoke($Job.Handle)
                )

                if ($JobResult.Count -gt 0) {
                    $Result = $JobResult[0]
                    $Results += $Result
                    Write-LiveResult $Result
                }
            }
            catch {
                $ErrorResult = [PSCustomObject][ordered]@{
                    DC             = $Job.DC
                    ShortName      = $Job.DC.Split(".")[0]
                    Classification = "ERROR"
                    Priority       = 9
                    Selected       = "NO"
                    LocalSite      = "NO"
                    DNS            = "ERROR"
                    PING           = "ERROR"
                    Kerberos88     = "ERROR"
                    RPC135         = "ERROR"
                    LDAP389        = "ERROR"
                    SMB445         = "ERROR"
                    SYSVOL         = "ERROR"
                    NETLOGON       = "ERROR"
                    JoinStatus     = "FAIL"
                    ElapsedSec     = 0
                }

                $Results += $ErrorResult

                Write-Host (
                    "{0,-20} ERROR: {1}" -f
                    $Job.DC.Split(".")[0],
                    $_.Exception.Message
                ) -ForegroundColor $Colors.Error
            }
            finally {
                $Job.PowerShell.Dispose()
                $CompletedCount++

                Write-Progress `
                    -Activity "Testing Domain Controllers" `
                    -Status "$CompletedCount of $TotalCount completed" `
                    -PercentComplete (($CompletedCount / $TotalCount) * 100)
            }
        }

        if (-not $ActivityDetected) {
            Start-Sleep -Milliseconds 100
        }
    }
}
finally {
    Write-Progress -Activity "Testing Domain Controllers" -Completed

    foreach ($Job in $Jobs) {
        if ($Job.PowerShell) {
            try {
                $Job.PowerShell.Dispose()
            }
            catch {
            }
        }
    }

    if ($RunspacePool) {
        try {
            $RunspacePool.Close()
            $RunspacePool.Dispose()
        }
        catch {
        }
    }
}

# ======================================================================
# Normalize Sorting
# ======================================================================

$Results = @(
    $Results |
    Sort-Object Priority, ShortName
)

# ======================================================================
# Final Per-DC Results
# ======================================================================

Write-Section "FINAL PER-DC RESULTS"

$Results |
    Select-Object `
        ShortName,
        Classification,
        DNS,
        PING,
        Kerberos88,
        RPC135,
        LDAP389,
        SMB445,
        SYSVOL,
        NETLOGON,
        JoinStatus,
        ElapsedSec |
    Format-Table -AutoSize

# ======================================================================
# Paginated Matrix
# ======================================================================

$MatrixTests = [ordered]@{
    "DNS"         = "DNS"
    "PING"        = "PING"
    "Kerberos/88" = "Kerberos88"
    "RPC/135"     = "RPC135"
    "LDAP/389"    = "LDAP389"
    "SMB/445"     = "SMB445"
    "SYSVOL"      = "SYSVOL"
    "NETLOGON"    = "NETLOGON"
    "JOIN"        = "JoinStatus"
}

$TotalMatrixPages = [int][math]::Ceiling(
    $Results.Count / [double]$MatrixPageSize
)

for ($Page = 0; $Page -lt $TotalMatrixPages; $Page++) {
    $PageResults = @(
        $Results |
        Select-Object `
            -Skip ($Page * $MatrixPageSize) `
            -First $MatrixPageSize
    )

    Write-Section (
        "DC TEST MATRIX - BLOCK {0} OF {1}" -f
        ($Page + 1),
        $TotalMatrixPages
    )

    Write-Host "* = current DC     " -NoNewline
    Write-Host "L = local-site DC" -ForegroundColor $Colors.Local
    Write-Host ""

    $Matrix = foreach ($TestName in $MatrixTests.Keys) {
        $Property = $MatrixTests[$TestName]

        $Row = [ordered]@{
            Test = $TestName
        }

        foreach ($Result in $PageResults) {
            $Column = $Result.ShortName

            if ($Result.Selected -eq "YES") {
                $Column += "*"
            }
            elseif ($Result.LocalSite -eq "YES") {
                $Column += "-L"
            }

            $Row[$Column] = $Result.$Property
        }

        [PSCustomObject]$Row
    }

    $Matrix |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Write-Host
}

# ======================================================================
# Current / Local Site Summary
# ======================================================================

$LocalResults = @(
    $Results |
    Where-Object {
        $_.Classification -in @(
            "CURRENT",
            "LOCAL"
        )
    }
)

Write-Section "CURRENT SITE DC SUMMARY"

$LocalResults |
    Select-Object `
        ShortName,
        Classification,
        DNS,
        PING,
        Kerberos88,
        RPC135,
        LDAP389,
        SMB445,
        SYSVOL,
        NETLOGON,
        JoinStatus |
    Format-Table -AutoSize

# ======================================================================
# Findings
# ======================================================================

$HardFailures = @(
    $Results |
    Where-Object {
        $_.JoinStatus -eq "FAIL"
    }
)

$Checks = @(
    $Results |
    Where-Object {
        $_.JoinStatus -eq "CHECK"
    }
)

$Ready = @(
    $Results |
    Where-Object {
        $_.JoinStatus -eq "READY"
    }
)

$PingWarnings = @(
    $Results |
    Where-Object {
        $_.PING -eq "WARN"
    }
)

Write-Section "FINDINGS"

if ($HardFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "HARD FAILURES" -ForegroundColor $Colors.Fail

    foreach ($Result in $HardFailures) {
        $Failures = @()

        if ($Result.DNS -eq "FAIL") {
            $Failures += "DNS"
        }

        if ($Result.Kerberos88 -eq "FAIL") {
            $Failures += "Kerberos/88"
        }

        if ($Result.RPC135 -eq "FAIL") {
            $Failures += "RPC/135"
        }

        if ($Result.LDAP389 -eq "FAIL") {
            $Failures += "LDAP/389"
        }

        if ($Result.SMB445 -eq "FAIL") {
            $Failures += "SMB/445"
        }

        Write-Host (
            "{0,-22} [{1}] {2}" -f
            $Result.ShortName,
            $Result.Classification,
            ($Failures -join ", ")
        ) -ForegroundColor $Colors.Fail
    }
}

if ($Checks.Count -gt 0) {
    Write-Host ""
    Write-Host "ACCESS / AUTHENTICATION CHECKS" `
        -ForegroundColor $Colors.Warn

    foreach ($Result in $Checks) {
        $Items = @()

        if ($Result.SYSVOL -eq "ACCESS") {
            $Items += "SYSVOL"
        }

        if ($Result.NETLOGON -eq "ACCESS") {
            $Items += "NETLOGON"
        }

        Write-Host (
            "{0,-22} [{1}] Verify access/authentication: {2}" -f
            $Result.ShortName,
            $Result.Classification,
            ($Items -join ", ")
        ) -ForegroundColor $Colors.Warn
    }
}

if ($PingWarnings.Count -gt 0) {
    Write-Host ""
    Write-Host (
        "PING warnings: {0} DC(s). ICMP failure does not imply AD failure." -f
        $PingWarnings.Count
    ) -ForegroundColor $Colors.Warn
}

# ======================================================================
# Summary
# ======================================================================

$ExecutionDuration = [math]::Round(
    ((Get-Date) - $ScriptStartTime).TotalSeconds,
    2
)

Write-Section "SUMMARY"

Write-Host "Computer             : $ComputerName"
Write-Host "IPv4                 : $IPv4Display"
Write-Host "Domain               : $DomainName"
Write-Host "AD Site              : $(if ($SiteName) { $SiteName } else { 'Unknown' })"

Write-Host "Selected DC          : " -NoNewline
Write-Host $(if ($SelectedDC) { $SelectedDC } else { "Unknown" }) -ForegroundColor $Colors.Current

Write-Host ""
Write-Host "Total DCs            : $($Results.Count)"

Write-Host "READY                : " -NoNewline
Write-Host $Ready.Count -ForegroundColor $Colors.Pass

Write-Host "CHECK                : " -NoNewline
Write-Host $Checks.Count -ForegroundColor $Colors.Warn

Write-Host "FAIL                 : " -NoNewline
Write-Host $HardFailures.Count -ForegroundColor $Colors.Fail

Write-Host "PING WARN            : " -NoNewline
Write-Host $PingWarnings.Count -ForegroundColor $Colors.Warn

Write-Host ""
Write-Host "Execution Time       : $ExecutionDuration seconds"

# ======================================================================
# Reports
# ======================================================================

if (-not $NoReport) {
    Write-Section "REPORT GENERATION"

    # CSV report
    $Results |
        Select-Object `
            DC,
            ShortName,
            Classification,
            Priority,
            Selected,
            LocalSite,
            DNS,
            PING,
            Kerberos88,
            RPC135,
            LDAP389,
            SMB445,
            SYSVOL,
            NETLOGON,
            JoinStatus,
            ElapsedSec |
        Export-Csv `
            -Path $CsvReportPath `
            -NoTypeInformation `
            -Encoding UTF8

    # TXT report
    $Report = New-Object System.Collections.Generic.List[string]

    function Add-ReportLine {
        param(
            [string]$Text = ""
        )

        $Report.Add($Text)
    }

    Add-ReportLine ("=" * 100)
    Add-ReportLine " ACTIVE DIRECTORY DOMAIN CONTROLLER CONNECTIVITY REPORT"
    Add-ReportLine ("=" * 100)

    Add-ReportLine ""
    Add-ReportLine "Tool                 : $($ScriptMetadata.Name)"
    Add-ReportLine "Version              : $($ScriptMetadata.Version)"
    Add-ReportLine "Author               : $($ScriptMetadata.Author)"
    Add-ReportLine "Generated            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    Add-ReportLine ""
    Add-ReportLine "Computer             : $ComputerName"
    Add-ReportLine "IPv4                 : $IPv4Display"
    Add-ReportLine "Current User         : $CurrentUser"
    Add-ReportLine "Domain Joined        : $($ComputerSystem.PartOfDomain)"
    Add-ReportLine "Computer Domain      : $($ComputerSystem.Domain)"
    Add-ReportLine "Primary DNS Suffix   : $PrimaryDnsSuffix"
    Add-ReportLine "Domain Tested        : $DomainName"
    Add-ReportLine "AD Site              : $SiteName"
    Add-ReportLine "Selected DC          : $SelectedDC"
    Add-ReportLine "Selected DC Site     : $($DcLocator.DcSiteName)"
    Add-ReportLine "Timeout              : $TimeoutMs ms"
    Add-ReportLine "Parallel Workers     : $ThrottleLimit"
    Add-ReportLine "Matrix Page Size     : $MatrixPageSize"

    Add-ReportLine ""
    Add-ReportLine ("=" * 100)
    Add-ReportLine " RESULT SEMANTICS"
    Add-ReportLine ("=" * 100)

    Add-ReportLine ""
    Add-ReportLine "PASS   = Test positively succeeded."
    Add-ReportLine "FAIL   = Required network/service prerequisite failed."
    Add-ReportLine "WARN   = Non-critical test failed, such as ICMP."
    Add-ReportLine "ACCESS = Service reachable but access could not be verified."
    Add-ReportLine "READY  = Core domain-join prerequisites passed and share access verified."
    Add-ReportLine "CHECK  = Core prerequisites passed but access/authentication needs verification."

    Add-ReportLine ""
    Add-ReportLine ("=" * 100)
    Add-ReportLine " DOMAIN CONTROLLER INVENTORY"
    Add-ReportLine ("=" * 100)
    Add-ReportLine ""

    foreach ($Result in $Results) {
        Add-ReportLine (
            "{0,-45} {1}" -f
            $Result.DC,
            $Result.Classification
        )
    }

    Add-ReportLine ""
    Add-ReportLine ("=" * 100)
    Add-ReportLine " DETAILED RESULTS"
    Add-ReportLine ("=" * 100)
    Add-ReportLine ""

    Add-ReportLine (
        $Results |
        Select-Object `
            ShortName,
            Classification,
            DNS,
            PING,
            Kerberos88,
            RPC135,
            LDAP389,
            SMB445,
            SYSVOL,
            NETLOGON,
            JoinStatus,
            ElapsedSec |
        Format-Table -AutoSize |
        Out-String -Width 4096
    )

    for ($Page = 0; $Page -lt $TotalMatrixPages; $Page++) {
        $PageResults = @(
            $Results |
            Select-Object `
                -Skip ($Page * $MatrixPageSize) `
                -First $MatrixPageSize
        )

        Add-ReportLine ""
        Add-ReportLine ("=" * 100)

        Add-ReportLine (
            " DC TEST MATRIX - BLOCK {0} OF {1}" -f
            ($Page + 1),
            $TotalMatrixPages
        )

        Add-ReportLine ("=" * 100)
        Add-ReportLine ""
        Add-ReportLine "* = current DC"
        Add-ReportLine "L = local-site DC"
        Add-ReportLine ""

        $Matrix = foreach ($TestName in $MatrixTests.Keys) {
            $Property = $MatrixTests[$TestName]

            $Row = [ordered]@{
                Test = $TestName
            }

            foreach ($Result in $PageResults) {
                $Column = $Result.ShortName

                if ($Result.Selected -eq "YES") {
                    $Column += "*"
                }
                elseif ($Result.LocalSite -eq "YES") {
                    $Column += "-L"
                }

                $Row[$Column] = $Result.$Property
            }

            [PSCustomObject]$Row
        }

        Add-ReportLine (
            $Matrix |
            Format-Table -AutoSize |
            Out-String -Width 4096
        )
    }

    Add-ReportLine ""
    Add-ReportLine ("=" * 100)
    Add-ReportLine " CURRENT SITE DC SUMMARY"
    Add-ReportLine ("=" * 100)
    Add-ReportLine ""

    Add-ReportLine (
        $LocalResults |
        Select-Object `
            ShortName,
            Classification,
            DNS,
            PING,
            Kerberos88,
            RPC135,
            LDAP389,
            SMB445,
            SYSVOL,
            NETLOGON,
            JoinStatus |
        Format-Table -AutoSize |
        Out-String -Width 4096
    )

    Add-ReportLine ""
    Add-ReportLine ("=" * 100)
    Add-ReportLine " FINDINGS"
    Add-ReportLine ("=" * 100)
    Add-ReportLine ""

    if ($HardFailures.Count -eq 0) {
        Add-ReportLine "No hard failures detected."
    }
    else {
        foreach ($Result in $HardFailures) {
            $Failures = @()

            if ($Result.DNS -eq "FAIL") {
                $Failures += "DNS"
            }

            if ($Result.Kerberos88 -eq "FAIL") {
                $Failures += "Kerberos/88"
            }

            if ($Result.RPC135 -eq "FAIL") {
                $Failures += "RPC/135"
            }

            if ($Result.LDAP389 -eq "FAIL") {
                $Failures += "LDAP/389"
            }

            if ($Result.SMB445 -eq "FAIL") {
                $Failures += "SMB/445"
            }

            Add-ReportLine (
                "{0,-22} [{1}] HARD FAIL: {2}" -f
                $Result.ShortName,
                $Result.Classification,
                ($Failures -join ", ")
            )
        }
    }

    if ($Checks.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "Access/authentication checks:"

        foreach ($Result in $Checks) {
            $Items = @()

            if ($Result.SYSVOL -eq "ACCESS") {
                $Items += "SYSVOL"
            }

            if ($Result.NETLOGON -eq "ACCESS") {
                $Items += "NETLOGON"
            }

            Add-ReportLine (
                "{0,-22} [{1}] Verify: {2}" -f
                $Result.ShortName,
                $Result.Classification,
                ($Items -join ", ")
            )
        }
    }

    if ($PingWarnings.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine (
            "PING warnings: {0} DC(s). ICMP failure does not imply AD failure." -f
            $PingWarnings.Count
        )
    }

    Add-ReportLine ""
    Add-ReportLine ("=" * 100)
    Add-ReportLine " SUMMARY"
    Add-ReportLine ("=" * 100)

    Add-ReportLine ""
    Add-ReportLine "Total DCs            : $($Results.Count)"
    Add-ReportLine "READY                : $($Ready.Count)"
    Add-ReportLine "CHECK                : $($Checks.Count)"
    Add-ReportLine "FAIL                 : $($HardFailures.Count)"
    Add-ReportLine "PING WARN            : $($PingWarnings.Count)"
    Add-ReportLine "Execution Time       : $ExecutionDuration seconds"

    Add-ReportLine ""
    Add-ReportLine "NOTE:"
    Add-ReportLine "READY is a network/service readiness assessment."
    Add-ReportLine "It does not perform or guarantee Add-Computer."
    Add-ReportLine "SYSVOL/NETLOGON ACCESS can depend on the current security context."

    $Report |
        Out-File `
            -FilePath $TextReportPath `
            -Encoding UTF8 `
            -Width 4096

    Write-Host ""
    Write-Host "Reports generated:" -ForegroundColor $Colors.Pass

    Write-Host "  TXT : " -NoNewline
    Write-Host $TextReportPath -ForegroundColor $Colors.Pass

    Write-Host "  CSV : " -NoNewline
    Write-Host $CsvReportPath -ForegroundColor $Colors.Pass
}

# ======================================================================
# Optional Pipeline Output
# ======================================================================

if ($PassThru) {
    Write-Output $Results
}

# ======================================================================
# Exit State
#
# Only hard failures among CURRENT/LOCAL DCs constitute an operational
# failure. ACCESS/CHECK and PING WARN do not.
# ======================================================================

$LocalHardFailures = @(
    $Results |
    Where-Object {
        $_.Classification -in @(
            "CURRENT",
            "LOCAL"
        ) -and
        $_.JoinStatus -eq "FAIL"
    }
)

if ($LocalHardFailures.Count -gt 0) {
    Write-Host ""
    Write-Host (
        "Completed with {0} CURRENT/LOCAL DC hard failure(s)." -f
        $LocalHardFailures.Count
    ) -ForegroundColor $Colors.Fail

    $global:LASTEXITCODE = 1
}
else {
    Write-Host ""
    Write-Host "Completed. No hard failures detected among CURRENT/LOCAL DCs." `
        -ForegroundColor $Colors.Pass

    $global:LASTEXITCODE = 0
}
