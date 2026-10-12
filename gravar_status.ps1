# ============================================================
# gravar_status.ps1
# Escreve no quadro compartilhado (sync.json, dentro do gist
# secreto) que desta vez quem atualizou foi a NUVEM, e nao o PC.
#
# E o que faz o painel do PC (e o do celular) mostrarem:
#   "ultima atualizacao: feita pela nuvem / pelo PC / pelo celular"
# ============================================================

$ErrorActionPreference = 'Continue'

$arquivo = Join-Path $PSScriptRoot 'autoupd.status.json'
$msg = 'rodada na nuvem'
$status = 'sucesso'
$falhas = 0

if (Test-Path -LiteralPath $arquivo) {
  try {
    $e = Get-Content -LiteralPath $arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($e.msg)    { $msg = [string]$e.msg }
    if ($e.status) { $status = [string]$e.status }
    if ($e.falhas -ne $null) { $falhas = [int]$e.falhas }
  } catch { }
}

# Recorta a mensagem para caber no quadro (ficava gigante e nao ajudava).
if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }

Write-Host "--- gravando o status da rodada ---"
Write-Host "  resultado: $status | falhas: $falhas"
Write-Host "  mensagem:  $msg"

try {
  . (Join-Path $PSScriptRoot 'Sincronizacao.ps1')
  $r = Set-Atualizacao -Quem 'Nuvem' -Status $status -Msg "$msg (nuvem; falhas: $falhas)"
  Write-Host "  gravado no quadro: $($r.gravou)"
} catch {
  Write-Host "  nao deu para gravar o status: $($_.Exception.Message)"
}