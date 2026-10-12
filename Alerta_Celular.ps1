# ============================================================
# Alerta_Celular.ps1
# Manda um aviso no celular toda vez que a atualizacao termina,
# dizendo QUEM atualizou, QUANTOS links foram trocados e se o
# NoviPlay esta firme.
#
# Como funciona: usa o servico ntfy (ntfy.sh), que e gratis,
# nao pede cadastro e nao pede cartao. O celular so precisa ter
# o aplicativo ntfy e "se increvido" num canal (que e so uma
# palavra). A partir dai, tudo que for publicado nesse canal
# aparece como notificacao, mesmo com o app fechado.
#
# O canal (topico) fica em config.np / nos Segredos do GitHub,
# para ninguem adivinhar e ficar mandando besteira.
# ============================================================

# --- configuracao: onde o aviso vai ---
# NOVIPLAY_NTFY_URL e o endereco do canal, no formato
# https://ntfy.sh/<algum-texto-secreto>. Esse texto e o que protege o
# canal: quem nao souber, nao consegue mandar mensagem nele.
# Se nao estiver definido, o alerta simplesmente nao e enviado (sem erro).

function Get-AlertaDestino {
  $u = [Environment]::GetEnvironmentVariable('NOVIPLAY_NTFY_URL')
  if (-not $u) {
    $arq = Join-Path $PSScriptRoot 'config.np'
    if (Test-Path -LiteralPath $arq) {
      foreach ($ln in [IO.File]::ReadAllLines($arq, [Text.Encoding]::UTF8)) {
        $t = $ln.Trim()
        if ($t -like 'NTFY_URL=*') { $u = $t.Substring('NTFY_URL='.Length).Trim(); break }
      }
    }
  }
  return $u
}

# --- extrai os numeros da mensagem da rodada ---
# A mensagem do rodape tem um formato fixo, tipo:
#   "... - 25 link(s) conferido(s) e trocado(s), 4 mantido(s) por ainda
#    abrirem, 2 resgatado(s) no Fenix; 3 link(s) novo(s) no catalogo,
#    0 titulo(s) sem link novo"
# Da para transformar isso em numeros.
function Get-NumerosRodada([string]$msg) {
  $n = [ordered]@{
    Trocados = -1; Mantidos = -1; Resgatados = -1; Novos = -1; SemLink = -1
  }
  if (-not $msg) { return $null }
  $padroes = @(
    @{ Chave='Trocados';   Regex='(\d+)\s+link\(s\)\s+conferido\(s\)\s+e\s+trocado\(s\)' },
    @{ Chave='Mantidos';   Regex='(\d+)\s+mantido\(s\)' },
    @{ Chave='Resgatados'; Regex='(\d+)\s+resgatado\(s\)' },
    @{ Chave='Novos';      Regex='(\d+)\s+link\(s\)\s+novo\(s\)' },
    @{ Chave='SemLink';    Regex='(\d+)\s+titulo\(s\)\s+sem\s+link\s+novo' }
  )
  foreach ($p in $padroes) {
    $m = [regex]::Match($msg, $p.Regex)
    if ($m.Success) { $n[$p.Chave] = [int]$m.Groups[1].Value }
  }
  return $n
}

function Formatar-ParteLinks($n) {
  if (-not $n) { return '' }
  $partes = @()
  if ($n.Trocados -ge 0) { $partes += "$($n.Trocados) link(s) atualizado(s)" }
  if ($n.Mantidos -ge 0) { $partes += "$($n.Mantidos) mantido(s)" }
  if ($n.Resgatados -ge 0) { $partes += "$($n.Resgatados) resgatado(s)" }
  if ($n.Novos -ge 0) { $partes += "$($n.Novos) novo(s) no catalogo" }
  if (-not $partes) { return '' }
  return ($partes -join ', ')
}

function Obter-OrigemAmigavel([string]$quem) {
  switch ($quem) {
    'PC'      { return 'PC' }
    'Nuvem'   { return 'NUVEM (servidor GitHub)' }
    'Android' { return 'CELULAR' }
    default   { return 'desconhecido' }
  }
}

# ============================================================
# Funcao principal: manda o aviso.
# Chame assim depois da rodada:
#   Send-AlertaCelular
# ============================================================
function Send-AlertaCelular {
  $destino = Get-AlertaDestino
  if (-not $destino) {
    Write-Host 'Alerta: NOVIPLAY_NTFY_URL nao definido - nada a enviar.'
    return 'sem destino'
  }

  try { . (Join-Path $PSScriptRoot 'Sincronizacao.ps1') } catch { }
  $resumo = $null
  try { $resumo = Get-SyncResumo } catch { }

  $origem = 'PC'
  $status = 'sucesso'
  $msg = ''
  $quando = Get-Date
  if ($resumo) {
    $origem = [string]$resumo.quem_atualizou
    $status = [string]$resumo.status_ultima
    $msg = [string]$resumo.msg_ultima
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$resumo.atualizado_em, [ref]$t)) { $quando = $t }
  }
  if (-not $origem) { $origem = 'PC' }

  $origemTxt = Obter-OrigemAmigavel $origem
  $num = Get-NumerosRodada $msg
  $linksTxt = Formatar-ParteLinks $num

  $pcTxt = 'nao sei'
  if ($resumo) { $pcTxt = $(if ($resumo.pc_vivo) { 'LIGADO' } else { 'DESLIGADO (a nuvem assumiu)' }) }

  # ---- titulo da notificacao ----
  if ($status -eq 'sucesso') {
    $titulo = "NoviPlay OK - $origemTxt"
    $prioridade = 3   # default (sem som alto)
  } elseif ($status -eq 'parcial') {
    $titulo = "NoviPlay PARCIAL - $origemTxt"
    $prioridade = 4   # default alto
  } else {
    $titulo = "NoviPlay ERRO - $origemTxt"
    $prioridade = 5   # urgente
  }

  # ---- corpo da notificacao ----
  $linhas = @()
  $linhas += "Quando: $($quando.ToString('dd/MM HH:mm'))"
  $linhas += "PC: $pcTxt"
  if ($linksTxt) { $linhas += $linksTxt }

  $okTudo = ($status -eq 'sucesso') -and ($num) -and ($num.SemLink -eq 0) -and ($num.Trocados -ge 0)
  if ($okTudo) {
    $linhas += ''
    $linhas += 'Todos os links conferidos, NoviPlay no ar.'
  } elseif ($status -eq 'parcial') {
    $linhas += ''
    $linhas += 'Ficaram titulos sem link que abra. Vale olhar.'
  }

  $corpo = $linhas -join "`n"

  # ---- titulos do ntfy sao texto puro; usamos o campo Title com quebra ---
  $payload = @{
    topic = ($destino -replace '^https?://[^/]+/', '')
    title = $titulo
    message = $corpo
    priority = $prioridade
    tags = $(if ($status -eq 'sucesso') { 'white_check_mark' } elseif ($status -eq 'parcial') { 'warning' } else { 'x' })
  }
  $json = $payload | ConvertTo-Json -Compress

  try {
    $null = Invoke-RestMethod -Method Post -Uri $destino `
              -Headers @{ 'Content-Type' = 'application/json' } `
              -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
              -TimeoutSec 30
    Write-Host "Alerta enviado para o celular: $titulo"
    return 'enviado'
  } catch {
    Write-Host "ERRO ao enviar o alerta: $($_.Exception.Message)"
    return 'erro'
  }
}

# --- teste manual: .\Alerta_Celular.ps1 -Teste ---
$executadoDireto = ($MyInvocation.InvocationName -ne '.')
if ($executadoDireto) {
  if ($args -contains '-Teste') {
    Send-AlertaCelular
  } elseif ($args -contains '-TesteForcado') {
    # testa com dados de mentira, sem esperar a rodada real
    $destino = Get-AlertaDestino
    if (-not $destino) { Write-Host 'Defina NOVIPLAY_NTFY_URL primeiro.'; return }
    $p = @{
      topic = ($destino -replace '^https?://[^/]+/', '')
      title = 'Teste do NoviPlay'
      message = "Quando: agora`nPC: LIGADO`n25 link(s) atualizado(s)`n`nTodos os links conferidos, NoviPlay no ar."
      priority = 3
      tags = 'white_check_mark'
    }
    $json = $p | ConvertTo-Json -Compress
    try {
      $null = Invoke-RestMethod -Method Post -Uri $destino -Headers @{ 'Content-Type'='application/json' } -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30
      Write-Host 'Teste enviado! Ve se chegou no celular.'
    } catch { Write-Host "ERRO: $($_.Exception.Message)" }
  }
}