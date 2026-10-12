# ============================================================
# baixar_dados.ps1
# Puxa os arquivos de dados do catalogo que estao guardados no
# Gist secreto e coloca na pasta do app, para a atualizacao
# encontrar o catalogo existente em vez de comecar do zero.
#
# Roda dentro do GitHub Actions. Usa a mesma API do gist que o
# painel ja usa.
# ============================================================

$ErrorActionPreference = 'Continue'

$GistId   = $env:NOVIPLAY_GIST_ID
$Token    = $env:NOVIPLAY_GITHUB_TOKEN
$Destino  = $PSScriptRoot
$NomePax  = 'dados'

Write-Host "--- baixando os dados do gist $GistId ---"

if (-not $GistId -or -not $Token) {
  Write-Host 'AVISO: sem GIST_ID ou token. A rodada vai rodar sem catalogo anterior.'
  return
}

$h = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'NoviPlay-Actions' }

try {
  $gist = Invoke-RestMethod -Uri ("https://api.github.com/gists/" + $GistId) -Headers $h -TimeoutSec 60
} catch {
  Write-Host "ERRO ao ler o gist: $($_.Exception.Message)"
  return
}

# Nomes de arquivo no gist -> nome local. Tudo que comeca com
# "np_" no gist vira um arquivo de dado.
$queridos = @{
  'np_channels.np'         = 'channels.np'
  'np_froststream.np'      = 'froststream.np'
  'np_fenix.np'            = 'fenix.np'
  'np_futuro.np'           = 'futuro.np'
  'np_tvbox.np'            = 'tvbox.np'
  'np_channels.mtv'        = 'channels.mtv'
  'np_aviso.np'            = 'aviso.np'
  'np_destaques.np'        = 'destaques.np'
  'np_ultimos_ok.txt'      = 'ultimos_ok.txt'
  'np_series_frias.txt'    = 'series_frias.txt'
  'np_prov_travado.txt'    = 'prov_travado.txt'
  'np_titulo_trad.np'      = 'titulo_trad.np'
  'np_users.np'            = 'users.np'
  'np_autologin.np'        = 'autologin.np'
}

$baixados = 0
foreach ($chave in $queridos.Keys) {
  $f = $gist.files.$chave
  if (-not $f) { continue }
  if (-not $f.content) {
    Write-Host "  $($chave) veio sem conteudo (truncado?), pulando."
    continue
  }
  try {
    [IO.File]::WriteAllText((Join-Path $Destino $queridos[$chave]), $f.content, (New-Object Text.UTF8Encoding($false)))
    $baixados++
  } catch { Write-Host "  falhou ao gravar $($queridos[$chave]): $($_.Exception.Message)" }
}

Write-Host "baixados $baixados arquivo(s) de dados."