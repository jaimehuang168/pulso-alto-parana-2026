# Run locally from the extracted project. Never paste server secrets here or in ChatGPT.
# This creates a NEW PUBLIC SOURCE repository after an explicit local confirmation.
[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$RepoName = 'pulso-alto-parana-2026',
  [string]$SupabaseUrl = '',
  [string]$PublishableKey = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Invoke-Checked {
  param([string]$Command, [string[]]$Arguments)
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE). Stopped without forcing changes." }
}
try {
  $root = Split-Path -Parent $PSScriptRoot
  Set-Location $root
  foreach ($command in @('git','gh','node')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
      throw "Install $command from its official website, reopen PowerShell, and run this script again. See docs/DEPLOY_ZH.md."
    }
  }
  & gh auth status
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'Sign in to GitHub in the browser. Do not send a token to anyone.'
    Invoke-Checked 'gh' @('auth','login','--web','--git-protocol','https','--scopes','repo,workflow')
  }
  $login = (& gh api user --jq '.login').Trim()
  if ($LASTEXITCODE -ne 0 -or -not $login) { throw 'Cannot identify the GitHub account.' }
  $uid = (& gh api user --jq '.id').Trim()
  $repo = "$login/$RepoName"
  if (Test-Path '.git') { throw 'This folder already contains .git. Use a fresh extracted copy. Existing repositories are never overwritten by this script.' }
  & gh repo view $repo --json name 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { throw "$repo already exists. Use the ZIP import workflow for this repository or node scripts/continue-deploy-zh.mjs --publish after source import. Do NOT recreate or delete it. No existing repo was changed." }
  if (-not $SupabaseUrl) { $SupabaseUrl = Read-Host 'Supabase project URL (https://xxxxx.supabase.co)' }
  if (-not $PublishableKey) { $PublishableKey = Read-Host 'Supabase PUBLISHABLE key (sb_publishable_...). NEVER a secret key' }
  if ($SupabaseUrl -notmatch '^https://[a-z0-9-]+\.supabase\.co/?$') { throw 'Invalid Supabase URL.' }
  if ($PublishableKey -notmatch '^sb_publishable_[A-Za-z0-9_-]+$') { throw 'Only sb_publishable_ keys accepted. Server secrets must remain in Supabase.' }
  Invoke-Checked 'node' @('--check','web/app.js')
  Invoke-Checked 'node' @('--test','tests/core.test.cjs')
  Write-Host "This will create PUBLIC source code at $repo, publish ONLY web/ through GitHub Pages, and configure two PUBLIC variables."
  Write-Host 'It will NOT create your database, deploy its Edge Function, or make the app production-ready automatically.'
  Write-Host 'No real survey records, staff credentials, GPS records or secret keys belong in this source folder.'
  $confirm = Read-Host "Type the repository name $RepoName to authorize creation and publishing"
  if ($confirm -cne $RepoName) { throw 'Cancelled. No repository was created.' }
  Invoke-Checked 'git' @('init','-b','main')
  if (-not (& git config user.name)) { Invoke-Checked 'git' @('config','user.name',$login) }
  if (-not (& git config user.email)) { Invoke-Checked 'git' @('config','user.email',"$uid+$login@users.noreply.github.com") }
  Invoke-Checked 'git' @('add','web','supabase','scripts','tests','docs','.github','.gitignore','.env.example','README.md','THIRD_PARTY.md')
  Invoke-Checked 'git' @('commit','-m','Pulso v2: municipal exit survey, private roles and station tracking')
  Invoke-Checked 'gh' @('repo','create',$repo,'--public','--source','.','--remote','origin','--description','Private exit-survey app: login frontend, no public election results')
  Invoke-Checked 'gh' @('variable','set','SUPABASE_URL','--repo',$repo,'--body',$SupabaseUrl.TrimEnd('/'))
  Invoke-Checked 'gh' @('variable','set','SUPABASE_PUBLISHABLE_KEY','--repo',$repo,'--body',$PublishableKey)
  Invoke-Checked 'git' @('push','-u','origin','main')
  # The Pages endpoint needs the initialized default branch. A first CI run may race;
  # after enabling Pages, dispatch a fresh workflow and check its result below.
  & gh api "repos/$repo/pages" --method POST -f 'build_type=workflow' 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Enable Settings > Pages > Source: GitHub Actions in $repo, then rerun the Deploy Pulso frontend workflow."
    throw 'Pages not enabled automatically. Source was pushed; deployment is NOT yet verified.'
  }
  Start-Sleep -Seconds 5
  Invoke-Checked 'gh' @('workflow','run','pages.yml','--repo',$repo,'--ref','main')
  Start-Sleep -Seconds 6
  $run = (& gh run list --repo $repo --workflow pages.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId').Trim()
  if (-not $run) { throw "No run ID yet. Check Actions at https://github.com/$repo/actions ." }
  Invoke-Checked 'gh' @('run','watch',$run,'--repo',$repo,'--exit-status')
  $pageUrl = (& gh api "repos/$repo/pages" --jq '.html_url').Trim()
  Write-Host "Frontend workflow passed: $pageUrl"
  Write-Host 'Open it on TWO phones and validate against the same backend before distributing accounts.'
  Write-Host 'Keep viewer access blocked until the applicable dissemination restrictions have been reviewed.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
