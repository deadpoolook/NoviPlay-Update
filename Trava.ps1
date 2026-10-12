# ============================================================
# Trava.ps1 - impede o PC e a nuvem de atualizarem ao mesmo tempo
# --------------------------------------------------------
# COMO FUNCIONA
#   Antes de comecar, cada lado "pega a trava": grava no quadro
#   compartilhado (sync.json, no gist) que ele esta trabalhando,
#   com o horario de inicio. O outro lado, ao tentar pegar a
#   trava, ve que ela esta ocupada e sai sem mexer em nada.
#
#   A trava e solta sozinha: se o dono dela morrer (PC desligou no
#   meio, a nuvem caiu), ela expira depois de TRAVA_MINUTOS e o
#   outro lado pode assumir.
#
# POR QUE PRECISA
#   Os dois escrevem no mesmo catalogo (channels.np). Se fizessem
#   isso juntos, um sobrescreveria o trabalho do outro e o app
#   poderia ficar com link velho. Com a trava, so um por vez.
# ============================================================

$script:TravaMinutos = 45   # tempo maximo que uma trava vale

function Set-TravaAtiva([string]$quem) {
  $s = Read-SyncGist
  if (-not $s) { $s = New-SyncVazio }

  $agora = Get-Date

  # a trava esta ocupada?
  $ocupada = $false
  $donoAntigo = ''
  if ($s.trava) {
    $donoAntigo = [string]$s.trava.quem
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$s.trava.inicio, [ref]$t)) {
      $minutos = ($agora - $t).TotalMinutes
      if ($minutos -gt $script:TravaMinutos) {
        # expirou (o dono caiu no meio) - pode tomar
        Write-Host "Trava antiga de '$donoAntigo' expirou ($([int]$minutos) min). Assumindo."
      } else {
        $ocupada = $true
      }
    }
  }

  if ($ocupada) {
    return @{ Pegou = $false; Motivo = "a trava esta com '$donoAntigo'"; Dono = $donoAntigo }
  }

  # pega a trava
  if (-not ($s.PSObject.Properties['trava'])) {
    $s | Add-Member -NotePropertyName 'trava' -NotePropertyValue $null -Force
  }
  $s.trava = [PSCustomObject]@{ quem = $quem; inicio = $agora.ToString('yyyy-MM-dd HH:mm:ss') }
  $r = Write-SyncGist $s
  if ($r -ne 'ok') {
    return @{ Pegou = $false; Motivo = "nao deu para gravar a trava: $r"; Dono = '' }
  }
  return @{ Pegou = $true; Motivo = ''; Dono = $quem }
}

function Remove-Trava {
  $s = Read-SyncGist
  if (-not $s) { return }
  if ($s.PSObject.Properties['trava']) { $s.trava = $null }
  $null = Write-SyncGist $s
}

# O PC esta ligado? (recente = bateu no quadro)
function Test-PcLigado {
  $s = Read-SyncGist
  if (-not $s) { return $false }
  if (-not $s.pc.pulso) { return $false }
  try {
    $t = [datetime]::Parse($s.pc.pulso)
    # Consideramos o PC ligado se ele bateu nos ultimos 2h (a tarefa e de 1h).
    return (((Get-Date) - $t).TotalMinutes -le 120)
  } catch { return $false }
}