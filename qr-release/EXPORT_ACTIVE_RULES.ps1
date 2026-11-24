# Run only from an already authorized Google Cloud session. Reads Firebase only.
# Never prints the access token. Does not change IAM or request new permissions.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot ('rules-export-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
try {
  $token = & gcloud.cmd auth print-access-token
  if ($LASTEXITCODE -ne 0 -or !$token) { throw 'Authentication unavailable; stop.' }
  $headers = @{
    Authorization = "Bearer $token"
    "x-goog-user-project" = "az-express-b0469"
}
  $uri = 'https://firebaserules.googleapis.com/v1/projects/az-express-b0469/releases/cloud.firestore'
  $before = Invoke-RestMethod -Uri $uri -Headers $headers
  $rules = Invoke-RestMethod -Uri ('https://firebaserules.googleapis.com/v1/' + $before.rulesetName) -Headers $headers
  $after = Invoke-RestMethod -Uri $uri -Headers $headers
  if ($before.rulesetName -ne $after.rulesetName -or $before.updateTime -ne $after.updateTime) {
    throw 'Active release changed during export; stop and obtain a consistent export.'
  }
  New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
  $before | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $out 'release.json') -Encoding UTF8
  $rules | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $out 'ruleset.json') -Encoding UTF8
  Write-Output "Export saved to $out. Supply release.json and ruleset.json only."
} finally {
  $token = $null
  $headers = $null
}

