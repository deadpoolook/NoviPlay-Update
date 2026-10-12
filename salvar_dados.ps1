# ============================================================
# salvar_dados.ps1
# Depois da atualizacao, manda os arquivos de dados de volta
# para o Gist secreto, para a proxima rodada (e para o seu PC)
# encontra tudo no lugar.
#
# Roda dentro do GitHub Actions.
# ============================================================

$ErrorActionPreference = 'Continue'

$GistId  = $env:NOVIPLAY_GIST_ID
$Token   = $env:NOVIPLAY_GITHUB_TOKEN
$Destino = $PSScriptRoot

Write-Host "--- salvando os dados no gist $GistId ---"

if (-not $GistId -or -not $Token) {
  Write-Host 'AVISO: sem GIST_ID ou token. Os dados desta rodada NAO foram salvos.'
  return
}

$h = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'NoviPlay-Actions' }

# nome local -> nome dentro do gist
$paraGravar = @{
  'channels.np'      = 'np_channels.np'
  'froststream.np'   = 'np_froststream.np'
  'fenix.np'         = 'np_fenix.np'
  'futuro.np'        = 'np_futuro.np'
  'tvbox.np'         = 'np_tvbox.np'
  'channels.mtv'     = 'np_channels.mtv'
  'aviso.np'         = 'np_aviso.np'
  'destaques.np'     = 'np_destaques.np'
  'ultimos_ok.txt'   = 'np_ultimos_ok.txt'
  'series_frias.txt' = 'np_series_frias.txt'
  'prov_travado.txt' = 'np_prov_travado.txt'
  'titulo_trad.np'   = 'np_titulo_trad.np'
  'users.np'         = 'np_users.np'
  'autologin.np'     = 'np_autologin.np'
}

$files = @{}
$gravados = 0
foreach ($local in $paraGravar.Keys) {
  $caminho = Join-Path $Destino $local
  if (-not (Test-Path -LiteralPath $caminho)) { continue }
  try {
    $conteudo = [IO.File]::ReadAllText($caminho, [Text.Encoding]::UTF8)
    if (-not $conteudo) { continue }
    $files[$paraGravar[$local]] = @{ content = $conteudo }
    $gravados++
  } catch { Write-Host "  falhou ao ler ${local}: $($_.Exception.Message)" }
}

if ($gravados -eq 0) {
  Write-Host 'nada para salvar.'
  return
}

try {
  $body = @{ files = $files } | ConvertTo-Json -Depth 6 -Compress
  $null = Invoke-RestMethod -Method Patch -Uri ("https://api.github.com/gists/" + $GistId) -Headers $h -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
  Write-Host "salvos $gravados arquivo(s) no gist."
} catch {
  Write-Host "ERRO ao salvar no gist: $($_.Exception.Message)"
}