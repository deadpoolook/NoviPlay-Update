# ============================================================
# Sincronizacao.ps1
# O "quadro de avisos" que o PC e o Android consultam para saber
# quem esta vivo e quem fez a ultima atualizacao.
#
# Guarda tudo em UM arquivo dentro do mesmo Gist que ja publica o
# noviplay.json (o arquivo sync.json). Como o Gist ja esta
# configurado e e FREE, nao precisamos de servidor novo.
#
# COMO FUNCIONA (regra: PC sempre ganha se estiver ligado)
#   - O PC grava o proprio batimento (heartbeat) na rodada.
#   - O Android grava o proprio batimento quando abre/roda.
#   - Cada um le o sync.json e responde: "o PC esta vivo?"
#     (vivo = bateu nos ultimos X minutos).
#   - Se o PC estiver vivo -> o Android NAO mexe, so mostra o status.
#   - Se o PC estiver mudo -> o Android assume e roda a atualizacao.
#
# RODA EM QUALQUER LUGAR: nao usa nada do Windows, entao o mesmo
# arquivo roda no PowerShell do PC e no PowerShell do Termux (Android).
# ============================================================

# O id do gist NAO fica escrito aqui: vem da variavel de ambiente
# (no GitHub Actions, dos Segredos) ou do config.np (no PC). Se faltar,
# o quadro compartilhado simplesmente nao funciona - a atualizacao segue
# normal, so que os dois paineis nao se avisam.
$script:SyncGistId   = $(if ($env:NOVIPLAY_GIST_ID) { $env:NOVIPLAY_GIST_ID } else { '' })
$script:SyncFile     = 'sync.json'
$script:SyncPasta    = $PSScriptRoot
$script:SyncTokenFile = Join-Path $script:SyncPasta 'github.np'

if (-not $script:SyncGistId -and (Test-Path -LiteralPath (Join-Path $script:SyncPasta 'config.np'))) {
  try {
    foreach ($ln in [IO.File]::ReadAllLines((Join-Path $script:SyncPasta 'config.np'), [Text.Encoding]::UTF8)) {
      $t = $ln.Trim()
      if ($t -like 'GIST_ID=*') { $script:SyncGistId = $t.Substring(8).Trim(); break }
    }
  } catch { }
}

# Quanto tempo (em minutos) sem bater o "pulso" = considerarOffline.
# A tarefa do PC roda de 1 em 1 hora, entao 2h de silencio ja e
# com seguranca o PC desligado.
$script:SyncMinutosOffline = 120

function Get-SyncToken {
  # No GitHub Actions o token chega pela variavel de ambiente (vem dos
  # Segredos). No PC ele continua sendo lido do arquivo github.np.
  if ($env:NOVIPLAY_GITHUB_TOKEN) { return $env:NOVIPLAY_GITHUB_TOKEN.Trim() }
  if (-not (Test-Path -LiteralPath $script:SyncTokenFile)) { return '' }
  try {
    $t = ([IO.File]::ReadAllLines($script:SyncTokenFile, [Text.Encoding]::UTF8) |
          Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } |
          Select-Object -Last 1).Trim()
    return $t
  } catch { return '' }
}

function Get-SyncHeaders {
  $tok = Get-SyncToken
  if (-not $tok) { return $null }
  return @{
    'Authorization' = "Bearer $tok"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'NoviPlay-Sync'
  }
}

# --- leitura / escrita do sync.json no Gist ------------------------

function Read-SyncGist {
  $h = Get-SyncHeaders
  if (-not $h) { return $null }
  try {
    $r = Invoke-RestMethod -Method Get `
           -Uri ("https://api.github.com/gists/" + $script:SyncGistId) `
           -Headers $h -TimeoutSec 40
    $f = $r.files.($script:SyncFile)
    if (-not $f) { return $null }
    return ($f.content | ConvertFrom-Json)
  } catch { return $null }
}

function Write-SyncGist($obj) {
  $h = Get-SyncHeaders
  if (-not $h) { return 'sem token (github.np) - nao gravou.' }
  $json = $obj | ConvertTo-Json -Depth 6 -Compress
  $body = @{ files = @{ $script:SyncFile = @{ content = $json } } } | ConvertTo-Json -Depth 6 -Compress
  try {
    $null = Invoke-RestMethod -Method Patch `
             -Uri ("https://api.github.com/gists/" + $script:SyncGistId) `
             -Headers $h -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
    return 'ok'
  } catch { return ('erro: ' + $_.Exception.Message) }
}

# --- estado vazio (primeira vez) -----------------------------------

function New-SyncVazio {
  return [PSCustomObject]@{
    atualizado_em = ''
    quem_atualizou = ''
    pc = [PSCustomObject]@{ vivo = $false; pulso = '' }
    android = [PSCustomObject]@{ vivo = $false; pulso = '' }
    status = ''
    msg = ''
  }
}

function Test-PcVivo($sync) {
  if (-not $sync) { return $false }
  if (-not $sync.pc.pulso) { return $false }
  try {
    $t = [datetime]::Parse($sync.pc.pulso)
    return (((Get-Date) - $t).TotalMinutes -le $script:SyncMinutosOffline)
  } catch { return $false }
}

function Test-AndroidVivo($sync) {
  if (-not $sync) { return $false }
  if (-not $sync.android.pulso) { return $false }
  try {
    $t = [datetime]::Parse($sync.android.pulso)
    return (((Get-Date) - $t).TotalMinutes -le $script:SyncMinutosOffline)
  } catch { return $false }
}

# --- batimento -----------------------------------------------------
# Chame ao abrir o painel (PC ou Android). Grava "estou vivo agora".

function Add-Pulso {
  param(
    [ValidateSet('PC','Android','Nuvem')][string]$Quem = 'PC'
  )
  $s = Read-SyncGist
  if (-not $s) { $s = New-SyncVazio }
  $agora = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if ($Quem -eq 'PC') {
    $s.pc.pulso = $agora; $s.pc.vivo = $true
  } elseif ($Quem -eq 'Android') {
    $s.android.pulso = $agora; $s.android.vivo = $true
  }
  $r = Write-SyncGist $s
  return @{ quem = $Quem; pulso = $agora; gravou = $r }
}

# --- registro de rodadas ------------------------------------------
# Chame no fim (ou no erro) de uma atualizacao para o outro painel
# mostrar "atualizado pelo PC/Android".

function Set-Atualizacao {
  param(
    [ValidateSet('PC','Android','Nuvem')][string]$Quem = 'PC',
    [string]$Status = 'sucesso',
    [string]$Msg = ''
  )
  $s = Read-SyncGist
  if (-not $s) { $s = New-SyncVazio }
  $s.atualizado_em   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $s.quem_atualizou  = $Quem
  $s.status          = $Status
  $s.msg             = $Msg
  if ($Quem -eq 'PC')     { $s.pc.pulso = $s.atualizado_em; $s.pc.vivo = $true }
  elseif ($Quem -eq 'Android') { $s.android.pulso = $s.atualizado_em; $s.android.vivo = $true }
  $r = Write-SyncGist $s
  return @{ quem = $Quem; quando = $s.atualizado_em; status = $Status; gravou = $r }
}

# --- resumo pro painel ---------------------------------------------
# Retorna um objeto com tudo que a tela precisa mostrar.
#
# -SyncLocal: em vez de ler o Gist, usa um objeto informado na chamada.
#   Serve para teste offline e para o painel funcionar mesmo sem internet
#   (nesse caso quem chama decide o que fazer com a informacao velha).

function Get-SyncResumo($SyncLocal = $null) {
  if ($null -ne $SyncLocal) { $s = $SyncLocal } else { $s = Read-SyncGist }
  if (-not $s) { $s = New-SyncVazio }
  $pcVivo = Test-PcVivo $s
  $anVivo = Test-AndroidVivo $s
  $res = [PSCustomObject]@{
    pc_vivo          = $pcVivo
    android_vivo     = $anVivo
    pc_pulso         = $s.pc.pulso
    android_pulso    = $s.android.pulso
    atualizado_em    = $s.atualizado_em
    quem_atualizou   = $s.quem_atualizou
    status_ultima    = $s.status
    msg_ultima       = $s.msg
    # regra de decisao: quem DEVE atualizar agora
    quem_deve_atualizar = $(if ($pcVivo) { 'PC' } else { 'Android' })
  }
  return $res
}

# --- teste manual (rode: .\Sincronizacao.ps1 -Teste) ---------------
# So roda se este arquivo for EXECUTADO. Se ele for importado com ". "
# pelo painel principal (InvocationName == '.'), o bloco e ignorado -
# senao o teste dispararia a cada atualizacao.

$executadoDireto = ($MyInvocation.InvocationName -ne '.')
if ($executadoDireto -and ($args -contains '-Teste')) {
  '--- leitura atual do sync.json ---'
  $r = Get-SyncResumo
  $r | Format-List
  '--- mandando pulso de teste do PC ---'
  Add-Pulso -Quem 'PC' | Format-List
  '--- resumo depois do pulso ---'
  Get-SyncResumo | Format-List
}