param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [int]$FailoverTimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"

function Invoke-Compose {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  Push-Location $ProjectRoot
  try {
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
  }
  finally {
    Pop-Location
  }
}

function Get-LeaderNode {
  foreach ($node in @("patroni1", "patroni2")) {
    Push-Location $ProjectRoot
    try {
      & docker compose exec -T $node curl -fsS -o /dev/null -w "%{http_code}" http://localhost:8008/primary 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        return $node
      }
    }
    finally {
      Pop-Location
    }
  }

  throw "Leader node was not found."
}

function Invoke-ClientSql {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Sql
  )

  Push-Location $ProjectRoot
  try {
    $Sql | & docker compose exec -T backup-scheduler bash -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -h haproxy -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to execute SQL through HAProxy."
    }
  }
  finally {
    Pop-Location
  }
}

Write-Host "Cluster state before failover:"
Invoke-Compose -Arguments @("exec", "-T", "patroni1", "patronictl", "-c", "/etc/patroni/patroni.yml", "list")

$initialLeader = Get-LeaderNode
Write-Host "Current leader: $initialLeader"

$beforeFailoverSql = @'
CREATE TABLE IF NOT EXISTS public.ha_failover_log (
  id bigserial PRIMARY KEY,
  note text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.ha_failover_log (note)
VALUES ('before failover via haproxy');
SELECT id, note, created_at
FROM public.ha_failover_log
ORDER BY id DESC
LIMIT 3;
'@

Write-Host "Writing marker through HAProxy before failover..."
Invoke-ClientSql -Sql $beforeFailoverSql

Write-Host "Stopping leader container $initialLeader..."
Invoke-Compose -Arguments @("stop", $initialLeader)

$deadline = (Get-Date).AddSeconds($FailoverTimeoutSeconds)
$newLeader = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  try {
    $candidate = Get-LeaderNode
    if ($candidate -and $candidate -ne $initialLeader) {
      $newLeader = $candidate
      break
    }
  }
  catch {
  }
}

if (-not $newLeader) {
  throw "Automatic failover did not finish within $FailoverTimeoutSeconds seconds."
}

Write-Host "New leader: $newLeader"

$afterFailoverSql = @'
INSERT INTO public.ha_failover_log (note)
VALUES ('after failover via haproxy');
SELECT id, note, created_at
FROM public.ha_failover_log
ORDER BY id DESC
LIMIT 5;
'@

Write-Host "Writing marker through the same HAProxy endpoint after failover..."
Invoke-ClientSql -Sql $afterFailoverSql

Write-Host "Starting former leader again..."
Invoke-Compose -Arguments @("start", $initialLeader)
Start-Sleep -Seconds 5

Write-Host "Cluster state after failover and recovery:"
Invoke-Compose -Arguments @("exec", "-T", $newLeader, "patronictl", "-c", "/etc/patroni/patroni.yml", "list")
