# Active Directory Domain Controller Connectivity Tester

`testdc.ps1` is a Windows PowerShell diagnostic script for troubleshooting Active Directory domain-controller connectivity and domain-join readiness. It discovers domain controllers from AD DNS records, compares the current-site and remote DCs, tests the network services used during a domain join, and produces TXT and CSV evidence.

The script does not join a computer to a domain and does not run `Add-Computer`.

## What the script does

For the target domain, the script:

1. Detects the local computer, user, IPv4 addresses, domain, DNS suffix, and AD site when available.
2. Uses Windows DC Locator to identify the writable DC currently selected for the client.
3. Discovers domain controllers through AD DNS SRV records.
4. Classifies each DC as `CURRENT`, `LOCAL`, or `REMOTE`.
5. Tests each DC in parallel using a configurable runspace pool.
6. Streams live results, prints final tables and paginated matrices, and summarizes findings.
7. Optionally writes a TXT report and a CSV report.
8. Optionally returns the result objects to the PowerShell pipeline.

## Requirements

- Windows PowerShell 5.1.
- A Windows host with the `DnsClient` functionality used by `Resolve-DnsName`.
- Network access to the AD DNS service and the discovered domain controllers.
- A DNS configuration that can resolve the AD SRV records for the target domain.
- A security context suitable for testing `SYSVOL` and `NETLOGON` over SMB.

The script normally works without administrative changes to the computer, but the results depend on the local firewall, routing, DNS, authentication context, and domain policy.

## Run the script

Run from this directory in Windows PowerShell:

```powershell
.\testdc.ps1
```

If the domain cannot be inferred from the current environment, provide it explicitly:

```powershell
.\testdc.ps1 -DomainName 'example.contoso.com'
```

The script attempts domain discovery in this order:

1. `USERDNSDOMAIN`.
2. The domain reported by `Win32_ComputerSystem` when the computer is domain joined.
3. The primary DNS suffix from the TCP/IP registry settings.
4. An interactive prompt when running in an interactive session.

For automation, always supply `-DomainName` instead of relying on interactive prompting.

## Parameters

| Parameter | Type | Default | Description |
| --- | --- | ---: | --- |
| `-DomainName` | `string` | Auto-detected | AD DNS domain to test. Trailing dots are removed. |
| `-TimeoutMs` | `int` | `1500` | Timeout used for DNS, ICMP, TCP, and share checks. Valid range: `250`-`30000`. |
| `-ThrottleLimit` | `int` | `20` | Maximum number of DC worker runspaces. Valid range: `1`-`64`. |
| `-MatrixPageSize` | `int` | `8` | Number of DC columns shown in each result matrix block. Valid range: `3`-`15`. |
| `-ReportDirectory` | `string` | Script directory | Directory for the generated TXT and CSV reports. Created when it does not exist. |
| `-NoReport` | `switch` | Off | Suppresses report generation. |
| `-PassThru` | `switch` | Off | Writes the normalized per-DC result objects to the pipeline after console processing. |

### Common parameter combinations

Use a shorter timeout and more workers for a quick scan:

```powershell
.\testdc.ps1 `
    -DomainName 'example.contoso.com' `
    -TimeoutMs 1000 `
    -ThrottleLimit 30
```

Write reports to a dedicated directory:

```powershell
.\testdc.ps1 `
    -DomainName 'example.contoso.com' `
    -ReportDirectory 'C:\Temp\AD-Diagnostics'
```

Run without creating files:

```powershell
.\testdc.ps1 -DomainName 'example.contoso.com' -NoReport
```

Capture structured results for filtering or further automation:

```powershell
$results = .\testdc.ps1 `
    -DomainName 'example.contoso.com' `
    -NoReport `
    -PassThru

$results |
    Where-Object JoinStatus -eq 'FAIL' |
    Select-Object DC, Classification, JoinStatus, DNS, Kerberos88, RPC135, LDAP389, SMB445
```

## DC discovery and prioritization

The script uses the following Windows and DNS lookups:

- `nltest.exe /dsgetsite` to identify the local AD site.
- `nltest.exe /dsgetdc:<domain> /WRITABLE` to identify the DC selected by Windows DC Locator.
- `_ldap._tcp.dc._msdcs.<domain>` to discover all domain controllers.
- `_ldap._tcp.<site>._sites.dc._msdcs.<domain>` to discover DCs in the client site.

Each discovered DC is assigned a priority:

| Priority | Classification | Meaning |
| ---: | --- | --- |
| `0` | `CURRENT` | The DC currently selected by Windows DC Locator. |
| `1` | `LOCAL` | Another DC in the client’s current AD site. |
| `2` | `REMOTE` | A discovered DC outside the client’s current AD site. |

Workers are queued in priority order and run concurrently. Results are sorted by priority and short DC name for the final tables and reports.

## Checks performed

Each DC worker performs these checks using the configured timeout:

| Result field | Check | Success condition |
| --- | --- | --- |
| `DNS` | Hostname resolution | The DC resolves to at least one address. |
| `PING` | ICMP echo | The DC responds successfully. A failure is reported as `WARN`. |
| `Kerberos88` | TCP port `88` | A TCP connection can be established. |
| `RPC135` | TCP port `135` | A TCP connection can be established. |
| `LDAP389` | TCP port `389` | A TCP connection can be established. |
| `SMB445` | TCP port `445` | A TCP connection can be established. |
| `SYSVOL` | `\\<dc>\SYSVOL` access | `cmd.exe` can enumerate the share using the current security context. |
| `NETLOGON` | `\\<dc>\NETLOGON` access | `cmd.exe` can enumerate the share using the current security context. |

`SYSVOL` and `NETLOGON` are tested only when the SMB check succeeds. The checks are access checks from the current user context; they are not a substitute for a complete Kerberos or authorization investigation.

## Result status meanings

Individual checks and the aggregate `JoinStatus` use the following values:

| Status | Meaning |
| --- | --- |
| `PASS` | The check succeeded. |
| `FAIL` | A required network or service prerequisite failed. |
| `WARN` | A non-critical check failed. ICMP failure is reported this way and does not by itself make a DC not ready. |
| `ACCESS` | The service or network path was reachable, but the resource could not be verified with the current security context or within the timeout. |
| `READY` | DNS, Kerberos/88, RPC/135, LDAP/389, and SMB/445 passed, and both SYSVOL and NETLOGON were verified. |
| `CHECK` | Core network checks passed, but SYSVOL or NETLOGON access needs verification. |

The aggregate `JoinStatus` is calculated as follows:

```text
Any core check (DNS, Kerberos88, RPC135, LDAP389, SMB445) = FAIL -> FAIL
Otherwise SYSVOL or NETLOGON = ACCESS                      -> CHECK
Otherwise SYSVOL and NETLOGON = PASS                       -> READY
Otherwise                                                   -> CHECK
```

`PING` is intentionally excluded from the aggregate readiness calculation because ICMP is commonly blocked by policy and is not required for a domain join.

## Console output

The console includes:

- Local environment information.
- The client AD site and DC Locator result.
- The discovered DC inventory and classification.
- Live per-DC results as workers complete.
- Final per-DC result tables.
- Paginated DC matrices.
- A current-site summary.
- Hard failures, access checks, and ICMP warnings.
- A final count of `READY`, `CHECK`, `FAIL`, and `PING WARN` results.
- Generated report paths when reporting is enabled.

In the DC matrix, `*` marks the current DC selected by DC Locator and `-L` marks a local-site DC.

## Reports

Reporting is enabled by default. If `-ReportDirectory` is omitted, files are written beside `testdc.ps1`.

The script creates files with this naming pattern:

```text
DC_Test_<ComputerName>_<yyyyMMdd_HHmmss>.txt
DC_Test_<ComputerName>_<yyyyMMdd_HHmmss>.csv
```

The TXT report contains the environment, result semantics, DC inventory, detailed result tables, matrices, findings, and summary. The CSV report contains one normalized row per DC and is suitable for filtering, comparison, or ingestion into another tool.

Use `-NoReport` when the output directory must remain unchanged. Reports can contain hostnames, domain and site names, usernames, connectivity results, and other operational details; store and share them according to your organization’s security policy.

## `-PassThru` result schema

With `-PassThru`, the script writes one object per DC with these properties:

| Property | Description |
| --- | --- |
| `DC` | Fully qualified DC hostname. |
| `ShortName` | Host portion used in console tables. |
| `Classification` | `CURRENT`, `LOCAL`, or `REMOTE`. |
| `Priority` | Numeric discovery priority: `0`, `1`, or `2`. |
| `Selected` | `YES` when selected by DC Locator; otherwise `NO`. |
| `LocalSite` | `YES` when discovered in the client site; otherwise `NO`. |
| `DNS` | DNS result. |
| `PING` | ICMP result. |
| `Kerberos88` | TCP/88 result. |
| `RPC135` | TCP/135 result. |
| `LDAP389` | TCP/389 result. |
| `SMB445` | TCP/445 result. |
| `SYSVOL` | SYSVOL share result. |
| `NETLOGON` | NETLOGON share result. |
| `JoinStatus` | Aggregate readiness result. |
| `ElapsedSec` | Approximate worker duration in seconds. |

## Exit behavior

On normal completion, the script sets `$global:LASTEXITCODE` to:

- `1` when one or more `CURRENT` or `LOCAL` DCs have `JoinStatus = FAIL`.
- `0` when no `CURRENT` or `LOCAL` DC has a hard failure. `CHECK`, `ACCESS`, and ICMP `WARN` states do not cause this operational failure state.

This means a remote DC failure is reported but does not alone make the script return the hard-failure state. Discovery or initialization exceptions can stop the script before the normal completion state is reached.

## Troubleshooting workflow

### No domain can be determined

Specify the domain directly:

```powershell
.\testdc.ps1 -DomainName 'example.contoso.com'
```

Then verify the local environment with:

```powershell
Get-CimInstance Win32_ComputerSystem |
    Select-Object ComputerName, PartOfDomain, Domain

$env:USERDNSDOMAIN
```

### No DCs are discovered

Confirm that the host is using DNS servers that can answer the AD SRV records:

```powershell
Resolve-DnsName '_ldap._tcp.dc._msdcs.example.contoso.com' -Type SRV
```

Also verify DC Locator and the local site:

```powershell
nltest.exe /dsgetsite
nltest.exe /dsgetdc:example.contoso.com /WRITABLE
```

### A core TCP check fails

Use the result field to identify the service or network path to investigate. Confirm the port independently when needed:

```powershell
Test-NetConnection dc01.example.contoso.com -Port 88
Test-NetConnection dc01.example.contoso.com -Port 135
Test-NetConnection dc01.example.contoso.com -Port 389
Test-NetConnection dc01.example.contoso.com -Port 445
```

Compare a failing DC with another DC in the same site. Differences commonly point to firewall rules, routing, load balancers, security groups, host-based firewalls, or DNS records.

### `PING` is `WARN`

This is not automatically a problem. ICMP is informational and is excluded from `JoinStatus`. Continue with the DNS, TCP, SYSVOL, and NETLOGON results.

### `SYSVOL` or `NETLOGON` is `ACCESS`

The share check uses the current PowerShell user context. Verify that:

- The user can authenticate to the domain.
- The host can access SMB/445.
- The shares exist and are published by the DC.
- The test is not being run under a service account or other restricted context.
- Kerberos, time synchronization, and policy are healthy.

You can reproduce the access check interactively:

```powershell
Get-ChildItem '\\dc01.example.contoso.com\SYSVOL'
Get-ChildItem '\\dc01.example.contoso.com\NETLOGON'
```

### A domain join still fails even when a DC is `READY`

`READY` is a network and share-readiness assessment, not a guarantee that `Add-Computer` will succeed. Investigate the additional domain-join dependencies, including:

- Dynamic RPC ports and firewall policy.
- Account permissions and authentication policy.
- Existing or stale computer objects.
- AD replication health.
- Kerberos and time synchronization.
- DNS dynamic registration and suffix configuration.
- Group Policy and security policy.

For an actual failed domain join, inspect:

```text
C:\Windows\Debug\NetSetup.log
```

## Operational notes and limitations

- The script does not execute `Add-Computer` or make a domain membership change.
- DC discovery depends on correct AD DNS SRV records.
- The current-site classification depends on the site returned by `nltest` or DC Locator.
- A successful TCP connection proves reachability to that port, not that every higher-level AD operation will succeed.
- SYSVOL and NETLOGON results depend on the current identity and authorization context.
- ICMP failure is not evidence of an AD failure.
- `READY` covers only the prerequisites tested by this script.
- Reports are written locally unless `-NoReport` is used.

## Script metadata

- Internal tool name: `AD Domain Controller Connectivity Tester`
- Version: `2.2.0`
- Author: `AndyXuan@CCoE`
- Script compatibility: Windows PowerShell 5.1
