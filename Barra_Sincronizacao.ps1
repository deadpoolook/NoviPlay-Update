# ============================================================
# Barra_Sincronizacao.ps1
# Monta a linha que diz QUEM fez a ultima atualizacao e quando
# sao as proximas.
#
# Roda dentro do painel do PC. Le o quadro compartilhado (sync.json
# no gist) e mostra, por exemplo:
#
#   Ultima: 12/10 03:05  concluida  [FEITA PELO GITHUB]
#   Proxima: 03:17 (nuvem) | 04:05 (PC)
#
# O gist so e consultado de tempos em tempos (nao a cada segundo),
# para nao ficar travando o painel esperando a internet.
# ============================================================

$script:SyncBarrao = @{
  Cache     = $null      # ultima leitura do quadro
  QuandoLido = [datetime]::MinValue
  IntervaloSegundos = 60
}

function Get-SyncCache {
  $agora = Get-Date
  if ($script:SyncBarrao.Cache -and (($agora - $script:SyncBarrao.QuandoLido).TotalSeconds -lt $script:SyncBarrao.IntervaloSegundos)) {
    return $script:SyncBarrao.Cache
  }
  try {
    $r = Get-SyncResumo
    $script:SyncBarrao.Cache = $r
    $script:SyncBarrao.QuandoLido = $agora
  } catch { }
  return $script:SyncBarrao.Cache
}

# Nome bonitinho de quem rodou
function Get-OrigemTexto([string]$quem) {
  switch ($quem) {
    'PC'     { return 'PC' }
    'Nuvem'  { return 'GITHUB (servidor)' }
    'Android' { return 'CELULAR' }
    default  { return 'desconhecido' }
  }
}

# Calcula o proximo horario de rodada.
# O PC roda todo dia :05 e a nuvem todo dia :17 (ver atualizar.yml).
function Get-ProximoHorario([int]$minuto) {
  $agora = Get-Date
  $p = Get-Date -Year $agora.Year -Month $agora.Month -Day $agora.Day -Hour $agora.Hour -Minute $minuto -Second 0
  if ($p -le $agora) { $p = $p.AddHours(1) }
  return $p
}

function Atualiza-BarraSincronizacao {
  if (-not $script:NPBarraSinc) { $script:NPBarraSinc = $null }

  $cache = Get-SyncCache

  # ---- linha 1: quem fez a ultima ----
  if (-not $cache -or -not $cache.atualizado_em) {
    $script:NPBarraSinc = 'Ultima: ainda nao houve registro compartilhado'
    if ($LblSinc) {
      $LblSinc.Text = $script:NPBarraSinc
      try { if ($ColorDim) { $LblSinc.ForeColor = $ColorDim } } catch { }
    }
    return
  }

  $quando = ''
  $t = [datetime]::MinValue
  if ([datetime]::TryParse([string]$cache.atualizado_em, [ref]$t)) {
    $quando = $t.ToString('dd/MM HH:mm')
  } else { $quando = [string]$cache.atualizado_em }

  $origem = Get-OrigemTexto ([string]$cache.quem_atualizou)
  $estado = [string]$cache.status_ultima
  if ($estado -eq 'sucesso') { $estado = 'concluida' }
  elseif ($estado -eq 'parcial') { $estado = 'parcial' }
  elseif ($estado -eq 'erro') { $estado = 'ERRO' }

  $texto = "Ultima: $quando  $estado  [FEITA PELA $origem]"

  # ---- linha 2: as proximas rodadas ----
  $proxNuvem  = Get-ProximoHorario 17
  $proxPC     = Get-ProximoHorario 5
  $txt = "$texto`r`nProxima: $($proxNuvem.ToString('HH:mm')) no Github  |  $($proxPC.ToString('HH:mm')) no PC"

  # ---- quem esta ligado agora ----
  if ($cache.pc_vivo) {
    $txt += "   |   PC ligado: SIM"
  } else {
    $txt += "   |   PC ligado: NAO (a nuvem assume)"
  }

  $script:NPBarraSinc = $txt
  if ($LblSinc) {
    $LblSinc.Text = $txt
    # As cores vem do painel. Se por algum motivo nao estiverem defined
    # (teste isolado, por exemplo), nao quebra o painel por causa disso.
    try {
      if ($cache.pc_vivo) {
        if ($ColorGreen) { $LblSinc.ForeColor = $ColorGreen }
      } else {
        $LblSinc.ForeColor = [Drawing.Color]::FromArgb(230, 160, 60)
      }
    } catch { }
  }
}