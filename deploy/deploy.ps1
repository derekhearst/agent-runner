# Installs or updates the agent-runner custom app on TrueNAS, from Windows PowerShell 7.
# Same job as deploy.sh, but it uses Windows' own ssh, so a key held in an SSH agent
# (Bitwarden) works without Git Bash. Needs deploy/.env (see worker/.env.example).
#   pwsh deploy/deploy.ps1            # create or update the app
#   pwsh deploy/deploy.ps1 restart    # after a new image is published
#   pwsh deploy/deploy.ps1 -DryRun    # render the compose file and stop; contacts nothing
param(
    [ValidateSet('', 'restart')][string]$Action = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$HostName = 'truenas_admin@192.168.0.2'
$App = 'agent-runner'
$SshArgs = @('-o', 'BatchMode=yes')
# A key file on disk is used when present; otherwise ssh takes the key from the agent.
$KeyFile = Join-Path $HOME '.ssh/truenas_ed25519'
if (Test-Path $KeyFile) { $SshArgs = @('-i', $KeyFile) + $SshArgs }

function Invoke-Box([string]$Command, [string]$InputText) {
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $out = $InputText | ssh @SshArgs $HostName $Command
    } else {
        $out = ssh @SshArgs $HostName $Command
    }
    if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $Command" }
    $out
}

if ($Action -eq 'restart') {
    Invoke-Box "midclt call -j app.stop $App && midclt call -j app.start $App" | Out-Host
    exit 0
}

# The template sees the process environment, overridden by deploy/.env. Plain KEY=VALUE
# lines, not sourced: values may hold spaces, and a Windows editor may add CRs.
$Vars = @{}
foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $Vars[$e.Key] = [string]$e.Value }
foreach ($line in Get-Content .env) {
    if ($line -match '^\s*#') { continue }
    $key, $value = $line -split '=', 2
    if ($null -eq $value -or $key -cnotmatch '^[A-Z][A-Z0-9_]*$') { continue }
    $value = $value.TrimEnd("`r")
    if ($value.StartsWith('"')) { $value = $value.Substring(1) }
    if ($value.EndsWith('"')) { $value = $value.Substring(0, $value.Length - 1) }
    $Vars[$key] = $value
}
foreach ($k in 'ANTHROPIC_ENVIRONMENT_KEY', 'ANTHROPIC_ENVIRONMENT_ID', 'ANTHROPIC_API_KEY', 'GH_TOKEN', 'GIT_EMAIL') {
    if (-not $Vars[$k]) { throw "deploy/.env must set $k" }
}
function Set-Default([string]$Key, [string]$Value) { if (-not $Vars[$Key]) { $Vars[$Key] = $Value } }
Set-Default GIT_NAME 'Claude Agent'
Set-Default BUDGET_USD '10'
Set-Default CLAUDE_STATS_TOKEN ''
Set-Default DEVBOX_SSH_PORT '2222'
Set-Default DEVBOX_MEM_LIMIT '48g'
Set-Default DEVBOX_CI '0'
Set-Default CI_GH_TOKEN ''
Set-Default TMD_CI_REPO 'derekhearst/TheMerrowDeep'
Set-Default TMD_CI_AUTHORS 'derekhearst'

# Dev box authorized keys: public keys from DEVBOX_PUBKEY_FILES (space separated), joined with ;.
if (-not $Vars['SSH_AUTHORIZED_KEYS']) {
    $files = if ($Vars['DEVBOX_PUBKEY_FILES']) { $Vars['DEVBOX_PUBKEY_FILES'] -split '\s+' | Where-Object { $_ } }
             else { @(Join-Path $HOME '.ssh/truenas_ed25519.pub') }
    $keys = ''
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { throw "missing public key file: $f" }
        $keys += ((Get-Content -Raw $f) -replace "[`r`n]", '') + ';'
    }
    $Vars['SSH_AUTHORIZED_KEYS'] = $keys
}

# Same rules as Python's string.Template.substitute: $$ is a literal $, $NAME and ${NAME}
# are replaced, and a name with no value is an error.
$Template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'truenas.compose.yaml'))
$Compose = [regex]::Replace($Template, '\$(?:(\$)|([_a-zA-Z][_a-zA-Z0-9]*)|\{([_a-zA-Z][_a-zA-Z0-9]*)\}|())', {
    param($m)
    if ($m.Groups[1].Success) { return '$' }
    $name = if ($m.Groups[2].Success) { $m.Groups[2].Value } elseif ($m.Groups[3].Success) { $m.Groups[3].Value } else { $null }
    if (-not $name) { throw "invalid placeholder at offset $($m.Index) in truenas.compose.yaml" }
    if (-not $Vars.ContainsKey($name)) { throw "truenas.compose.yaml needs $name, which is not set" }
    $Vars[$name]
})

if ($DryRun) {
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Compose))).ToLower()
    Write-Host "Rendered truenas.compose.yaml ($($Compose.Length) chars, sha256 $sha). Dry run: nothing sent."
    exit 0
}

# Rendered here so secrets never touch a file on the NAS other than the app's own config.
Invoke-Box 'mkdir -p /mnt/Apps/Apps/AgentRunner/rfs-tools /mnt/Apps/Apps/AgentRunner/devhome/work' | Out-Null

$existing = Invoke-Box "midclt call app.query '[[""name"",""="",""$App""]]'"
if (($existing -join "`n") -match '"name"') {
    $payload = @{ custom_compose_config_string = $Compose } | ConvertTo-Json -Compress
    Invoke-Box "midclt call -j app.update $App ""`$(cat)""" $payload | Out-Host
} else {
    $payload = @{ custom_compose_config_string = $Compose; custom_app = $true; app_name = $App } | ConvertTo-Json -Compress
    Invoke-Box "midclt call -j app.create ""`$(cat)""" $payload | Out-Host
}
Write-Host "Deployed $App. Logs: TrueNAS UI > Apps > $App > Logs"
