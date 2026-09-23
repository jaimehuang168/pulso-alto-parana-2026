$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js first.' }
node scripts/build-demo.mjs
if ($LASTEXITCODE -ne 0) { throw 'Cannot build practice HTML.' }
Start-Process (Join-Path (Get-Location) 'DEMO_ABRIR_EN_NAVEGADOR.html')
