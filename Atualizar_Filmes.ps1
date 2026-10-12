param([switch]$Autoupdate, [switch]$SomenteFilmes, [switch]$SoJson, [switch]$SoCanais, [switch]$SoSeries, [switch]$SoCong, [string]$CongItem, [string]$CongProv, [switch]$CongVerbose, [switch]$Rechecar, [switch]$TestMTV, [switch]$TestFenixRepair, [switch]$TestPickStream, [switch]$TestFuturo, [switch]$TestAviso, [switch]$SoTesteFrost, [switch]$BuscaCompleta)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11

# pasta do app = a pasta deste script (funciona em qualquer PC, inclusive no do cliente)
$NoviplayDir  = $PSScriptRoot

# Nome da tarefa agendada deste app. O app NoviPlay usa
# 'NoviPlay FrostStream Auto' e o clone DarkPlay usa 'DarkPlay Auto Atualizacao'.
# Descobre qual existe olhando qual tarefa aponta para ESTA pasta, e cai para o
# marcador servidor.np (que so existe no clone). Sem isso o painel ficava
# mostrando "nao agendada" mesmo com a tarefa funcionando.
$script:TarefaNome = $null
function Get-FSTarefaNome {
  if ($script:TarefaNome) { return $script:TarefaNome }
  $preferida = 'NoviPlay FrostStream Auto'
  $antiga    = 'DarkPlay Auto Atualizacao'
  $meuDir    = $NoviplayDir.TrimEnd('\')
  try {
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
      if ($t.TaskName -ne $preferida -and $t.TaskName -ne $antiga) { continue }
      foreach ($a in $t.Actions) {
        if ($a.WorkingDirectory -and $a.WorkingDirectory.TrimEnd('\') -ieq $meuDir) {
          $script:TarefaNome = $t.TaskName
          return $script:TarefaNome
        }
      }
    }
  } catch { }
  if (Test-Path (Join-Path $NoviplayDir 'servidor.np')) { $script:TarefaNome = $antiga }
  else { $script:TarefaNome = $preferida }
  return $script:TarefaNome
}
$ChannelsPath = Join-Path $NoviplayDir 'channels.np'
$FrostFile    = Join-Path $NoviplayDir 'froststream.np'
# 01/10/2026: a busca de catalogo completa (Update-AllFS/Update-AllFenix) leva
# ~38 min e, com a renovacao de link ja funcionando, nao precisa de hora em
# hora. Ela vira 1x por dia. Este arquivo guarda a data da ultima completa.
$FullSearchFile = Join-Path $NoviplayDir 'ultima_busca_completa.txt'
$FuturoFile   = Join-Path $NoviplayDir 'futuro.np'

# ---------------- CONFIGURACAO (sem segredo dentro do script) ----------------
# Antes estas addresses e senhas estavam escritas no script. Isso impedia de
# publicar o repositorio em publico (a senha do Paldi ia junto).
# AGORA o script nao tem NENHUM segredo escrito dentro. A ordem de leitura e:
#   1) variavel de ambiente NOVIPLAY_<NOME>   (e o que o GitHub Actions usa,
#      alimentado pelos Segredos - nunca aparece no repositorio)
#   2) arquivo config.np na pasta do app      (o PC usa este)
#   3) valor padrao abaixo                    (so endereco, nunca senha)
# O config.np NAO entra no repositorio (esta no .gitignore). Quem clona o
# repositorio em publico ve so a logica, sem nenhuma chave.
$script:NPCfgArq = Join-Path $NoviplayDir 'config.np'
$script:NPCfg = @{}
if (Test-Path -LiteralPath $script:NPCfgArq) {
  try {
    foreach ($ln in [IO.File]::ReadAllLines($script:NPCfgArq, [Text.Encoding]::UTF8)) {
      $t = $ln.Trim()
      if (-not $t -or $t.StartsWith('#')) { continue }
      $i = $t.IndexOf('=')
      if ($i -lt 1) { continue }
      $script:NPCfg[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
  } catch { }
}
function Get-NPConfig([string]$nome) {
  $v = [Environment]::GetEnvironmentVariable('NOVIPLAY_' + $nome)
  if ($v) { return $v }
  if ($script:NPCfg.ContainsKey($nome)) { return $script:NPCfg[$nome] }
  # Sem valor nenhum: devolve vazio em vez de erro, para o script rodar e o
  # painel mostrar o que falta em vez de quebrar.
  return ''
}

$FenixFile    = Join-Path $NoviplayDir 'fenix.np'
$FenixLog     = Join-Path $NoviplayDir 'fenix.log'
$FenixMark    = 'FENIX'
$TokenFile    = Join-Path $NoviplayDir 'github.np'
$TvBoxFile    = Join-Path $NoviplayDir 'tvbox.np'
$JsonDir      = Join-Path $NoviplayDir 'NoviPlay_GitHub'
$JsonPath     = Join-Path $JsonDir 'noviplay.json'
$GistFile     = 'gistfile1.txt'
$MtvMapFile   = Join-Path $NoviplayDir 'channels.mtv'
$AvisoFile    = Join-Path $NoviplayDir 'aviso.np'
$AvisoProgFile = Join-Path $NoviplayDir 'aviso_pendente.np'
# 10/10/2026: aviso automatico de titulo novo (aba "Aviso automatico").
#   - aviso_auto.np        : configuracao (ligado/desligado, minutos, modelos)
#   - aviso_auto_atual.np  : o aviso que esta na tela agora + hora que ele some
#   - aviso_auto_log.txt   : historico dos avisos automaticos enviados
$AvisoAutoCfg   = Join-Path $NoviplayDir 'aviso_auto.np'
$AvisoAutoAtual = Join-Path $NoviplayDir 'aviso_auto_atual.np'
$AvisoAutoLog   = Join-Path $NoviplayDir 'aviso_auto_log.txt'

# aplica a configuracao (do ambiente ou alternativa)
$FsBase       = Get-NPConfig 'FS_BASE'
$FenixBase    = Get-NPConfig 'FENIX_BASE'
$MtvBase      = Get-NPConfig 'MTV_BASE'
$GistId       = Get-NPConfig 'GIST_ID'
$PaldiHost    = Get-NPConfig 'PALDI_HOST'
$PaldiUser    = Get-NPConfig 'PALDI_USER'
$PaldiPass    = Get-NPConfig 'PALDI_PASS'

# ---------------- SINCRONIZACAO PC <-> ANDROID ----------------
# Importa o modulo que faz o PC e o Android se avisarem pelo Gist.
# E opcional: se o arquivo nao existir (instalacao antiga), segue tudo
# normal. O bloco try/catch garante que nunca quebra a atualizacao.
try { . (Join-Path $NoviplayDir 'Sincronizacao.ps1') } catch { }

# Barra de sincronizacao (mostra quem atualizou e a proxima rodada).
# Depende do Sincronizacao.ps1, entao so entra se o outro carregou.
try { if (Get-Command Get-SyncResumo -ErrorAction SilentlyContinue) { . (Join-Path $NoviplayDir 'Barra_Sincronizacao.ps1') } } catch { }

function Normalize-Text([string]$s) {
  if (-not $s) { return '' }
  $formD = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $formD.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($ch)
    }
  }
  return $sb.ToString().ToLowerInvariant()
}

$global:Filmes = @()
$global:Canais = @()

function Test-VodLine([string]$l) {
  if ([string]::IsNullOrWhiteSpace($l)) { return $false }
  $px = $l.Split([char]'|', [System.StringSplitOptions]::None)
  return $px.Count -ge 5 -and ($px[4] -eq 'filme' -or $px[4] -eq 'serie')
}

function Read-Data {
  $global:Filmes = @()
  $global:Canais = @()
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return }
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if (Test-VodLine $l) {
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -lt 5) { continue }
      $ep = ''; $capa = ''; $serie = ''
      if ($p[4] -eq 'serie' -and $p.Count -ge 6) { $serie = $p[5] }
      if ($p[4] -eq 'serie' -and $p.Count -ge 7) { $ep = $p[6] }
      if ($p.Count -ge 8) { $capa = $p[7] }
      $src = 'Frost'
      if ($p.Count -ge 3 -and $p[2] -eq 'FENIX') { $src = 'Fenix' }
      $disp = "[$src] $($p[0])"
      if ($ep) { $disp = "$disp  [$ep]" }
      $global:Filmes += [PSCustomObject]@{ Idx=$i; Nome=$p[0]; Url=$p[1]; Cat=$p[4]; Ep=$ep; Capa=$capa; Serie=$serie; Src=$src; Display=$disp }
    }
    elseif ($l.Trim() -ne '') {
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -lt 2) { continue }
      $cat = ''; $logo = ''
      if ($p.Count -ge 3) { $cat = $p[2] }
      if ($p.Count -ge 4) { $logo = $p[3] }
      $global:Canais += [PSCustomObject]@{ Idx=$i; Nome=$p[0]; Url=$p[1]; Cat=$cat; Logo=$logo; Display="$($p[0])   [$cat]" }
    }
  }
}

function Write-File([string[]]$lines) {
  $content = ($lines -join "`r`n")
  if ($content) { $content += "`r`n" }
  [IO.File]::WriteAllText($ChannelsPath, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-LinhaChave([string]$l) {
  if (-not $l) { return 'X:' }
  $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
  $cat = if ($p.Count -ge 5) { $p[4] } else { '' }
  if ($cat -eq 'filme') { return 'F:' + (Normalize-Text $p[0]).Trim().ToLowerInvariant() }
  if ($cat -eq 'serie' -and $p.Count -ge 7 -and $p[5] -and $p[6]) {
    return 'S:' + (Normalize-Text $p[5]).Trim().ToLowerInvariant() + '|' + ([string]$p[6]).Trim().ToUpperInvariant()
  }
  return 'C:' + $l.Trim()
}

# Grava no fim de um ciclo longo (Update-AllFS/Update-AllFenix). Se ninguem
# mexia no channels.np durante a rodada, e' o Write-File de sempre. Se mexeu
# (edicao manual no painel enquanto o ciclo rodava), preserva o que foi mudado
# no disco: (1) item tocado pela rodada -> link novo da rodada vence; (2) item
# nao tocado e editado no disco -> vale a edicao do disco; (3) item novo no
# disco e que a rodada nao gerou -> entra no final; (4) item que existia no
# inicio mas foi deletado no disco durante a rodada -> nao ressuscita.
$global:LinhasInicioUpdate = $null
function Write-MergeDisco([string[]]$rodada) {
  if ($null -eq $global:LinhasInicioUpdate) { Write-File $rodada; return }
  $inc = @{}
  foreach ($l in $global:LinhasInicioUpdate) { if ($l) { $k = Get-LinhaChave $l; if (-not $inc.ContainsKey($k)) { $inc[$k] = $l } } }
  $rod = @{}
  foreach ($l in $rodada) { if ($l) { $k = Get-LinhaChave $l; if (-not $rod.ContainsKey($k)) { $rod[$k] = $l } } }
  $disc = @{}; $discOrdem = New-Object 'System.Collections.Generic.List[string]'
  foreach ($dl in [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)) {
    if (-not $dl) { continue }
    $k = Get-LinhaChave $dl
    if (-not $disc.ContainsKey($k)) { $disc[$k] = $dl; $discOrdem.Add($dl) }
  }
  $out = New-Object 'System.Collections.Generic.List[string]'
  $vistos = @{}
  foreach ($l in $rodada) {
    if (-not $l) { continue }
    $k = Get-LinhaChave $l
    if ($vistos.ContainsKey($k)) { continue }
    $vistos[$k] = $true
    $noInicio = $inc.ContainsKey($k)
    $toco = ($noInicio -and $inc[$k] -ne $l)
    if ($noInicio -and -not $toco) {
      if ($disc.ContainsKey($k)) {
        if ($disc[$k] -ne $l) { $out.Add($disc[$k]) } else { $out.Add($l) }
      }
      # sem disco: foi removido durante a rodada -> nao volta
    } else {
      $out.Add($l)
    }
  }
  foreach ($dl in $discOrdem) {
    $k = Get-LinhaChave $dl
    if ($vistos.ContainsKey($k)) { continue }
    $vistos[$k] = $true
    $out.Add($dl)
  }
  Write-File $out.ToArray()
}

  $global:RelayFora = $null   # cache: o relay respondeu alguma vez nesta rodada?
  function MTV-RelayForaDoAr {
    if ($null -eq $global:RelayFora) {
      try {
        $rq = [System.Net.HttpWebRequest]::Create('https://frostview.squareweb.app/')
        $rq.Method = 'HEAD'; $rq.Timeout = 8000
        $rs = $rq.GetResponse(); $rs.Close()
        $global:RelayFora = $false
      } catch {
        $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch {}
        $global:RelayFora = ($c -ge 500 -or $c -eq 0 -or $c -eq 408)
      }
    }
    return $global:RelayFora
  }
  function MTV-RelayUrl([string]$url) {
    if (-not $url) { return '' }
    if ($url -like 'https://*') { return $url }
    if ($url -like 'http://*') {
      # O relay (frostview.squareweb.app) e' um servidor proprio e pode estar
      # fora do ar: quando cai, TODO canal que passa por ele morre, e como o
      # painel regrava o link morto na atualizacao seguinte, os canais "caem
      # sozinhos". A fonte dos canais extras responde em https, entao o link direto
      # funciona no app sem depender do relay. So cai no relay quando nao ha
      # https disponivel - e, nesse caso, o relay precisa estar no ar.
      # Tira o ":80" tambem: https na porta 80 nao responde (a fonte escuta em
      # 80 para http e em 443 para https).
      $resto = $url -replace '^http://', ''
      $resto = $resto -replace '^([^/:]+):80(?=[:/]|$)', '$1'
      if ($resto -match '^(paldi\.pro|\d{1,3}(\.\d{1,3}){3})(?=[:/]|$)') {
        return ('https://' + $resto)
      }
      $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($url))
      $relay = 'https://frostview.squareweb.app/relay/m/' + $b + '.m3u8'
      # Se o relay esta fora do ar, devolver a URL do relay seria gravar no
      # catalogo um link morto (o canal cairia na hora). Nesse caso devolve
      # vazio: quem chama trata como "sem resposta" e mantem a URL antiga.
      if (MTV-RelayForaDoAr) { return '' }
      return $relay
    }
    return $url
  }

function MTV-SaveId([string]$nome, [string]$id) {
  if (-not $nome -or -not $id) { return }
  $key = Normalize-Text $nome
  $out = @()
  $found = $false
  if (Test-Path -LiteralPath $MtvMapFile) {
    foreach ($l in [IO.File]::ReadAllLines($MtvMapFile, [Text.Encoding]::UTF8)) {
      if ($l.Trim() -eq '') { continue }
      if ($l.Split([char]'|')[0] -eq $key) { $out += ($key + '|' + $id); $found = $true }
      else { $out += $l }
    }
  }
  if (-not $found) { $out += ($key + '|' + $id) }
  [IO.File]::WriteAllLines($MtvMapFile, $out, (New-Object System.Text.UTF8Encoding($false)))
}

function MTV-FindIdDoNome([string]$nome) {
  if (-not $nome) { return '' }
  $flat = MTV-FlatCatalogo
  if ($flat.Count -eq 0) { return '' }
  $nn = Normalize-Text $nome
  foreach ($m in $flat) {
    if ((Normalize-Text $m.name) -eq $nn) { return $m.id }
  }
  foreach ($m in $flat) {
    if ((Normalize-Text $m.name) -like ('*' + $nn + '*')) { return $m.id }
  }
  return ''
}

function Update-MinhaTvUrls {
  if (-not (Test-Path -LiteralPath $MtvMapFile)) { return 'nenhum canal MinhaTV mapeado ainda.' }
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return 'channels.np nao existe.' }
  $map = @{}
  foreach ($l in [IO.File]::ReadAllLines($MtvMapFile, [Text.Encoding]::UTF8)) {
    if ($l.Trim() -eq '') { continue }
    $p = $l.Split([char]'|')
    if ($p.Count -ge 2 -and $p[0]) { $map[$p[0]] = $p[1] }
  }
  if ($map.Count -eq 0) { return 'nenhum canal MinhaTV mapeado ainda.' }
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $changed = $false
  $atualizados = 0
  $falhas = 0
  $failNames = New-Object 'System.Collections.Generic.List[string]'
  foreach ($l in $lines) {
    if ((Test-VodLine $l) -or $l.Trim() -eq '') { continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -lt 2) { continue }
    $key = Normalize-Text $p[0]
    if (-not $map.ContainsKey($key)) { continue }
    $id = $map[$key]
    $url = MTV-StreamOf $id
    if (-not $url) { $falhas++; $failNames.Add($p[0]); continue }
    $url = MTV-RelayUrl $url
    if ($url -ne $p[1]) {
      # REGRA QUE IMPEDE O CANAL DE CAIR: so grava a URL nova se ela
      # responder de verdade. Sem esta checagem, um link que a fonte devolveu
      # quebrado era gravado no catalogo e o canal morre na hora - era
      # exatamente o que fazia os canais "cairem sozinhos" quando o relay
      # caia. Agora: link novo que nao responde e' descartado, o canal continua
      # com a URL que tinha, e o nome dele vai para o log como "sem resposta".
      if (-not (Test-StreamUrl $url)) {
        $falhas++
        $failNames.Add($p[0])
        continue
      }
      $p[1] = $url
      $lines[[array]::IndexOf($lines, $l)] = ($p -join '|')
      $changed = $true
      $atualizados++
    }
  }
  if ($changed) {
    Backup-Channels | Out-Null
    Write-File $lines
  }
  $msg = "canais do addon: $atualizados atualizados, $falhas sem resposta (mantiveram a URL atual)"
  if ($atualizados -eq 0 -and $falhas -gt 0) { $msg += '. Addon instavel - tenta de novo na proxima.' }
  if ($failNames.Count -gt 0) { $msg += ' Sem resposta: ' + ($failNames -join ', ') }
  return $msg
}

function Normalize-TvCapa {
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return }
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $out = @()
  $changed = $false
  foreach ($l in $lines) {
    if ((Test-VodLine $l) -or $l.Trim() -eq '') { $out += $l; continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -ge 8 -and $p[7] -ne '') { $p[7] = ''; $changed = $true }
    $out += ($p -join '|')
  }
  if ($changed) {
    Backup-Channels | Out-Null
    Write-File $out
  }
}

function Normalize-TvGrupos {
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return }
  $bad = @('Filmes e Series', 'Filmes', 'Series')
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $out = @()
  $changed = $false
  foreach ($l in $lines) {
    if ((Test-VodLine $l) -or $l.Trim() -eq '') { $out += $l; continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -lt 4) { $out += $l; continue }
    if ($p.Count -ge 3 -and $p[2] -ne '' -and $bad -contains $p[2]) { $p[2] = 'Abertos e Variedades'; $changed = $true }
    $out += ($p -join '|')
  }
  if ($changed) {
    Backup-Channels | Out-Null
    Write-File $out
  }
}

# ---------------- FROSTSTREAM (API do addon) ----------------

$global:FSCache = @{}

function Invoke-FSJson([string]$u) {
  $h = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' }
  for ($t = 1; $t -le 3; $t++) {
    try {
      return Invoke-RestMethod -Uri $u -Headers $h -TimeoutSec 30 -ErrorAction Stop
    } catch {
      if ($t -lt 3) { Start-Sleep -Milliseconds 1200 }
    }
  }
  return $null
}

  # A coleta ja serve? Dublado de um provedor conhecido e' o que importa. Nao
  # exige 720/1080 no criterio de PARADA porque o add-on na maioria das vezes nao traz
  # rotulo de resolucao, e ai a funcao nunca dava "bom" e o painel gastava as 3
  # tentativas (10 a 15 s) em CADA episodio sem necessidade. A preferencia por
  # 720/1080 continua valendo na ORDENACAO, que e onde ela e' decisiva.
  function Test-FSColetaBoa($arr) {
    foreach ($s in @($arr)) {
      if (-not $s) { continue }
      if ((Get-FSAudioRank $s) -ne 1) { continue }
      if ((Get-FSProvRank $s) -le 3) { return $true }
    }
    return $false
  }
  function Get-FSStreams([string]$type, [string]$rid) {
    $key = "$type/$rid"
    if ($global:FSCache.ContainsKey($key)) { return $global:FSCache[$key] }
    $u = "$FsBase/stream/$type/$rid.json"
    $arr = @()
    # ACHADO IMPORTANTE: o add-on e' agregador de varias fontes (CloutDB,
    # RedeFlix, MegaEmbed, IPTV) e a resposta MUDA SOZINHA ao longo do dia.
    # Medido no The 100 T1E1: as 12:00 veio "MegaEmbed / Legendado" e as 13:20
    # veio "Nova / Dublado" - mesmo endpoint, mesmo episodio. O codigo antigo
    # parava na PRIMEIRA resposta ("break"), entao ficava com o que viesse
    # primeiro, mesmo sendo a fonte que estava fora do ar. E' por isso que no
    # Stremio (que insiste) o episodio tocava e aqui nao.
    # Agora as respostas sao SOMADAS (sem repetir a mesma URL). Assim, se a Nova
    # respondeu em uma das tentativas, ela entra na lista e o seletor escolhe a
    # dublada. Se ja veio algo dublado 720/1080 de provedor conhecido, para
    # de gastar chamada.
    $global:FSLastCall = Get-Date
    for ($t = 1; $t -le 3; $t++) {
      # Respiro entre pedidos. Medido: em rajada de 20, ~35% voltaram VAZIO.
      # O add-on esvazia o "streams": [] quando aperta. Com 800 ms o esvaziamento
      # some; 350 ms nao segurava.
      $desde = ((Get-Date) - $global:FSLastCall).TotalMilliseconds
      if ($desde -lt 800) { Start-Sleep -Milliseconds ([int](800 - $desde)) }
      $r = Invoke-FSJson $u
      $global:FSLastCall = Get-Date
      if ($r -and $r.streams) {
        foreach ($s in @($r.streams)) {
          if (-not $s) { continue }
          $urlS = [string]$s.url
          if (-not $urlS) { continue }
          $dupe = $false
          foreach ($x in $arr) { if ([string]$x.url -eq $urlS) { $dupe = $true; break } }
          if (-not $dupe) { $arr += $s }
        }
        # FILMES: tira fora os provedores bloqueados (Space). O filtro e' feito
        # ANTES do Test-FSColetaBoa para a decisao de "ja coletou o bastante?"
        # medir so os provedores que podem ser usados.
        if ($type -eq 'movie' -and $global:FilmeProvidersBloqueados.Count -gt 0) {
          $arr = @($arr | Where-Object { (Get-StreamProvedor $_) -notin $global:FilmeProvidersBloqueados })
        }
        if (Test-FSColetaBoa $arr) { break }
      }
      if ($t -lt 3) { Start-Sleep -Milliseconds (1500 * $t) }
    }
    $global:FSCache[$key] = $arr
    return $arr
  }

function Get-FSResRank([string]$name) {
  $n = ([string]$name).ToLowerInvariant()
  if ($n -match '720|\bhd\b') { return 1 }
  if ($n -match '1080|fhd|fullhd') { return 2 }
  if ($n -match '\bsd\b') { return 3 }
  if ($n -match '4k|2160|uhd') { return 4 }
  return 5
}

# ---------------------------------------------------------------------
# TITULOS QUE O APARELHO DO CLIENTE NAO AGUENTA EM 4K
# ---------------------------------------------------------------------
# Nestes titulos o NoviPlay usa SO 720p/1080p, de onde vier o link
# (Frost, Fenix ou MinhaTV). Sem isso o aparelho travava ao abrir.
# Para acrescentar outro titulo, e so incluir o nome aqui. Use o radical
# sem o "s" final para casar singular/plural ("minion" pega "Minions 2").
# 'panico' = Panico 7 (tt27047903). A TV do cliente nao abre em 4K e o Nova
# so oferece 4K e 1080p para esse titulo: com o Panico 7 aqui o 4K fica fora
# da lista e o 1080p dublado passa a ser sempre o escolhido.
$global:FS_SoHD = @('minion', 'monstro', 'panico')

# =====================================================================
# FILMES SO PELO NOVA (SPACE FORA NAS ATUALIZACOES).
# Regra do usuario: o Space caiu e os links de filme dele nao abrem mais;
# os filmes que funcionam no Stremio sao do Nova. Entao os FILMES sao
# puxados SEM o Space (so Nova/DNSPlay; DNSPlay continua por ultimo e so
# entra se a Nova nao entregar nada vivo). Series ficam na fila normal
# (Space -> Nova -> DNSPlay).
# Quando o Space voltar, e so tirar 'Space' desta lista.
# =====================================================================
$global:FilmeProvidersBloqueados = @('Space')

# =====================================================================
# SERIES PROTEGIDAS: NAO ATUALIZAR NESTA RODADA (30/09/2026)
# O usuario esta assistindo The 100 e pediu para o painel NAO mexer
# nela: atualizar trocaria o link no meio do episodio e a serie "nao
# abriria" justo quando ele esta vendo.
#
# Regra: o episodio que ja esta no catalogo e' preservado como esta, com o
# link atual. Nao e' apagado, nao e' congelado, nao e' contado como falha.
# Quando o usuario terminar de assistir, e so tirar o nome daqui.
#
# Para acrescentar outra serie, inclua o nome em 'serie' (sem o T#E#).
# =====================================================================
$global:SeriesProtegidas = @(
  'The 100'
)

# O nome da linha do catalogo traz o sufixo de audio; o radical da serie e' o
# que esta na lista. Ex.: "The 100 (Dublado PT-BR) T5E9" casa com 'The 100'.
function Test-SerieProtegida([string]$nomeLinha, [string]$serie) {
  if ($null -eq $global:SeriesProtegidas -or $global:SeriesProtegidas.Count -eq 0) { return $false }
  if ($serie) {
    $rad = Remove-AcentosPS $serie
    foreach ($s in $global:SeriesProtegidas) {
      if ($rad -eq (Remove-AcentosPS $s)) { return $true }
    }
    return $false
  }
  if (-not $nomeLinha) { return $false }
  $n = Remove-AcentosPS $nomeLinha
  foreach ($s in $global:SeriesProtegidas) {
    $alvo = Remove-AcentosPS $s
    # Radical no comeco do nome: "The 100 (Dublado...) T5E9" casa com 'The 100',
    # mas "Os 100" nao - assim nao pegamos outra serie por parecido.
    if ($n -like ($alvo + '*')) { return $true }
  }
  return $false
}

function Remove-AcentosPS([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return '' }
  $t = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $t.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
  }
  return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Test-FSSoHD([string]$titulo) {
  if ([string]::IsNullOrWhiteSpace($titulo)) { return $false }
  $t = (Remove-AcentosPS $titulo).ToLowerInvariant()
  foreach ($p in $global:FS_SoHD) {
    if ($t -like ('*' + $p.ToLowerInvariant() + '*')) { return $true }
  }
  return $false
}

# Deixa passar so 720p/1080p (rank 1 = 720/HD, rank 2 = 1080/FHD).
# Se o add-on nao devolver NENHUM 720/1080, devolve a lista inteira: melhor
# entregar o titulo numa resolucao alta do que deixar ele "sem abrir".
function Filter-FSSoHD($arr, [string]$titulo) {
  if ($null -eq $arr) { return $arr }
  if (-not (Test-FSSoHD $titulo)) { return $arr }
  $hd = @($arr | Where-Object { $r = Get-FSResRank $_.name; ($r -eq 1 -or $r -eq 2) })
  if ($hd.Count -gt 0) { return $hd }
  return $arr
}

# Descobre de qual provedor (Space, DNSPlay, Nova) veio o stream. Serve para
# ordenar por preferencia e tambem para a aba de Congelamento, que deixa o
# usuario travar UM provedor por titulo (ex.: travar The 100 no Nova).
function Get-StreamProvedor($s) {
  # O rotulo do provedor NAO fica sempre na mesma linha. Medido no FrostStream:
  # "Os 100 | T01-E01 | Nova | Portugues" (3a linha) e
  # "Todo Mundo em Panico | Nova | Portugues" (2a linha). Entao aqui varremos
  # TODAS as linhas do titulo, nessa ordem, e nao uma posicao fixa.
  #
  # 10/10/2026: o Azure entrou como provedor de PRIMEIRA linha (pedido do
  # usuario). Ele e' o primeiro a ser testado porque esta delivering bem e o
  # Nova so serve de reserva. O Space foi desligado (esta na lista de
  # $ProvedoresDesativados), entao nao compete mais.
  foreach ($l in (([string]$s.title) -split "`r?`n")) {
    if ($l -match 'Azure') { return 'Azure' }
  }
  foreach ($l in (([string]$s.title) -split "`r?`n")) {
    if ($l -match 'Space') { return 'Space' }
  }
  foreach ($l in (([string]$s.title) -split "`r?`n")) {
    if ($l -match 'DNS') { return 'DNSPlay' }
  }
  foreach ($l in (([string]$s.title) -split "`r?`n")) {
    if ($l -match 'Nova') { return 'Nova' }
  }
  foreach ($l in (([string]$s.title) -split "`r?`n")) {
    if ($l -match 'Mega\s*Embed|MegaEmbed') { return 'MegaEmbed' }
  }
  return ''
}

function Get-FSProvRank($s) {
  # Ordem de preferencia dos provedores.
  #
  # ORDEM ATUAL (10/10/2026): Azure -> Nova.
  #
  # O AZURE entrou em PRIMEIRO (pedido do usuario): o painel esta pegando ele
  # funcionando bem e os links dele abrem, entao ele ganha de todo mundo. O Nova
  # vira reserva, usado so quando o Azure nao devolve nada aproveitavel. O Fenix
  # continua como ultima instancia depois de tudo isso.
  #
  # O Space esta DESLIGADO (esta em $ProvedoresDesativados): o servico caiu e,
  # em primeiro, gastava a leva de sondagem voltando vazio. Se o Space voltar,
  # e so tirar 'Space' de $ProvedoresDesativados que ele volta a competir.
  switch (Get-StreamProvedor $s) {
    'Azure'   { return 1 }
    'Nova'    { return 2 }
    'Space'   { return 3 }
    'DNSPlay' { return 4 }
  }
  return 5
}

# ---------------------------------------------------------------------------
# PROVEDORES FORA DE OPERACAO (temporario, 01/10/2026 - a pedido do usuario)
# ---------------------------------------------------------------------------
# 10/10/2026: continua Space e DNSPlay desligados, agora com o Azure em
# PRIMEIRA linha da preferencia (ele e' o provedor que esta delivering bem).
# Os dois sao removidos da lista ANTES de qualquer teste, em Get-FSRankedStreams,
# para FILMES e SERIES. Se um titulo so exista nesses provedores, ele fica SEM
# LINK em vez de receber uma URL que falha ao carregar - e titulo sem link
# continua visivel no app.
# PARA RELIGAR: tirar o nome do provedor da lista abaixo. Nada mais precisa mudar.
$global:ProvedoresDesativados = @('Space', 'DNSPlay')

function Test-ProvedorDesativado($s) {
  if ($null -eq $global:ProvedoresDesativados) { return $false }
  if ($global:ProvedoresDesativados.Count -eq 0) { return $false }
  return ((Get-StreamProvedor $s) -in $global:ProvedoresDesativados)
}

# Filtro dos FILMES. 'Space' ja estava aqui desde antes; a lista
# $ProvedoresDesativados (acima) e' que tira Space e DNSPlay de filmes E
# series. Esta lista aqui e' a restricao antiga de FILMES, mantida porque o
# movies do add-on as vezes devolve Space para titulo de filme.
$global:FilmeProvidersBloqueados = @('Space')

function Get-FSAudioRank($s) {
  $t = [string]$s.title
  if ($t -match 'Dublado|Portugu') { return 1 }
  if ($t -match 'Legendado') { return 2 }
  return 3
}

# Bucket de qualidade: separa o que o usuario PRECISA (720p/1080p) do resto.
#   1 = 720p ou 1080p
#   2 = 4K / SD / sem marcacao
# E o que faz o 720p/1080p do Space E do Nova sempre gaining de qualquer 4K,
# como pedido: "so vai colocar 4k ou full hd se nao achar o 720p ou 1080p".
function Get-FSQualBucket([string]$name) {
  $r = Get-FSResRank $name
  if ($r -eq 1 -or $r -eq 2) { return 1 }
  return 2
}

# LEMA DO NOVIPLAY: "LINKS SEMPRE O MAIS ATUALIZADO POSSIVEL"
#
  # REGRA DE SELECAO (ordem exata, do mais desejado ao menos desejado):
  #    1) Azure   720p dublado
  #    2) Azure   1080p dublado
  #    3) Nova    720p dublado
  #    4) Nova    1080p dublado
  #    5) Azure   4K dublado
  #    6) Nova    4K dublado
  #    7) Azure   SD/sem marcacao dublado
  #    8) Nova    SD/sem marcacao dublado
  #    9) Azure   720p legendado
  #   10) Azure   1080p legendado
  #   11) Nova    720p legendado
  #   12) Nova    1080p legendado
  #   13) Azure   4K legendado
  #   14) Nova    4K legendado
  #   15) qualquer outro provedor, na mesma ordem
  #
  # Ordem dos PROVEDORES: Azure -> Nova. (10/10/2026, pedido do usuario)
  # O Azure foi para PRIMEIRO porque esta funcionando bem e os links dele
  # abrem; o Nova virou reserva. O Space esta DESLIGADO (na lista de
  # $ProvedoresDesativados) - o servico caiu e ele so gastava a leva de
  # sondagem voltando vazio. O DNSPlay segue desligado tambem.
  #
  # Os dois provedores que competem (Azure e Nova) entram na MESMA posicao de
  # qualidade e audio, so mudando de lugar na preferencia. Ou seja: se o Azure
  # 720p dublado estiver no ar, ele ganha; se estiver em manutencao, fora do ar,
  # ou o add-on nao devolver 720/1080 dele, o painel cai para o Nova.
  #
  # Dublado SEMPRE ganha de legendado, porque o conteudo do NoviPlay e dublado.
  # O 720p/1080p (de qualquer provedor) sempre ganha do 4K.
  # Um item so fica sem link quando o add-on nao devolve NENHUM stream que preste.
  #
  # A chave concatena ranks de 1 digito, entao ordena lexicograficamente igual
  # a ordenacao numerica. Ex.: Nova 720 dublado = "1111" vem antes de
  # Nova 1080 dublado = "1112", que vem antes de Space 720 dublado = "1121".
# Devolve todos os streams ja ordenados pela regra (do melhor para o pior).
  function Get-FSRankedStreams($arr, [string]$Titulo = '') {
  $out = @()
  if ($null -eq $arr) { return $out }
  # O @() aqui e' ESSENCIAL. Quando o add-on devolve UM link so, o PowerShell
  # devolve o objeto solto, e um objeto solto nao tem .Count (fica nulo). O
  # laco "for ($i = 0; $i -lt $arr.Count; ...)" nunca rodava e o episodio era
  # descartado em silencio - sem erro nenhum no log. Foi assim que a 5a
  # temporada do The 100 (12 de 13 episodios com 1 link so) "nao existia"
  # para o painel, mesmo o add-on servindo todos. Com 2+ links funcionava,
  # por isso o bug passou tanto tempo escondido.
  $arr = @(Filter-FSSoHD $arr $Titulo)
  # Provedores desativados (10/10/2026): Space e DNSPlay saem da lista ANTES
  # de qualquer teste. Sem isso, um titulo que so existe nesses dois provedores
  # receberia o link deles - que e' justamente o link que "da falha ao carregar".
  # Resultado: o titulo fica sem link (e continua aparecendo no app) em vez de
  # carregar errado. Vale para filmes E series.
  if ($global:ProvedoresDesativados -and $global:ProvedoresDesativados.Count -gt 0) {
    $arr = @($arr | Where-Object { -not (Test-ProvedorDesativado $_) })
  }
  if ($null -eq $arr -or $arr.Count -eq 0) { return $out }
  $keys = @()
  for ($i = 0; $i -lt $arr.Count; $i++) {
    $s = $arr[$i]
    $cab = if ($s.headers) { 1 } else { 0 }
    # audio + bucket(720/1080 vs resto) + provedor + qualidade + cabecalho + posicao
    $k = '{0}{1}{2}{3}{4}{5:d3}' -f (Get-FSAudioRank $s), (Get-FSQualBucket $s.name), (Get-FSProvRankComLock $s $Titulo), (Get-FSResRank $s.name), $cab, $i
    $keys += [PSCustomObject]@{ K = $k; S = $s }
  }
  foreach ($x in ($keys | Sort-Object K)) { $out += $x.S }
  return $out
}

function Pick-FSStream($arr, [string]$Titulo = '') {
  $r = Get-FSRankedStreams $arr $Titulo
  if ($r.Count -eq 0) { return $null }
  return $r[0]
}

# Testa se a URL do stream realmente responde. Sem isso, o painel guardava link
# morto (o add-on anuncia um stream que devolve 404/403/503) e o episodio ficava
# "sem abrir" mesmo existindo alternativa boa.
# Politica: so 2xx/3xx conta como vivo. 404, 403, 5xx, timeout e DNS caem como
# morto, para o seletor tentar o proximo candidato. Quando o add-on manda headers
# (Referer etc.), a sondagem usa eles - senao o link bom seria descartado.
$global:FSHostSemRede = @{}

function Get-StreamProbeHeaders($s) {
  # So os headers extras do add-on. O User-Agent vai no parametro proprio do
  # Invoke-WebRequest: em PS 5.1, passar 'User-Agent' em -Headers da erro.
  $h = @{}
  $raw = $s.headers
  if ($null -eq $raw) { return $h }
  try {
    if ($raw -is [string]) {
      foreach ($ln in ($raw -split "`r?`n")) {
        $i = $ln.IndexOf(':')
        if ($i -gt 0) {
          $k = $ln.Substring(0, $i).Trim()
          if ($k -and $k -notmatch '^(User-Agent|Host|Content-Length|Connection)$') { $h[$k] = $ln.Substring($i + 1).Trim() }
        }
      }
    } else {
      foreach ($pr in $raw.PSObject.Properties) {
        if ($pr.Name -notmatch '^(User-Agent|Host|Content-Length|Connection)$') { $h[$pr.Name] = [string]$pr.Value }
      }
    }
  } catch { }
  return $h
}

  # Sonda o link do jeito que o PLAYER pede: GET com Range, lendo 1 byte.
  #
  # Antes usavamos so HEAD, e isso dava falso positivo: servidor de link
  # expirado responde 200 no HEAD (o arquivo existe) e REJEITA o GET (o token
  # diede). O painel achava que o filme estava vivo, nao buscava link novo e
  # nao congelava - o usuario via o filme no catalogo e ele nao abria. Medido:
  # "Piratas do Caribe" e os outros respondiam 200/403 no HEAD e davam erro
  # no GET.
  # Ler 1 byte e' o teste honesto: devolve $true so se saiu video de verdade.
  function Test-LinkEntregaVideo([string]$u, $hdrs, [int]$timeout) {
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  try {
  $req = [System.Net.HttpWebRequest]::Create($u)
  $req.Method = 'GET'
  $req.Timeout = $timeout * 1000
  $req.ReadWriteTimeout = $timeout * 1000
  $req.AllowAutoRedirect = $true
  $req.UserAgent = $ua
  foreach ($k in $hdrs.Keys) { try { $req.Headers[$k] = [string]$hdrs[$k] } catch { } }
  try { $req.AddRange(0, 1) } catch { }
  $resp = $req.GetResponse()
  $code = [int]$resp.StatusCode
  $st = $resp.GetResponseStream()
  if ($null -eq $st) { $resp.Close(); return ($code -ge 200 -and $code -lt 300) }
  $buf = New-Object byte[] 1
  $lido = 0
  try { $lido = $st.Read($buf, 0, 1) } catch { }
  $ct = ''
  try { $ct = [string]$resp.ContentType } catch { }
  $resp.Close()
  # Saiu byte de verdade? Um link expirado costuma devolver HTML de erro (que
  # tem bytes) entao conferimos tambem que nao seja pagina de erro.
  if ($lido -le 0) { return $false }
  if ($ct -match 'text/html' -or $ct -match 'application/json') { return $false }
  return ($code -ge 200 -and $code -lt 400)
  } catch {
  $c = 0
  try { $c = [int]$_.Exception.Response.StatusCode } catch { }
  # Erro de rede (0) e' inconclusive, quem decide e' o chamador.
  return ($false)
  }
  }

  function Get-HttpCode([string]$u, $hdrs, [int]$timeout) {
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  try {
    $r = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec $timeout -UseBasicParsing -UserAgent $ua -Headers $hdrs -MaximumRedirection 5 -ErrorAction Stop
    return [int]$r.StatusCode
  } catch {
    $c = 0
    try { $c = [int]$_.Exception.Response.StatusCode } catch { }
    return $c
  }
}

  # ================= CACHE DE LINK QUE JA RESPONDEU =================
  # A leva completa leva 30-50 min porque cada item e' sondado ate 3 vezes
  # (Space -> DNSPlay -> Nova) e cada sondagem pode esperar 7 s, dando ate 14 s
  # com o retry de GET. O custo fica todo nos itens QUE ESTAO RUINS; os ~200
  # itens bons gastam uma sondagem rapida cada um, toda vez, sem perguntar nada.
  #
  # Aqui: quando um link responde, grava a hora. Na proxima rodada, se o MESMO
  # link respondeu nas ultimas horas, nao sondo de novo - confia. O que sobra
  # para sondar e' justamente o suspeito, que e' onde a sondagem serve.
  #
  # Nao muda nenhuma regra de decisao: se a sondagem rodar, o resultado e' o de
  # sempre. E o cache so vale para o link exato - se a URL mudou, o cache erra
  # e o item e' sondado normalmente.
  $global:FSOkCache = $null
  $global:FSOkHits = 0
  $global:FSOkMiss = 0
  $global:FSOkTTL_H = 0
  $global:SerieOk = @{}
  # Chaves vistas na rodada (temporada de serie ou filme). E o que o fechamento
  # do ciclo usa para decidir quem congelar, em vez de varrer o registro inteiro.
  $global:TempasVistas = @{}

  function Get-FSOkCache {
    if ($null -ne $global:FSOkCache) { return $global:FSOkCache }
    $global:FSOkCache = @{}
    $f = Join-Path $NoviplayDir 'ultimos_ok.txt'
    if (Test-Path -LiteralPath $f) {
      foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) {
        if ($l.Trim() -eq '') { continue }
        $q = $l.Split([char]'|')
        if ($q.Count -ge 2) {
          $t = [datetime]::MinValue
          if ([datetime]::TryParse($q[1], [ref]$t)) { $global:FSOkCache[$q[0]] = $t }
        }
      }
    }
    return $global:FSOkCache
  }

  function Save-FSOkCache {
    if ($null -eq $global:FSOkCache) { return }
    $f = Join-Path $NoviplayDir 'ultimos_ok.txt'
    $corte = (Get-Date).AddHours(-48)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($kv in $global:FSOkCache.GetEnumerator()) {
      if ($kv.Value -ge $corte) { $out.Add($kv.Key + '|' + $kv.Value.ToString('yyyy-MM-dd HH:mm:ss')) }
    }
    try { [IO.File]::WriteAllLines($f, $out, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }

  function Test-FSOkCache([string]$u) {
    # CACHE DESLIGADO (30/09/2026, pedido do usuario): FSOkTTL_H = 0 significa
    # "re-testar TUDO em toda rodada". Sem o cache, um link que morreu ha 5 min
    # era considerado vivo por 2 h e ficava quebrado no app - era o motivo de
    # "atualiza de hora em hora e meus videos nao abrem".
    # O TTL = 0 sozinho nao bastava: um link sondado no mesmo segundo ficava
    # com 0 h de diferenca e o '-gt 0' nao disparava, voltando a ser aceito.
    # Entao o TTL <= 0 retorna FALHA sempre, e a contagem de "pulado" zera.
    if ($global:FSOkTTL_H -le 0) { $global:FSOkMiss++; return $false }
    $c = Get-FSOkCache
    if (-not $c.ContainsKey($u)) { $global:FSOkMiss++; return $false }
    if (((Get-Date) - $c[$u]).TotalHours -gt $global:FSOkTTL_H) { $global:FSOkMiss++; return $false }
    $global:FSOkHits++
    return $true
  }

  function Add-FSOkCache([string]$u) {
    $c = Get-FSOkCache
    $c[$u] = Get-Date
  }

  function Test-StreamAlive($s, [switch]$SemCache) {
  $u = [string]$s.url
  $global:FSVeredito = 'morto'; if ([string]::IsNullOrWhiteSpace($u)) { return $false }
  # LIMITE DE TEMPO POR LINK (01/10/2026). A cadeia de sondagem fazia ate 4
  # chamadas (GET + HEAD + GET + HEAD) de 4 a 7 s cada, com 1,5 a 1,8 s de
  # espera entre elas. Um servidor que nao respondia custava ate ~30 s, e a leva
  # de 513 sondagens passava de 3 h. A rodada estourava o limite de 4 h do
  # agendador, ficava segurando o mutex e TODAS as horas seguintes eram puladas
  # ("Atualizacao ignorada: ja existe uma atualizacao em andamento"). Agora a
  # sondagem para quando o prazo deste link acaba: veredito 'morto' e o seletor
  # segue para o proximo candidato. Nao muda a regra de decisao, so o tempo
  # maximo gasto em UM link que nao responde.
  $t0 = Get-Date
  $limiteSeg = 8
  # LINK DE MANUTENCAO DO PROVEDOR: quando o Space (ou o Nova) esta em
  # manutencao, o add-on nao devolve link morto: devolve um arquivo de aviso
  # (ex.: .../manutencao.mp4) que EXISTE e responde HTTP 200. Como so o
  # codigo HTTP era testado, o painel achava que o link estava no ar e
  # guardava o aviso de manutencao no catalogo.
  # Aqui esse arquivo conta como MORTO, para o seletor cair no proximo
  # provedor: Space -> DNSPlay -> Nova.
  $global:FSVeredito = 'morto'; if ($u -match '(?i)manuten') { return $false }
    # link igual ao da ultima rodada e que respondeu: confia e nao gasta tempo
    # (-SemCache, usado nos FILMES: o token do link expira antes das 2 h do
    #  cache e o cache fazia o painel achar o filme vivo sem sondar de novo).
  if (-not $SemCache) {
    $global:FSVeredito = 'ok'; if (Test-FSOkCache $u) { return $true }
  }
  # Os hosts (workers.dev) comecam a barrar quem sonda em rajada. Mantemos um
  # intervalo entre as sondagens para a leva nao se auto-bloquear.
  if ($null -ne $global:FSLastProbe) {
    $d = ((Get-Date) - $global:FSLastProbe).TotalMilliseconds
    if ($d -lt 250) { Start-Sleep -Milliseconds ([int](250 - $d)) }
  }
    $global:FSLastProbe = Get-Date
    $hdrs = Get-StreamProbeHeaders $s
    # Timeout conforme a posicao na fila: o PRIMEIRO provedor testado e' o Nova
    # (ver Get-FSProvRank). Quando o Nova nao responde, esperar 7 s para cair no
    # Space e' tempo jogado fora. Nos provedores seguintes o tempo cheio e
    # mantido, porque valem a pena esperar.
  $rankProv = Get-FSProvRank $s
  $tmo = if ($rankProv -le 1) { 4 } else { 7 }
  # Teste de verdade: GET com Range lendo 1 byte. E' o que o player faz, e o
  # unico jeito de pegar link com token expirado (que responde 200 no HEAD).
  if (Test-LinkEntregaVideo $u $hdrs $tmo) { Add-FSOkCache $u; $global:FSVeredito = 'ok'; return $true }
  # Nao entregou video. Antes de dar por morto, uma segunda chance: pode ser
  # bloqueio por sondagem em rajada (403/5xx) ou uma queda de rede (0).
  $code = Get-HttpCode $u $hdrs ([Math]::Max(2, $limiteSeg - [int]((Get-Date) - $t0).TotalSeconds))
  # Erro de CONEXAO (0): o host nao respondeu. Uma segunda chance, porque
  # pode ser queda de rede. Se falhar de novo, o servidor esta fora do ar e o
  # link morreu mesmo - e nao grava no cache, para a proxima rodada reavaliar.
  if ($code -eq 0) {
  $restou = $limiteSeg - [int]((Get-Date) - $t0).TotalSeconds
  if ($restou -lt 2) { $global:FSVeredito = 'morto'; return $false }
  Start-Sleep -Milliseconds 1500
  if (Test-LinkEntregaVideo $u $hdrs ([Math]::Max(2, $restou))) { Add-FSOkCache $u; $global:FSVeredito = 'ok'; return $true }
  $global:FSVeredito = 'morto'; return $false
  }
  # 404/410: morreu de vez.
  if ($code -eq 404 -or $code -eq 410) { $global:FSVeredito = 'morto'; return $false }
  # HEAD 2xx/3xx mas o GET nao entregou video = TOKEN EXPIRADO. O arquivo
  # existe mas o acesso nao. Isso e link MORTO, e nao inconclusivo: e o caso
  # dos filmes que apareciam no app e nao abriam.
  if ($code -ge 200 -and $code -lt 400) { $global:FSVeredito = 'morto'; return $false }
  # 403/5xx: pode ser bloqueio por sondagem em rajada. Segunda chance.
  if (($code -eq 403) -or ($code -ge 500)) {
  $restou = $limiteSeg - [int]((Get-Date) - $t0).TotalSeconds
  if ($restou -lt 2) { $global:FSVeredito = 'incerto'; return $true }
  Start-Sleep -Milliseconds 1800
  if (Test-LinkEntregaVideo $u $hdrs ([Math]::Max(2, $restou))) { Add-FSOkCache $u; $global:FSVeredito = 'ok'; return $true }
  $restou = $limiteSeg - [int]((Get-Date) - $t0).TotalSeconds
  if ($restou -lt 2) { $global:FSVeredito = 'incerto'; return $true }
  $code2 = Get-HttpCode $u $hdrs ([Math]::Max(2, $restou))
  if ($code2 -ge 200 -and $code2 -lt 400) { Add-FSOkCache $u; $global:FSVeredito = 'ok'; return $true }
  if ($code2 -eq 404 -or $code2 -eq 410) { $global:FSVeredito = 'morto'; return $false }
  $global:FSVeredito = 'incerto'; return $true   # ainda nao da para saber: mantem no app
  }
  $global:FSVeredito = 'morto'; return $false
  }

# Escolhe o stream respeitando a regra do NoviPlay E exigindo que o link
# responda. Se o melhor da lista estiver morto, cai para o proximo.
# Se NENHUM responder, mas o link que ja esta no channels.np ainda funciona,
# devolve $null para o painel MANTER o link atual em vez de estragar o episodio.
  # O player (ExoPlayer) precisa que o servidor diga o TAMANHO do arquivo. Sem
  # Content-Length, ele nao sabe a duracao e, ao re-bufferar, volta pro inicio
  # do filme ou da "falha ao reproduzir". Medido no Werewolves: o addon servia 3
  # links, todos com video, mas um deles NAO devolvia Content-Length e era
  # justamente o escolhido - so esse filme dava problema. Entao, entre os
  # candidatos que entregam video, preferimos o que informa o tamanho.
  function Test-LinkInformaTamanho([string]$u, $hdrs) {
  try {
  $rq = [System.Net.HttpWebRequest]::Create($u)
  $rq.Method = 'HEAD'
  $rq.Timeout = 8000
  # Sem isto, o .NET segura a conexao pelo tempo padrao (100 s) quando o
  # servidor aceita e depois nao envia: o Timeout acima so cobre a espera pela
  # resposta. Foi um dos motivos da leva passar de 3 h.
  $rq.ReadWriteTimeout = 8000
  $rq.AllowAutoRedirect = $true
  $rq.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  foreach ($k in $hdrs.Keys) { try { $rq.Headers[$k] = [string]$hdrs[$k] } catch { } }
  $rs = $rq.GetResponse()
  $tem = ($rs.ContentLength -gt 0)
  $rs.Close()
  return $tem
  } catch { return $false }
  }

  function Resolve-FSStream($arr, [string]$urlAtual, [string]$Titulo = '', [switch]$SemTudo) {
  $r = Get-FSRankedStreams $arr $Titulo
  if ($r.Count -eq 0) { return $null }
  # So aceita candidato que ENTREGA VIDEO de verdade (veredito 'ok'). Um 403/5xx
  # deixa o veredito 'incerto' e NAO vale: o painel seguia gravando esse link e
  # nao testava os outros que funcionavam. Os add-ons servem 3 a 4 links por
  # filme e quase sempre algum entrega video, mesmo quando o primeiro esta com
  # token velho. Era por isso que "a maioria dos filmes nao abria" enquanto o
  # add-on tinha alternativa boa na mao.
  # ORDEM DA ESCOLHA: audio primeiro, tamanho depois.
  # Dublado sempre ganha de legendado - o NoviPlay e' dublado. O "informa
  # tamanho" so desempata ENTRE LINKS DO MESMO AUDIO, porque sem Content-Length
  # o player do app tem dificuldade. Antes o tamanho vinha antes do audio e o
  # Werewolves acabou em ingles: os 2 dublados nao informavam tamanho e o
  # legendado informava, entao ele vencia. Content-Length e' problema de um
  # arquivo; audio em ingles e' problema de todo cliente.
  $bons = @()
  foreach ($c in $r) {
  $v = Test-StreamAlive $c -SemCache:$SemTudo
  if ($v -and $global:FSVeredito -eq 'ok') { $bons += $c }
  }
  if ($bons.Count -gt 0) {
  $melhorAudio = 99
  foreach ($c in $bons) { $a = Get-FSAudioRank $c; if ($a -lt $melhorAudio) { $melhorAudio = $a } }
  foreach ($c in $bons) {
  if ((Get-FSAudioRank $c) -ne $melhorAudio) { continue }
  $hd = Get-StreamProbeHeaders $c
  if (Test-LinkInformaTamanho ([string]$c.url) $hd) { return $c }
  }
  return $bons[0]
  }
  $incerto = $null
  foreach ($c in $r) {
  if ((Test-StreamAlive $c -SemCache:$SemTudo) -and -not $incerto) { $incerto = $c }
  }
  # nenhum link entregou video, mas o link que ja estava no catalogo entrega:
  # mantem o que funciona em vez de trocar por um link morto.
  if (-not [string]::IsNullOrWhiteSpace($urlAtual) -and (Test-StreamAlive ([PSCustomObject]@{ url = $urlAtual }) -SemCache:$SemTudo)) {
  return $null
  }
  if ($incerto) { return $incerto }
  return $r[0]
  }

function Get-FSAudio($s) {
  $t = [string]$s.title
  $lbl = ''
  if ($t -match 'Legendado') {
    if ($t -match 'Portugu') { $lbl = 'Legendado PT-BR' }
    elseif ($t -match 'Ingl') { $lbl = 'Legendado EN' }
    else { $lbl = 'Legendado' }
  } elseif ($t -match 'Portugu') {
    $lbl = 'Dublado PT-BR'
  } elseif ($t -match 'Espa') {
    $lbl = 'Espanhol'
  } elseif ($t -match 'Ingl') {
    $lbl = 'Ingles'
  }
  return $lbl
}

function Search-FSNames([string]$q) {
  $out = @()
  foreach ($type in @('movie','series')) {
    $u = "https://v3-cinemeta.strem.io/catalog/$type/top/search=" + [Uri]::EscapeDataString($q) + '.json'
    $r = Invoke-FSJson $u
    if ($r -and $r.metas) {
      foreach ($m in $r.metas) {
        $yr = if ($m.releaseInfo) { $m.releaseInfo } else { '????' }
        $out += [PSCustomObject]@{
          Type = $type; Id = [string]$m.id; Name = [string]$m.name
          Year = $yr; Poster = [string]$m.poster
          Display = ('[{0}] {1} ({2})  {3}' -f $type.ToUpper(), $m.name, $yr, $m.id)
        }
      }
    }
  }
  return $out
}

function Read-FrostReg {
  $out = @()
  if (-not (Test-Path -LiteralPath $FrostFile)) { return $out }
  foreach ($l in [IO.File]::ReadAllLines($FrostFile, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -lt 3) { continue }
    $out += [PSCustomObject]@{ Nome = $p[0]; Type = $p[1]; Id = $p[2]; Season = $(if ($p.Count -ge 4) { $p[3] } else { '' }) }
  }
  return $out
}

function Write-FrostReg($list) {
  $sb = New-Object System.Collections.Generic.List[string]
  foreach ($r in $list) {
    $line = "$($r.Nome)|$($r.Type)|$($r.Id)"
    if ($r.Season) { $line += "|$($r.Season)" }
    $sb.Add($line)
  }
  $body = if ($sb.Count -gt 0) { ($sb -join "`r`n") } else { '' }
  [IO.File]::WriteAllText($FrostFile, $body, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------- FUTURO LANCAMENTOS (fila de espera) ----------------
# O usuario escolhe um filme/serie na aba FrostStream e clica em
# "FUTURO LANCAMENTOS". O item NAO entra no channels.np na hora: fica na
# fila (futuro.np) e e a atualizacao automatica que volta a
# tentar. Quando o addon devolve o stream, o item entra no channels.np e o
# noviplay.json vai para o GitHub no fim da mesma atualizacao. O que entrou
# sai da fila; o que o addon ainda nao tem continua nela para a proxima atualizacao.

function Read-FuturoQueue {
  $out = @()
  if (-not (Test-Path -LiteralPath $FuturoFile)) { return $out }
  foreach ($l in [IO.File]::ReadAllLines($FuturoFile, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -lt 3) { continue }
    $tipo   = [string]$p[1]
    $season = $(if ($p.Count -ge 4) { [string]$p[3] } else { '' })
    $epIni  = $(if ($p.Count -ge 5) { [string]$p[4] } else { '0' })
    $epFim  = $(if ($p.Count -ge 6) { [string]$p[5] } else { '0' })
    $poster = $(if ($p.Count -ge 7) { [string]$p[6] } else { '' })
    $quando = $(if ($p.Count -ge 8) { [string]$p[7] } else { '' })
    $cat    = $(if ($p.Count -ge 9) { [string]$p[8] } else { '' })
    $faixa = 'filme'
    if ($tipo -eq 'series') {
      $nIni = 1; $nFim = 0
      [void][int]::TryParse($epIni, [ref]$nIni)
      [void][int]::TryParse($epFim, [ref]$nFim)
      if ($nIni -lt 1) { $nIni = 1 }
      if ((-not $season) -or $season -eq '*') {
        if ($nFim -ge 1) { $faixa = "T*  E$nIni..E$nFim" } else { $faixa = 'todas as temporadas' }
      } else {
        if ($nFim -ge 1) { $faixa = "T$season  E$nIni..E$nFim" } else { $faixa = "T$season  (todos os episodios)" }
      }
    }
    $out += [PSCustomObject]@{
      Nome = [string]$p[0]; Tipo = $tipo; Id = [string]$p[2]; Season = $season
      EpIni = $epIni; EpFim = $epFim; Poster = $poster; Quando = $quando; Cat = $cat
      Display = ('[{0}] {1}   {2}   {3}   (na fila desde {4})' -f $tipo.ToUpper(), [string]$p[0], $faixa, $(if ($cat) { "[$cat]" } else { '' }), $(if ($quando) { $quando } else { 'hoje' }))
    }
  }
  return $out
}

function Write-FuturoQueue($list) {
  $sb = New-Object System.Collections.Generic.List[string]
  foreach ($r in $list) {
    $sb.Add("$($r.Nome)|$($r.Tipo)|$($r.Id)|$($r.Season)|$($r.EpIni)|$($r.EpFim)|$($r.Poster)|$($r.Quando)|$($r.Cat)")
  }
  $body = if ($sb.Count -gt 0) { ($sb -join "`r`n") } else { '' }
  [IO.File]::WriteAllText($FuturoFile, $body, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-FuturoItem($it, [int]$season, [int]$epIni, [int]$epFim, [string]$cat = '') {
  if ($null -eq $it -or -not $it.Id) { return 'Selecione um resultado da busca antes de clicar em FUTURO LANCAMENTOS.' }
  $fila = @(Read-FuturoQueue)
  $seasonTxt = ''; $eIni = '0'; $eFim = '0'
  if ($it.Type -eq 'series') {
    if ($season -ge 1) { $seasonTxt = [string]$season } else { $seasonTxt = '*' }
    if ($epFim -ge 1 -and $epIni -ge 1 -and $epFim -ge $epIni) { $eIni = [string]$epIni; $eFim = [string]$epFim }
  }
  foreach ($r in $fila) {
    if ($r.Tipo -eq $it.Type -and $r.Id -eq $it.Id -and $r.Season -eq $seasonTxt) {
      return "Esse titulo JA esta na fila. Itens na fila: $($fila.Count)."
    }
  }
  if ($it.Type -ne 'series') { $cat = '' }
  $fila += [PSCustomObject]@{
    Nome = [string]$it.Name; Tipo = [string]$it.Type; Id = [string]$it.Id
    Season = $seasonTxt; EpIni = $eIni; EpFim = $eFim; Poster = [string]$it.Poster
    Quando = (Get-Date -Format 'dd/MM HH:mm'); Cat = [string]$cat
  }
  Write-FuturoQueue $fila
  $msg = "NA FILA: $($it.Name)."
  if ($it.Type -eq 'series') {
    if ($cat) { $msg += " Categoria: $cat." }
    if ($seasonTxt -eq '*') { $msg += ' Todas as temporadas e episodios.' }
    elseif ($eFim -ne '0') { $msg += " Temporada $seasonTxt, episodios $eIni ate $eFim." }
    else { $msg += " Temporada $seasonTxt, todos os episodios." }
  }
  $msg += " A proxima atualizacao automatica ($(Get-FSIntervaloTexto)) tenta incluir e manda ao GitHub. Total na fila: $($fila.Count)."
  return $msg
}

function Remove-FuturoItem($it) {
  if ($null -eq $it) { return 'Selecione um item da fila.' }
  $fila = @(Read-FuturoQueue)
  $rest = @()
  $achou = $false
  foreach ($r in $fila) {
    if ((-not $achou) -and $r.Tipo -eq $it.Tipo -and $r.Id -eq $it.Id -and $r.Season -eq $it.Season) { $achou = $true; continue }
    $rest += $r
  }
  if (-not $achou) { return 'Esse item nao esta na fila.' }
  Write-FuturoQueue $rest
  return "Removido da fila: $($it.Nome). Restam $($rest.Count) item(ns)."
}

# Episodios que o Cinemeta ja lista da serie (1 requisicao so). Serve para
# saber o que procurar quando o usuario deixa a temporada/faixa em branco.
function Get-FSMetaEps([string]$id) {
  $key = "meta/series/$id"
  if ($global:FSCache.ContainsKey($key)) { return $global:FSCache[$key] }
  $saida = @()
  $r = Invoke-FSJson ("https://v3-cinemeta.strem.io/meta/series/" + $id + ".json")
  if ($r -and $r.meta -and $r.meta.videos) {
    foreach ($v in @($r.meta.videos)) {
      $se = 0; $ep = 0
      [void][int]::TryParse([string]$v.season, [ref]$se)
      [void][int]::TryParse([string]$v.episode, [ref]$ep)
      if ($se -lt 1 -or $ep -lt 1) {
        $tl = Parse-EpLabel ([string]$v.id)
        if ($tl.Ok) { $se = $tl.Season; $ep = $tl.Ep }
      }
      if ($se -ge 1 -and $ep -ge 1) { $saida += [PSCustomObject]@{ Season = $se; Ep = $ep } }
    }
  }
  $global:FSCache[$key] = $saida
  return $saida
}

# Lista de episodios a procurar para o item da fila (S1E1, S1E2, ...).
function Get-FutureTargets($it) {
  $alvos = @()
  $season = 0; $epIni = 0; $epFim = 0
  [void][int]::TryParse([string]$it.Season, [ref]$season)
  [void][int]::TryParse([string]$it.EpIni, [ref]$epIni)
  [void][int]::TryParse([string]$it.EpFim, [ref]$epFim)
  if ($epIni -lt 1) { $epIni = 1 }
  if ($season -ge 1 -and $epFim -ge $epIni) {
    for ($e = $epIni; $e -le $epFim; $e++) { $alvos += [PSCustomObject]@{ Season = $season; Ep = $e } }
    return $alvos
  }
  foreach ($v in (Get-FSMetaEps $it.Id)) {
    if ($season -ge 1 -and $v.Season -ne $season) { continue }
    if ($epFim -ge 1 -and $v.Ep -gt $epFim) { continue }
    $alvos += $v
  }
  return $alvos
}

function Test-FutureMovieLine([string[]]$lines, [string]$nome) {
  foreach ($l in $lines) {
    if ($l -notmatch '\|\|\|filme\|') { continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if (Is-FenixLine $p) { continue }
    if (FSMatchName $p[0] $nome) { return $true }
  }
  return $false
}

function Test-FutureEpLine([string[]]$lines, [string]$serie, [string]$label) {
  foreach ($l in $lines) {
    if ($l -notmatch '\|\|\|serie\|') { continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -lt 7) { continue }
    if (Is-FenixLine $p) { continue }
    if ((Normalize-Text $p[5]) -eq (Normalize-Text $serie) -and (Normalize-Text $p[6]) -eq (Normalize-Text $label)) { return $true }
  }
  return $false
}

# Escolhe o stream da mesma forma do painel, mas com uma saida de emergencia:
# quando o addon devolve UM stream so, o seletor do painel (que nao foi mexido)
# devolve vazio, e um lancamento novo e exatamente o caso de um stream unico.
function Select-FutureStream($arr, [string]$titulo) {
  $a = @($arr)
  if ($a.Count -eq 0) { return $null }
  $s = Pick-FSStream $a $titulo
  if ($s) { return $s }
  if ($a.Count -eq 1) { return $a[0] }
  return $null
}

# Grava a categoria escolhida nas linhas da serie que JA estao no channels.np
# (inclusive as que vieram do Fenix). Assim da para categorizar uma serie que
# foi cadastrada antes de a opcao de categoria existir. Devolve as LINHAS
# (usa o resultado) e quantas mudaram.
function Set-FutureEpCat([string[]]$lines, [string]$serie, [string]$cat) {
  $saida = $lines
  $n = 0
  if ($cat) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -notmatch '\|\|\|serie\|') { continue }
      $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -lt 7) { continue }
      if ((Normalize-Text $p[5]) -ne (Normalize-Text $serie)) { continue }
      if ($p.Count -ge 10 -and (Normalize-Text $p[9]) -eq (Normalize-Text $cat)) { continue }
      $novo = @(); for ($k = 0; $k -lt $p.Count; $k++) { $novo += $p[$k] }
      while ($novo.Count -lt 10) { $novo += '' }
      $novo[9] = $cat
      $saida[$i] = $novo -join '|'
      $n++
    }
  }
  return [PSCustomObject]@{ Lines = $saida; Changed = $n }
}

# Roda dentro da atualizacao automatica (e no botao PROCESSAR AGORA da aba).
# So adiciona o que ainda NAO esta no channels.np: o que ja entrou fica
# sob controle do Update-AllFS/Fenix, que continua renovando o link todo dia.
function Process-FuturoQueue([int]$Minutos = 12) {
  $fila = @(Read-FuturoQueue)
  if ($fila.Count -eq 0) {
    return [PSCustomObject]@{ Added = 0; Itens = 0; Done = 0; Pendentes = 0; Msg = 'Futuros lancamentos: fila vazia (nada a fazer).' }
  }
  if (-not (Test-Path -LiteralPath $ChannelsPath)) {
    return [PSCustomObject]@{ Added = 0; Itens = $fila.Count; Done = 0; Pendentes = $fila.Count; Msg = "Futuros lancamentos: $($fila.Count) item(ns) na fila, mas o channels.np nao foi encontrado." }
  }
  $limite = (Get-Date).AddMinutes($Minutos)
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $done = @(); $pending = @(); $added = 0; $catsGravadas = 0
  foreach ($it in $fila) {
    if ((Get-Date) -ge $limite) { $pending += $it; continue }
    if ($it.Tipo -eq 'movie') {
      if (Test-FutureMovieLine $lines $it.Nome) { $done += $it; continue }
      $s = Select-FutureStream (Get-FSStreams 'movie' $it.Id) $it.Nome
      if (-not $s) { $s = Select-FutureStream (Get-FenixRescue 'movie' $it.Id) $it.Nome }
      if (-not $s) { $pending += $it; continue }
      $lbl = Get-FSAudio $s
      $nome = $it.Nome; if ($lbl) { $nome = "$($it.Nome) ($lbl)" }
      $lines += "$nome|$([string]$s.url)|||filme|||$($it.Poster)"
      $added++
      $done += $it
      continue
    }
    $alvos = Get-FutureTargets $it
    if ($alvos.Count -eq 0) { $pending += $it; continue }
    $cat = [string]$it.Cat
    $setCat = Set-FutureEpCat $lines $it.Nome $cat
    $lines = $setCat.Lines
    $catsGravadas += $setCat.Changed
    $addEp = 0; $errosEp = 0
    foreach ($a in $alvos) {
      $label = "T$($a.Season)E$($a.Ep)"
      if (Test-FutureEpLine $lines $it.Nome $label) { continue }
      if ((Get-Date) -ge $limite) { break }
      $rid = "$($it.Id):$($a.Season):$($a.Ep)"
      $s = Select-FutureStream (Get-FSStreams 'series' $rid) $it.Nome
      if (-not $s) { $s = Select-FutureStream (Get-FenixRescue 'series' $rid) $it.Nome }
      if (-not $s) {
        # O addon ainda nao tem este episodio: para de martelar depois de 6
        # seguidos e deixa o item na fila para a proxima atualizacao.
        $errosEp++
        if ($errosEp -ge 6) { break }
        continue
      }
      $errosEp = 0
      $lbl = Get-FSAudio $s
      $base = $it.Nome; if ($lbl) { $base = "$($it.Nome) ($lbl)" }
      # 10o campo = categoria da serie (o app usa para a coluna da esquerda).
      $lines += "$base $label|$([string]$s.url)|||serie|$($it.Nome)|$label|$($it.Poster)||$cat"
      $addEp++; $added++
    }
    $sobrou = $false
    foreach ($a in $alvos) {
      $existeEp = Test-FutureEpLine $lines $it.Nome "T$($a.Season)E$($a.Ep)"
      if (-not $existeEp) { $sobrou = $true; break }
    }
    if ($sobrou) { $pending += $it } else { $done += $it }
  }
  if ($added -gt 0 -or $catsGravadas -gt 0) { Backup-Channels | Out-Null; Write-File $lines }
  if ($done.Count -gt 0) {
    # registro no froststream.np: e o que mantem o link sempre renovado
    $reg = @(Read-FrostReg)
    $mexeuReg = $false
    foreach ($it in $done) {
      $existe = $false
      foreach ($r in $reg) { if ($r.Type -eq $it.Tipo -and $r.Id -eq $it.Id) { $existe = $true; break } }
      if ($existe) { continue }
      $reg += [PSCustomObject]@{ Nome = $it.Nome; Type = $it.Tipo; Id = $it.Id; Season = $(if ($it.Tipo -eq 'series') { '*' } else { '' }) }
      $mexeuReg = $true
    }
    if ($mexeuReg) { Write-FrostReg $reg }
  }
  Write-FuturoQueue $pending
  Read-Data
  $nomes = @(); foreach ($it in $done) { $nomes += $it.Nome }
  $esperando = @(); foreach ($it in $pending) { $esperando += $it.Nome }
  $msg = "Futuros lancamentos: $($done.Count) concluido(s), $added linha(s) nova(s) em canais, $($pending.Count) continuam na fila."
  if ($catsGravadas -gt 0) { $msg += " Categoria gravada em $catsGravadas episodio(s) que ja estavam no canal." }
  if ($nomes.Count -gt 0) { $msg += " Entrou: " + ($nomes -join ', ') + '.' }
  if ($esperando.Count -gt 0) { $msg += " O addon ainda nao tem: " + ($esperando -join ', ') + '.' }
  return [PSCustomObject]@{ Added = $added; Itens = $fila.Count; Done = $done.Count; Pendentes = $pending.Count; Msg = $msg }
}

function Parse-EpLabel([string]$eps) {
  if ($eps -match '^[tT](\d+)[eE](\d+)$') { return [PSCustomObject]@{ Season = [int]$Matches[1]; Ep = [int]$Matches[2]; Ok = $true } }
  if ($eps -match '^[sS](\d+)[eE](\d+)$') { return [PSCustomObject]@{ Season = [int]$Matches[1]; Ep = [int]$Matches[2]; Ok = $true } }
  return [PSCustomObject]@{ Season = 0; Ep = 0; Ok = $false }
}

function FSMatchName([string]$candidate, [string]$base) {
  $c = Normalize-Text $candidate
  $b = Normalize-Text $base
  if ($c -eq $b) { return $true }
  if ($c.StartsWith($b)) {
    $rest = $c.Substring($b.Length).TrimStart()
    if ($rest -eq '' -or $rest.StartsWith('(') -or $rest.StartsWith('[')) { return $true }
  }
  return $false
}

function Backup-Channels {
  $dest = Join-Path $NoviplayDir 'channels.np.backup'
  Copy-Item -LiteralPath $ChannelsPath -Destination $dest -Force
  return 'channels.np.backup'
}

# ---------------- ESTADO DA ULTIMA ATUALIZACAO (painel + autoupdate) ----------------

$EstadoFile = Join-Path $NoviplayDir 'autoupd.status.json'
$script:EstadoInicio = $null

function Write-Estado([string]$status, [string]$msg = '', [int]$upd = 0, [int]$found = 0, [int]$falhas = 0, [array]$items = @(), [string]$fase = '') {
  if (-not $script:EstadoInicio) { $script:EstadoInicio = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
  $e = [ordered]@{
    inicio     = $script:EstadoInicio
    pulso      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    fim        = $(if ($status -eq 'rodando') { '' } else { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') })
    status     = $status
    pid        = $PID
    atualizados = $upd
    encontrados = $found
    falhas     = $falhas
    msg        = $msg
    fase       = $fase
    itens      = @($items)
  }
  try {
    [IO.File]::WriteAllText($EstadoFile, ($e | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Ler-Estado {
  if (-not (Test-Path -LiteralPath $EstadoFile)) { return $null }
  try { return (Get-Content -LiteralPath $EstadoFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Remove-EstadoItem($o) {
  $est = Ler-Estado
  if (-not $est) { return }
  $rest = @()
  if ($est.itens) {
    foreach ($i in @($est.itens)) {
      if (([string]$i.src -ne [string]$o.src) -or ([string]$i.tipo -ne [string]$o.tipo) -or ([string]$i.nome -ne [string]$o.nome) -or ([string]$i.ep -ne [string]$o.ep)) { $rest += $i }
    }
  }
  $e = [ordered]@{
    inicio     = $est.inicio
    pulso      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    fim        = $est.fim
    status     = $est.status
    atualizados = $est.atualizados
    encontrados = $est.encontrados
    falhas     = $rest.Count
    msg        = $est.msg
    fase       = $est.fase
    itens      = @($rest)
  }
  try {
    [IO.File]::WriteAllText($EstadoFile, ($e | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Retentar-ItemFalha($f) {
  if (-not $f) { return 'sem item.' }
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return 'channels.np nao encontrado' }
  $src = [string]$f.src
  $isSerie = ([string]$f.tipo -eq 'serie')
  $serieNome = [string]$f.serie
  $ep = [string]$f.ep
  $nome = [string]$f.nome
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $reg = if ($src -eq 'Fenix') { Read-FenixReg } else { Read-FrostReg }
  $rec = $null
  foreach ($r in $reg) {
    if ($isSerie) {
      if ($r.Type -eq 'series' -and (Normalize-Text $r.Nome) -eq (Normalize-Text $serieNome)) { $rec = $r; break }
    } else {
      if ($r.Type -eq 'movie' -and (FSMatchName $nome $r.Nome)) { $rec = $r; break }
    }
  }
  if (-not $rec) { return "sem registro no addon para: $nome" }
  $idx = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if (-not (Test-VodLine $lines[$i])) { continue }
    $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
    if ($src -eq 'Frost') { if (Is-FenixLine $p) { continue } } else { if (-not (Is-FenixLine $p)) { continue } }
    if ($isSerie) {
      if ($p.Count -ge 7 -and (Normalize-Text $p[5]) -eq (Normalize-Text $serieNome) -and $p[6] -eq $ep) { $idx = $i; break }
    } else {
      if (FSMatchName $p[0] $nome) { $idx = $i; break }
    }
  }
  if ($idx -lt 0) { return "linha nao encontrada para: $nome $ep" }
  $p = $lines[$idx].Split([char]'|', [System.StringSplitOptions]::None)
  $s = $null
  if ($isSerie) {
    $tl = Parse-EpLabel $p[6]
    if (-not $tl.Ok) { return "episodio nao reconhecido: $($p[6])" }
    $rid = "$($rec.Id):$($tl.Season):$($tl.Ep)"
    if ($src -eq 'Frost') { $s = Pick-FSStream (Get-FSStreams 'series' $rid) $rec.Nome } else { $s = Pick-FenixStream (Get-FenixStreams 'series' $rid) $rec.Nome }
  } else {
    if ($src -eq 'Frost') { $s = Pick-FSStream (Get-FSStreams 'movie' $rec.Id) $rec.Nome } else { $s = Pick-FenixStream (Get-FenixStreams 'movie' $rec.Id) $rec.Nome }
  }
  if (-not $s) { return "sem stream no addon para: $nome $ep" }
  $url = [string]$s.url
  if ($p[1] -eq $url) { return "ja estava atualizado: $nome $ep" }
  $p[1] = $url
  $lines[$idx] = $p -join '|'
  Backup-Channels | Out-Null
  Write-File $lines
  Read-Data
  return "OK atualizado: $nome $ep"
}

function Register-FSMovie($it) {
  if ($it.Type -ne 'movie') { return "Selecione um resultado do tipo MOVIE. (Tipo atual: $($it.Type))" }
  $arr = Get-FSStreams 'movie' $it.Id
  $s = Pick-FSStream $arr $it.Name
  if (-not $s) { return "Sem stream disponivel no FrostStream para: $($it.Name)" }
  $url = [string]$s.url
  $qual = [string]$s.name
  $lbl = Get-FSAudio $s
  $nome = $it.Name; if ($lbl) { $nome = "$($it.Name) ($lbl)" }

  $conf = [System.Windows.Forms.MessageBox]::Show(
    "Cadastrar/atualizar o filme:" + [Environment]::NewLine + "  $nome ($($it.Year))" + [Environment]::NewLine +
    'Stream: ' + $qual + ' / Audio: ' + $(if ($lbl) { $lbl } else { 'indefinido' }) + [Environment]::NewLine + [Environment]::NewLine + $url,
    'FrostStream - confirmar', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return 'Cancelado.' }

  $ts = Backup-Channels
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $target = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch '\|\|\|filme\|') { continue }
    $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
    if (FSMatchName $p[0] $it.Name) { $target = $i; break }
  }
  if ($target -ge 0) {
    $p = $lines[$target].Split([char]'|', [System.StringSplitOptions]::None)
    $p[1] = $url
    $p[0] = $nome
    if ($p.Count -ge 8 -and [string]::IsNullOrWhiteSpace($p[7]) -and $it.Poster) { $p[7] = $it.Poster }
    $lines[$target] = $p -join '|'
  } else {
    $lines += "$nome|$url|||filme|||$($it.Poster)"
    Add-NovTitulo 'movie' $it.Name
  }
  Write-File $lines

  $reg = Read-FrostReg
  if (-not ($reg | Where-Object { $_.Type -eq 'movie' -and $_.Id -eq $it.Id })) {
    $reg += [PSCustomObject]@{ Nome = $it.Name; Type = 'movie'; Id = $it.Id; Season = '' }
    Write-FrostReg $reg
  }
  Flush-AvisoAuto | Out-Null
  return "OK! Filme '$nome' gravado ($qual). Backup: channels.np.backup"
}

function Register-FSSeries($it, [int]$season, [int]$startEp, [int]$endEp, [string]$cat = '') {
  if ($it.Type -ne 'series') { return "Selecione um resultado do tipo SERIES. (Tipo atual: $($it.Type))" }
  if ($season -lt 1 -or $startEp -lt 1 -or $endEp -lt $startEp) { return 'Temporada >= 1, ep. inicial >= 1 e ep. final >= ep. inicial.' }
  $cat = [string]$cat

  $conf = [System.Windows.Forms.MessageBox]::Show(
    "Cadastrar a serie:" + [Environment]::NewLine + "  $($it.Name) ($($it.Year))" + [Environment]::NewLine +
    "Temporada $season, episodios $startEp ate $endEp." + $(if ($cat) { [Environment]::NewLine + "Categoria: $cat" } else { '' }) + [Environment]::NewLine + "Continuar?",
    'FrostStream - confirmar serie', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return 'Cancelado.' }

  $ts = Backup-Channels
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $added = 0; $fails = 0; $miss = @()
  for ($e = $startEp; $e -le $endEp; $e++) {
    $rid = "$($it.Id):${season}:$e"
    $arr = Get-FSStreams 'series' $rid
    $s = Pick-FSStream $arr $it.Name
    if (-not $s) { $fails++; $miss += "T${season}E${e}"; continue }
    $lbl = Get-FSAudio $s
    $label = "T${season}E${e}"
    $baseNome = $it.Name; if ($lbl) { $baseNome = "$($it.Name) ($lbl)" }
    $nome = "$baseNome $label"
    $target = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -notmatch '\|\|\|serie\|') { continue }
      $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -ge 7 -and (Normalize-Text $p[5]) -eq (Normalize-Text $it.Name) -and (Normalize-Text $p[6]) -eq $label) { $target = $i; break }
    }
    if ($target -ge 0) {
      $p = $lines[$target].Split([char]'|', [System.StringSplitOptions]::None)
      $p[1] = [string]$s.url
      $p[0] = $nome
      if ($p.Count -ge 8 -and [string]::IsNullOrWhiteSpace($p[7]) -and $it.Poster) { $p[7] = $it.Poster }
      if ($cat) {
        $novo = @()
        for ($k = 0; $k -lt $p.Count; $k++) { $novo += $p[$k] }
        while ($novo.Count -lt 10) { $novo += '' }
        $novo[9] = $cat
        $p = $novo
      }
      $lines[$target] = $p -join '|'
    } else {
      $lines += "$nome|$([string]$s.url)|||serie|$($it.Name)|$label|$($it.Poster)||$cat"
      Add-NovTitulo 'series' $it.Name
    }
    $added++
  }
  if ($added -eq 0) { return "Nenhum episodio encontrado para $($it.Name) T$season. Faltando: " + ($miss -join ', ') + ". Nada gravado." }
  Write-File $lines

  $reg = Read-FrostReg
  if (-not ($reg | Where-Object { $_.Type -eq 'series' -and $_.Id -eq $it.Id -and $_.Season -eq ([string]$season) })) {
    $reg += [PSCustomObject]@{ Nome = $it.Name; Type = 'series'; Id = $it.Id; Season = [string]$season }
    Write-FrostReg $reg
  }
  Flush-AvisoAuto | Out-Null
  $msg = "OK! $added episodios de '$($it.Name)' T$season gravados. Falhas: $fails"
  if ($miss.Count -gt 0) { $msg += " (faltando: " + ($miss -join ', ') + ")" }
  $msg += ". Backup: channels.np.backup"
  return $msg
}

function Add-FSAutoReg([string[]]$lines, [array]$reg) {
  $wanted = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  foreach ($l in $lines) {
    if ($l -match '\|\|\|filme\|') {
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -ge 5 -and $p[0] -and -not (Is-FenixLine $p)) { $k = Normalize-Text $p[0]; if (-not $wanted.ContainsKey($k)) { $wanted[$k] = 'movie' } }
    } elseif ($l -match '\|\|\|serie\|') {
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -ge 7 -and $p[5] -and -not (Is-FenixLine $p)) { $k = Normalize-Text $p[5]; if (-not $wanted.ContainsKey($k)) { $wanted[$k] = 'series' } }
    }
  }
  $has = @{}
  foreach ($r in $reg) { if ($r.Nome) { $has[(Normalize-Text $r.Nome)] = $true } }
  $added = 0
  foreach ($k in $wanted.Keys) {
    if ($has.ContainsKey($k)) { continue }
    $kind = $wanted[$k]
    $disp = $null
    foreach ($l in $lines) {
      if ($kind -eq 'movie' -and $l -notmatch '\|\|\|filme\|') { continue }
      if ($kind -eq 'series' -and $l -notmatch '\|\|\|serie\|') { continue }
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      $cand = $null
      if ($kind -eq 'movie') { $cand = $p[0] }
      elseif ($p.Count -ge 7) { $cand = $p[5] }
      if ($cand -and (Normalize-Text $cand) -eq $k) { $disp = $cand; break }
    }
    if (-not $disp) { continue }
    $sterm = $disp
    if ($sterm -match '^\s*(.+?)\s*\([^\)]*\)\s*$') { $sterm = $Matches[1] }
    $res = Search-FSNames $sterm | Where-Object { $_.Type -eq $kind } | Select-Object -First 1
    if (-not $res) { continue }
    $reg += [PSCustomObject]@{ Nome = $disp; Type = $kind; Id = $res.Id; Season = $(if ($kind -eq 'series') { '*' } else { '' }) }
    $has[$k] = $true
    $added++
  }
  if ($added -gt 0) { Write-FrostReg $reg }
  return $added
}

function Find-VodLineInBackups([string]$tipo, [string]$nome) {
  $pat = if ($tipo -eq 'filme') { '\|\|\|filme\|' } else { '\|\|\|serie\|' }
  $single = Join-Path $NoviplayDir 'channels.np.backup'
  if (-not (Test-Path -LiteralPath $single)) {
    if ($tipo -eq 'filme') { return $null }
    return @()
  }
  $backups = @(Get-Item -LiteralPath $single)
  foreach ($b in $backups) {
    try { $txt = [IO.File]::ReadAllText($b.FullName, [Text.Encoding]::UTF8) } catch { continue }
    $hits = @()
    foreach ($l in ($txt -split "`r?`n")) {
      if (-not $l -or $l -notmatch $pat) { continue }
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($tipo -eq 'filme' -and (FSMatchName $p[0] $nome)) { $hits += $l }
      elseif ($tipo -eq 'serie' -and $p.Count -ge 6 -and (Normalize-Text $p[5]) -eq (Normalize-Text $nome)) { $hits += $l }
    }
    if ($hits.Count -gt 0) {
      if ($tipo -eq 'filme') { return $hits[0] }
      return $hits
    }
  }
  if ($tipo -eq 'filme') { return $null }
  return @()
}

function Repair-MissingVods([string[]]$lines, [array]$reg) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) { $out.Add($l) }
  $added = 0
  foreach ($r in $reg) {
    $exists = $false
    if ($r.Type -eq 'movie') {
      foreach ($l in $out) {
        if ($l -notmatch '\|\|\|filme\|') { continue }
        $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
        if (FSMatchName $p[0] $r.Nome) { $exists = $true; break }
      }
      if (-not $exists) {
        $src = Find-VodLineInBackups 'filme' $r.Nome
        if ($src -and -not $out.Contains($src)) { $out.Add($src); $added++ }
      }
    } else {
      foreach ($l in $out) {
        if ($l -notmatch '\|\|\|serie\|') { continue }
        $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
        if ($p.Count -ge 6 -and (Normalize-Text $p[5]) -eq (Normalize-Text $r.Nome)) { $exists = $true; break }
      }
      if (-not $exists) {
        foreach ($src in (Find-VodLineInBackups 'serie' $r.Nome)) {
          if ($src -and -not $out.Contains($src)) { $out.Add($src); $added++ }
        }
      }
    }
  }
  return [PSCustomObject]@{ Added = $added; Lines = $out.ToArray() }
}

# RESGATE: quando o Frost nao devolve NENHUM stream para um episodio (ele falha
# de forma intermitente, devolvendo "streams": []), procuramos no addon do Fenix
# antes de desistir. E o que garante o lema do NoviPlay: nenhum filme e nenhuma
# serie ficam sem link enquanto existir alguma fonte com o episodio.
function Get-FenixRescue([string]$type, [string]$rid) {
  $key = "rescue/$type/$rid"
  if ($global:FSCache.ContainsKey($key)) { return $global:FSCache[$key] }
  $u = "$FenixBase/stream/$type/$rid.json"
  $arr = @()
  for ($t = 1; $t -le 3; $t++) {
    $r = Invoke-FSJson $u
    if ($r -and $r.streams) { $arr = @($r.streams); break }
    if ($t -lt 3) { Start-Sleep -Milliseconds (1000 * $t) }
  }
  $global:FSCache[$key] = $arr
  return $arr
}

  # ================= SERIE FORA DO ADDON: ESCALONAMENTO =================
  # Os addons giram o catalogo: um titulo sai de um dia para o outro e os
  # links antigos (que sao de cache, com token) morrem junto. Sem isso, a cada
  # rodada o painel gastava ~7 s por episodio tentando um titulo que nao
  # existe mais - e a serie aparecia na tela sem abrir nada.
  #
  # Aqui: serie que nao devolve NENHUM link entra em "fria", com espera que
  # dobra a cada tentativa. 1a vez espera 1 h, depois 2 h, 4 h, 8 h (teto).
  # A serie some da lista do app enquanto esta fria e volta sozinha se o addon
  # trazela de volta.
  $global:SeriesFria = $null
  function Get-SeriesFria {
    if ($null -ne $global:SeriesFria) { return $global:SeriesFria }
    $global:SeriesFria = @{}
    $f = Join-Path $NoviplayDir 'series_frias.txt'
    if (Test-Path -LiteralPath $f) {
      foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) {
        if ($l.Trim() -eq '') { continue }
        $q = $l.Split([char]'|')
        if ($q.Count -ge 3) {
          $prox = [datetime]::MinValue
          if ([datetime]::TryParse($q[2], [ref]$prox)) { $global:SeriesFria[$q[0]] = [PSCustomObject]@{ Nome=$q[1]; Tent=([int]$q[3]); Prox=$prox } }
        }
      }
    }
    return $global:SeriesFria
  }
  function Save-SeriesFria {
    $f = Join-Path $NoviplayDir 'series_frias.txt'
    $out = New-Object System.Collections.Generic.List[string]
    $corte = (Get-Date).AddDays(-30)
    foreach ($kv in (Get-SeriesFria).GetEnumerator()) {
      if ($kv.Value.Prox -lt $corte) { continue }
      $out.Add($kv.Key + '|' + $kv.Value.Nome + '|' + $kv.Value.Prox.ToString('yyyy-MM-dd HH:mm:ss') + '|' + $kv.Value.Tent)
    }
    try { [IO.File]::WriteAllLines($f, $out, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    Write-SeriesFriasRelatorio
  }

  # Relatorio legivel: para o cliente saber o que esta fora e quando volta a ser
  # procurado. Ele confere no Stremio se o titulo voltou e, se voltou, roda
  # -Rechecar para nao esperar a hora marcada.
  function Write-SeriesFriasRelatorio {
    $f = Join-Path $NoviplayDir 'series_frias_RELATORIO.txt'
    $c = Get-SeriesFria
    $sb = New-Object System.Collections.Generic.List[string]
    $sb.Add('DIAGNOSTICO: TITULOS SEM LINK NA ULTIMA RODADA')
    $sb.Add('O congelamento foi desligado: nada e mais escondido do app.')
    $sb.Add('O que esta aqui NAO some do catalogo - fica so como registro do que')
    $sb.Add('o add-on ainda nao devolveu, para voce saber o que falha.')
    $sb.Add('Atualizado em: ' + (Get-Date -Format 'dd/MM/yyyy HH:mm'))
    $sb.Add('')
    if ($c.Count -eq 0) {
      $sb.Add('Nenhum titulo sem link. Tudo em dia.')
    } else {
      $sb.Add(('TITULO'.PadRight(36) + 'TENTATIVA'.PadRight(11) + 'PROXIMA'.PadRight(14) + 'SITUACAO'))
      $sb.Add(('-' * 78))
      foreach ($kv in ($c.GetEnumerator() | Sort-Object { $_.Value.Prox })) {
        $faltam = ($kv.Value.Prox - (Get-Date)).TotalHours
        $sit = if ($faltam -gt 0) { 'daqui a ' + [math]::Round($faltam * 60, 0) + ' min' } else { 'PODE checar agora' }
        $sb.Add($kv.Value.Nome.PadRight(36) + ([string]$kv.Value.Tent).PadRight(11) + $kv.Value.Prox.ToString('dd/MM HH:mm').PadRight(14) + $sit)
      }
      $sb.Add('')
      $sb.Add('Todos sao re-sondados a cada ' + (Get-FSRodadaMin) + ' min (Space, DNSPlay, Nova).')
      $sb.Add('')
      $sb.Add('Para forcar a checagem de um titulo especifico:')
      $sb.Add('  Atualizar_Filmes.ps1 -Rechecar')
    }
    try { [IO.File]::WriteAllLines($f, $sb, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }
  # Marca/renova a espera. O objetivo e SEMPRE pular 1 atualizacao e checar de
  # novo na seguinte, independente de que hora dentro da janela a deteccao
  # aconteceu. O intervalo da atualizacao vem da tarefa agendada (1 h), entao a
  # proxima checagem e sempre a primeira marca DEPOIS do instante atual.
  #   detectou 12:35 -> pula 13:05 -> checa 14:05 (de 1 em 1 hora)
  #   detectou 12:05 -> pula 13:05 -> checa 14:05 (de 1 em 1 hora)
  # Se voltar a funcionar, a proxima checagem bem-sucedida limpa o registro.
  # ATENCAO: o intervalo de 30 min e' lido da propria tarefa agendada, para
  # acompanhar de forma automatica caso o intervalo mude no futuro.
  # Intervalo real da atualizacao automatica, lido da propria tarefa agendada.
  # Aceita PT1H e PT30M (o formato muda conforme o valor), para o painel nunca
  # exibir um intervalo diferente do que esta realmente rodando.
  function Get-FSIntervaloMin {
    $min = 60
    try {
      $xml = Export-ScheduledTask -TaskName (Get-FSTarefaNome) -ErrorAction Stop
      if ($xml -match '<Interval>PT(\d+)H</Interval>') { $min = [int]$Matches[1] * 60 }
      elseif ($xml -match '<Interval>PT(\d+)M</Interval>') { $min = [int]$Matches[1] }
    } catch { }
    if ($min -lt 5) { $min = 5 }
    return $min
  }
  # Texto curto do intervalo, usado nos rotulos do painel.
  function Get-FSIntervaloTexto {
    $m = Get-FSIntervaloMin
    if ($m -eq 60) { return 'de 1 em 1 hora' }
    if ($m -ge 60) { return 'a cada ' + [int]($m / 60) + ' h' }
    return 'de ' + $m + ' em ' + $m + ' min'
  }
  # Espera entre a deteccao de um titulo sem link e a proxima checagem dele.
  # Anda marca a marca ate passar do instante atual: garante exatamente 1
  # rodada pulada, acompanhando o intervalo da tarefa se ele mudar.
  function Get-FSRodadaMin {
    $min = 60
    try {
      $xml = Export-ScheduledTask -TaskName (Get-FSTarefaNome) -ErrorAction Stop
      if ($xml -match '<Interval>PT(\d+)H</Interval>') { $min = [int]$Matches[1] * 60 }
      elseif ($xml -match '<Interval>PT(\d+)M</Interval>') { $min = [int]$Matches[1] }
    } catch { }
    if ($min -lt 5) { $min = 5 }
    return $min
  }
  function Set-SerieFria([string]$key, [string]$nome) {
    $c = Get-SeriesFria
    $tent = 1
    if ($c.ContainsKey($key)) { $tent = $c[$key].Tent + 1 }
    if ($tent -lt 1) { $tent = 1 }
    # Anda marca a marca ate passar do instante atual. Garante
    # exatamente 1 rodada pulada: a marca imediatamente seguinte.
    $step = Get-FSRodadaMin
    $prox = Get-Date
    do { $prox = $prox.AddMinutes($step) } while ($prox -le (Get-Date))
    $c[$key] = [PSCustomObject]@{ Nome=$nome; Tent=$tent; Prox=$prox }
  }
  function Clear-SerieFria([string]$key) {
    $c = Get-SeriesFria
    if ($c.ContainsKey($key)) { $c.Remove($key) }
  }
  function SerieEstaFria([string]$key) {
    $c = Get-SeriesFria
    if ($c.ContainsKey($key) -and $c[$key].Prox -gt (Get-Date)) { return $true }
    return $false
  }

  # ---------------------------------------------------------------------------
  # PROVEDOR TRAVADO POR TITULO
  # O usuario escolhe (na aba Congelamento) um provedor para um titulo, ex.:
  # The 100 -> Nova. A partir dai a atualizacao testa esse provedor PRIMEIRO e,
  # se ele responde, ja fica com o link e nao perde tempo testando os outros.
  # Se o provedor travado deixar de responder, cai para os demais e so assim
  # considera o titulo congelado. O arquivo e "Titulo|Provedor".
  # ---------------------------------------------------------------------------
  function Get-ProvTravado {
    $c = @{}
    $f = Join-Path $NoviplayDir 'prov_travado.txt'
    if (-not (Test-Path -LiteralPath $f)) { return $c }
    foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) {
      $q = $l.Split([char]'|')
      if ($q.Count -ge 2 -and $q[0] -and $q[1]) { $c[(Normalize-Text $q[0])] = $q[1].Trim() }
    }
    return $c
  }
  function Save-ProvTravado($c) {
    $f = Join-Path $NoviplayDir 'prov_travado.txt'
    $sb = New-Object System.Collections.Generic.List[string]
    foreach ($k in ($c.Keys | Sort-Object)) { $sb.Add("$k|$($c[$k])") }
    try { [IO.File]::WriteAllLines($f, $sb, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }
  function Set-ProvTravado([string]$titulo, [string]$prov) {
    $c = Get-ProvTravado
    $c[(Normalize-Text $titulo)] = $prov
    Save-ProvTravado $c
    $global:ProvLock = $c
  }
  function Clear-ProvTravado([string]$titulo) {
    $c = Get-ProvTravado
    $k = Normalize-Text $titulo
    if ($c.ContainsKey($k)) { $c.Remove($k); Save-ProvTravado $c; $global:ProvLock = $c }
  }
  function Load-ProvTravado { $global:ProvLock = Get-ProvTravado }

  # Rank de provedor ja considerando o provedor travado do titulo: o travado
  # vira 0 (sempre primeiro) e os outros ficam depois, sem perder a ordem antiga.
  function Get-FSProvRankComLock($s, [string]$Titulo) {
    $r = Get-FSProvRank $s
    $lock = ''
    if ($Titulo -and $global:ProvLock -and $global:ProvLock.Count -gt 0) {
      $k = Normalize-Text $Titulo
      if ($global:ProvLock.ContainsKey($k)) { $lock = [string]$global:ProvLock[$k] }
    }
    if ($lock) {
      if ((Get-StreamProvedor $s) -eq $lock) { return 0 }
      return $r + 4
    }
    return $r
  }

  # Deixa SO os streams do provedor pedido. Usado pelo botao "Atualizar" da aba
  # de Congelamento, para buscar o titulo direto naquele provedor.
  function Filter-FSByProvider($arr, [string]$prov) {
    $out = @()
    if ($null -eq $arr) { return $out }
    foreach ($s in $arr) { if ((Get-StreamProvedor $s) -eq $prov) { $out += $s } }
    return $out
  }

  # Chaves de congelamento. A chave E o proprio nome, para o construtor do JSON
  # conseguir reproduzi-la so olhando a linha do catalogo. Guarda o nome COMO
  # esta no catalogo (nao minusculo): o Normalize-Text e' so para comparar, e se
  # fosse usado aqui o titulo aparecia na aba escrito "the 100 T1".
  #   serie  -> "The 100 T1"  (uma chave por TEMPORADA)
  #   filme  -> "Scary Movie (Dublado PT-BR)"
  function Get-TemporadaChave([string]$serie, $season) {
    $n = 0; [void][int]::TryParse([string]$season, [ref]$n)
    if ($n -lt 1) { $n = 1 }
    return (([string]$serie).Trim() + ' T' + $n)
  }
  # Chave de congelamento de um EPISODIO: "The 100 T1E4". O congelamento e' por
  # episodio (nao por temporada) para que um unico episode sem link nao leve
  # junto os outros 12 que estao funcionando. A temporada so e marcada quando
  # NENHUM dos seus episodios tem link.
  function Get-EpisodioChave([string]$serie, $season, [string]$ep) {
    $n = 0; [void][int]::TryParse([string]$ep, [ref]$n)
    if ($n -lt 1) { $n = 1 }
    return ((Get-TemporadaChave $serie $season) + 'E' + $n)
  }
  function Get-FilmeChave([string]$filme) { return (([string]$filme).Trim()) }

  # Provedor travado deste titulo ('' se nenhum).
  function Get-ProvDoTitulo([string]$titulo) {
    if (-not $global:ProvLock) { Load-ProvTravado }
    if ($global:ProvLock.Count -eq 0) { return '' }
    $k = Normalize-Text $titulo
    if ($global:ProvLock.ContainsKey($k)) { return [string]$global:ProvLock[$k] }
    return ''
  }

  # ---------------------------------------------------------------------------
  # ATUALIZAR SO O QUE O USUARIO ESCOLHEU, NUM PROVEDOR SO
  # Chamado pela aba de Congelamento. Recebe as chaves selecionadas (no formato
  # "Nome T<n>" para temporada de serie, ou o nome do filme) e o provedor.
  # Para cada episodio da temporada escolhida busca stream e usa SO aquele
  # provedor. Se responder, grava o link, tira do congelamento e trava o
  # provedor no titulo, para as proximas atualizacoes irem direto nele.
  # ---------------------------------------------------------------------------
  function Update-FriosEscolhidos($escolhidas, [string]$prov) {
    if ($null -eq $escolhidas -or @($escolhidas).Count -eq 0) { return "Nada selecionado." }
    if (-not $prov) { return "Escolha um provedor (Space, DNSPlay ou Nova)." }
    Load-ProvTravado
    $reg = Read-FrostReg
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $rel = New-Object System.Collections.Generic.List[string]
    $oks = 0; $errosN = 0
    foreach ($item in @($escolhidas)) {
      # "Nome T<n>" = temporada de serie; sem T = filme
      $serie = $null; $temp = 0
      # "The 100 T1" = temporada inteira; "The 100 T1E4" = so aquele episodio
      $soEp = 0
      if ([string]$item -match '^(.*)\s+T(\d+)E(\d+)$') { $serie = $Matches[1].Trim(); $temp = [int]$Matches[2]; $soEp = [int]$Matches[3] }
      elseif ([string]$item -match '^(.*)\s+T(\d+)$') { $serie = $Matches[1].Trim(); $temp = [int]$Matches[2] }
      if ($serie) {
        $rec = $null
        foreach ($r in $reg) { if ($r.Type -ne 'movie' -and (Normalize-Text $r.Nome) -eq (Normalize-Text $serie)) { $rec = $r; break } }
        if (-not $rec) { $rel.Add("  $item : serie nao esta no registro do addon"); $errosN++; continue }
        $global:SerieOk = @{}; $global:TempasVistas = @{}
        $chave = Get-TemporadaChave $rec.Nome $temp
        $tempAsVistas = $chave
        $okEp = 0; $mudEp = 0; $totEp = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
          $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
          if ($p.Count -lt 7) { continue }
          if ($p[4] -ne 'serie') { continue }
          if ((Normalize-Text $p[5]) -ne (Normalize-Text $rec.Nome)) { continue }
          $ep = Parse-EpLabel $p[6]
          if (-not $ep.Ok -or $ep.Season -ne $temp) { continue }
      if ($soEp -gt 0 -and $ep.Ep -ne $soEp) { continue }
          if ($soEp -gt 0 -and $ep.Ep -ne $soEp) { continue }   # marcado so 1 episodio
          if (Is-FenixLine $p) { continue }
          $totEp++
          $rid = "$($rec.Id):$($ep.Season):$($ep.Ep)"
          $arr = Get-FSStreams 'series' $rid
          if ($prov -ne 'Todos') { $arr = Filter-FSByProvider $arr $prov }
          if ($arr.Count -eq 0) {
            $r2 = Get-FenixRescue 'series' $rid
            if ($prov -ne 'Todos') { $r2 = Filter-FSByProvider $r2 $prov }
            $arr = $r2
          }
          $s = $null
          if ($arr.Count -gt 0) { $s = Resolve-FSStream $arr $p[1] $rec.Nome }
          if ($global:CongVerbose) {
            $pl = @($arr | ForEach-Object { $l2 = ([string]$_.title) -split "`r?`n"; (Get-StreamProvedor $_) + '/' + $l2[3] }) -join ' ; '
            $rel.Add(('      {0,-6} addon={1}  resolvido={2}  providers=[{3}]' -f $p[6], @($arr).Count, $(if ($s) { 'sim' } else { 'NAO' }), $pl))
          }
          # Vale como "com link" tanto o candidato novo quanto o link ANTIGO que
          # ainda responde (o Resolve-FSStream devolve $null nesse caso, para
          # dizer "deixa o que ja funciona"). Sem isso, um episodio saudavel
          # era contado como falha.
          $epOk = $false
          if ($s) { $epOk = $true }
          elseif ($p[1] -and (Test-StreamAlive ([PSCustomObject]@{ url = $p[1] })) -and $global:FSVeredito -eq 'ok') { $epOk = $true }
          if ($epOk) { $okEp++ }
          if ($s -and $p[1] -ne ([string]$s.url)) { $p[1] = [string]$s.url; $lines[$i] = $p -join '|'; $mudEp++ }
        }
  if ($okEp -gt 0) {
  $global:SerieOk[$tempAsVistas] = $okEp
  Clear-SerieFria $tempAsVistas
  # Se o usuario marcou UM episodio, a chave que sai do congelamento e' a
  # dele, e nao a da temporada (que continua no app com o resto).
  if ($soEp -gt 0) { Clear-SerieFria (Get-EpisodioChave $rec.Nome $temp ([string]$soEp)) }
  $oks++
  $rel.Add("  $item : $($okEp)/$totEp episodio(s) com link no $prov ($mudEp trocaram de URL)")
  $rel.Add("     -> link gravado. Nas proximas atualizacoes ele entra no ciclo normal:")
  $rel.Add("        e re-sondado a cada rodada (Space, DNSPlay, Nova).")
  } else {
  $global:SerieOk[$tempAsVistas] = 0
  $errosN++
  $rel.Add("  $item : o $prov nao devolveu nenhum episodio (sem link nesta rodada)")
  }
      } else {
        $nomeF = ([string]$item).Trim()
        $rec = $null
        foreach ($r in $reg) { if ($r.Type -eq 'movie' -and (Normalize-Text $r.Nome) -eq (Normalize-Text $nomeF)) { $rec = $r; break } }
        if (-not $rec) { foreach ($r in $reg) { if ($r.Type -eq 'movie' -and (FSMatchName $r.Nome $nomeF)) { $rec = $r; break } } }
        if (-not $rec) { $rel.Add("  $nomeF : filme nao esta no registro do addon"); $errosN++; continue }
        $arr = Get-FSStreams 'movie' $rec.Id
        if ($prov -ne 'Todos') { $arr = Filter-FSByProvider $arr $prov }
        if ($arr.Count -eq 0) {
          $r2 = Get-FenixRescue 'movie' $rec.Id
          if ($prov -ne 'Todos') { $r2 = Filter-FSByProvider $r2 $prov }
          $arr = $r2
        }
        $achou = $false
        if ($arr.Count -gt 0) {
          for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '\|\|\|filme\|') { continue }
            $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
            if (Is-FenixLine $p) { continue }
            if (FSMatchName $p[0] $rec.Nome) {
              $s = Resolve-FSStream $arr $p[1] $rec.Nome
              if ($s) { $p[1] = [string]$s.url; $lines[$i] = $p -join '|'; $achou = $true }
              break
            }
          }
        }
        if ($achou) {
          Clear-SerieFria (Get-FilmeChave $rec.Nome)
          $oks++
          $rel.Add("  $nomeF : atualizado no $prov")
          $rel.Add("     -> voltou para o app e entra no ciclo normal (pula a proxima, depois checa).")
        } else {
          $rel.Add("  $nomeF : o $prov nao devolveu nada (continua congelado)")
          $errosN++
        }
      }
    }
    if ($oks -gt 0 -or $errosN -gt 0) { Backup-Channels | Out-Null; Write-File $lines }
    Save-SeriesFria
    Write-SeriesFriasRelatorio
    $cab = "Atualizacao dirigida no $prov`r`n"
    return $cab + ($rel -join "`r`n") + "`r`n`r`n" + "$oks recuperado(s), $errosN ainda congelado(s)."
  }

  # Monta as duas listas da aba de Congelamento: temporadas de serie e filmes.
  # Cada item ja vem no formato da chave, entao o que for marcado pode ir
  # direto para Update-FriosEscolhidos sem conversao.
  # Convertem o arquivo antigo (chave = id do add-on) para o formato atual
  # (chave = "Nome T<n>", uma por TEMPORADA). Sem isso, um titulo gravado no
  # formato antigo aparecia na lista de FILMES em vez da de SERIES, e o app nao
  # escondia os episodios. Roda sozinho, sem depender de reboot.
  function Normalize-SeriesFrias {
    $c = Get-SeriesFria
    if ($c.Count -eq 0) { return }
    $linhas = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $novo = @{}
    $mudou = $false
    foreach ($kv in $c.GetEnumerator()) {
      $nome = [string]$kv.Value.Nome
      if ([string]$nome -match '\sT\d+$' -or $kv.Key -notmatch '^tt\d+') { $novo[$kv.Key] = $kv.Value; continue }
      # Chave comecando em tt => formato antigo. Descobre as temporadas no catalogo.
      $temps = @()
      foreach ($l in $linhas) {
        $p = $l.Split('|')
        if ($p.Count -ge 7 -and $p[4] -eq 'serie' -and $p[5] -eq $nome -and $p[6] -match '^T(\d+)E') { $temps += [int]$Matches[1] }
      }
      if ($temps.Count -eq 0) {
        # Nao e serie: e filme. A chave passa a ser o NOME do filme, que e o
        # que o construtor do JSON consegue reproduzir a partir da linha.
        $chF = Get-FilmeChave $nome
        $novo[$chF] = [PSCustomObject]@{ Nome = $chF; Tent = $kv.Value.Tent; Prox = $kv.Value.Prox }
        $mudou = $true
        continue
      }
      $mudou = $true
      foreach ($sn in ($temps | Sort-Object -Unique)) {
        $ch = Get-TemporadaChave $nome $sn
        $novo[$ch] = [PSCustomObject]@{ Nome = $ch; Tent = $kv.Value.Tent; Prox = $kv.Value.Prox }
      }
    }
    if (-not $mudou) { return }
    $global:SeriesFria = $novo
    $f = Join-Path $NoviplayDir 'series_frias.txt'
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($kv in $novo.GetEnumerator()) { $out.Add($kv.Key + '|' + $kv.Value.Nome + '|' + $kv.Value.Prox.ToString('yyyy-MM-dd HH:mm:ss') + '|' + $kv.Value.Tent) }
    try { [IO.File]::WriteAllLines($f, $out, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  }

  function Get-FriasParaAba {
  Normalize-SeriesFrias
  $serie = @(); $filme = @()
  # Usa GetEnumerator() e nao "foreach ($x em $d)". Com o foreach, o PowerShell
  # nao desembrulha o hashtable devolvido pela funcao e entrega UM item vazio
  # (Key e Value vazios), o que fazia a aba aparecer vazia mesmo com a lista
  # congelada cheia. GetEnumerator() percorre as entradas de verdade.
  $c = Get-SeriesFria
  $epsSoltos = @()
  foreach ($kv in $c.GetEnumerator()) {
  $d = $kv.Value
  if (-not $d -or -not $d.Prox -or $d.Prox -le (Get-Date)) { continue }   # so quem ainda esta esperando
  $nome = [string]$d.Nome
  if (-not $nome) { continue }
  # "The 100 T1E4" = um episodio solto congelado (a temporada ainda esta no
  # app). Ele vai para a caixa propria de episodios e a temporada aparece
  # uma unica vez na caixa de series.
  if ($nome -match '^(.*\sT\d+)E\d+$') {
    $epsSoltos += $nome
    $serie += $Matches[1]
    continue
  }
  if ($nome -match '\sT\d+$') { $serie += $nome } else { $filme += $nome }
  }
  $serie = @($serie | Sort-Object -Unique)
  $filme = @($filme | Sort-Object -Unique)
  $epsSoltos = @($epsSoltos | Sort-Object -Unique)
  $lock = Get-ProvTravado
  $ord = { param($x) $k = Normalize-Text $x; $p = if ($lock.ContainsKey($k)) { '0' + $lock[$k] } else { '1' }; "$p|$x" }
  return [PSCustomObject]@{
    Series = @($serie | Sort-Object -Property $ord)
    Filmes = @($filme | Sort-Object)
    Episodios = @($epsSoltos)
  }
}

  # Onde este titulo existe de verdade? Consulta os dois add-ons e conta, por
  # provedor, quantos episodios devolveram stream. Serve para o usuario nao
  # ficar no escuro: em vez de so ouvir "nao funciona", ele ve que o titulo esta
  # no Nova (por exemplo) e escolhe esse provedor no botao de atualizar.
  function Find-TituloNosProvedores($escolhidos, [switch]$soVerbose) {
    if ($null -eq $escolhidos -or @($escolhidos).Count -eq 0) { return "Marque pelo menos um titulo." }
    $reg = Read-FrostReg
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $rel = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($escolhidos)) {
      $serie = $null; $temp = 0
      # "The 100 T1" = temporada inteira; "The 100 T1E4" = so aquele episodio
      $soEp = 0
      if ([string]$item -match '^(.*)\s+T(\d+)E(\d+)$') { $serie = $Matches[1].Trim(); $temp = [int]$Matches[2]; $soEp = [int]$Matches[3] }
      elseif ([string]$item -match '^(.*)\s+T(\d+)$') { $serie = $Matches[1].Trim(); $temp = [int]$Matches[2] }
      $rec = $null
      if ($serie) {
        foreach ($r in $reg) { if ($r.Type -ne 'movie' -and (Normalize-Text $r.Nome) -eq (Normalize-Text $serie)) { $rec = $r; break } }
      } else {
        $n = ([string]$item).Trim()
        foreach ($r in $reg) { if ($r.Type -eq 'movie' -and ((Normalize-Text $r.Nome) -eq (Normalize-Text $n) -or (FSMatchName $r.Nome $n))) { $rec = $r; break } }
      }
      if (-not $rec) { $rel.Add("  $item : nao esta no registro do add-on"); continue }
      $rel.Add("  $item  (id $($rec.Id))")
      $cont = @{ Space = 0; DNSPlay = 0; Nova = 0; '(sem rotulo)' = 0 }
      $vivos = 0; $comLink = 0
      for ($i = 0; $i -lt $lines.Count; $i++) {
        $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
        if ($p.Count -lt 7) { continue }
        $ehSerie = ($p[4] -eq 'serie')
        if ($serie) {
          if (-not $ehSerie -or $p[5] -ne $rec.Nome) { continue }
          $ep = Parse-EpLabel $p[6]
          if (-not $ep.Ok -or $ep.Season -ne $temp) { continue }
      if ($soEp -gt 0 -and $ep.Ep -ne $soEp) { continue }
          if ($soEp -gt 0 -and $ep.Ep -ne $soEp) { continue }   # marcado so 1 episodio
          $rid = "$($rec.Id):$($ep.Season):$($ep.Ep)"
        } else {
          if ($ehSerie -or -not (FSMatchName $p[0] $rec.Nome)) { continue }
          $rid = $rec.Id
        }
        if (Is-FenixLine $p) { continue }
        $comLink++
        $arr = Get-FSStreams ($(if ($ehSerie) { 'series' } else { 'movie' })) $rid
        if (@($arr).Count -eq 0) { $arr = Get-FenixRescue ($(if ($ehSerie) { 'series' } else { 'movie' })) $rid }
        $achouAlgum = $false
        foreach ($s in @($arr)) {
          $pv = Get-StreamProvedor $s
          if (-not $pv) { $pv = '(sem rotulo)' }
          if ($cont.ContainsKey($pv)) { $cont[$pv]++ } else { $cont[$pv] = 1 }
          $achouAlgum = $true
        }
        if ($soVerbose) { $rel.Add(('      {0,-6} {1}' -f $p[6], $(if ($achouAlgum) { "$(@($arr).Count) link(s)" } else { 'o addon nao devolveu NADA' }))) }
      if ($achouAlgum) { $vivos++ }
      }
      foreach ($k in @('Space', 'Nova', 'DNSPlay', '(sem rotulo)')) {
        if ($cont[$k] -gt 0) { $rel.Add("     $k : $($cont[$k]) link(s)") }
      }
      if ($vivos -eq 0) {
        $rel.Add("     NENHUM addon devolveu link para este titulo.")
        $rel.Add("     Se voce viu ele no Stremio, ele pode estar em OUTRO addon, que este painel nao le.")
      } else {
        $rel.Add("     -> $vivos de $comLink episodio(s) tem link. Escolha acima o provedor e clique em ATUALIZAR.")
      }
    }
    return ($rel -join "`r`n")
  }

  # Segunda opiniao ANTES de congelar. O Frost devolve "streams": [] quando
  # aperta em rajada; se a gente perguntasse uma vez so, um titulo bom podia
  # ser congelado por engano. Aqui, quando algo vai ser congelado, o painel
  # espera, limpa o cache daquele item e pergunta DE NOVO. Se aparecer link que
  # abre, o titulo NAO e' congelado.
  #
  # Custo controlado: UMA consulta por episodio (sem as 3 tentativas normais) e
  # no maximo 40 episodios por rodada. Com ~0,9 s por consulta, o pior caso e'
  # 30 s de espera + ~36 s = ~1 min. Antes, sem teto, uma temporada com 24
  # episodios custava 24 x 5,4 s e a leva passava de 15 min.
  function Get-FSStreamsUmaVez([string]$type, [string]$rid) {
    $u = "$FsBase/stream/$type/$rid.json"
    if ($null -eq $global:FSLastCall) { $global:FSLastCall = Get-Date }
    $desde = ((Get-Date) - $global:FSLastCall).TotalMilliseconds
    if ($desde -lt 800) { Start-Sleep -Milliseconds ([int](800 - $desde)) }
    $r = Invoke-FSJson $u
    $global:FSLastCall = Get-Date
    if ($r -and $r.streams) { return @($r.streams) }
    return @()
  }
  function Reconfirmar-FriosAntesDeCongelar($chaves) {
    $alvo = @()
    foreach ($k in @($chaves)) { if ($k -and $alvo -notcontains $k) { $alvo += $k } }
    if ($alvo.Count -eq 0) { return @() }
    $orcamento = 20      # maximo de episodios checados na segunda opiniao
    $reg = Read-FrostReg
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $salvo = $false
    $recuperados = @()
    $gastos = 0
    # Espera curta: so o suficiente para a rajada do add-on passar.
    Start-Sleep -Seconds 20
    foreach ($ch in $alvo) {
      if ($gastos -ge $orcamento) { break }
      $serie = $null; $temp = 0; $soEp = 0
      if ($ch -match '^(.*)\s+T(\d+)E(\d+)$') { $serie = $Matches[1].Trim(); $temp = [int]$Matches[2]; $soEp = [int]$Matches[3] }
      elseif ($ch -match '^(.*)\s+T(\d+)$') { $serie = $Matches[1].Trim(); $temp = [int]$Matches[2] }
      $rec = $null
      if ($serie) {
        foreach ($r in $reg) { if ($r.Type -ne 'movie' -and (Normalize-Text $r.Nome) -eq (Normalize-Text $serie)) { $rec = $r; break } }
      } else {
        foreach ($r in $reg) { if ($r.Type -eq 'movie' -and ((Normalize-Text $r.Nome) -eq (Normalize-Text $ch) -or (FSMatchName $r.Nome $ch))) { $rec = $r; break } }
      }
      if (-not $rec) { continue }
      $achou = 0
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($gastos -ge $orcamento) { break }
        $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
        if ($p.Count -lt 2) { continue }
        if (Is-FenixLine $p) { continue }
        if ($serie) {
          if ($p.Count -lt 7 -or $p[4] -ne 'serie') { continue }
          if ((Normalize-Text $p[5]) -ne (Normalize-Text $rec.Nome)) { continue }
          $ep = Parse-EpLabel $p[6]
          if (-not $ep.Ok -or $ep.Season -ne $temp) { continue }
          if ($soEp -gt 0 -and $ep.Ep -ne $soEp) { continue }
          $arr = Get-FSStreamsUmaVez 'series' "$($rec.Id):$($ep.Season):$($ep.Ep)"
        } else {
          if ($p.Count -lt 5 -or $p[4] -ne 'filme') { continue }
          if (-not (FSMatchName $p[0] $rec.Nome)) { continue }
          $arr = Get-FSStreamsUmaVez 'movie' $rec.Id
        }
        $gastos++
        if (@($arr).Count -eq 0) { continue }
        $s = Resolve-FSStream $arr $p[1] $rec.Nome
        if ($s) { $p[1] = [string]$s.url; $lines[$i] = $p -join '|'; $achou++ }
      }
      if ($achou -gt 0) {
        $recuperados += $ch
        Clear-SerieFria $ch
        if (-not $salvo) { Backup-Channels | Out-Null; Write-MergeDisco $lines; $salvo = $true }
      }
    }
    return $recuperados
  }

  function Update-AllFS {
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return "channels.np nao encontrado em $ChannelsPath" }
  # Carrega os provedores travados ANTES de comecar, para o ranking ja saber
  # qual provedor tem prioridade em cada titulo.
  Load-ProvTravado
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $global:LinhasInicioUpdate = $lines
    $reg = Read-FrostReg
    $auto = Add-FSAutoReg $lines $reg
    if ($auto -gt 0) { $reg = Read-FrostReg }
    # SERIES PROTEGIDAS: saem do registro ANTES de qualquer coisa. Nao vao para
    # o add-on, nao entram no passe 1 nem no passe 2, e portanto nao podem ter
    # o link trocado nem entrar na contagem de falhas. Como elas ja estao no
    # catalogo com link gravado, o app continua com o episodio que o usuario
    # esta assistindo. (Ver $global:SeriesProtegidas no topo do arquivo.)
    if ($global:SeriesProtegidas -and $global:SeriesProtegidas.Count -gt 0) {
      $reg = @($reg | Where-Object { -not (Test-SerieProtegida $_.Nome '') })
    }
    # Modo SO SERIES: pula os filmes. Serve para recuperar serie sem voltar a
    # consultar os 30 filmes (que ja estao bons) e gastando tempo com eles.
    if ($global:SoSeriesOnly) {
      $reg = @($reg | Where-Object { $_.Type -ne 'movie' })
      if ($reg.Count -eq 0) { return 'Nenhuma serie no registro.' }
    }
    if ($global:SoFilmesOnly) {
      $reg = @($reg | Where-Object { $_.Type -eq 'movie' })
      if ($reg.Count -eq 0) { return 'Nenhum filme no registro.' }
    }
  $seriesType = 'series'
  $rep = Repair-MissingVods $lines $reg
  if ($rep.Added -gt 0) { $lines = $rep.Lines }
      $rec = $null
    # -----------------------------------------------------------------------
    # PASSE 1 - O LINK QUE JA ESTA NO CATALOGO E' A FONTE DA VERDADE
    # -----------------------------------------------------------------------
    # Regra que resolve o problema de vez: antes de perguntar ao add-on se o
    # episodio existe, o painel TESTA o proprio link que ja gravou. Se ele
    # responde, o episodio FUNCIONA e nao ha o que fazer - nem chamada de
    # add-on, nem sondagem de candidato.
    #
    # Isso mata o "o Stremio mostra e o nosso nao acha": a decisao passa a
    # vir do link real, e nao de um terceiro que troca de fonte de hora em
    # hora (medido: o mesmo episodio veio MegaEmbed/legendado as 12:00 e
    # Nova/dublado as 13:20). O add-on so e consultado no passe 2, para o
    # que realmente morreu - e ai, se ele nao tiver nada, o titulo entra no
    # congelamento, que e a unica forma de ele sumir do app.
    $ok1 = 0
    $global:ProtegidasNoCatalogo = 0
  $global:VodOk = @{}
    $global:VodFalhou = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -lt 2) { continue }
      $tipoL = if ($p.Count -ge 5) { $p[4] } else { '' }
      if ($tipoL -ne 'filme' -and $tipoL -ne 'serie') { continue }
      if ($global:SoSeriesOnly -and $tipoL -ne 'serie') { continue }
      if ($global:SoFilmesOnly -and $tipoL -ne 'filme') { continue }
      if (Is-FenixLine $p) { continue }
      # SERIE PROTEGIDA: o painel nao sonda, nao troca o link e nao conta como
      # falha. O episodio fica como esta no catalogo, com o link que ja
      # funciona. (Ver $global:SeriesProtegidas no topo do arquivo.)
      if ($tipoL -eq 'serie') {
        $serieL = if ($p.Count -ge 6) { [string]$p[5] } else { '' }
        if (Test-SerieProtegida $p[0] $serieL) { $global:ProtegidasNoCatalogo++; continue }
      }
      $urlL = [string]$p[1]
      if ([string]::IsNullOrWhiteSpace($urlL)) { continue }
      # chave do congelamento deste episodio (por EPISODIO, nao por temporada)
      $chL = $null; $chT = $null
      if ($tipoL -eq 'filme') { $chL = Get-FilmeChave $p[0] }
      else {
        if ($p.Count -lt 7 -or -not $p[5] -or -not $p[6]) { continue }
        $epL = Parse-EpLabel $p[6]
        if (-not $epL.Ok) { continue }
        $chT = Get-TemporadaChave $p[5] $epL.Season
        $chL = Get-EpisodioChave $p[5] $epL.Season ([string]$epL.Ep)
      }
        # (nao pula mais temporada/episodio congelado: com o congelamento
        #  desligado, TODO item do catalogo e' re-sondado a cada rodada)
        if ((Test-StreamAlive ([PSCustomObject]@{ url = $urlL }) -SemCache:$($tipoL -eq 'filme')) -and $global:FSVeredito -eq 'ok') {
        $global:VodOk[$i] = $chT
        # O contador que o fechamento do ciclo consulta e' o da TEMPORADA
        # ($chT). Para filme nao existe temporada, e o proprio nome (chL) e' a
        # chave. Contar no episodio aqui zerava as temporadas e fazia o
        # painel congelar series inteiras que estavam funcionando.
        $conta = if ($chT) { $chT } else { $chL }
        if (-not $global:SerieOk.ContainsKey($conta)) { $global:SerieOk[$conta] = 0; $global:TempasVistas[$conta] = $conta }
        $global:SerieOk[$conta] = $global:SerieOk[$conta] + 1
        $ok1++
      }
    }

  $updated = 0; $fails = 0; $found = 0; $failList = @(); $resgatados = 0
  $global:LastFailList = @()
  # VARRENDA DE FILMES (independe do add-on). O laco 'foreach $reg' abaixo so
  # mede os filmes que o add-on ainda devolve. Quando o add-on tira o titulo
  # do catalogo, o filme nao entra no laco: nao e testado, nao e contado e nao
  # vira falha - o log dizia "Sem falhas" com 23 de 30 filmes mortos. Aqui
  # varremos TODA linha 'filme' do catalogo. Se o link guardado ainda
  # responde, o filme entra em SerieOk e o laco do add-on nao gasta tempo com
  # ele. Se morreu, ele fica marcado para o passo de busca abaixo, que so
  # desiste depois de tentar todas as fontes.
  $filmesCat = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -notmatch '\|\|\|filme\|') { continue }
  $pc = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
  if ($pc.Count -lt 2) { continue }
  if (Is-FenixLine $pc) { continue }
  $chaveC = Get-FilmeChave $pc[0]
  if ($global:SerieOk.ContainsKey($chaveC) -and $global:SerieOk[$chaveC] -gt 0) { continue }
  $urlC = [string]$pc[1]
  if ([string]::IsNullOrWhiteSpace($urlC)) { continue }
  # Testa o VEREDITO, nao so o booleano: 'incerto' volta como True e nao
  # serve como prova de que o link funciona. Aqui so vale 'ok'.
  if ((Test-StreamAlive ([PSCustomObject]@{ url = $urlC }) -SemCache) -and $global:FSVeredito -eq 'ok') { $global:SerieOk[$chaveC] = 1; continue }
  $filmesCat += [PSCustomObject]@{ Idx = $i; Linha = $pc; Chave = $chaveC; Nome = $pc[0] }
  }
  foreach ($r in $reg) {
  if ($r.Type -eq 'movie') {
  # Titulo frio: o addon tirou do catalogo. Nao gasta tempo agora.
  # A chave tem que ser o nome da LINHA DO CATALOGO ("Minions (Dublado
  # PT-BR)"), e nao o nome do registro do addon ("Minions"). O passe 1 contou
  # pelo nome da linha; usar o nome do addon criava uma chave nova com zero e
  # congelava filmes que estavam funcionando (aconteceu com 23 filmes).
  $chave = Get-FilmeChave $r.Nome
  for ($k = 0; $k -lt $lines.Count; $k++) {
  $pk = $lines[$k].Split([char]'|', [System.StringSplitOptions]::None)
  if ($pk.Count -ge 5 -and $pk[4] -eq 'filme' -and -not (Is-FenixLine $pk) -and (FSMatchName $pk[0] $r.Nome)) { $chave = Get-FilmeChave $pk[0]; break }
  }
    if (-not $global:SerieOk.ContainsKey($chave)) { $global:SerieOk[$chave] = 0; $global:TempasVistas[$chave] = $chave }
  $arr = Get-FSStreams 'movie' $r.Id
      $s = Pick-FSStream $arr $r.Nome
      if (-not $s) {
        $resc = Get-FenixRescue 'movie' $r.Id
        $s = Pick-FSStream $resc $r.Nome
        if ($s) { $arr = $resc; $resgatados++ }
      }
      if (-not $s) { $fails++; $failList += $r.Nome; $global:LastFailList += [PSCustomObject]@{ Src='Frost'; Tipo='filme'; Nome=$r.Nome; Serie=''; Ep='' }; continue }
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '\|\|\|filme\|') { continue }
        $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
        if (Is-FenixLine $p) { continue }
  if (FSMatchName $p[0] $r.Nome) {
  $found++
  # O passe 1 ja provou que este link responde: nao ha o que buscar.
  if ($global:VodOk.ContainsKey($i)) { continue }
  $s3 = Resolve-FSStream $arr $p[1] $r.Nome -SemTudo
  $filOk = $false
  if ($s3) {
  $filOk = $true
  if ($p[1] -ne ([string]$s3.url)) { $p[1] = [string]$s3.url; $lines[$i] = $p -join '|'; $updated++ }
} elseif ($p[1] -and (Test-StreamAlive ([PSCustomObject]@{ url = $p[1] }) -SemCache) -and $global:FSVeredito -eq 'ok') { $filOk = $true }
  if ($filOk) { $global:SerieOk[$chave] = $global:SerieOk[$chave] + 1 }
  break
  }
  }
  } else {
      $allSeasons = $false
      if ($r.Season -eq '*' -or $r.Season -eq '') { $allSeasons = $true }
      else {
        $season = 0; [void][int]::TryParse($r.Season, [ref]$season)
        if ($season -lt 1) { $fails++; $failList += $r.Nome; $global:LastFailList += [PSCustomObject]@{ Src='Frost'; Tipo='serie'; Nome=$r.Nome; Serie=$r.Nome; Ep='' }; continue }
      }
        for ($i = 0; $i -lt $lines.Count; $i++) {
          if ($lines[$i] -notmatch '\|\|\|serie\|') { continue }
          $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
          if ($p.Count -lt 7) { continue }
          if (Is-FenixLine $p) { continue }
          if ((Normalize-Text $p[5]) -ne (Normalize-Text $r.Nome)) { continue }
          $ep = Parse-EpLabel $p[6]
          if (-not $ep.Ok) { continue }
          if (-not $allSeasons -and $ep.Season -ne $season) { continue }
          # Congelamento por EPISODIO. A temporada ("Nome T<n>") so e marcada
          # quando nenhum dos seus episodios tem link - assim um unico
          # episodio quebrado nao esconde os outros que funcionam.
          $chave = Get-TemporadaChave $r.Nome $ep.Season
          $chEp = Get-EpisodioChave $r.Nome $ep.Season ([string]$ep.Ep)
    if (-not $global:SerieOk.ContainsKey($chave)) { $global:SerieOk[$chave] = 0; $global:TempasVistas[$chave] = $chave }
    $found++
  # O passe 1 ja provou que este link responde: nao ha o que buscar.
  if ($global:VodOk.ContainsKey($i)) { continue }
  $rid = "$($r.Id):$($ep.Season):$($ep.Ep)"
        $arr = Get-FSStreams 'series' $rid
        $s = Pick-FSStream $arr $r.Nome
        if (-not $s) {
          $resc = Get-FenixRescue 'series' $rid
          $s = Pick-FSStream $resc $r.Nome
          if ($s) { $arr = $resc; $resgatados++ }
        }
        if (-not $s) { $fails++; $failList += "$($r.Nome) $($p[6])"; $global:VodFalhou[$chEp] = $chEp; $global:LastFailList += [PSCustomObject]@{ Src='Frost'; Tipo='serie'; Nome=$p[0]; Serie=$p[5]; Ep=$p[6] }; continue }
        $s2 = Resolve-FSStream $arr $p[1] $r.Nome
        # Conta como "funcionando" tanto o link NOVO quanto o link ANTIGO que
        # ainda responde. Antes so contava o novo: quando o candidato novo
        # falhava na sondagem e o antigo continuava no ar, o episodio era
        # marcado como falha e a TEMPORADA INTEIRA era congelada, mesmo com
        # todos os episodios tocando. Era esse o bug que sumia serie do app.
        $epOk = $false
        if ($s2) {
          $epOk = $true
          if ($p[1] -ne ([string]$s2.url)) { $p[1] = [string]$s2.url; $lines[$i] = $p -join '|'; $updated++ }
        } elseif ($p[1] -and (Test-StreamAlive ([PSCustomObject]@{ url = $p[1] })) -and $global:FSVeredito -eq 'ok') { $epOk = $true }
        if ($epOk) { $global:SerieOk[$chave] = $global:SerieOk[$chave] + 1 }
      }
    }
  }
  # BUSCA EXAUSTIVA DOS FILMES QUE O ADD-ON NAO DEVOLVEU.
  # Regra do usuario: se o link existe em ALGUM lugar, ele tem que funcionar.
  # So quando o titulo nao existe em fonte nenhuma ele e' descartado do app.
  # '$filmesCat' reune os filmes cujo link guardado morreu. Aqui, para cada um,
# a gente tenta: 1) o proprio add-on (varias vezes), 2) o resgate Fenix,
  # 3) REBUSCA por titulo no add-on, e so se tudo der errado marca falha. O
  # add-on costuma trocar a fonte de hora em hora, entao insistir e' o que faz
  # o filme voltar - foi assim que 127 links voltaram na rodada das 13:19.
  foreach ($fc in $filmesCat) {
  if ($global:SerieOk.ContainsKey($fc.Chave) -and $global:SerieOk[$fc.Chave] -gt 0) { continue }
  $pl = $fc.Linha
  $plOk = $false
  # (1) Tenta o add-on varias vezes com o id do proprio filme. novo filme
  #     que o add-on devolve ja entra aqui; o que sumiu do catalogo do add-on
  #     cai no passo (3), a busca por titulo.
  $idsFilm = @()
  foreach ($r2 in $reg) {
    if ($r2.Type -ne 'movie') { continue }
    if (FSMatchName $r2.Nome $fc.Nome) { $idsFilm += $r2.Id }
  }
  if (-not $idsFilm.Count) {
    # (3) Nenhum registro com esse nome exato. Rebusca no catalogo do add-on
    #     por um titulo parecido: o nome pode ter mudado de grafia, de ano ou
    #     de traducao, mas o filme continua la e vale a pena tentar.
    foreach ($r3 in $reg) {
      if ($r3.Type -ne 'movie') { continue }
      $n3 = [string]$r3.Nome
      if ($n3 -and ((Normalize-Text $n3) -eq (Normalize-Text $fc.Nome))) { $idsFilm += $r3.Id }
    }
  }
  foreach ($idf in @($idsFilm)) {
    for ($tent = 1; $tent -le 3; $tent++) {
      $arrF = Get-FSStreams 'movie' $idf
      $sF = Pick-FSStream $arrF $fc.Nome
      if (-not $sF) {
        $rescF = Get-FenixRescue 'movie' $idf
        $sF = Pick-FSStream $rescF $fc.Nome
        if ($sF) { $arrF = $rescF; $resgatados++ }
      }
      if ($sF) {
        $sF2 = Resolve-FSStream $arrF $pl[1] $fc.Nome -SemTudo
        if ($sF2) {
          $pl[1] = [string]$sF2.url
          $lines[$fc.Idx] = $pl -join '|'
          $global:SerieOk[$fc.Chave] = 1
          $updated++
          $plOk = $true
          break
        }
      }
      if ($tent -lt 3) { Start-Sleep -Milliseconds 700 }
    }
    if ($plOk) { break }
  }
  if (-not $plOk) {
    $fails++
    $failList += $fc.Nome
    $global:LastFailList += [PSCustomObject]@{ Src='Catalogo'; Tipo='filme'; Nome=$fc.Nome; Serie=''; Ep='' }
  }
  }
  # ==========================================================================
  # VARRENDURA FINAL (a garantia). Roda DEPOIS de todo o processamento e
  # re-teste, de fora para dentro, TODA linha do catalogo. Ela existe para
  # cumprir a regra do usuario: se algo comecou a rodada com link quebrado,
  # so pode terminar a rodada quebrado se nao existir link em fonte nenhuma.
  #
# Antes nao havia essa etapa: o resultado dependia inteiramente do
  # que os lacos anterioresZWIVERrememberam, e um item que nao passou por
  # nenhum deles ficava sem checagem nenhuma - era o furo que deixou 23
  # filmes parados enquanto o log dizia "Sem falhas".
  #
  # Aqui nao ha excecao por tipo: filme, serie e episodio entram todos. O que
  # responder e' confirmado; o que nao responde vai para a ultima tentativa
  # (abaixo), que so desiste depois de add-on + Fenix + busca por titulo.
  $quebradosFim = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
  $vf = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
  if ($vf.Count -lt 2) { continue }
  $tipoV = if ($vf.Count -ge 5) { $vf[4] } else { '' }
  if ($tipoV -ne 'filme' -and $tipoV -ne 'serie') { continue }
  if (Is-FenixLine $vf) { continue }
  $urlV = [string]$vf[1]
  if ([string]::IsNullOrWhiteSpace($urlV)) { continue }
  # IMPORTANTE: testar o VEREDITO, nao so o booleano. Test-StreamAlive
  # devolve 'incerto' como True (link com 403/5xx em duas sondagens, em que
  # nao da para afirmar que morreu). Se a auditoria aceitasse esse True, ela
  # dava o item por bom sem trocar o link - foi assim que os 23 episodios de
  # Pursuit of Jade ficaram parados: o host inteiro estava fora do ar, o
  # veredito era 'incerto' e a auditoria dava por certo. Aqui so passa quem
  # respondeu de verdade ('ok'); 'incerto' e 'morto' entram na ultima tentativa.
  $vResp = Test-StreamAlive ([PSCustomObject]@{ url = $urlV }) -SemCache:$($tipoV -eq 'filme')
  if ($vResp -and $global:FSVeredito -eq 'ok') { continue }
  $quebradosFim += [PSCustomObject]@{ Idx=$i; Linha=$vf; Tipo=$tipoV; Url=$urlV; Rot=$vf[0] }
  }
  $finalOK = 0; $finalFalhou = @()
  foreach ($qf in $quebradosFim) {
  $pv = $qf.Linha
  $idV = $null
  if ($qf.Tipo -eq 'filme') {
    foreach ($r4 in $reg) { if ($r4.Type -eq 'movie' -and (FSMatchName $r4.Nome $qf.Rot)) { $idV = $r4.Id; break } }
    if (-not $idV) { foreach ($r4 in $reg) { if ($r4.Type -eq 'movie' -and ((Normalize-Text $r4.Nome) -eq (Normalize-Text $qf.Rot))) { $idV = $r4.Id; break } } }
  } else {
    $epV = if ($pv.Count -ge 7) { Parse-EpLabel $pv[6] } else { $null }
    if ($epV -and $epV.Ok) {
      foreach ($r4 in $reg) { if ($r4.Type -ne 'series') { continue }; if (-not (FSMatchName $r4.Nome $pv[5])) { continue }
        $idV = "$($r4.Id):$($epV.Season):$($epV.Ep)"; break }
    }
  }
  $tipoAdd = if ($qf.Tipo -eq 'filme') { 'movie' } else { 'series' }
  $okFim = $false
  if ($idV) {
    for ($tenta = 1; $tenta -le 3; $tenta++) {
      $aF = Get-FSStreams $tipoAdd $idV
      $zF = Pick-FSStream $aF $qf.Rot
      if (-not $zF) { $rrF = Get-FenixRescue $tipoAdd $idV; $zF = Pick-FSStream $rrF $qf.Rot; if ($zF) { $aF = $rrF; $resgatados++ } }
      if ($zF) {
        $zF2 = Resolve-FSStream $aF $pv[1] $qf.Rot -SemTudo:$($qf.Tipo -eq 'filme')
        if ($zF2) { $pv[1] = [string]$zF2.url; $lines[$qf.Idx] = $pv -join '|'; $updated++; $okFim = $true; break }
      }
      if ($tenta -lt 3) { Start-Sleep -Milliseconds 700 }
    }
  }
  if ($okFim) { $finalOK++ } else {
    # Nao existe link em fonte nenhuma: aqui sim ele vira falha declarada.
    $fails++
    $failList += $qf.Rot
    $serieV = ''; $epV2 = ''
    if ($qf.Tipo -eq 'serie') { $serieV = $pv[5]; $epV2 = $pv[6] }
    $global:LastFailList += [PSCustomObject]@{ Src='Final'; Tipo=$qf.Tipo; Nome=$qf.Rot; Serie=$serieV; Ep=$epV2 }
    $finalFalhou += $qf.Rot
  }
  }
  $auditoria = " auditoria final: $($quebradosFim.Count) quebrado(s) no inicio do fecho, $finalOK salvo(s), $($finalFalhou.Count) sem fonte em lugar nenhum"
  # Fecha o ciclo. CONGELAMENTO DESLIGADO (pedido do usuario): nada mais e'
  # marcado como "frio" nem some do app. O que continua valendo e' a segunda
  # opiniao: antes de dar a rodada por perdida, o painel espera e pergunta de
  # novo ao provedor, e o que voltar a responder tem o link gravado. A lista do
  # que ficou sem link e' mantida no log, so para diagnostico.
  if ($global:SoSeriesOnly -or $true) {
    $friasN = 0; $friasNomes = @()
    $praCongelar = @()
    foreach ($chave in @($global:TempasVistas.Keys)) {
      if ($global:SerieOk[$chave] -gt 0) {
        # a temporada esta viva: limpa qualquer registro antigo
        Clear-SerieFria $chave
        continue
      }
      $praCongelar += $chave
    }
    foreach ($chEp in @($global:VodFalhou.Keys)) { $praCongelar += $chEp }
    # Segunda opiniao: so agora, com tudo ja tentado, o painel espera e
    # pergunta de novo. O que voltar a responder tem o link gravado.
    $resgatou = Reconfirmar-FriosAntesDeCongelar $praCongelar
    foreach ($chave in $praCongelar) {
      if ($resgatou -contains $chave) { continue }
      $friasN++; $friasNomes += $chave
    }
    $script:FriasNoCatalogo = $friasNomes
    # Grava o registro como DIAGNOSTICO (nao e' mais usado para esconder nada
    # do app): a lista do que ficou sem link fica visivel no relatorio.
    $cLimpa = Get-SeriesFria
    $cLimpa.Clear()
    foreach ($chave in $friasNomes) { $cLimpa[$chave] = [PSCustomObject]@{ Nome=$chave; Tent=1; Prox=(Get-Date).AddMinutes((Get-FSRodadaMin)) } }
    Save-SeriesFria
    $msgFria = ''
    # Contagem honesta: soma o que ficou sem link em FILMES e o que ficou sem
    # link em SERIES. Antes o log so listava as series, entao aparecia
    # "Sem falhas" com 23 de 30 filmes parados.
    $filmesSemLink = @($failList | Where-Object { $_ -and -not ($_ -match '^(.+?)\s+(T\d+E\d+|\d+x\d+)$') })
    $totalSemLink = $filmesSemLink.Count + $friasN
    if ($totalSemLink -gt 0) {
      $msgFria = " Sem link nesta rodada ($totalSemLink, continuam no app): "
      if ($filmesSemLink.Count) { $msgFria += "FILMES: " + ($filmesSemLink -join ', ') + ". " }
      if ($friasN) { $msgFria += "SERIES: " + ($friasNomes -join ', ') }
      $msgFria = $msgFria.Trim()
    }
    if (@($resgatou).Count -gt 0) { $msgFria += " | Segunda opiniao salvou: " + ($resgatou -join ", ") }
  }
  $global:LastFSStats = @{ Updated = $updated; Found = $found; Fails = $fails; Resgatados = $resgatados }
  if ($updated -gt 0 -or $rep.Added -gt 0) {
    Backup-Channels | Out-Null
    Write-MergeDisco $lines
  }
  if ($fails -gt 0) {
  $msg = "FrostStream: $updated link(s) atualizado(s) de $found localizado(s). Falhas: $fails"
  $msg += ". Passe 1 (link testado e funcionando, sem pedir ao add-on): $ok1"
    if ($resgatados -gt 0) { $msg += ". ($resgatados resgatado(s) no Fenix)" }
    if ($rep.Added -gt 0) { $msg += ". ($($rep.Added) linha(s) de VOD restaurada(s) de backup)" }
    $msg += '. Sem link: ' + ($failList -join ', ')
  } elseif ($updated -gt 0 -or $resgatados -gt 0 -or $rep.Added -gt 0) {
  # O total agora e' o do catalogo inteiro (filmes + series), e nao so o que o
  # add-on devolveu. E o texto diz quantos ficaram sem link - nunca mais
  # "Sem falhas" quando existe filme parado.
  $totalCat = $filmesCat.Count + $found
  $msg = "OK! $updated link(s) atualizado(s) de $totalCat no catalogo."
  $semN = @($failList).Count + $friasN
  if ($semN -gt 0) { $msg += " $semN sem link (tentaram todas as fontes)." } else { $msg += " Todos os links respondem." }
  $msg += " (passe 1 resolveu $ok1 sem chamar o add-on)"
    if ($resgatados -gt 0) { $msg += " ($resgatados resgatado(s) no Fenix)" }
    if ($rep.Added -gt 0) { $msg += " ($($rep.Added) linha(s) de VOD restaurada(s))" }
    $msg += $auditoria
  } elseif (@($failList).Count -gt 0 -or $friasN -gt 0) {
  # Nenhum link mudou, mas algo esta morto: nao pode dizer "Nada a atualizar"
  # sem avisar, porque era exatamente esse o furo que escondeu 23 filmes.
  $semN2 = @($failList).Count + $friasN
  $msg = "Nada mudou nesta rodada, mas $semN2 titulo(s) estao sem link apos tentar todas as fontes. Lista: " + (@($failList) -join ', ')
  $msg += $auditoria
  } else {
    $msg = "Nada a atualizar. Passe 1 confirmou $ok1 link(s) funcionando; o add-on so foi chamado nos que falharam."
  }
  # fecha o ciclo do cache: grava o que respondeu e mostra quanto se poupou,
  # para dar para conferir se a leva ficou mais curta.
  Save-FSOkCache
  # Esta linha estava sem as aspas e derrubava a ATUALIZACAO INTEIRA do
  # FrostStream ("O termo 's' nao e reconhecido") - por isso as series sumiam
  # do app mesmo com tudo certo na busca.
    $msg += ". Cache de link: $($global:FSOkHits) pulado(s), $($global:FSOkMiss) sondado(s)"
    if ($global:ProtegidasNoCatalogo -gt 0) {
      $msg += ". PROTEGIDAS (nao atualizadas): $($global:SeriesProtegidas -join ', ') - $($global:ProtegidasNoCatalogo) episodio(s) deixados como estao"
    }
    $msg += $msgFria
  return $msg
}

# ---------------- FENIX (addon de filmes/series) ----------------

function Is-FenixLine([string[]]$p) {
  if ($null -eq $p -or $p.Count -lt 5) { return $false }
  return ($p[4] -eq 'filme' -or $p[4] -eq 'serie') -and $p[2] -eq $FenixMark
}

$global:FenixCache = @{}

function Get-FenixStreams([string]$type, [string]$rid) {
  $key = "$type/$rid"
  if ($global:FenixCache.ContainsKey($key)) { return $global:FenixCache[$key] }
  $r = Invoke-FSJson "$FenixBase/stream/$type/$rid.json"
  $arr = @()
  if ($r -and $r.streams) { $arr = @($r.streams) }
  $global:FenixCache[$key] = $arr
  return $arr
}

function Get-FenixAudio($s) {
  $t = [string]$s.title
  $lbl = ''
  if ($t -match 'Dublado|Portugu') { $lbl = 'Dublado PT-BR' }
  elseif ($t -match 'Legendado') { $lbl = 'Legendado PT-BR' }
  elseif ($t -match 'Ingl') { $lbl = 'Ingles' }
  elseif ($t -match 'Espa') { $lbl = 'Espanhol' }
  return $lbl
}

function Pick-FenixStream($arr, [string]$Titulo = '') {
  $arr = Filter-FSSoHD $arr $Titulo
  if ($null -eq $arr) { return $null }
  $best = $null; $bestScore = -1
  foreach ($s in $arr) {
    $t = [string]$s.title; $n = [string]$s.name; $u = [string]$s.url
    $score = 0
    if ($t -match 'Dublado|Portugu') { $score += 120 }
    elseif ($t -match 'Legendado') { $score += 60 }
    if ($s.headers) { $score -= 40 }
    if ($u -match '/vauth/') { $score += 50 }
    elseif ($u -match '\.workers\.dev') { $score -= 90 }
    if ($n -match '720') { $score += 50 }
    elseif ($n -match '1080|fhd|fullhd') { $score += 30 }
    elseif ($n -match '2160|4k') { $score += 20 }
    elseif ($n -match '\bsd\b') { $score -= 5 }
    if ($score -gt $bestScore) { $bestScore = $score; $best = $s }
  }
  return $best
}

function Read-FenixReg {
  $out = @()
  if (-not (Test-Path -LiteralPath $FenixFile)) { return $out }
  foreach ($l in [IO.File]::ReadAllLines($FenixFile, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -lt 3) { continue }
    $out += [PSCustomObject]@{ Nome = $p[0]; Type = $p[1]; Id = $p[2]; Season = $(if ($p.Count -ge 4) { $p[3] } else { '' }) }
  }
  return $out
}

function Write-FenixReg($list) {
  $sb = New-Object System.Collections.Generic.List[string]
  foreach ($r in $list) {
    $line = "$($r.Nome)|$($r.Type)|$($r.Id)"
    if ($r.Season) { $line += "|$($r.Season)" }
    $sb.Add($line)
  }
  $body = if ($sb.Count -gt 0) { ($sb -join "`r`n") } else { '' }
  [IO.File]::WriteAllText($FenixFile, $body, (New-Object System.Text.UTF8Encoding($false)))
}

function Register-FenixMovie($it) {
  if ($it.Type -ne 'movie') { return "Selecione um resultado do tipo MOVIE. (Tipo atual: $($it.Type))" }
  $arr = Get-FenixStreams 'movie' $it.Id
  $s = Pick-FenixStream $arr $it.Name
  if (-not $s) { return "Sem stream disponivel no Fenix para: $($it.Name)" }
  $url = [string]$s.url
  $qual = [string]$s.name
  $lbl = Get-FenixAudio $s
  $nome = $it.Name; if ($lbl) { $nome = "$($it.Name) ($lbl)" }

  $conf = [System.Windows.Forms.MessageBox]::Show(
    "Cadastrar/atualizar o filme no Fenix:" + [Environment]::NewLine + "  $nome ($($it.Year))" + [Environment]::NewLine +
    'Stream: ' + $qual + ' / Audio: ' + $(if ($lbl) { $lbl } else { 'indefinido' }) + [Environment]::NewLine + [Environment]::NewLine + $url,
    'Fenix - confirmar', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return 'Cancelado.' }

  $ts = Backup-Channels
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $target = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch '\|\|\|filme\|') { continue }
    $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
    if (-not (Is-FenixLine $p)) { continue }
    if (FSMatchName $p[0] $it.Name) { $target = $i; break }
  }
  if ($target -ge 0) {
    $p = $lines[$target].Split([char]'|', [System.StringSplitOptions]::None)
    $p[1] = $url
    $p[0] = $nome
    $p[2] = $FenixMark
    if ($p.Count -ge 8 -and [string]::IsNullOrWhiteSpace($p[7]) -and $it.Poster) { $p[7] = $it.Poster }
    $lines[$target] = $p -join '|'
  } else {
    $capa = ''
    if ($it.Poster) { $capa = [string]$it.Poster }
    $lines += "$nome|$url|$FenixMark||filme|||$capa"
    Add-NovTitulo 'movie' $it.Name
  }
  Write-File $lines

  $reg = Read-FenixReg
  if (-not ($reg | Where-Object { $_.Type -eq 'movie' -and $_.Id -eq $it.Id })) {
    $reg += [PSCustomObject]@{ Nome = $it.Name; Type = 'movie'; Id = $it.Id; Season = '' }
    Write-FenixReg $reg
  }
  Flush-AvisoAuto | Out-Null
  return "OK! Filme '$nome' gravado no Fenix ($qual). Backup: channels.np.backup"
}

function Register-FenixSeries($it, [int]$season, [int]$startEp, [int]$endEp) {
  if ($it.Type -ne 'series') { return "Selecione um resultado do tipo SERIES. (Tipo atual: $($it.Type))" }
  if ($season -lt 1 -or $startEp -lt 1 -or $endEp -lt $startEp) { return 'Temporada >= 1, ep. inicial >= 1 e ep. final >= ep. inicial.' }

  $conf = [System.Windows.Forms.MessageBox]::Show(
    "Cadastrar a serie no Fenix:" + [Environment]::NewLine + "  $($it.Name) ($($it.Year))" + [Environment]::NewLine +
    "Temporada $season, episodios $startEp ate $endEp. Continuar?",
    'Fenix - confirmar serie', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return 'Cancelado.' }

  $ts = Backup-Channels
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $added = 0; $fails = 0; $miss = @()
  for ($e = $startEp; $e -le $endEp; $e++) {
    $rid = "$($it.Id):${season}:$e"
    $arr = Get-FenixStreams 'series' $rid
    $s = Pick-FenixStream $arr $it.Name
    if (-not $s) { $fails++; $miss += "T${season}E${e}"; continue }
    $lbl = Get-FenixAudio $s
    $label = "T${season}E${e}"
    $baseNome = $it.Name; if ($lbl) { $baseNome = "$($it.Name) ($lbl)" }
    $nome = "$baseNome $label"
    $target = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -notmatch '\|\|\|serie\|') { continue }
      $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -lt 7) { continue }
      if (-not (Is-FenixLine $p)) { continue }
      if ((Normalize-Text $p[5]) -eq (Normalize-Text $it.Name) -and (Normalize-Text $p[6]) -eq $label) { $target = $i; break }
    }
    if ($target -ge 0) {
      $p = $lines[$target].Split([char]'|', [System.StringSplitOptions]::None)
      $p[1] = [string]$s.url
      $p[0] = $nome
      $p[2] = $FenixMark
      if ($p.Count -ge 8 -and [string]::IsNullOrWhiteSpace($p[7]) -and $it.Poster) { $p[7] = $it.Poster }
      $lines[$target] = $p -join '|'
    } else {
      $capa = ''
      if ($it.Poster) { $capa = [string]$it.Poster }
      $lines += "$nome|$([string]$s.url)|$FenixMark||serie|$($it.Name)|$label|$capa"
      Add-NovTitulo 'series' $it.Name
    }
    $added++
  }
  if ($added -eq 0) { return "Nenhum episodio encontrado para $($it.Name) T$season. Faltando: " + ($miss -join ', ') + ". Nada gravado." }
  Write-File $lines

  $reg = Read-FenixReg
  if (-not ($reg | Where-Object { $_.Type -eq 'series' -and $_.Id -eq $it.Id -and $_.Season -eq ([string]$season) })) {
    $reg += [PSCustomObject]@{ Nome = $it.Name; Type = 'series'; Id = $it.Id; Season = [string]$season }
    Write-FenixReg $reg
  }
  Flush-AvisoAuto | Out-Null
  $msg = "OK! $added episodios de '$($it.Name)' T$season gravados no Fenix. Falhas: $fails"
  if ($miss.Count -gt 0) { $msg += " (faltando: " + ($miss -join ', ') + ")" }
  $msg += ". Backup: channels.np.backup"
  return $msg
}

function Add-FenixAutoReg([string[]]$lines, [array]$reg) {
  $wanted = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  foreach ($l in $lines) {
    if ($l -match '\|filme\|') {
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -ge 5 -and $p[0] -and (Is-FenixLine $p)) { $k = Normalize-Text $p[0]; if (-not $wanted.ContainsKey($k)) { $wanted[$k] = 'movie' } }
    } elseif ($l -match '\|serie\|') {
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -ge 7 -and $p[5] -and (Is-FenixLine $p)) { $k = Normalize-Text $p[5]; if (-not $wanted.ContainsKey($k)) { $wanted[$k] = 'series' } }
    }
  }
  $has = @{}
  foreach ($r in $reg) { if ($r.Nome) { $has[(Normalize-Text $r.Nome)] = $true } }
  $added = 0
  foreach ($k in $wanted.Keys) {
    if ($has.ContainsKey($k)) { continue }
    $kind = $wanted[$k]
    $disp = $null
    foreach ($l in $lines) {
      if ($kind -eq 'movie' -and $l -notmatch '\|filme\|') { continue }
      if ($kind -eq 'series' -and $l -notmatch '\|serie\|') { continue }
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if (-not (Is-FenixLine $p)) { continue }
      $cand = $null
      if ($kind -eq 'movie') { $cand = $p[0] }
      elseif ($p.Count -ge 7) { $cand = $p[5] }
      if ($cand -and (Normalize-Text $cand) -eq $k) { $disp = $cand; break }
    }
    if (-not $disp) { continue }
    $sterm = $disp
    if ($sterm -match '^\s*(.+?)\s*\([^\)]*\)\s*$') { $sterm = $Matches[1] }
    $res = Search-FSNames $sterm | Where-Object { $_.Type -eq $kind } | Select-Object -First 1
    if (-not $res) { continue }
    $reg += [PSCustomObject]@{ Nome = $disp; Type = $kind; Id = $res.Id; Season = $(if ($kind -eq 'series') { '*' } else { '' }) }
    $has[$k] = $true
    $added++
  }
  if ($added -gt 0) { Write-FenixReg $reg }
  return $added
}

function Repair-MissingFenix([string[]]$lines, [array]$reg) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) { $out.Add($l) }
  $added = 0
  $pending = @()
  foreach ($r in $reg) {
    if (-not $r -or -not $r.Nome) { continue }
    if ($r.Type -eq 'movie') {
      $exists = $false
      foreach ($l in $out) {
        if ($l -notmatch '\|filme\|') { continue }
        $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
        if ($p.Count -lt 5) { continue }
        if (-not (Is-FenixLine $p)) { continue }
        if (FSMatchName $p[0] $r.Nome) { $exists = $true; break }
      }
      if ($exists) { continue }
      $s = Pick-FenixStream (Get-FenixStreams 'movie' $r.Id) $r.Nome
      if (-not $s) { $pending += $r.Nome; continue }
      $lbl = Get-FenixAudio $s
      $nome = [string]$r.Nome
      if ($lbl -and $nome -notlike "*$lbl*") { $nome = "$nome ($lbl)" }
      $out.Add("$nome|$([string]$s.url)|$FenixMark||filme|||")
      $added++
    } else {
      $exists = $false
      foreach ($l in $out) {
        if ($l -notmatch '\|serie\|') { continue }
        $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
        if ($p.Count -lt 7) { continue }
        if (-not (Is-FenixLine $p)) { continue }
        if ((Normalize-Text $p[5]) -eq (Normalize-Text $r.Nome)) { $exists = $true; break }
      }
      if ($exists) { continue }
      $restaurou = 0
      foreach ($b in @(Find-VodLineInBackups 'serie' $r.Nome)) {
        if (-not $b) { continue }
        $pb = $b.Split([char]'|', [System.StringSplitOptions]::None)
        if (-not (Is-FenixLine $pb)) { continue }
        if ($out.Contains($b)) { continue }
        $out.Add($b); $added++; $restaurou++
      }
      if ($restaurou -eq 0) { $pending += $r.Nome }
    }
  }
  return [PSCustomObject]@{ Added = $added; Lines = $out.ToArray(); Pending = $pending }
}

function Update-AllFenix {
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return "channels.np nao encontrado em $ChannelsPath" }
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $global:LinhasInicioUpdate = $lines
  $reg = Read-FenixReg
  $auto = Add-FenixAutoReg $lines $reg
  if ($auto -gt 0) { $reg = Read-FenixReg }
  if ($reg.Count -eq 0) { return 'Nenhum item em fenix.np. Cadastre pelo painel primeiro.' }
  $rep = Repair-MissingFenix $lines $reg
  if ($rep.Added -gt 0) { $lines = $rep.Lines }
  $updated = 0; $fails = 0; $found = 0; $failList = @()
  $global:LastFenixFailList = @()
  foreach ($r in $reg) {
    if ($r.Type -eq 'movie') {
      $arr = Get-FenixStreams 'movie' $r.Id
      $s = Pick-FenixStream $arr $r.Nome
      if (-not $s) { $fails++; $failList += $r.Nome; $global:LastFenixFailList += [PSCustomObject]@{ Src='Fenix'; Tipo='filme'; Nome=$r.Nome; Serie=''; Ep='' }; continue }
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '\|filme\|') { continue }
        $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
        if (-not (Is-FenixLine $p)) { continue }
        if (FSMatchName $p[0] $r.Nome) {
          $found++
          if ($p[1] -ne ([string]$s.url)) { $p[1] = [string]$s.url; $lines[$i] = $p -join '|'; $updated++ }
          break
        }
      }
    } else {
      $allSeasons = $false
      if ($r.Season -eq '*' -or $r.Season -eq '') { $allSeasons = $true }
      else {
        $season = 0; [void][int]::TryParse($r.Season, [ref]$season)
        if ($season -lt 1) { $fails++; $failList += $r.Nome; $global:LastFenixFailList += [PSCustomObject]@{ Src='Fenix'; Tipo='serie'; Nome=$r.Nome; Serie=$r.Nome; Ep='' }; continue }
      }
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '\|serie\|') { continue }
        $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
        if ($p.Count -lt 7) { continue }
        if (-not (Is-FenixLine $p)) { continue }
        if ((Normalize-Text $p[5]) -ne (Normalize-Text $r.Nome)) { continue }
        $ep = Parse-EpLabel $p[6]
        if (-not $ep.Ok) { continue }
        if (-not $allSeasons -and $ep.Season -ne $season) { continue }
        $found++
        $rid = "$($r.Id):$($ep.Season):$($ep.Ep)"
        $arr = Get-FenixStreams 'series' $rid
        $s = Pick-FenixStream $arr $r.Nome
        if (-not $s) { $fails++; $failList += "$($r.Nome) $($p[6])"; $global:LastFenixFailList += [PSCustomObject]@{ Src='Fenix'; Tipo='serie'; Nome=$p[0]; Serie=$p[5]; Ep=$p[6] }; continue }
        if ($p[1] -ne ([string]$s.url)) { $p[1] = [string]$s.url; $lines[$i] = $p -join '|'; $updated++ }
      }
    }
  }
  $global:LastFenixStats = @{ Updated = $updated; Found = $found; Fails = $fails }
  if ($updated -gt 0 -or $rep.Added -gt 0) {
    Backup-Channels | Out-Null
    Write-MergeDisco $lines
  }
  if ($fails -gt 0) {
    $msg = "Fenix: $updated link(s) atualizado(s) de $found localizado(s). Falhas: $fails"
    if ($rep.Added -gt 0) { $msg += ". ($($rep.Added) linha(s) do Fenix recuperada(s) - agora visivel(is) em Filmes e Series)" }
    $msg += '. Sem link: ' + ($failList -join ', ')
  } elseif ($updated -gt 0 -or $rep.Added -gt 0) {
    $msg = "OK! $updated link(s) atualizado(s) de $found. Todos os itens medidos respondem."
    if ($rep.Added -gt 0) { $msg += " ($($rep.Added) linha(s) do Fenix recuperada(s))" }
  } else {
    $msg = "Nada para atualizar. $found item(ns) ja estavam com link bom."
  }
  return $msg
}

# ---------------- MINHA TV (addon de canais ao vivo) ----------------

function MTV-Request([string]$u, [int]$timeout = 40) {
  try {
    $h = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' }
    return Invoke-RestMethod -Uri $u -Headers $h -TimeoutSec $timeout -ErrorAction Stop
  } catch { return $null }
}

$global:MTVFlat = $null
$global:MTVPaldi = $null
$global:MTVPaldiCat = @{}

function MTV-PaldiCatalogo {
  if ($null -ne $global:MTVPaldi) { return $global:MTVPaldi }
  $u = "$PaldiHost/player_api.php?username=$PaldiUser&password=$PaldiPass&action=get_live_streams"
  for ($t = 1; $t -le 3; $t++) {
    $r = MTV-Request $u 60
    if ($r -and $r.Count -gt 0) {
      $global:MTVPaldi = @($r)
      try {
        $c = MTV-Request "$PaldiHost/player_api.php?username=$PaldiUser&password=$PaldiPass&action=get_live_categories" 45
        if ($c) { foreach ($x in $c) { $global:MTVPaldiCat[[string]$x.category_id] = [string]$x.category_name } }
      } catch {}
      return $global:MTVPaldi
    }
    Start-Sleep -Seconds 4
  }
  return @()
}

function MTV-PaldiCategoriaDoId([string]$id) {
  if ($id -and $global:MTVPaldiCat.ContainsKey($id)) { return $global:MTVPaldiCat[$id] }
  return ''
}

function MTV-FlatCatalogo {
  if ($null -ne $global:MTVFlat) { return $global:MTVFlat }
  $pal = MTV-PaldiCatalogo
  if ($pal.Count -gt 0) {
    $out = @()
    foreach ($c in $pal) {
      $logo = ''
      if ($c.stream_icon) { $logo = [string]$c.stream_icon }
      $out += [PSCustomObject]@{ name=[string]$c.name; id=[string]$c.stream_id; poster=$logo; category_id=[string]$c.category_id }
    }
    $global:MTVFlat = $out
    return $global:MTVFlat
  }
  for ($t = 1; $t -le 3; $t++) {
    $r = MTV-Request "$MtvBase/catalog/tv/minhatv_channels.json" 90
    if ($r -and $r.metas) { $global:MTVFlat = @($r.metas); return $global:MTVFlat }
    Start-Sleep -Seconds 4
  }
  return @()
}

function MTV-GrupoDeNome([string]$nome) {
  $nn = Normalize-Text $nome
  if ($nn -match 'home.*health|health.*home|h.?&.?h') { return 'Variedades' }
  $b = MTV-BaseNome $nome
  if ($b -match '^premiere') { return 'Esportes' }
  if ($b -match 'cartoon|nick|disney') { return 'Infantis' }
  return 'Abertos e Variedades'
}

function MTV-Buscar([string]$q) {
  $flat = MTV-FlatCatalogo
  if ($flat.Count -eq 0) { return @() }
  $qn = Normalize-Text $q
  $alias = @()
  if ($qn -match '^h.?&?.?h$|^hh$') { $alias = @('home', 'health') }
  $res = @()
  foreach ($m in $flat) {
    $nome = [string]$m.name
    $nn = Normalize-Text $nome
    $ok = $false
    if ($alias.Count -gt 0) { if ($nn -match '\bhome\b' -and $nn -match '\bhealth\b') { $ok = $true } }
    elseif ($nn -like "*$qn*") { $ok = $true }
    if (-not $ok) { continue }
    if ($nome -match '(?i)\b(?:uhd|4k|8k|hdr|qhd|fhd|h265|hevc|1440p|1080p|1080i)\b') { continue }
    $grp = MTV-GrupoDeNome $nome
    $res += [PSCustomObject]@{ Name=$nome; Id=[string]$m.id; Poster=$(if($m.poster){[string]$m.poster}else{''}); Grupo=$grp; Display="$nome   [$grp]" }
  }
  return ($res | Sort-Object Name)
}

function Add-MinhaTv($it, [string]$grupo, [string]$logo, [bool]$usarRelay = $true) {
  $nome = $it.Name
  if (-not $grupo) { $grupo = $it.Grupo }
  if (-not $logo) { $logo = $it.Poster }
  $s = MTV-StreamOf $it.Id
  if (-not $s) { return "Nao consegui a URL do addon agora (504): $nome - tente de novo, ou cole a URL direto (opcao abaixo)" }
  if ($usarRelay) { $s = MTV-RelayUrl $s }
  $ts = Backup-Channels
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $target = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -ge 2 -and (Normalize-Text $p[0]) -eq (Normalize-Text $nome)) { $target = $i; break }
  }
  $line = (@($nome, $s, $grupo, $logo, '', '', '', '') -join '|')
  if ($target -ge 0) { $lines[$target] = $line } else { $lines += $line }
  Write-File $lines
  MTV-SaveId $nome $it.Id
  return "OK! Canal '$nome' gravado (grupo: $grupo). Backup: channels.np.backup"
}

function Add-MinhaTvUrl([string]$nome, [string]$url, [string]$grupo, [string]$logo, [bool]$usarRelay = $true) {
  if (-not $url) { return 'URL vazia, nada a fazer.' }
  if (-not $nome) { $nome = 'Canal colado ' + (Get-Date -Format 'dd-MM-HHmm') }
  if (-not $grupo) { $grupo = 'Abertos e Variedades' }
  if (-not $logo) { $logo = '' }
  if ($usarRelay) { $url = MTV-RelayUrl $url }
  $ts = Backup-Channels
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $target = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $p = $lines[$i].Split([char]'|', [System.StringSplitOptions]::None)
    if ($p.Count -ge 2 -and (Normalize-Text $p[0]) -eq (Normalize-Text $nome)) { $target = $i; break }
  }
  $line = (@($nome, $url, $grupo, $logo, '', '', '', '') -join '|')
  if ($target -ge 0) { $lines[$target] = $line } else { $lines += $line }
  Write-File $lines
  $id = MTV-FindIdDoNome $nome
  if ($id) { MTV-SaveId $nome $id }
  $msg = "OK! Canal '$nome' gravado (grupo: $grupo). Backup: channels.np.backup"
  if ($logo) { $msg += '  Logo: ' + $logo.Substring(0, [math]::Min(50, $logo.Length)) + '...' }
  return $msg
}

function MTV-LogoDoNome([string]$nome) {
  if (-not $nome) { return '' }
  $flat = MTV-FlatCatalogo
  if ($flat.Count -eq 0) { return '' }
  $nn = Normalize-Text $nome
  $best = $null
  foreach ($m in $flat) {
    $mn = Normalize-Text ([string]$m.name)
    if ($mn -eq $nn) { $best = $m; break }
    if (-not $best -and $mn -like "*$nn*") { $best = $m }
  }
  if ($best -and $best.poster) { return [string]$best.poster }
  return ''
}

function MTV-StreamOf([string]$id) {
  if ($id -and $id -match '^\d+$') {
    return ("$PaldiHost/live/$PaldiUser/$PaldiPass/$id.m3u8")
  }
  $u = "$MtvBase/stream/tv/$id.json"
  $sleeps = @(8, 20, 35)
  for ($t = 0; $t -le 3; $t++) {
    $r = MTV-Request $u 90
    if ($r -and $r.streams -and $r.streams.Count -gt 0) { return [string]$r.streams[0].url }
    if ($t -lt $sleeps.Count) { Start-Sleep -Seconds $sleeps[$t] }
  }
  return $null
}

function Test-StreamUrl([string]$url) {
  if (-not $url) { return $false }
  try {
    $r = [System.Net.WebRequest]::Create($url)
    $r.Method = 'GET'
    $r.Timeout = 10000
    $r.ReadWriteTimeout = 10000
    $r.UserAgent = 'Mozilla/5.0'
    $r.MaximumAutomaticRedirections = 5
    $r.Proxy = $null
    $resp = $r.GetResponse()
    try {
      $ct = [string]$resp.ContentType
      $s = $resp.GetResponseStream()
      try {
        $buf = New-Object byte[] 8192
        $n = $s.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $false }
        $head = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        if ($head -match '#EXTM3U') { return $true }
        if ($ct -match 'm3u8|vnd.apple|mp2t|octet|video|x-mpegurl') { return $true }
        return $false
      } finally { $s.Close() }
    } finally { $resp.Close() }
  } catch { return $false }
}

function MTV-BaseNome([string]$nome) {
  $n = ($nome.ToLowerInvariant() -replace '\([^)]*\)', ' ' -replace '\b(uhd|8k|4k|hdr|qhd|1440p|1080p|1080i|720p|480p|480i|360p|240p|fhd|hd|hq|sq|sd)\b', ' ')
  $n = ($n -replace '[\s-]+', ' ').Trim()
  if ($n -match '^(.*)\s+(sp|rj|mg|rs|sc|pr|ba|ce|pe|rn|pb|al|se|pi|ma|pa|am|ac|ro|rr|ap|to|go|ms|mt|es|df|sul|norte)$') { $n = $Matches[1].Trim() }
  if ($n -match '^(.*)\s+(nordeste|sudeste|centro.?oeste|do sul|do norte|brasilia)$') { $n = $Matches[1].Trim() }
  $n = $n -replace '^(tv|rede|canal|site)\s+', ''
  return $n.Trim()
}

function FS-JsonEscape([string]$s) {
  if ($null -eq $s) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($c in $s.ToCharArray()) {
    if ($c -eq '"') { [void]$sb.Append('\"') }
    elseif ($c -eq '\') { [void]$sb.Append('\\') }
    elseif ($c -eq "`n") { [void]$sb.Append('\n') }
    elseif ($c -eq "`r") { [void]$sb.Append('\r') }
    elseif ($c -eq "`t") { [void]$sb.Append('\t') }
    elseif ($c -eq "`b") { [void]$sb.Append('\b') }
    elseif ($c -eq "`f") { [void]$sb.Append('\f') }
    else { [void]$sb.Append($c) }
  }
  return $sb.ToString()
}

  function FS-TvCategory([string]$group) {
    $t = $group.Replace(';', '').Trim().ToLowerInvariant()
    if ($t.Length -eq 0) { return 'Outros' }
    switch ($t) {
      'infantis'             { return 'Infantis' }
      # canal de filme (HBO, Megapix, Telecine) e' categoria propria, "FILMES TV".
      # "Filmes" sozinho e' a aba de filme suinto do app e ficaria confuso no
      # mesmo trilho da TV ao vivo.
      'filmes'               { return 'FILMES TV' }
      'filmes tv'            { return 'FILMES TV' }
      'series'               { return 'Series' }
    'esportes'             { return 'Esportes' }
    'noticias'             { return 'Noticias' }
    'religiosos'           { return 'Religiosos' }
    'documentarios'        { return 'Documentarios' }
    'musica'               { return 'Musica' }
    'educativos'           { return 'Educativos' }
    'abertos e variedades' { return 'Abertos e Variedades' }
    'outros'               { return 'Outros' }
  }
  if ($t.IndexOf('kids') -ge 0 -or $t.IndexOf('animation') -ge 0 -or $t.IndexOf('cartoon') -ge 0) { return 'Infantis' }
    if ($t.IndexOf('movie') -ge 0 -or $t.IndexOf('cinema') -ge 0 -or $t.IndexOf('films') -ge 0 -or $t.IndexOf('filmes') -ge 0 -or $t.IndexOf('hits') -ge 0) { return 'FILMES TV' }
  if ($t.IndexOf('document') -ge 0 -or $t.IndexOf('auto') -ge 0) { return 'Documentarios' }
  if ($t.IndexOf('series') -ge 0 -or $t.IndexOf('comedy') -ge 0 -or $t.IndexOf('classic') -ge 0) { return 'Series' }
  if ($t.IndexOf('sport') -ge 0 -or $t.IndexOf('outdoor') -ge 0) { return 'Esportes' }
  if ($t.IndexOf('news') -ge 0 -or $t.IndexOf('business') -ge 0 -or $t.IndexOf('legisl') -ge 0 -or $t.IndexOf('congr') -ge 0 -or $t.IndexOf('senate') -ge 0 -or $t.IndexOf('parl') -ge 0) { return 'Noticias' }
  if ($t.IndexOf('relig') -ge 0 -or $t.IndexOf('chris') -ge 0 -or $t.IndexOf('muslim') -ge 0 -or $t.IndexOf('jewish') -ge 0 -or $t.IndexOf('bible') -ge 0 -or $t.IndexOf('catholic') -ge 0 -or $t.IndexOf('evang') -ge 0) { return 'Religiosos' }
  if ($t.IndexOf('educ') -ge 0 -or $t.IndexOf('school') -ge 0 -or $t.IndexOf('learn') -ge 0 -or $t.IndexOf('univ') -ge 0 -or $t.IndexOf('course') -ge 0) { return 'Educativos' }
  if ($t.IndexOf('music') -ge 0 -or $t.IndexOf('concert') -ge 0) { return 'Musica' }
  return 'Abertos e Variedades'
}

function FS-CategoriaDoItem([string]$tipo, [string]$group, [string]$catSerie = '') {
  if ($tipo -eq 'filme') { return 'Filmes' }
  if ($tipo -eq 'serie') {
    # A categoria escolhida no painel (aba Frost) manda na do padrao "Series".
    # E ela que o app usa para separar as series na coluna da esquerda.
    $c = ([string]$catSerie).Trim()
    if ($c) { return $c }
    return 'Series'
  }
  return FS-TvCategory $group
}

function Get-AvisoTexto {
  if (-not (Test-Path -LiteralPath $AvisoFile)) { return '' }
  try { return [IO.File]::ReadAllText($AvisoFile, [Text.Encoding]::UTF8).Trim() } catch { return '' }
}

# ---------------- AVISO AUTOMATICO DE TITULO NOVO (10/10/2026) ----------------
# O painel wrote na aba "Aviso na tela inicial". Esta parte e' o aviso que o
# painel faz SOZINHO: quando entra um filme ou serie nova no catalogo, ele manda
# um "NOVA SERIE ADICIONADA! (fulano)" para a tela inicial do app.
#
# Como some sozinho: o aviso automatico tem HORA LIMITE. Ele vai para o
# noviplay.json junto com "avisoAte" (a hora, em milissegundos). O app esconde
# o cartao quando essa hora passa (isso precisa do app novo) e o painel tambem
# para de mandar o texto depois disso - o aviso manual que o usuario escreveu
# volta a valer.
#
# Regra do usuario: so avisa quando entra UM titulo por vez. Se a atualizacao
# achou 2 ou mais titulos novos, nao avisa - assim a tela de todo mundo nao
# fica pulando aviso.
$script:NovosTitulos = @()

function Get-AvisoAutoCfg {
  $cfg = [PSCustomObject]@{
    On = $true; Min = 5
    Traduzir = $true
    Serie = 'NOVA SERIE ADICIONADA! ({nome})'
    Filme = 'NOVO FILME ADICIONADO! ({nome})'
  }
  if (-not (Test-Path -LiteralPath $AvisoAutoCfg)) { return $cfg }
  try {
    foreach ($l in [IO.File]::ReadAllLines($AvisoAutoCfg, [Text.Encoding]::UTF8)) {
      if (-not $l.Trim()) { continue }
      $p = $l.Split([char]'=', 2)
      if ($p.Count -lt 2) { continue }
      $k = $p[0].Trim().ToLowerInvariant()
      $v = $p[1]
      switch ($k) {
        'on'    { $cfg.On = ($v.Trim() -eq '1') }
        'min'   { $m = 0; if ([int]::TryParse($v.Trim(), [ref]$m) -and $m -ge 1 -and $m -le 120) { $cfg.Min = $m } }
        'trad'  { $cfg.Traduzir = ($v.Trim() -ne '0') }
        'serie' { if ($v.Trim()) { $cfg.Serie = $v.Trim() } }
        'filme' { if ($v.Trim()) { $cfg.Filme = $v.Trim() } }
      }
    }
  } catch { }
  return $cfg
}

function Set-AvisoAutoCfg($cfg) {
  $b = 'on=' + $(if ($cfg.On) { '1' } else { '0' }) + "`r`n"
  $b += 'min=' + $cfg.Min + "`r`n"
  $b += 'trad=' + $(if ($cfg.Traduzir) { '1' } else { '0' }) + "`r`n"
  $b += 'serie=' + $cfg.Serie + "`r`n"
  $b += 'filme=' + $cfg.Filme + "`r`n"
  [IO.File]::WriteAllText($AvisoAutoCfg, $b, (New-Object System.Text.UTF8Encoding($false)))
}

# Devolve o aviso automatico que esta valendo agora, ou $null se nao tem ou se
# ja venceu. Quando vence, apaga o arquivo: assim o aviso manual volta.
function Get-AvisoAutoAtivo {
  if (-not (Test-Path -LiteralPath $AvisoAutoAtual)) { return $null }
  try {
    $linhas = [IO.File]::ReadAllLines($AvisoAutoAtual, [Text.Encoding]::UTF8)
    if ($linhas.Count -lt 2) { return $null }
    $txt = $linhas[0]
    $ate = 0L
    if (-not [int64]::TryParse($linhas[1].Trim(), [ref]$ate)) { return $null }
    if ($ate -le 0) { return $null }
    if ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge $ate) {
      try { Remove-Item -LiteralPath $AvisoAutoAtual -Force -ErrorAction SilentlyContinue } catch { }
      return $null
    }
    return [PSCustomObject]@{ Texto = $txt; Ate = $ate }
  } catch { return $null }
}

function Set-AvisoAuto([string]$texto, [int]$minutos) {
  $min = [int]$minutos
  if ($min -lt 1) { $min = 5 }
  $ate = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ([int64]$min * 60000)
  $b = $texto + "`r`n" + $ate + "`r`n"
  [IO.File]::WriteAllText($AvisoAutoAtual, $b, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $ateTxt = [DateTimeOffset]::FromUnixTimeMilliseconds($ate).ToLocalTime().ToString('dd/MM HH:mm:ss')
    [IO.File]::AppendAllText($AvisoAutoLog, ((Get-Date -Format 'dd/MM/yyyy HH:mm:ss') + '  ' + $texto + '   |  some as ' + $ateTxt + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
  return $ate
}

# Traduz o NOME do titulo para portugues (pt-BR) na hora do aviso automatico.
# "Finding Nemo" vira "Encontrando Nemo", e o aviso vai para a tela em portugues.
# O resultado fica guardado em titulo_trad.np: assim cada titulo e' traduzido
# UMA vez so, sem chamar o Google de novo a cada atualizacao.
$script:CacheTrad = $null

function Get-CacheTrad {
  if ($null -ne $script:CacheTrad) { return $script:CacheTrad }
  $h = @{}
  $f = Join-Path $NoviplayDir 'titulo_trad.np'
  if (Test-Path -LiteralPath $f) {
    try {
      foreach ($l in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) {
        if (-not $l.Trim()) { continue }
        $p = $l.Split([char]'|', 2)
        if ($p.Count -ge 2 -and $p[0].Trim()) { $h[$p[0].Trim()] = [string]$p[1] }
      }
    } catch { }
  }
  $script:CacheTrad = $h
  return $h
}

function Traduz-Titulo([string]$titulo) {
  $t = ([string]$titulo).Trim()
  if (-not $t -or $t.Length -gt 160) { return '' }
  $cache = Get-CacheTrad
  if ($cache.ContainsKey($t)) { return [string]$cache[$t] }
  # ja esta em portugues? o google devolveria igual, mas nao vale a pena perguntar
  if ($t -notmatch '[a-zA-Z]') { return '' }
  $q = [uri]::EscapeDataString($t)
  $resp = ''
  foreach ($u in @(
      ('https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=pt&dt=t&q=' + $q),
      ('https://translate.googleapis.com/translate_a/t?client=gtx&sl=auto&tl=pt&q=' + $q))) {
    try { $r = SP-Http $u } catch { $r = $null }
    if ($r) { $resp = SP-ParseTrans $r }
    if ($resp) { break }
  }
  $resp = ([string]$resp).Trim()
  # guarda o resultado (inclusive o vazio, para nao tentar de novo)
  $cache[$t] = $resp
  try {
    $linhas = @()
    foreach ($k in $cache.Keys) { $linhas += ($k + '|' + $cache[$k]) }
    [IO.File]::WriteAllText((Join-Path $NoviplayDir 'titulo_trad.np'), (($linhas -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
  return $resp
}

function Texto-AvisoTraduzido([string]$tipo, [string]$nome) {
  $cfg = Get-AvisoAutoCfg
  $usar = $nome
  if ($cfg.Traduzir) {
    $tr = Traduz-Titulo $nome
    # so usa a traducao se ela make sentido (nao vazia, nao igual, nao lixo)
    if ($tr -and $tr.Length -le 160 -and (Normalize-Text $tr) -ne (Normalize-Text $nome)) { $usar = $tr }
  }
  $modelo = if ($tipo -eq 'movie') { $cfg.Filme } else { $cfg.Serie }
  return ($modelo -replace '\{nome\}', $usar)
}

function Limpa-AvisoAuto {
  if (Test-Path -LiteralPath $AvisoAutoAtual) {
    try { Remove-Item -LiteralPath $AvisoAutoAtual -Force } catch { }
  }
}

function Get-AvisoAutoLog {
  $itens = @()
  if (-not (Test-Path -LiteralPath $AvisoAutoLog)) { return $itens }
  try {
    $ls = [IO.File]::ReadAllLines($AvisoAutoLog, [Text.Encoding]::UTF8)
    $p = @($ls | Where-Object { $_.Trim() })
    if ($p.Count -gt 40) { $p = $p[($p.Count - 40)..($p.Count - 1)] }
    for ($i = $p.Count - 1; $i -ge 0; $i--) { $itens += $p[$i] }
  } catch { }
  return $itens
}

# Chamado por todo lugar que acrescenta um titulo novo no catalogo.
function Add-NovTitulo([string]$tipo, [string]$nome) {
  if (-not $nome) { return }
  # o mesmo titulo so entra uma vez, mesmo que venha temporada por temporada
  $k = (Normalize-Text $nome) + '|' + $tipo
  foreach ($t in @($script:NovosTitulos)) {
    if (((Normalize-Text $t.Nome) + '|' + $t.Tipo) -eq $k) { return }
  }
  $script:NovosTitulos += [PSCustomObject]@{ Tipo = $tipo; Nome = $nome }
}

# Decide e age: so manda aviso se entrar UM titulo e se o recurso estiver ligado.
function Flush-AvisoAuto([switch]$SemEnvio) {
  $novos = @($script:NovosTitulos)
  $script:NovosTitulos = @()
  if ($novos.Count -ne 1) { return '' }
  $cfg = Get-AvisoAutoCfg
  if (-not $cfg.On) { return '' }
  $n = $novos[0]
  # o texto vai traduzido para portugues (Finding Nemo -> Encontrando Nemo),
  # se a traducao estiver ligada na aba "Aviso automatico"
  $texto = Texto-AvisoTraduzido $n.Tipo $n.Nome
  if ($SemEnvio) { Set-AvisoAuto $texto $cfg.Min; return "aviso automatico gravado (sem envio): $texto" }
  Set-AvisoAuto $texto $cfg.Min
  $res = Sync-NoviplayJson -Force
  Agenda-LimpezaAvisoAuto
  return "aviso automatico enviado: $texto | $res"
}

# Deixa um processo de fundo esperando o aviso vencer para tirar o texto do
# servidor. Roda escondido e nao depende do painel continuar aberto - por isso
# o app novo consegue sumir com o cartao na hora exata, e o app antigo apaga
# no proximo refresh dele.
function Agenda-LimpezaAvisoAuto {
  $at = Get-AvisoAutoAtivo
  if (-not $at) { return }
  $ms = $at.Ate - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $seg = [int][Math]::Ceiling($ms / 1000.0) + 5
  if ($seg -lt 10) { $seg = 10 }
  if ($seg -gt 7200) { $seg = 7200 }
  $ajudante = Join-Path $NoviplayDir 'limpa_aviso_auto.ps1'
  if (-not (Test-Path -LiteralPath $ajudante)) { return }
  $psExe = Join-Path $PSHOME 'powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe)) { return }
  try {
    Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $ajudante, '-Segundos', "$seg") -WindowStyle Hidden | Out-Null
  } catch { }
}

# ---------------- AVISO PROGRAMADO (entra na proxima atualizacao) ----------------
# Mesmo esquema da fila de futuros lancamentos: o painel GRAVA o texto, mas nao
# manda nada agora. E a atualizacao automatica que aplica o
# aviso e envia junto com o noviplay.json do mesmo horario (no fim dela vem o
# Sync-NoviplayJson). Assim o aviso e os filmes novos chegam juntos no app.

function Get-AvisoProgramado {
  if (-not (Test-Path -LiteralPath $AvisoProgFile)) { return '' }
  try { return [IO.File]::ReadAllText($AvisoProgFile, [Text.Encoding]::UTF8) } catch { return '' }
}

function Set-AvisoProgramado([string]$txt) {
  [IO.File]::WriteAllText($AvisoProgFile, $txt, (New-Object System.Text.UTF8Encoding($false)))
  return $true
}

function Cancelar-AvisoProgramado {
  if (Test-Path -LiteralPath $AvisoProgFile) { Remove-Item -LiteralPath $AvisoProgFile -Force }
}

function Aplicar-AvisoProgramado {
  if (-not (Test-Path -LiteralPath $AvisoProgFile)) { return '' }
  $txt = Get-AvisoProgramado
  [IO.File]::WriteAllText($AvisoFile, $txt.Trim(), (New-Object System.Text.UTF8Encoding($false)))
  Cancelar-AvisoProgramado
  if ($txt.Trim()) { return 'aviso aplicado e sera enviado nesta atualizacao: "' + $txt.Trim() + '"' }
  return 'aviso aplicado: a tela inicial fica SEM cartao de aviso.'
}

  function Build-NoviPlayJson {
    $sb = New-Object System.Collections.Generic.List[string]

    # Mapa canal -> tvg-id do EPG. Sem isso o app nao tinha como casar o canal
    # com o guia (epgshare01) e caia num casamento por nome, que trazia a
    # programacao do canal errado. O id vem da propria fonte (epg_channel_id).
    $epgMap = @{}
    $EpgFile = Join-Path $NoviplayDir 'channels.epg'
    if (Test-Path -LiteralPath $EpgFile) {
      foreach ($l in [IO.File]::ReadAllLines($EpgFile, [Text.Encoding]::UTF8)) {
        if ($l.Trim() -eq '') { continue }
        $q = $l.Split([char]'|')
        if ($q.Count -ge 2 -and $q[1]) { $epgMap[[string]$q[0]] = [string]$q[1] }
      }
    }
  # 10/10/2026: aviso automatico tem HORA LIMITE. O texto automatico (quando
  # existe) tem prioridade sobre o manual enquanto estiver na tela, e o app
  # esconde o cartao sozinho quando o "avisoAte" passa. Sem aviso automatico,
  # o JSON sai igual sempre - com o aviso manual e sem o avisoAte.
  $avisoAuto = Get-AvisoAutoAtivo
  $aviso = [string](Get-AvisoTexto)
  if ($avisoAuto -and $avisoAuto.Texto) { $aviso = [string]$avisoAuto.Texto }
  $sb.Add('{"aviso":"' + (FS-JsonEscape $aviso) + '"')
  if ($avisoAuto) { $sb.Add(',"avisoAte":' + [int64]$avisoAuto.Ate) }
  $sb.Add(',"devices":{')
  $count = 0
  if (Test-Path -LiteralPath $TvBoxFile) {
    $tvs = [IO.File]::ReadAllLines($TvBoxFile, [Text.Encoding]::UTF8)
    foreach ($line in $tvs) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $p = $line.Split([char]'|')
      if ($p.Count -lt 4) { continue }
      if ($count -gt 0) { $sb.Add(',') }
      $count++
      $ativo = 'false'
      if ($p[3] -eq '1' -or $p[3] -ieq 'true') { $ativo = 'true' }
      $sb.Add('"' + (FS-JsonEscape $p[0]) + '":{"nome":"' + (FS-JsonEscape $p[1]) + '","ativo":' + $ativo)
      $exp = 0L
      if ($p.Count -ge 5 -and [int64]::TryParse($p[4], [ref]$exp) -and $exp -gt 0) { $sb.Add(',"validade":' + $exp.ToString()) }
      $sb.Add('}')
    }
  }
  $sb.Add('},"canais":[')

  $first = $true
  # CONGELAMENTO DESLIGADO (pedido do usuario): titulo marcado como "frio"
  # NAO e' mais removido do JSON. O app passa a mostrar sempre o catalogo
  # inteiro, e o que nao abre fica visivel em vez de sumir. A lista continua
  # sendo montada e registrada no log, so para diagnostico.
  $friasNome = @{}
  $friasArq = Join-Path $NoviplayDir 'series_frias.txt'
  $friasLista = @()
  if (Test-Path -LiteralPath $friasArq) {
    foreach ($fl in [IO.File]::ReadAllLines($friasArq, [Text.Encoding]::UTF8)) {
      $fq = $fl.Split([char]'|')
      if ($fq.Count -ge 2 -and $fq[1]) { $friasNome[(Normalize-Text $fq[1])] = $true; $friasLista += $fq[1] }
    }
  }
  $script:FriasNoCatalogo = $friasLista
  # id IMDb das series: sai do registro do addon (froststream.np/fenix.np) e
  # vai no JSON para o app nao precisar adivinhar pelo nome (ex.: "See").
  $serieIds = @{}
  try {
    foreach ($r in @(Read-FrostReg)) {
      if ([string]$r.Type -eq 'series' -and $r.Id) { $serieIds[(Normalize-Text $r.Nome)] = [string]$r.Id }
    }
    foreach ($r in @(Read-FenixReg)) {
      if ([string]$r.Type -eq 'series' -and $r.Id -and -not $serieIds.ContainsKey((Normalize-Text $r.Nome))) { $serieIds[(Normalize-Text $r.Nome)] = [string]$r.Id }
    }
  } catch { }
  if (Test-Path -LiteralPath $ChannelsPath) {
    $cls = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    foreach ($line in $cls) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $p = $line.Split([char]'|')
      if ($p.Count -lt 1) { continue }
      # (o filtro de titulo congelado foi removido: nada e' pulado aqui)
      $nome  = $p[0]
      $url   = $(if ($p.Count -ge 2) { $p[1] } else { '' })
      $group = $(if ($p.Count -ge 3) { $p[2] } else { '' })
      $logo  = $(if ($p.Count -ge 4) { $p[3] } else { '' })
      $tipo  = $(if ($p.Count -ge 5) { $p[4] } else { '' })
      $serie = $(if ($p.Count -ge 6) { $p[5] } else { '' })
      $eps   = $(if ($p.Count -ge 7) { $p[6] } else { '' })
      $capa  = $(if ($p.Count -ge 8) { $p[7] } else { '' })
      $sinop = $(if ($p.Count -ge 9) { $p[8] } else { '' })
      $catS  = $(if ($p.Count -ge 10) { $p[9] } else { '' })
      if ($nome.Length -eq 0) { continue }
      if (-not $first) { $sb.Add(',') }
      $first = $false
      $sb.Add('{"nome":"' + (FS-JsonEscape $nome) + '","url":"' + (FS-JsonEscape $url) + '","logo":"' + (FS-JsonEscape $logo) + '","categoria":"' + (FS-JsonEscape (FS-CategoriaDoItem $tipo $group $catS)) + '"')
      if ($epgMap.ContainsKey($nome)) {
        $tvg = $epgMap[$nome]
        $sb.Add(',"tvg_id":"' + (FS-JsonEscape $tvg) + '"')
        $sb.Add(',"tvg-ido":"' + (FS-JsonEscape $tvg) + '"')
        $sb.Add(',"tvg":"' + (FS-JsonEscape $tvg) + '"')
      }
      if ($serie.Length -gt 0) {
        $sb.Add(',"serie":"' + (FS-JsonEscape $serie) + '"')
        $sidS = $null
        $sk = Normalize-Text $serie
        if ($serieIds.ContainsKey($sk)) { $sidS = $serieIds[$sk] }
        if ($sidS) { $sb.Add(',"id":"' + (FS-JsonEscape $sidS) + '"') }
      }
      if ($eps.Length -gt 0) { $sb.Add(',"eps":"' + (FS-JsonEscape $eps) + '"') }
      if ($capa.Length -gt 0) { $sb.Add(',"capa":"' + (FS-JsonEscape $capa) + '"') }
      if ($sinop.Length -gt 0) { $sb.Add(',"sinopse":"' + (FS-JsonEscape $sinop) + '"') }
      $sb.Add('}')
    }
  }
  $sb.Add(']}')
  return ($sb -join '')
}

function Push-NoviplayGist([string]$content) {
  $token = ''
  if (Test-Path -LiteralPath $TokenFile) {
    $token = ([IO.File]::ReadAllLines($TokenFile, [Text.Encoding]::UTF8) | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } | Select-Object -Last 1).Trim()
  }
  if (-not $token) { return 'nao enviado: github.np sem token.' }
  $body = @{ files = @{ $GistFile = @{ content = $content } } } | ConvertTo-Json -Depth 4 -Compress
  $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'NoviPlay' }
  $null = Invoke-RestMethod -Method Patch -Uri ("https://api.github.com/gists/" + $GistId) -Headers $headers -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
  return "enviado com sucesso ao gist $GistId (a URL que a TV usa continua a mesma)."
}

function Sync-NoviplayJson([switch]$Force) {
  $json = Build-NoviPlayJson
  if (-not (Test-Path -LiteralPath $JsonDir)) { New-Item -ItemType Directory -Path $JsonDir | Out-Null }
  $changed = $true
  if (-not $Force -and (Test-Path -LiteralPath $JsonPath)) {
    $old = [IO.File]::ReadAllText($JsonPath, [Text.Encoding]::UTF8)
    if ($old -eq $json) { $changed = $false }
  }
  if ($changed) {
    [IO.File]::WriteAllText($JsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $res = Push-NoviplayGist $json
    return "noviplay.json regenerado e $res"
  }
  return 'ja esta igual (nada a enviar).'
}

function Open-Panel {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $NoviplayDir 'AutoLogin_Painel.ps1') + '"')
}

# ---------------- SINOPSE PT-BR (traduzir e enviar ao Gist) ----------------

function SP-CleanQuery([string]$q) {
  if (-not $q) { return '' }
  $n = Normalize-Text $q
  $n = $n -replace '\s*\([^)]*\)\s*', ' '
  $n = $n -replace '\s*\[[^\]]*\]\s*', ' '
  $n = $n -replace '\s*(19|20)\d{2}\s*$', ' '
  $n = $n -replace '\s*(t\s*\d+\s*e\s*\d+|s\d+\s*e\d+|\d+\s*x\s*\d+|temporada\s*\d+|temp\s*\d+)\s*$', ' '
  return (($n -replace '\s+', ' ')).Trim()
}

function SP-CleanTitle([string]$t) {
  if (-not $t) { return '' }
  $c = $t -replace '\s*(\([^)]*\)|s[eE]rie(?: de televis[aA][oO])?|filme|franquia)\s*', ' '
  return (($c -replace '\s+', ' ')).Trim()
}

function SP-TokMatch([string]$title, [string]$stem) {
  $tw = @(($title.ToLowerInvariant() -split '[^a-z0-9]+') | Where-Object { $_.Length -ge 3 })
  $sw = @(($stem.ToLowerInvariant() -split '[^a-z0-9]+') | Where-Object { $_.Length -ge 3 })
  if ($sw.Count -eq 0 -or $tw.Count -eq 0) { return $title.ToLowerInvariant().Contains($stem.ToLowerInvariant()) }
  foreach ($w in $sw) { if ($tw -notcontains $w) { return $false } }
  return $true
}

function SP-Http([string]$uri) {
  $last = $null
  for ($i = 0; $i -lt 2; $i++) {
    try {
      return Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -TimeoutSec 25 -ErrorAction Stop
    } catch {
      $last = $_
      Start-Sleep -Milliseconds 600
    }
  }
  throw $last
}

function SP-GetImdb([string]$q) {
  if (-not $q) { return '' }
  try {
    $u = 'https://v3.sg.media-imdb.com/suggestion/x/' + [uri]::EscapeDataString($q) + '.json'
    $r = SP-Http $u
    foreach ($it in @($r.d)) {
      if ($it.id -match '^tt\d+$' -and ($it.q -eq 'TV series' -or $it.q -eq 'TV mini series')) { return $it.id }
    }
    foreach ($it in @($r.d)) { if ($it.id -match '^tt\d+$') { return $it.id } }
  } catch { }
  return ''
}

function SP-CinemetaDesc([string]$imdb) {
  if (-not $imdb) { return '' }
  try {
    $r = SP-Http ('https://v3-cinemeta.strem.io/meta/series/' + $imdb + '.json')
    if ($r.meta) {
      if ($r.meta.description) { return [string]$r.meta.description }
      if ($r.meta.overview) { return [string]$r.meta.overview }
    }
  } catch { }
  return ''
}

function SP-Wikidata([string]$q) {
  $res = @('', '')
  try {
    $u = 'https://www.wikidata.org/w/api.php?action=wbsearchentities&format=json&origin=*&language=en&type=item&limit=5&search=' + [uri]::EscapeDataString($q)
    $r = SP-Http $u
    $arr = @($r.search)
    if ($arr.Count -eq 0) { return ,$res }
    $ids = @()
    foreach ($a in $arr) { if ($ids.Count -lt 5 -and $a.id) { $ids += $a.id } }
    $u2 = 'https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&origin=*&ids=' + ($ids -join '|') + '&props=claims|sitelinks&languages=pt'
    $r2 = SP-Http $u2
    $ents = $r2.entities
    $clean = Normalize-Text (SP-CleanTitle $q)
    $bestPtw = ''; $bestImdb = ''; $bestScore = -1
    if ($ents) {
      foreach ($pr in $ents.PSObject.Properties) {
        $en = $pr.Value
        $imdbO = ''; $ptw = ''
        if ($en.claims -and $en.claims.P345) {
          try {
            $dv = $en.claims.P345[0].mainsnak.datavalue
            if ($dv -and $dv.value) { $imdbO = [string]$dv.value }
          } catch { }
        }
        if ($en.sitelinks -and $en.sitelinks.ptwiki -and $en.sitelinks.ptwiki.title) { $ptw = [string]$en.sitelinks.ptwiki.title }
        $score = 0
        if ($imdbO) { $score += 10 }
        if ($ptw) {
          $ptt = Normalize-Text (SP-CleanTitle $ptw)
          if ($ptt -and (SP-TokMatch $ptt $clean)) { $score += 10 }
          if ($ptt -notlike 'lista de*') { $score += 2 }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $bestPtw = $ptw; $bestImdb = $imdbO }
      }
    }
    if ($bestImdb) { $res[1] = $bestImdb }
    if ($bestPtw) { $res[0] = $bestPtw }
  } catch { }
  return ,$res
}

function SP-PtWiki([string]$sterm, [string]$ptTitle) {
  $u = ''
  if ($ptTitle) {
    $u = 'https://pt.wikipedia.org/w/api.php?action=query&format=json&origin=*&titles=' + [uri]::EscapeDataString($ptTitle) + '&prop=extracts&exintro=1&explaintext=1&exsentences=4'
  } else {
    $u = 'https://pt.wikipedia.org/w/api.php?action=query&format=json&origin=*&generator=search&gsrsearch=' + [uri]::EscapeDataString($sterm) + '&gsrlimit=8&gsrnamespace=0&prop=extracts&exintro=1&explaintext=1&exsentences=4'
  }
  try {
    $r = SP-Http $u
    $pages = $r.query.pages
    $slim = Normalize-Text $sterm
    $cands = New-Object System.Collections.Generic.List[object]
    if ($pages) {
      foreach ($pr in $pages.PSObject.Properties) {
        $pg = $pr.Value
        if (-not $pg -or -not $pg.extract) { continue }
        $t = Normalize-Text (SP-CleanTitle $pg.title)
        if (-not $t) { continue }
        if ($t -like 'lista de*' -or $t.Split(' ') -contains 'lista' -or $t.Split(' ') -contains 'episodios') { continue }
        if (-not (SP-TokMatch $t $slim)) { continue }
        $extra = @($t.Split(' ') | Where-Object { $_.Length -ge 3 -and $slim.Split(' ') -notcontains $_ }).Count
        $cands.Add([PSCustomObject]@{ Title=$t; Extract=[string]$pg.extract; Extra=$extra })
      }
    }
    if ($cands.Count -gt 0) {
      $best = $cands | Sort-Object @{ Expression = { if ($_.Title -eq $slim) { -1 } else { $_.Extra } } } | Select-Object -First 1
      return $best.Extract.Trim()
    }
  } catch { }
  return ''
}

function SP-ParseTrans($g4) {
  if ($null -eq $g4) { return '' }
  try {
    $seg = $g4[0]
    if ($null -eq $seg) { return '' }
    if ($seg -is [string]) { return $seg }
    if ($seg -is [System.Collections.IEnumerable]) {
      $first = @($seg)[0]
      if ($first -is [string]) { return $first }
      $sb = New-Object System.Text.StringBuilder
      foreach ($s in @($seg)) {
        if ($null -ne $s -and $s -is [System.Collections.IEnumerable]) {
          $firsts = @($s)[0]
          if ($null -ne $firsts) { [void]$sb.Append([string]$firsts) }
        }
      }
      if ($sb.Length -gt 0) { return $sb.ToString() }
    }
  } catch { }
  return ''
}

function SP-GoogleTrans([string]$text) {
  if (-not $text -or $text.Length -lt 60) { return '' }
  $q = [uri]::EscapeDataString($text.Substring(0, [Math]::Min(1500, $text.Length)))
  $tr = ''
  try {
    $r = SP-Http ('https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=pt&dt=t&q=' + $q)
    $tr = SP-ParseTrans $r
  } catch { }
  if ($tr.Length -eq 0) {
    try {
      $r2 = SP-Http ('https://translate.googleapis.com/translate_a/t?client=gtx&sl=auto&tl=pt&q=' + $q)
      $tr = SP-ParseTrans $r2
    } catch { }
  }
  return $tr
}

function Get-PtSinopse([string]$serieName) {
  $q = SP-CleanQuery $serieName
  if ($q.Length -lt 2) { return '' }
  $imdb = SP-GetImdb $q
  if ($imdb) {
    $en = SP-CinemetaDesc $imdb
    if ($en) {
      $tr = SP-GoogleTrans $en
      if ($tr) { return $tr }
    }
  }
  $wd = SP-Wikidata $q
  if ($wd[0]) {
    $pt = SP-PtWiki '' $wd[0]
    if ($pt) { return $pt }
  }
  $pt = SP-PtWiki $q ''
  if ($pt) { return $pt }
  return ''
}

function Save-Sinopse([string]$serieName, [string]$sinopse) {
  $sn = Normalize-Text $serieName
  $one = (($sinopse -replace "`r", ' ') -replace "`n", ' ' -replace '\s+', ' ').Trim()
  if (-not (Test-Path -LiteralPath $ChannelsPath)) { return 'channels.np nao encontrado.' }
  $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $out = New-Object System.Collections.Generic.List[string]
  $hits = 0
  foreach ($l in $lines) {
    if ([string]::IsNullOrWhiteSpace($l)) { $out.Add($l); continue }
    $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
    $match = $false
    if ($p.Count -ge 6 -and $p[4] -eq 'serie' -and (Normalize-Text $p[5]) -eq $sn) { $match = $true }
    elseif ($p.Count -ge 2 -and (Normalize-Text $p[0]) -eq $sn) { $match = $true }
    if ($match) {
      $parts = New-Object System.Collections.Generic.List[string]
      for ($i = 0; $i -lt $p.Count; $i++) { $parts.Add($p[$i]) }
      while ($parts.Count -lt 9) { $parts.Add('') }
      $parts[8] = $one
      $line = ($parts -join '|').TrimEnd('|')
      if ($line -eq '') { $line = $l }
      $out.Add($line)
      $hits++
    } else {
      $out.Add($l)
    }
  }
  if ($hits -eq 0) { return ('Nada salvo: serie "' + $serieName + '" nao encontrada em channels.np.') }
  Write-File @($out)
  $res = Sync-NoviplayJson -Force
  return "$hits linha(s) atualizada(s). $res"
}

# 10/10/2026: paleta do painel espelhada no APP (preto + vermelho #e50914).
# Antes era cinza-azulado com botao azul; agora o painel tem a cara do NoviPlay.
$ColorBg     = [Drawing.Color]::FromArgb(14, 15, 19)     # #0e0f13 - fundo do app
$ColorPanel  = [Drawing.Color]::FromArgb(24, 25, 31)     # card escuro
$ColorCard   = [Drawing.Color]::FromArgb(31, 32, 39)     # card mais claro
$ColorBorda  = [Drawing.Color]::FromArgb(62, 40, 44)     # borda com tom vermelho
$ColorFg     = [Drawing.Color]::FromArgb(237, 239, 243)
$ColorDim    = [Drawing.Color]::FromArgb(150, 154, 163)   # #8a8a8a
$ColorBlue   = [Drawing.Color]::FromArgb(229, 9, 20)      # #e50914 - vermelho do app
$ColorVerm   = [Drawing.Color]::FromArgb(255, 90, 99)      # #ff5a63 - vermelho claro
$ColorGreen  = [Drawing.Color]::FromArgb(126, 211, 168)
$ColorRed    = [Drawing.Color]::FromArgb(255, 59, 76)       # #ff3b4c

$Font = New-Object System.Drawing.Font('Segoe UI', 10)
$FontMono = New-Object System.Drawing.Font('Consolas', 9)

$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'NoviPlay Atualizacoes - Filmes, Series e Canais'
# 10/10/2026: painel em TELA CHEIA. Antes era 740x740 fixo, e os nomes ficavam
# cortados (o botao de enviar, o rodape, as listas).
# IMPORTANTE: o WindowState vem DEPOIS do ClientSize. Se ele vier antes, o
# WinForms volta o estado para Normal quando o ClientSize e' aplicado - e o
# painel abria daquele quadradinho mesmo. Por isso o maximizado e' aplicado
# no fim (antes do ShowDialog) e reforcado no Shown.
$Form.FormBorderStyle = 'Sizable'
$Form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$Form.StartPosition = 'CenterScreen'
$Form.BackColor = $ColorBg
$Form.ForeColor = $ColorFg
$Form.Font = $Font
$Form.ClientSize = New-Object System.Drawing.Size(740, 740)

try {
  $Form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $NoviplayDir 'NoviPlay.exe'))
} catch {
  try { $Form.Icon = New-Object System.Drawing.Icon((Join-Path $NoviplayDir 'NoviPlay.ico')) } catch { }
}

# 10/10/2026: fundo vermelho e preto, no mesmo clima do app: base preta com um
# brilho vermelho no topo e outro, mais fraco, embaixo (os mesmos radial-gradient
# do style.css do app). Se o desenho falhar, cai no fundo_painel.png antigo.
function New-FundoNoviPlay {
  try {
    $w = 1920; $h = 1080
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::FromArgb(9, 10, 13))
    foreach ($brilho in @(@{ y = -300; h = 700; a = 105 }, @{ y = 620; h = 760; a = 70 })) {
      $r = New-Object System.Drawing.Rectangle(0, $brilho.y, $w, $brilho.h)
      $br = New-Object System.Drawing.Drawing2D.PathGradientBrush($r)
      $br.CenterColor = [Drawing.Color]::FromArgb($brilho.a, 229, 9, 20)
      $br.SurroundColors = @([Drawing.Color]::FromArgb(0, 229, 9, 20))
      $g.FillEllipse($br, $r)
      $br.Dispose()
    }
    $g.Dispose()
    return $bmp
  } catch { return $null }
}

try {
  $img = New-FundoNoviPlay
  if (-not $img) {
    $bgPath = Join-Path $NoviplayDir 'fundo_painel.png'
    if (Test-Path -LiteralPath $bgPath) {
      $bgStream = [IO.File]::OpenRead($bgPath)
      try {
        $bgTmp = [System.Drawing.Image]::FromStream($bgStream)
        $img = New-Object System.Drawing.Bitmap($bgTmp)
        $bgTmp.Dispose()
      } finally { $bgStream.Dispose() }
    }
  }
  if ($img) {
    $Form.BackgroundImage = $img
    $Form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::None
  }
} catch { }

$LblTitulo = New-Object System.Windows.Forms.Label
$LblTitulo.Text = 'NoviPlay Atualizacoes'
$LblTitulo.Font = New-Object System.Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
$LblTitulo.Location = New-Object System.Drawing.Point(14, 10)
$LblTitulo.AutoSize = $true

$LblSub = New-Object System.Windows.Forms.Label
$LblSub.Text = 'Abas separadas: Filmes/Series (trocar URL caindo) e Canais TV (buscar e excluir).'
$LblSub.ForeColor = $ColorDim
$LblSub.Location = New-Object System.Drawing.Point(16, 40)
$LblSub.Size = New-Object System.Drawing.Size(708, 18)

$LblProxima = New-Object System.Windows.Forms.Label
$LblProxima.ForeColor = $ColorGreen
$LblProxima.AutoSize = $true
$LblProxima.Font = New-Object System.Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$LblProxima.Location = New-Object System.Drawing.Point(16, 62)
$LblProxima.Text = 'Proxima atualizacao automatica: ...'

$LblUltima = New-Object System.Windows.Forms.Label
$LblUltima.ForeColor = $ColorDim
$LblUltima.AutoSize = $true
$LblUltima.Font = New-Object System.Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$LblUltima.Location = New-Object System.Drawing.Point(16, 84)
$LblUltima.Text = 'Ultima atualizacao automatica: nenhuma ainda'

$LblSinc = New-Object System.Windows.Forms.Label
$LblSinc.ForeColor = $ColorDim
$LblSinc.AutoSize = $true
$LblSinc.Font = New-Object System.Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$LblSinc.Location = New-Object System.Drawing.Point(16, 106)
$LblSinc.Text = 'Ultima: consultando quem atualizou...'

$LblFalhasCap = New-Object System.Windows.Forms.Label
$LblFalhasCap.Text = 'Nao atualizados na ultima varredura (clique p/ ver, clique TENTAR p/ refazer):'
$LblFalhasCap.ForeColor = $ColorDim
$LblFalhasCap.AutoSize = $true
$LblFalhasCap.Location = New-Object System.Drawing.Point(16, 148)

$LstFalhas = New-Object System.Windows.Forms.ListBox
$LstFalhas.Location = New-Object System.Drawing.Point(16, 170)
$LstFalhas.Size = New-Object System.Drawing.Size(560, 60)
$LstFalhas.BackColor = $ColorPanel
$LstFalhas.ForeColor = $ColorFg
$LstFalhas.BorderStyle = 'FixedSingle'
$LstFalhas.IntegralHeight = $false
$LstFalhas.DisplayMember = 'Display'

$BtnFalha = New-Object System.Windows.Forms.Button
$BtnFalha.Text = 'TENTAR ATUALIZAR SELECIONADO'
$BtnFalha.Location = New-Object System.Drawing.Point(584, 128)
$BtnFalha.Size = New-Object System.Drawing.Size(140, 58)
$BtnFalha.BackColor = $ColorGreen
$BtnFalha.ForeColor = [Drawing.Color]::White
$BtnFalha.FlatStyle = 'Flat'
$BtnFalha.Enabled = $false

$TabCtl = New-Object System.Windows.Forms.TabControl
$TabCtl.Location = New-Object System.Drawing.Point(16, 196)
$TabCtl.Size = New-Object System.Drawing.Size(708, 508)
$TabCtl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$TabCtl.BackColor = $ColorBg

# ---------------- ABA FILMES E SERIES ----------------

$TabFilmes = New-Object System.Windows.Forms.TabPage
$TabFilmes.Text = 'Filmes e Series'
$TabFilmes.BackColor = $ColorBg

$LblSearchF = New-Object System.Windows.Forms.Label
$LblSearchF.Text = 'Buscar filme/serie (digite parte do nome):'
$LblSearchF.Location = New-Object System.Drawing.Point(12, 8)
$LblSearchF.AutoSize = $true
$LblSearchF.ForeColor = $ColorDim

$TxtFilterF = New-Object System.Windows.Forms.TextBox
$TxtFilterF.Location = New-Object System.Drawing.Point(14, 30)
$TxtFilterF.Size = New-Object System.Drawing.Size(580, 22)
$TxtFilterF.BackColor = $ColorPanel
$TxtFilterF.ForeColor = $ColorFg
$TxtFilterF.BorderStyle = 'FixedSingle'

$LblCountF = New-Object System.Windows.Forms.Label
$LblCountF.Location = New-Object System.Drawing.Point(600, 32)
$LblCountF.Size = New-Object System.Drawing.Size(90, 20)
$LblCountF.ForeColor = $ColorDim
$LblCountF.TextAlign = 'MiddleRight'

$ListF = New-Object System.Windows.Forms.ListBox
$ListF.Location = New-Object System.Drawing.Point(14, 58)
$ListF.Size = New-Object System.Drawing.Size(678, 185)
$ListF.BackColor = $ColorPanel
$ListF.ForeColor = $ColorFg
$ListF.BorderStyle = 'FixedSingle'
$ListF.DisplayMember = 'Display'
$ListF.IntegralHeight = $false
$ListF.SelectionMode = 'MultiExtended'

$LblInfoF = New-Object System.Windows.Forms.Label
$LblInfoF.Location = New-Object System.Drawing.Point(14, 252)
$LblInfoF.Size = New-Object System.Drawing.Size(678, 18)
$LblInfoF.ForeColor = $ColorDim

$LblAtual = New-Object System.Windows.Forms.Label
$LblAtual.Text = 'URL atual no painel:'
$LblAtual.Location = New-Object System.Drawing.Point(14, 276)
$LblAtual.AutoSize = $true
$LblAtual.ForeColor = $ColorDim

$TxtAtual = New-Object System.Windows.Forms.TextBox
$TxtAtual.Location = New-Object System.Drawing.Point(14, 296)
$TxtAtual.Size = New-Object System.Drawing.Size(678, 44)
$TxtAtual.Multiline = $true
$TxtAtual.ReadOnly = $true
$TxtAtual.WordWrap = $true
$TxtAtual.BackColor = $ColorPanel
$TxtAtual.ForeColor = $ColorDim
$TxtAtual.Font = $FontMono
$TxtAtual.BorderStyle = 'FixedSingle'

$LblNovo = New-Object System.Windows.Forms.Label
$LblNovo.Text = 'NOVA URL do servidor (cole aqui):'
$LblNovo.Location = New-Object System.Drawing.Point(14, 348)
$LblNovo.AutoSize = $true

$TxtNovo = New-Object System.Windows.Forms.TextBox
$TxtNovo.Location = New-Object System.Drawing.Point(14, 368)
$TxtNovo.Size = New-Object System.Drawing.Size(678, 44)
$TxtNovo.Multiline = $true
$TxtNovo.BackColor = $ColorPanel
$TxtNovo.ForeColor = $ColorFg
$TxtNovo.Font = $FontMono
$TxtNovo.BorderStyle = 'FixedSingle'

$BtnUpdate = New-Object System.Windows.Forms.Button
$BtnUpdate.Text = 'Atualizar servidor'
$BtnUpdate.Location = New-Object System.Drawing.Point(14, 420)
$BtnUpdate.Size = New-Object System.Drawing.Size(180, 40)
$BtnUpdate.BackColor = $ColorBlue
$BtnUpdate.ForeColor = [Drawing.Color]::White
$BtnUpdate.FlatStyle = 'Flat'
$BtnUpdate.Enabled = $false

$LblStatusF = New-Object System.Windows.Forms.Label
$LblStatusF.Location = New-Object System.Drawing.Point(14, 466)
$LblStatusF.Size = New-Object System.Drawing.Size(670, 24)
$LblStatusF.ForeColor = $ColorGreen
$LblStatusF.TextAlign = 'MiddleLeft'

$BtnFDel = New-Object System.Windows.Forms.Button
$BtnFDel.Text = 'Excluir selecionado'
$BtnFDel.Location = New-Object System.Drawing.Point(386, 420)
$BtnFDel.Size = New-Object System.Drawing.Size(180, 40)
$BtnFDel.BackColor = $ColorRed
$BtnFDel.ForeColor = [Drawing.Color]::White
$BtnFDel.FlatStyle = 'Flat'
$BtnFDel.Enabled = $false

$BtnFUpd = New-Object System.Windows.Forms.Button
$BtnFUpd.Text = 'Procurar atualizacao'
$BtnFUpd.Location = New-Object System.Drawing.Point(200, 420)
$BtnFUpd.Size = New-Object System.Drawing.Size(180, 40)
$BtnFUpd.BackColor = $ColorGreen
$BtnFUpd.ForeColor = [Drawing.Color]::White
$BtnFUpd.FlatStyle = 'Flat'
$BtnFUpd.Enabled = $false

$TabFilmes.Controls.AddRange(@($LblSearchF,$TxtFilterF,$LblCountF,$ListF,$LblInfoF,$LblAtual,$TxtAtual,$LblNovo,$TxtNovo,$BtnUpdate,$LblStatusF,$BtnFDel,$BtnFUpd))

# ---------------- ABA SINOPSE PT ----------------

$TabSin = New-Object System.Windows.Forms.TabPage
$TabSin.Text = 'Sinopse pt'
$TabSin.BackColor = $ColorBg

$LblSpHelp = New-Object System.Windows.Forms.Label
$LblSpHelp.Text = 'Escolha a serie e clique TRADUZIR: ele busca a sinopse em portugues e JA ENVIA ao GitHub (o APK passa a mostrar). Para editar depois, use SALVAR.'
$LblSpHelp.ForeColor = $ColorDim
$LblSpHelp.Location = New-Object System.Drawing.Point(12, 8)
$LblSpHelp.Size = New-Object System.Drawing.Size(686, 20)

$CmbSp = New-Object System.Windows.Forms.ComboBox
$CmbSp.DropDownStyle = 'DropDownList'
$CmbSp.Location = New-Object System.Drawing.Point(12, 32)
$CmbSp.Size = New-Object System.Drawing.Size(520, 24)
$CmbSp.BackColor = $ColorPanel
$CmbSp.ForeColor = $ColorFg

$BtnSpRefresh = New-Object System.Windows.Forms.Button
$BtnSpRefresh.Text = 'Atualizar lista'
$BtnSpRefresh.Location = New-Object System.Drawing.Point(540, 30)
$BtnSpRefresh.Size = New-Object System.Drawing.Size(150, 28)
$BtnSpRefresh.BackColor = $ColorPanel
$BtnSpRefresh.ForeColor = $ColorFg
$BtnSpRefresh.FlatStyle = 'Flat'

$LblSpAtual = New-Object System.Windows.Forms.Label
$LblSpAtual.Text = 'Sinopse (edite aqui se quiser):'
$LblSpAtual.ForeColor = $ColorGreen
$LblSpAtual.Location = New-Object System.Drawing.Point(12, 66)
$LblSpAtual.AutoSize = $true

$TxtSpSin = New-Object System.Windows.Forms.TextBox
$TxtSpSin.Location = New-Object System.Drawing.Point(12, 88)
$TxtSpSin.Size = New-Object System.Drawing.Size(686, 218)
$TxtSpSin.Multiline = $true
$TxtSpSin.ScrollBars = 'Vertical'
$TxtSpSin.WordWrap = $true
$TxtSpSin.BackColor = $ColorPanel
$TxtSpSin.ForeColor = $ColorFg
$TxtSpSin.Font = $FontMono
$TxtSpSin.BorderStyle = 'FixedSingle'

$BtnSpTraduz = New-Object System.Windows.Forms.Button
$BtnSpTraduz.Text = 'TRADUZIR'
$BtnSpTraduz.Location = New-Object System.Drawing.Point(12, 318)
$BtnSpTraduz.Size = New-Object System.Drawing.Size(180, 40)
$BtnSpTraduz.BackColor = $ColorBlue
$BtnSpTraduz.ForeColor = [Drawing.Color]::White
$BtnSpTraduz.FlatStyle = 'Flat'

$BtnSpSalvar = New-Object System.Windows.Forms.Button
$BtnSpSalvar.Text = 'SALVAR e Enviar p/ Gist'
$BtnSpSalvar.Location = New-Object System.Drawing.Point(208, 318)
$BtnSpSalvar.Size = New-Object System.Drawing.Size(230, 40)
$BtnSpSalvar.BackColor = $ColorGreen
$BtnSpSalvar.ForeColor = [Drawing.Color]::White
$BtnSpSalvar.FlatStyle = 'Flat'

$LblSpStatus = New-Object System.Windows.Forms.Label
$LblSpStatus.Location = New-Object System.Drawing.Point(12, 368)
$LblSpStatus.Size = New-Object System.Drawing.Size(686, 70)
$LblSpStatus.ForeColor = $ColorDim

$TabSin.Controls.AddRange(@($LblSpHelp,$CmbSp,$BtnSpRefresh,$LblSpAtual,$TxtSpSin,$BtnSpTraduz,$BtnSpSalvar,$LblSpStatus))

# ---------------- ABA FROSTSTREAM ----------------

$TabFrost = New-Object System.Windows.Forms.TabPage
$TabFrost.Text = 'FrostStream'
$TabFrost.BackColor = $ColorBg

$LblFS1 = New-Object System.Windows.Forms.Label
$LblFS1.Text = '1) Buscar filme/serie pelo nome (addon FrostStream):'
$LblFS1.Location = New-Object System.Drawing.Point(12, 8)
$LblFS1.AutoSize = $true
$LblFS1.ForeColor = $ColorDim

$TxtFS = New-Object System.Windows.Forms.TextBox
$TxtFS.Location = New-Object System.Drawing.Point(14, 30)
$TxtFS.Size = New-Object System.Drawing.Size(480, 22)
$TxtFS.BackColor = $ColorPanel
$TxtFS.ForeColor = $ColorFg
$TxtFS.BorderStyle = 'FixedSingle'

$BtnFSBuscar = New-Object System.Windows.Forms.Button
$BtnFSBuscar.Text = 'BUSCAR'
$BtnFSBuscar.Location = New-Object System.Drawing.Point(502, 28)
$BtnFSBuscar.Size = New-Object System.Drawing.Size(104, 28)
$BtnFSBuscar.BackColor = $ColorBlue
$BtnFSBuscar.ForeColor = [Drawing.Color]::White
$BtnFSBuscar.FlatStyle = 'Flat'

$ListFS = New-Object System.Windows.Forms.ListBox
$ListFS.Location = New-Object System.Drawing.Point(14, 58)
$ListFS.Size = New-Object System.Drawing.Size(678, 130)
$ListFS.BackColor = $ColorPanel
$ListFS.ForeColor = $ColorFg
$ListFS.BorderStyle = 'FixedSingle'
$ListFS.DisplayMember = 'Display'
$ListFS.IntegralHeight = $false
$ListFS.SelectionMode = 'One'

$LblFSInfo = New-Object System.Windows.Forms.Label
$LblFSInfo.Location = New-Object System.Drawing.Point(14, 196)
$LblFSInfo.Size = New-Object System.Drawing.Size(678, 34)
$LblFSInfo.ForeColor = $ColorDim

$LblFSSerie = New-Object System.Windows.Forms.Label
$LblFSSerie.Text = 'Serie: temporada'
$LblFSSerie.Location = New-Object System.Drawing.Point(14, 238)
$LblFSSerie.AutoSize = $false
$LblFSSerie.Size = New-Object System.Drawing.Size(102, 18)
$LblFSSerie.ForeColor = $ColorDim

$NudTemp = New-Object System.Windows.Forms.NumericUpDown
$NudTemp.Location = New-Object System.Drawing.Point(120, 234)
$NudTemp.Size = New-Object System.Drawing.Size(56, 22)
$NudTemp.Minimum = 1
$NudTemp.Maximum = 50
$NudTemp.Value = 1
$NudTemp.BackColor = $ColorPanel
$NudTemp.ForeColor = $ColorFg

$LblFSEpsIni = New-Object System.Windows.Forms.Label
$LblFSEpsIni.Text = 'ep. inicial'
$LblFSEpsIni.Location = New-Object System.Drawing.Point(186, 238)
$LblFSEpsIni.AutoSize = $true
$LblFSEpsIni.ForeColor = $ColorDim

$NudEpsIni = New-Object System.Windows.Forms.NumericUpDown
$NudEpsIni.Location = New-Object System.Drawing.Point(250, 234)
$NudEpsIni.Size = New-Object System.Drawing.Size(56, 22)
$NudEpsIni.Minimum = 1
$NudEpsIni.Maximum = 999
$NudEpsIni.Value = 1
$NudEpsIni.BackColor = $ColorPanel
$NudEpsIni.ForeColor = $ColorFg

$LblFSEps = New-Object System.Windows.Forms.Label
$LblFSEps.Text = 'ate o episodio'
$LblFSEps.Location = New-Object System.Drawing.Point(316, 238)
$LblFSEps.AutoSize = $true
$LblFSEps.ForeColor = $ColorDim

$NudEps = New-Object System.Windows.Forms.NumericUpDown
$NudEps.Location = New-Object System.Drawing.Point(412, 234)
$NudEps.Size = New-Object System.Drawing.Size(56, 22)
$NudEps.Minimum = 1
$NudEps.Maximum = 999
$NudEps.Value = 10
$NudEps.BackColor = $ColorPanel
$NudEps.ForeColor = $ColorFg

# Categorias da serie: e o que separa as series na coluna da esquerda da
# aba SERIES do app. Grava no channels.np (10o campo) e vai no noviplay.json
# como "categoria", entao o app consegue agrupar sem adivinhar pelo nome.
$SerieCats = @('Sem categoria','Doramas','Anime','Romance','Comedia','Acao','Suspense','Terror','Ficcao','Infantil','Documentario','Classicos')

$LblFSCat = New-Object System.Windows.Forms.Label
$LblFSCat.Text = 'categoria:'
$LblFSCat.Location = New-Object System.Drawing.Point(474, 238)
$LblFSCat.AutoSize = $true
$LblFSCat.ForeColor = $ColorDim

$CmbFSCat = New-Object System.Windows.Forms.ComboBox
$CmbFSCat.Location = New-Object System.Drawing.Point(538, 234)
$CmbFSCat.Size = New-Object System.Drawing.Size(154, 22)
$CmbFSCat.DropDownStyle = 'DropDownList'
$CmbFSCat.BackColor = $ColorPanel
$CmbFSCat.ForeColor = $ColorFg
[void]$CmbFSCat.Items.AddRange([string[]]$SerieCats)
if ($CmbFSCat.Items.Count -gt 0) { $CmbFSCat.SelectedIndex = 0 }

# '' = sem categoria (a serie vai para o padrao "Series", como antes).
function Get-FSCatEscolhida {
  $v = [string]$CmbFSCat.Text
  if (-not $v) { return '' }
  if ($v -eq 'Sem categoria') { return '' }
  return $v
}

$BtnFSCadFilme = New-Object System.Windows.Forms.Button
$BtnFSCadFilme.Text = 'CADASTRAR / ATUALIZAR FILME'
$BtnFSCadFilme.Location = New-Object System.Drawing.Point(14, 280)
$BtnFSCadFilme.Size = New-Object System.Drawing.Size(330, 40)
$BtnFSCadFilme.BackColor = $ColorBlue
$BtnFSCadFilme.ForeColor = [Drawing.Color]::White
$BtnFSCadFilme.FlatStyle = 'Flat'
$BtnFSCadFilme.Enabled = $false

$BtnFSCadSerie = New-Object System.Windows.Forms.Button
$BtnFSCadSerie.Text = 'CADASTRAR SERIE (T X, EPS INI..FIM)'
$BtnFSCadSerie.Location = New-Object System.Drawing.Point(360, 280)
$BtnFSCadSerie.Size = New-Object System.Drawing.Size(332, 40)
$BtnFSCadSerie.BackColor = $ColorBlue
$BtnFSCadSerie.ForeColor = [Drawing.Color]::White
$BtnFSCadSerie.FlatStyle = 'Flat'
$BtnFSCadSerie.Enabled = $false

$BtnFSAtualizar = New-Object System.Windows.Forms.Button
$BtnFSAtualizar.Text = 'ATUALIZAR TODOS OS LINKS FROSTSTREAM'
$BtnFSAtualizar.Location = New-Object System.Drawing.Point(14, 332)
$BtnFSAtualizar.Size = New-Object System.Drawing.Size(678, 44)
$BtnFSAtualizar.BackColor = $ColorGreen
$BtnFSAtualizar.ForeColor = [Drawing.Color]::Black
$BtnFSAtualizar.FlatStyle = 'Flat'

$LblFSStatus = New-Object System.Windows.Forms.Label
$LblFSStatus.Location = New-Object System.Drawing.Point(14, 384)
$LblFSStatus.Size = New-Object System.Drawing.Size(678, 70)
$LblFSStatus.ForeColor = $ColorGreen

$BtnFSGit = New-Object System.Windows.Forms.Button
$BtnFSGit.Text = 'Enviar JSON p/ GitHub (noviplay.json)'
$BtnFSGit.Location = New-Object System.Drawing.Point(14, 460)
$BtnFSGit.Size = New-Object System.Drawing.Size(322, 40)
$BtnFSGit.BackColor = $ColorPanel
$BtnFSGit.ForeColor = $ColorFg
$BtnFSGit.FlatStyle = 'Flat'

$BtnFSFuturo = New-Object System.Windows.Forms.Button
$BtnFSFuturo.Text = 'FUTURO LANCAMENTOS'
$BtnFSFuturo.Location = New-Object System.Drawing.Point(344, 460)
$BtnFSFuturo.Size = New-Object System.Drawing.Size(348, 40)
$BtnFSFuturo.BackColor = $ColorBlue
$BtnFSFuturo.ForeColor = [Drawing.Color]::White
$BtnFSFuturo.FlatStyle = 'Flat'
$BtnFSFuturo.Enabled = $false

$TabFrost.Controls.AddRange(@($LblFS1,$TxtFS,$BtnFSBuscar,$ListFS,$LblFSInfo,$LblFSSerie,$NudTemp,$LblFSEpsIni,$NudEpsIni,$LblFSEps,$NudEps,$LblFSCat,$CmbFSCat,$BtnFSCadFilme,$BtnFSCadSerie,$BtnFSAtualizar,$LblFSStatus,$BtnFSGit,$BtnFSFuturo))

# ---------------- ABA FUTURO LANCAMENTOS ----------------

$TabFuturo = New-Object System.Windows.Forms.TabPage
$TabFuturo.Text = 'Futuro Lancamentos'
$TabFuturo.BackColor = $ColorBg

$LblFu1 = New-Object System.Windows.Forms.Label
$LblFu1.Text = 'Fila do que ainda NAO saiu: na aba FrostStream, busque o titulo, selecione e clique em FUTURO LANCAMENTOS.'
$LblFu1.Location = New-Object System.Drawing.Point(12, 8)
$LblFu1.AutoSize = $true
$LblFu1.ForeColor = $ColorDim

$LblFu2 = New-Object System.Windows.Forms.Label
$LblFu2.Text = "A atualizacao automatica ($(Get-FSIntervaloTexto)) passa por aqui: quando o addon liberar o filme/serie, ele entra em canais e vai para o GitHub. O que entrou sai da fila."
$LblFu2.Location = New-Object System.Drawing.Point(12, 28)
$LblFu2.AutoSize = $true
$LblFu2.ForeColor = $ColorDim

$LstFuturo = New-Object System.Windows.Forms.ListBox
$LstFuturo.Location = New-Object System.Drawing.Point(14, 54)
$LstFuturo.Size = New-Object System.Drawing.Size(678, 236)
$LstFuturo.BackColor = $ColorPanel
$LstFuturo.ForeColor = $ColorFg
$LstFuturo.BorderStyle = 'FixedSingle'
$LstFuturo.DisplayMember = 'Display'
$LstFuturo.IntegralHeight = $false
$LstFuturo.SelectionMode = 'One'

$LblFuCount = New-Object System.Windows.Forms.Label
$LblFuCount.Location = New-Object System.Drawing.Point(14, 296)
$LblFuCount.Size = New-Object System.Drawing.Size(678, 20)
$LblFuCount.ForeColor = $ColorDim

$BtnFuAtualizar = New-Object System.Windows.Forms.Button
$BtnFuAtualizar.Text = 'ATUALIZAR LISTA'
$BtnFuAtualizar.Location = New-Object System.Drawing.Point(14, 320)
$BtnFuAtualizar.Size = New-Object System.Drawing.Size(216, 40)
$BtnFuAtualizar.BackColor = $ColorPanel
$BtnFuAtualizar.ForeColor = $ColorFg
$BtnFuAtualizar.FlatStyle = 'Flat'

$BtnFuProcessar = New-Object System.Windows.Forms.Button
$BtnFuProcessar.Text = 'PROCESSAR AGORA'
$BtnFuProcessar.Location = New-Object System.Drawing.Point(238, 320)
$BtnFuProcessar.Size = New-Object System.Drawing.Size(216, 40)
$BtnFuProcessar.BackColor = $ColorGreen
$BtnFuProcessar.ForeColor = [Drawing.Color]::Black
$BtnFuProcessar.FlatStyle = 'Flat'

$BtnFuRemover = New-Object System.Windows.Forms.Button
$BtnFuRemover.Text = 'REMOVER SELECIONADO'
$BtnFuRemover.Location = New-Object System.Drawing.Point(462, 320)
$BtnFuRemover.Size = New-Object System.Drawing.Size(230, 40)
$BtnFuRemover.BackColor = $ColorPanel
$BtnFuRemover.ForeColor = $ColorFg
$BtnFuRemover.FlatStyle = 'Flat'

$LblFuStatus = New-Object System.Windows.Forms.Label
$LblFuStatus.Location = New-Object System.Drawing.Point(14, 368)
$LblFuStatus.Size = New-Object System.Drawing.Size(678, 70)
$LblFuStatus.ForeColor = $ColorGreen

$TabFuturo.Controls.AddRange(@($LblFu1,$LblFu2,$LstFuturo,$LblFuCount,$BtnFuAtualizar,$BtnFuProcessar,$BtnFuRemover,$LblFuStatus))

# ---------------- ABA FENIX ----------------

$TabFenix = New-Object System.Windows.Forms.TabPage
$TabFenix.Text = 'Fenix'
$TabFenix.BackColor = $ColorBg

$LblFx1 = New-Object System.Windows.Forms.Label
$LblFx1.Text = '1) Buscar filme/serie pelo nome (addon FenixFlix):'
$LblFx1.Location = New-Object System.Drawing.Point(12, 8)
$LblFx1.AutoSize = $true
$LblFx1.ForeColor = $ColorDim

$TxtFx = New-Object System.Windows.Forms.TextBox
$TxtFx.Location = New-Object System.Drawing.Point(14, 30)
$TxtFx.Size = New-Object System.Drawing.Size(480, 22)
$TxtFx.BackColor = $ColorPanel
$TxtFx.ForeColor = $ColorFg
$TxtFx.BorderStyle = 'FixedSingle'

$BtnFxBuscar = New-Object System.Windows.Forms.Button
$BtnFxBuscar.Text = 'BUSCAR'
$BtnFxBuscar.Location = New-Object System.Drawing.Point(502, 28)
$BtnFxBuscar.Size = New-Object System.Drawing.Size(104, 28)
$BtnFxBuscar.BackColor = $ColorBlue
$BtnFxBuscar.ForeColor = [Drawing.Color]::White
$BtnFxBuscar.FlatStyle = 'Flat'

$ListFx = New-Object System.Windows.Forms.ListBox
$ListFx.Location = New-Object System.Drawing.Point(14, 58)
$ListFx.Size = New-Object System.Drawing.Size(678, 130)
$ListFx.BackColor = $ColorPanel
$ListFx.ForeColor = $ColorFg
$ListFx.BorderStyle = 'FixedSingle'
$ListFx.DisplayMember = 'Display'
$ListFx.IntegralHeight = $false
$ListFx.SelectionMode = 'One'

$LblFxInfo = New-Object System.Windows.Forms.Label
$LblFxInfo.Location = New-Object System.Drawing.Point(14, 196)
$LblFxInfo.Size = New-Object System.Drawing.Size(678, 34)
$LblFxInfo.ForeColor = $ColorDim

$LblFxSerie = New-Object System.Windows.Forms.Label
$LblFxSerie.Text = 'Serie: temporada'
$LblFxSerie.Location = New-Object System.Drawing.Point(14, 238)
$LblFxSerie.AutoSize = $false
$LblFxSerie.Size = New-Object System.Drawing.Size(102, 18)
$LblFxSerie.ForeColor = $ColorDim

$NudFxTemp = New-Object System.Windows.Forms.NumericUpDown
$NudFxTemp.Location = New-Object System.Drawing.Point(120, 234)
$NudFxTemp.Size = New-Object System.Drawing.Size(56, 22)
$NudFxTemp.Minimum = 1
$NudFxTemp.Maximum = 50
$NudFxTemp.Value = 1
$NudFxTemp.BackColor = $ColorPanel
$NudFxTemp.ForeColor = $ColorFg

$LblFxEpsIni = New-Object System.Windows.Forms.Label
$LblFxEpsIni.Text = 'ep. inicial'
$LblFxEpsIni.Location = New-Object System.Drawing.Point(186, 238)
$LblFxEpsIni.AutoSize = $true
$LblFxEpsIni.ForeColor = $ColorDim

$NudFxEpsIni = New-Object System.Windows.Forms.NumericUpDown
$NudFxEpsIni.Location = New-Object System.Drawing.Point(250, 234)
$NudFxEpsIni.Size = New-Object System.Drawing.Size(56, 22)
$NudFxEpsIni.Minimum = 1
$NudFxEpsIni.Maximum = 999
$NudFxEpsIni.Value = 1
$NudFxEpsIni.BackColor = $ColorPanel
$NudFxEpsIni.ForeColor = $ColorFg

$LblFxEps = New-Object System.Windows.Forms.Label
$LblFxEps.Text = 'ate o episodio'
$LblFxEps.Location = New-Object System.Drawing.Point(316, 238)
$LblFxEps.AutoSize = $true
$LblFxEps.ForeColor = $ColorDim

$NudFxEps = New-Object System.Windows.Forms.NumericUpDown
$NudFxEps.Location = New-Object System.Drawing.Point(412, 234)
$NudFxEps.Size = New-Object System.Drawing.Size(56, 22)
$NudFxEps.Minimum = 1
$NudFxEps.Maximum = 999
$NudFxEps.Value = 10
$NudFxEps.BackColor = $ColorPanel
$NudFxEps.ForeColor = $ColorFg

$BtnFxCadFilme = New-Object System.Windows.Forms.Button
$BtnFxCadFilme.Text = 'CADASTRAR / ATUALIZAR FILME'
$BtnFxCadFilme.Location = New-Object System.Drawing.Point(14, 280)
$BtnFxCadFilme.Size = New-Object System.Drawing.Size(330, 40)
$BtnFxCadFilme.BackColor = $ColorBlue
$BtnFxCadFilme.ForeColor = [Drawing.Color]::White
$BtnFxCadFilme.FlatStyle = 'Flat'
$BtnFxCadFilme.Enabled = $false

$BtnFxCadSerie = New-Object System.Windows.Forms.Button
$BtnFxCadSerie.Text = 'CADASTRAR SERIE (T X, EPS INI..FIM)'
$BtnFxCadSerie.Location = New-Object System.Drawing.Point(360, 280)
$BtnFxCadSerie.Size = New-Object System.Drawing.Size(332, 40)
$BtnFxCadSerie.BackColor = $ColorBlue
$BtnFxCadSerie.ForeColor = [Drawing.Color]::White
$BtnFxCadSerie.FlatStyle = 'Flat'
$BtnFxCadSerie.Enabled = $false

$BtnFxAtualizar = New-Object System.Windows.Forms.Button
$BtnFxAtualizar.Text = 'ATUALIZAR TODOS OS LINKS FENIX'
$BtnFxAtualizar.Location = New-Object System.Drawing.Point(14, 332)
$BtnFxAtualizar.Size = New-Object System.Drawing.Size(678, 44)
$BtnFxAtualizar.BackColor = $ColorGreen
$BtnFxAtualizar.ForeColor = [Drawing.Color]::Black
$BtnFxAtualizar.FlatStyle = 'Flat'

$LblFxStatus = New-Object System.Windows.Forms.Label
$LblFxStatus.Location = New-Object System.Drawing.Point(14, 384)
$LblFxStatus.Size = New-Object System.Drawing.Size(678, 70)
$LblFxStatus.ForeColor = $ColorGreen

$BtnFxGit = New-Object System.Windows.Forms.Button
$BtnFxGit.Text = 'Enviar JSON p/ GitHub (noviplay.json)'
$BtnFxGit.Location = New-Object System.Drawing.Point(14, 460)
$BtnFxGit.Size = New-Object System.Drawing.Size(322, 40)
$BtnFxGit.BackColor = $ColorPanel
$BtnFxGit.ForeColor = $ColorFg
$BtnFxGit.FlatStyle = 'Flat'

$TabFenix.Controls.AddRange(@($LblFx1,$TxtFx,$BtnFxBuscar,$ListFx,$LblFxInfo,$LblFxSerie,$NudFxTemp,$LblFxEpsIni,$NudFxEpsIni,$LblFxEps,$NudFxEps,$BtnFxCadFilme,$BtnFxCadSerie,$BtnFxAtualizar,$LblFxStatus,$BtnFxGit))

# ---------------- ABA CANAIS TV ----------------

$TabCanais = New-Object System.Windows.Forms.TabPage
$TabCanais.Text = 'Canais TV'
$TabCanais.BackColor = $ColorBg

$LblSearchC = New-Object System.Windows.Forms.Label
$LblSearchC.Text = 'Buscar canal de TV (digite parte do nome):'
$LblSearchC.Location = New-Object System.Drawing.Point(12, 8)
$LblSearchC.AutoSize = $true
$LblSearchC.ForeColor = $ColorDim

$TxtFilterC = New-Object System.Windows.Forms.TextBox
$TxtFilterC.Location = New-Object System.Drawing.Point(14, 30)
$TxtFilterC.Size = New-Object System.Drawing.Size(580, 22)
$TxtFilterC.BackColor = $ColorPanel
$TxtFilterC.ForeColor = $ColorFg
$TxtFilterC.BorderStyle = 'FixedSingle'

$LblCountC = New-Object System.Windows.Forms.Label
$LblCountC.Location = New-Object System.Drawing.Point(600, 32)
$LblCountC.Size = New-Object System.Drawing.Size(90, 20)
$LblCountC.ForeColor = $ColorDim
$LblCountC.TextAlign = 'MiddleRight'

$ListC = New-Object System.Windows.Forms.ListBox
$ListC.Location = New-Object System.Drawing.Point(14, 58)
$ListC.Size = New-Object System.Drawing.Size(678, 195)
$ListC.BackColor = $ColorPanel
$ListC.ForeColor = $ColorFg
$ListC.BorderStyle = 'FixedSingle'
$ListC.DisplayMember = 'Display'
$ListC.IntegralHeight = $false
$ListC.SelectionMode = 'MultiExtended'

$LblInfoC = New-Object System.Windows.Forms.Label
$LblInfoC.Location = New-Object System.Drawing.Point(14, 262)
$LblInfoC.Size = New-Object System.Drawing.Size(678, 18)
$LblInfoC.ForeColor = $ColorDim

$LblUrlC = New-Object System.Windows.Forms.Label
$LblUrlC.Text = 'URL do canal selecionado:'
$LblUrlC.Location = New-Object System.Drawing.Point(14, 286)
$LblUrlC.AutoSize = $true
$LblUrlC.ForeColor = $ColorDim

$TxtUrlC = New-Object System.Windows.Forms.TextBox
$TxtUrlC.Location = New-Object System.Drawing.Point(14, 306)
$TxtUrlC.Size = New-Object System.Drawing.Size(678, 44)
$TxtUrlC.Multiline = $true
$TxtUrlC.ReadOnly = $true
$TxtUrlC.WordWrap = $true
$TxtUrlC.BackColor = $ColorPanel
$TxtUrlC.ForeColor = $ColorDim
$TxtUrlC.Font = $FontMono
$TxtUrlC.BorderStyle = 'FixedSingle'

$LblLogoC = New-Object System.Windows.Forms.Label
$LblLogoC.Text = 'Nova logo/capa URL:'
$LblLogoC.Location = New-Object System.Drawing.Point(240, 290)
$LblLogoC.AutoSize = $true
$LblLogoC.ForeColor = $ColorDim

$TxtLogoC = New-Object System.Windows.Forms.TextBox
$TxtLogoC.Location = New-Object System.Drawing.Point(376, 286)
$TxtLogoC.Size = New-Object System.Drawing.Size(316, 22)
$TxtLogoC.BackColor = $ColorPanel
$TxtLogoC.ForeColor = $ColorFg
$TxtLogoC.BorderStyle = 'FixedSingle'

$BtnDelete = New-Object System.Windows.Forms.Button
$BtnDelete.Text = 'Excluir canal(ais) selecionado(s)'
$BtnDelete.Location = New-Object System.Drawing.Point(14, 362)
$BtnDelete.Size = New-Object System.Drawing.Size(250, 40)
$BtnDelete.BackColor = $ColorRed
$BtnDelete.ForeColor = [Drawing.Color]::White
$BtnDelete.FlatStyle = 'Flat'
$BtnDelete.Enabled = $false

$BtnCUp = New-Object System.Windows.Forms.Button
$BtnCUp.Text = 'Mover p/ cima'
$BtnCUp.Location = New-Object System.Drawing.Point(280, 362)
$BtnCUp.Size = New-Object System.Drawing.Size(120, 40)
$BtnCUp.BackColor = $ColorPanel
$BtnCUp.ForeColor = $ColorFg
$BtnCUp.FlatStyle = 'Flat'
$BtnCUp.Enabled = $false

$BtnCDown = New-Object System.Windows.Forms.Button
$BtnCDown.Text = 'Mover p/ baixo'
$BtnCDown.Location = New-Object System.Drawing.Point(406, 362)
$BtnCDown.Size = New-Object System.Drawing.Size(120, 40)
$BtnCDown.BackColor = $ColorPanel
$BtnCDown.ForeColor = $ColorFg
$BtnCDown.FlatStyle = 'Flat'
$BtnCDown.Enabled = $false

$BtnGit = New-Object System.Windows.Forms.Button
$BtnGit.Text = 'Enviar p/ GitHub'
$BtnGit.Location = New-Object System.Drawing.Point(14, 412)
$BtnGit.Size = New-Object System.Drawing.Size(250, 40)
$BtnGit.BackColor = $ColorPanel
$BtnGit.ForeColor = $ColorFg
$BtnGit.FlatStyle = 'Flat'
$BtnGit.Enabled = $true

$BtnRenomear = New-Object System.Windows.Forms.Button
$BtnRenomear.Text = 'Salvar nome/logo'
$BtnRenomear.Location = New-Object System.Drawing.Point(280, 412)
$BtnRenomear.Size = New-Object System.Drawing.Size(130, 40)
$BtnRenomear.BackColor = $ColorPanel
$BtnRenomear.ForeColor = $ColorFg
$BtnRenomear.FlatStyle = 'Flat'
$BtnRenomear.Enabled = $false

$LblNomeC = New-Object System.Windows.Forms.Label
$LblNomeC.Text = 'Novo nome:'
$LblNomeC.Location = New-Object System.Drawing.Point(418, 420)
$LblNomeC.AutoSize = $true
$LblNomeC.ForeColor = $ColorDim

$TxtNomeC = New-Object System.Windows.Forms.TextBox
$TxtNomeC.Location = New-Object System.Drawing.Point(496, 416)
$TxtNomeC.Size = New-Object System.Drawing.Size(196, 22)
$TxtNomeC.BackColor = $ColorPanel
$TxtNomeC.ForeColor = $ColorFg
$TxtNomeC.BorderStyle = 'FixedSingle'

$LblStatusC = New-Object System.Windows.Forms.Label
$LblStatusC.Location = New-Object System.Drawing.Point(272, 350)
$LblStatusC.Size = New-Object System.Drawing.Size(420, 56)
$LblStatusC.ForeColor = $ColorGreen

$TabCanais.Controls.AddRange(@($LblSearchC,$TxtFilterC,$LblCountC,$ListC,$LblInfoC,$LblUrlC,$TxtUrlC,$LblLogoC,$TxtLogoC,$BtnDelete,$LblStatusC,$BtnCUp,$BtnCDown,$BtnGit,$BtnRenomear,$LblNomeC,$TxtNomeC))

$TabMinhaTV = New-Object System.Windows.Forms.TabPage
$TabMinhaTV.Text = 'MinhaTV'
$TabMinhaTV.BackColor = $ColorBg

$LblMTVBuscar = New-Object System.Windows.Forms.Label
$LblMTVBuscar.Text = 'Buscar canal no addon MinhaTV (ex.: globo, premiere, telecine):'
$LblMTVBuscar.Location = New-Object System.Drawing.Point(12, 8)
$LblMTVBuscar.AutoSize = $true
$LblMTVBuscar.ForeColor = $ColorDim

$TxtMTVQ = New-Object System.Windows.Forms.TextBox
$TxtMTVQ.Location = New-Object System.Drawing.Point(14, 30)
$TxtMTVQ.Size = New-Object System.Drawing.Size(520, 22)
$TxtMTVQ.BackColor = $ColorPanel
$TxtMTVQ.ForeColor = $ColorFg
$TxtMTVQ.BorderStyle = 'FixedSingle'

$BtnMTVBuscar = New-Object System.Windows.Forms.Button
$BtnMTVBuscar.Text = 'Buscar'
$BtnMTVBuscar.Location = New-Object System.Drawing.Point(540, 28)
$BtnMTVBuscar.Size = New-Object System.Drawing.Size(90, 26)
$BtnMTVBuscar.BackColor = $ColorPanel
$BtnMTVBuscar.ForeColor = $ColorFg
$BtnMTVBuscar.FlatStyle = 'Flat'

$LblMTVCount = New-Object System.Windows.Forms.Label
$LblMTVCount.Location = New-Object System.Drawing.Point(636, 32)
$LblMTVCount.Size = New-Object System.Drawing.Size(54, 20)
$LblMTVCount.ForeColor = $ColorDim
$LblMTVCount.TextAlign = 'MiddleRight'

$ListMTV = New-Object System.Windows.Forms.ListBox
$ListMTV.Location = New-Object System.Drawing.Point(14, 58)
$ListMTV.Size = New-Object System.Drawing.Size(678, 170)
$ListMTV.BackColor = $ColorPanel
$ListMTV.ForeColor = $ColorFg
$ListMTV.BorderStyle = 'FixedSingle'
$ListMTV.DisplayMember = 'Display'
$ListMTV.IntegralHeight = $false

$LblMTVHelp = New-Object System.Windows.Forms.Label
$LblMTVHelp.Text = "'Adicionar canal' grava direto, sem teste (igual filme/serie). Se o addon nao devolver a URL (504), cole a URL do Stremio la embaixo. Variantes pesadas (FHD/H265/UHD/4K/8K/HDR/1080p) ficam de fora."
$LblMTVHelp.Location = New-Object System.Drawing.Point(14, 234)
$LblMTVHelp.Size = New-Object System.Drawing.Size(678, 34)
$LblMTVHelp.ForeColor = $ColorDim

$BtnMTVAdd = New-Object System.Windows.Forms.Button
$BtnMTVAdd.Text = 'Adicionar canal'
$BtnMTVAdd.Location = New-Object System.Drawing.Point(14, 272)
$BtnMTVAdd.Size = New-Object System.Drawing.Size(250, 36)
$BtnMTVAdd.BackColor = $ColorPanel
$BtnMTVAdd.ForeColor = $ColorFg
$BtnMTVAdd.FlatStyle = 'Flat'
$BtnMTVAdd.Enabled = $false

$LblMTVGrupo = New-Object System.Windows.Forms.Label
$LblMTVGrupo.Text = 'Grupo:'
$LblMTVGrupo.Location = New-Object System.Drawing.Point(272, 279)
$LblMTVGrupo.AutoSize = $true
$LblMTVGrupo.ForeColor = $ColorDim

$CmbMTVGrupo = New-Object System.Windows.Forms.ComboBox
$CmbMTVGrupo.DropDownStyle = 'DropDownList'
  $CmbMTVGrupo.Items.AddRange(@('Abertos e Variedades','Esportes','Infantis','Noticias','Religiosos','Documentarios','Musica','Educativos','Variedades','FILMES TV'))
$CmbMTVGrupo.SelectedItem = 'Abertos e Variedades'
$CmbMTVGrupo.Location = New-Object System.Drawing.Point(316, 277)
$CmbMTVGrupo.Size = New-Object System.Drawing.Size(210, 24)
$CmbMTVGrupo.BackColor = $ColorPanel
$CmbMTVGrupo.ForeColor = $ColorFg
$CmbMTVGrupo.FlatStyle = 'Flat'

$LblMTVStatus = New-Object System.Windows.Forms.Label
$LblMTVStatus.Location = New-Object System.Drawing.Point(14, 312)
$LblMTVStatus.Size = New-Object System.Drawing.Size(678, 34)
$LblMTVStatus.ForeColor = $ColorGreen

$LblMTVPaste = New-Object System.Windows.Forms.Label
$LblMTVPaste.Text = 'Ou cole a URL do Stremio/addon - grava direto:'
$LblMTVPaste.Location = New-Object System.Drawing.Point(14, 350)
$LblMTVPaste.Size = New-Object System.Drawing.Size(310, 18)
$LblMTVPaste.ForeColor = $ColorDim

$ChkMTVLogo = New-Object System.Windows.Forms.CheckBox
$ChkMTVLogo.Text = 'Puxar logo do addon'
$ChkMTVLogo.Location = New-Object System.Drawing.Point(332, 346)
$ChkMTVLogo.Size = New-Object System.Drawing.Size(148, 22)
$ChkMTVLogo.ForeColor = $ColorDim
$ChkMTVLogo.Checked = $true

$ChkMTVRelay = New-Object System.Windows.Forms.CheckBox
$ChkMTVRelay.Text = 'Usar relay (HTTPS)'
$ChkMTVRelay.Location = New-Object System.Drawing.Point(492, 346)
$ChkMTVRelay.Size = New-Object System.Drawing.Size(180, 22)
$ChkMTVRelay.ForeColor = $ColorDim
$ChkMTVRelay.Checked = $true

$TxtMTVPasteNome = New-Object System.Windows.Forms.TextBox
$TxtMTVPasteNome.Text = 'Cartoon Network SD'
$TxtMTVPasteNome.Location = New-Object System.Drawing.Point(14, 368)
$TxtMTVPasteNome.Size = New-Object System.Drawing.Size(150, 22)
$TxtMTVPasteNome.BackColor = $ColorPanel
$TxtMTVPasteNome.ForeColor = $ColorFg
$TxtMTVPasteNome.BorderStyle = 'FixedSingle'

$TxtMTVPaste = New-Object System.Windows.Forms.TextBox
$TxtMTVPaste.Location = New-Object System.Drawing.Point(170, 368)
$TxtMTVPaste.Size = New-Object System.Drawing.Size(380, 22)
$TxtMTVPaste.BackColor = $ColorPanel
$TxtMTVPaste.ForeColor = $ColorFg
$TxtMTVPaste.BorderStyle = 'FixedSingle'

$BtnMTVPaste = New-Object System.Windows.Forms.Button
$BtnMTVPaste.Text = 'Adicionar URL'
$BtnMTVPaste.Location = New-Object System.Drawing.Point(556, 366)
$BtnMTVPaste.Size = New-Object System.Drawing.Size(136, 26)
$BtnMTVPaste.BackColor = $ColorPanel
$BtnMTVPaste.ForeColor = $ColorFg
$BtnMTVPaste.FlatStyle = 'Flat'

$LblMTVLogo = New-Object System.Windows.Forms.Label
$LblMTVLogo.Text = 'Logo/capa (opcional - cola a URL ou deixa pro addon):'
$LblMTVLogo.Location = New-Object System.Drawing.Point(14, 396)
$LblMTVLogo.Size = New-Object System.Drawing.Size(678, 18)
$LblMTVLogo.ForeColor = $ColorDim

$TxtMTVLogo = New-Object System.Windows.Forms.TextBox
$TxtMTVLogo.Location = New-Object System.Drawing.Point(14, 414)
$TxtMTVLogo.Size = New-Object System.Drawing.Size(678, 22)
$TxtMTVLogo.BackColor = $ColorPanel
$TxtMTVLogo.ForeColor = $ColorFg
$TxtMTVLogo.BorderStyle = 'FixedSingle'

$TabMinhaTV.Controls.AddRange(@($LblMTVBuscar,$TxtMTVQ,$BtnMTVBuscar,$LblMTVCount,$ListMTV,$LblMTVHelp,$BtnMTVAdd,$LblMTVGrupo,$CmbMTVGrupo,$LblMTVStatus,$LblMTVPaste,$ChkMTVLogo,$ChkMTVRelay,$TxtMTVPasteNome,$TxtMTVPaste,$BtnMTVPaste,$LblMTVLogo,$TxtMTVLogo))

# ---------------- ABA ORDENAR CANAIS ----------------

$TabOrd = New-Object System.Windows.Forms.TabPage
$TabOrd.Text = 'Ordenar Canais'
$TabOrd.BackColor = $ColorBg

$LblOrdHead = New-Object System.Windows.Forms.Label
$LblOrdHead.Text = 'Canais na ordem atual do channels.np (o de cima e o primeiro no APK).'
$LblOrdHead.Location = New-Object System.Drawing.Point(14, 8)
$LblOrdHead.Size = New-Object System.Drawing.Size(678, 18)
$LblOrdHead.ForeColor = $ColorDim

$TxtOrdQ = New-Object System.Windows.Forms.TextBox
$TxtOrdQ.Text = 'Pesquisar canal nesta lista...'
$TxtOrdQ.Location = New-Object System.Drawing.Point(14, 30)
$TxtOrdQ.Size = New-Object System.Drawing.Size(678, 22)
$TxtOrdQ.BackColor = $ColorPanel
$TxtOrdQ.ForeColor = $ColorDim
$TxtOrdQ.BorderStyle = 'FixedSingle'

$ListOrd = New-Object System.Windows.Forms.ListBox
$ListOrd.Location = New-Object System.Drawing.Point(14, 58)
$ListOrd.Size = New-Object System.Drawing.Size(678, 252)
$ListOrd.BackColor = $ColorPanel
$ListOrd.ForeColor = $ColorFg
$ListOrd.BorderStyle = 'FixedSingle'
$ListOrd.DisplayMember = 'Display'
$ListOrd.IntegralHeight = $false
$ListOrd.SelectionMode = 'One'

$BtnOrdUp = New-Object System.Windows.Forms.Button
$BtnOrdUp.Text = 'Mover p/ cima'
$BtnOrdUp.Location = New-Object System.Drawing.Point(14, 318)
$BtnOrdUp.Size = New-Object System.Drawing.Size(130, 36)
$BtnOrdUp.BackColor = $ColorPanel
$BtnOrdUp.ForeColor = $ColorFg
$BtnOrdUp.FlatStyle = 'Flat'
$BtnOrdUp.Enabled = $false

$BtnOrdDown = New-Object System.Windows.Forms.Button
$BtnOrdDown.Text = 'Mover p/ baixo'
$BtnOrdDown.Location = New-Object System.Drawing.Point(150, 318)
$BtnOrdDown.Size = New-Object System.Drawing.Size(130, 36)
$BtnOrdDown.BackColor = $ColorPanel
$BtnOrdDown.ForeColor = $ColorFg
$BtnOrdDown.FlatStyle = 'Flat'
$BtnOrdDown.Enabled = $false

$BtnOrdTop = New-Object System.Windows.Forms.Button
$BtnOrdTop.Text = 'Mover p/ topo'
$BtnOrdTop.Location = New-Object System.Drawing.Point(286, 318)
$BtnOrdTop.Size = New-Object System.Drawing.Size(130, 36)
$BtnOrdTop.BackColor = $ColorPanel
$BtnOrdTop.ForeColor = $ColorFg
$BtnOrdTop.FlatStyle = 'Flat'
$BtnOrdTop.Enabled = $false

$BtnOrdEnd = New-Object System.Windows.Forms.Button
$BtnOrdEnd.Text = 'Mover p/ fim'
$BtnOrdEnd.Location = New-Object System.Drawing.Point(422, 318)
$BtnOrdEnd.Size = New-Object System.Drawing.Size(130, 36)
$BtnOrdEnd.BackColor = $ColorPanel
$BtnOrdEnd.ForeColor = $ColorFg
$BtnOrdEnd.FlatStyle = 'Flat'
$BtnOrdEnd.Enabled = $false

$LblOrdPos = New-Object System.Windows.Forms.Label
$LblOrdPos.Text = 'Posicao:'
$LblOrdPos.Location = New-Object System.Drawing.Point(14, 376)
$LblOrdPos.AutoSize = $true
$LblOrdPos.ForeColor = $ColorDim

$NudOrdPos = New-Object System.Windows.Forms.NumericUpDown
$NudOrdPos.Location = New-Object System.Drawing.Point(74, 372)
$NudOrdPos.Size = New-Object System.Drawing.Size(56, 22)
$NudOrdPos.Minimum = 1
$NudOrdPos.Maximum = 5000
$NudOrdPos.Value = 1
$NudOrdPos.BackColor = $ColorPanel
$NudOrdPos.ForeColor = $ColorFg

$BtnOrdGo = New-Object System.Windows.Forms.Button
$BtnOrdGo.Text = 'Mover para a posicao'
$BtnOrdGo.Location = New-Object System.Drawing.Point(140, 368)
$BtnOrdGo.Size = New-Object System.Drawing.Size(200, 34)
$BtnOrdGo.BackColor = $ColorPanel
$BtnOrdGo.ForeColor = $ColorFg
$BtnOrdGo.FlatStyle = 'Flat'
$BtnOrdGo.Enabled = $false

$BtnOrdGit = New-Object System.Windows.Forms.Button
$BtnOrdGit.Text = 'Enviar p/ GitHub'
$BtnOrdGit.Location = New-Object System.Drawing.Point(346, 368)
$BtnOrdGit.Size = New-Object System.Drawing.Size(200, 34)
$BtnOrdGit.BackColor = $ColorPanel
$BtnOrdGit.ForeColor = $ColorFg
$BtnOrdGit.FlatStyle = 'Flat'

$LblOrdStatus = New-Object System.Windows.Forms.Label
$LblOrdStatus.Location = New-Object System.Drawing.Point(14, 410)
$LblOrdStatus.Size = New-Object System.Drawing.Size(678, 34)
$LblOrdStatus.ForeColor = $ColorGreen

$TabOrd.Controls.AddRange(@($LblOrdHead,$TxtOrdQ,$ListOrd,$BtnOrdUp,$BtnOrdDown,$BtnOrdTop,$BtnOrdEnd,$LblOrdPos,$NudOrdPos,$BtnOrdGo,$BtnOrdGit,$LblOrdStatus))

# ---------------- ABA AVISO (mensagem na tela inicial do app) ----------------

$TabAviso = New-Object System.Windows.Forms.TabPage
$TabAviso.Text = 'Aviso na tela inicial'
$TabAviso.BackColor = $ColorBg

$LblAv1 = New-Object System.Windows.Forms.Label
$LblAv1.Text = 'AVISO PARA O USUARIO: este texto aparece no cartao da tela INICIO do app, logo depois do login.'
$LblAv1.Location = New-Object System.Drawing.Point(12, 8)
$LblAv1.AutoSize = $true
$LblAv1.ForeColor = $ColorDim

$LblAv2 = New-Object System.Windows.Forms.Label
$LblAv2.Text = 'Vazio = nenhum cartao aparece no app. Acentos, aspas e quebra de linha sao aceitos.'
$LblAv2.Location = New-Object System.Drawing.Point(12, 28)
$LblAv2.AutoSize = $true
$LblAv2.ForeColor = $ColorDim

$TxtAviso = New-Object System.Windows.Forms.TextBox
$TxtAviso.Location = New-Object System.Drawing.Point(14, 52)
$TxtAviso.Size = New-Object System.Drawing.Size(678, 196)
$TxtAviso.Multiline = $true
$TxtAviso.ScrollBars = 'Vertical'
$TxtAviso.BackColor = $ColorPanel
$TxtAviso.ForeColor = $ColorFg
$TxtAviso.BorderStyle = 'FixedSingle'

$BtnAvisoGravar = New-Object System.Windows.Forms.Button
$BtnAvisoGravar.Text = 'GRAVAR AVISO e ENVIAR ao GITHUB'
$BtnAvisoGravar.Location = New-Object System.Drawing.Point(14, 262)
$BtnAvisoGravar.Size = New-Object System.Drawing.Size(322, 40)
$BtnAvisoGravar.BackColor = $ColorGreen
$BtnAvisoGravar.ForeColor = [Drawing.Color]::Black
$BtnAvisoGravar.FlatStyle = 'Flat'

$BtnAvisoLimpar = New-Object System.Windows.Forms.Button
$BtnAvisoLimpar.Text = 'LIMPAR AVISO (esconder no app)'
$BtnAvisoLimpar.Location = New-Object System.Drawing.Point(344, 262)
$BtnAvisoLimpar.Size = New-Object System.Drawing.Size(348, 40)
$BtnAvisoLimpar.BackColor = $ColorPanel
$BtnAvisoLimpar.ForeColor = $ColorFg
$BtnAvisoLimpar.FlatStyle = 'Flat'

$LblAvStatus = New-Object System.Windows.Forms.Label
$LblAvStatus.Location = New-Object System.Drawing.Point(14, 388)
$LblAvStatus.Size = New-Object System.Drawing.Size(678, 64)
$LblAvStatus.ForeColor = $ColorDim

$BtnAvisoProgramar = New-Object System.Windows.Forms.Button
$BtnAvisoProgramar.Text = 'PROGRAMAR AVISO (enviar na proxima atualizacao)'
$BtnAvisoProgramar.Location = New-Object System.Drawing.Point(14, 306)
$BtnAvisoProgramar.Size = New-Object System.Drawing.Size(440, 40)
$BtnAvisoProgramar.BackColor = $ColorBlue
$BtnAvisoProgramar.ForeColor = [Drawing.Color]::White
$BtnAvisoProgramar.FlatStyle = 'Flat'

$BtnAvisoCancelar = New-Object System.Windows.Forms.Button
$BtnAvisoCancelar.Text = 'CANCELAR O PROGRAMADO'
$BtnAvisoCancelar.Location = New-Object System.Drawing.Point(462, 306)
$BtnAvisoCancelar.Size = New-Object System.Drawing.Size(230, 40)
$BtnAvisoCancelar.BackColor = $ColorPanel
$BtnAvisoCancelar.ForeColor = $ColorFg
$BtnAvisoCancelar.FlatStyle = 'Flat'

$LblAvProgramado = New-Object System.Windows.Forms.Label
$LblAvProgramado.Location = New-Object System.Drawing.Point(14, 352)
$LblAvProgramado.Size = New-Object System.Drawing.Size(678, 32)
$LblAvProgramado.ForeColor = $ColorDim

$TabAviso.Controls.AddRange(@($LblAv1,$LblAv2,$TxtAviso,$BtnAvisoGravar,$BtnAvisoLimpar,$BtnAvisoProgramar,$BtnAvisoCancelar,$LblAvProgramado,$LblAvStatus))

try { $TxtAviso.Text = Get-AvisoTexto } catch { }

$BtnAvisoGravar.Add_Click({
  $BtnAvisoGravar.Enabled = $false
  $LblAvStatus.ForeColor = $ColorDim
  $LblAvStatus.Text = 'Gravando o aviso e enviando ao GitHub...'
  $LblAvStatus.Refresh()
  try {
    [IO.File]::WriteAllText($AvisoFile, $TxtAviso.Text.Trim(), (New-Object System.Text.UTF8Encoding($false)))
    $LblAvStatus.Text = Sync-NoviplayJson -Force
    $LblAvStatus.ForeColor = $ColorGreen
  } catch {
    $LblAvStatus.Text = 'ERRO: ' + $_.Exception.Message
    $LblAvStatus.ForeColor = $ColorRed
  }
  $BtnAvisoGravar.Enabled = $true
})

$BtnAvisoLimpar.Add_Click({
  $TxtAviso.Clear()
  $BtnAvisoGravar.Enabled = $false
  $LblAvStatus.ForeColor = $ColorDim
  $LblAvStatus.Text = 'Limpando o aviso e enviando ao GitHub...'
  $LblAvStatus.Refresh()
  try {
    [IO.File]::WriteAllText($AvisoFile, '', (New-Object System.Text.UTF8Encoding($false)))
    $LblAvStatus.Text = Sync-NoviplayJson -Force
    $LblAvStatus.ForeColor = $ColorGreen
  } catch {
    $LblAvStatus.Text = 'ERRO: ' + $_.Exception.Message
    $LblAvStatus.ForeColor = $ColorRed
  }
  $BtnAvisoGravar.Enabled = $true
})

# Programar = nao envia agora. O texto fica esperando e sai junto com a
# atualizacao automatica (no mesmo noviplay.json dos filmes).
$BtnAvisoProgramar.Add_Click({
  $txt = $TxtAviso.Text.Trim()
  $conf = [System.Windows.Forms.MessageBox]::Show(
    "Programar este aviso para a PROXIMA atualizacao automatica ($(Get-FSIntervaloTexto))?" + [Environment]::NewLine + [Environment]::NewLine +
    $(if ($txt) { '  ' + $txt } else { '  (texto vazio = a tela inicial fica sem cartao de aviso)' }) + [Environment]::NewLine + [Environment]::NewLine +
    'Ele vai junto com os filmes/series que entrarem na mesma atualizacao.',
    'Programar aviso', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return }
  try {
    Set-AvisoProgramado $txt | Out-Null
    $LblAvStatus.ForeColor = $ColorGreen
    $LblAvStatus.Text = $(if ($txt) { 'Aviso PROGRAMADO. Ele entra na proxima atualizacao automatica, junto com os filmes/series novos.' } else { 'Aviso PROGRAMADO para APAGAR o cartao de aviso na proxima atualizacao.' })
    Atualiza-AvisoProgramado
  } catch {
    $LblAvStatus.ForeColor = $ColorRed
    $LblAvStatus.Text = 'ERRO: ' + $_.Exception.Message
  }
})

$BtnAvisoCancelar.Add_Click({
  if (-not (Test-Path -LiteralPath $AvisoProgFile)) {
    $LblAvStatus.ForeColor = $ColorDim
    $LblAvStatus.Text = 'Nao ha aviso programado para cancelar.'
    return
  }
  try {
    Cancelar-AvisoProgramado
    $LblAvStatus.ForeColor = $ColorDim
    $LblAvStatus.Text = 'Aviso programado cancelado. A proxima atualizacao nao mexe no aviso.'
    Atualiza-AvisoProgramado
  } catch {
    $LblAvStatus.ForeColor = $ColorRed
    $LblAvStatus.Text = 'ERRO: ' + $_.Exception.Message
  }
})

# ---------------- ABA AVISO AUTOMATICO (10/10/2026) ----------------
# O painel avisa SOZINHO quando entra um titulo novo. O aviso tem hora limite:
# depois de N minutos ele some da tela do app e o aviso manual volta a valer.
$TabAvAuto = New-Object System.Windows.Forms.TabPage
$TabAvAuto.Text = 'Aviso automatico'
$TabAvAuto.BackColor = $ColorBg

$LblAa1 = New-Object System.Windows.Forms.Label
$LblAa1.Text = 'AVISO AUTOMATICO: quando voce adicionar um filme ou serie no catalogo, o painel manda sozinho'
$LblAa1.Location = New-Object System.Drawing.Point(12, 8)
$LblAa1.Size = New-Object System.Drawing.Size(678, 18)
$LblAa1.AutoSize = $false
$LblAa1.ForeColor = $ColorDim

$LblAa2 = New-Object System.Windows.Forms.Label
$LblAa2.Text = 'um "NOVA SERIE ADICIONADA!" para a tela inicial do app. Depois de alguns minutos o cartao some sozinho.'
$LblAa2.Location = New-Object System.Drawing.Point(12, 28)
$LblAa2.Size = New-Object System.Drawing.Size(678, 18)
$LblAa2.AutoSize = $false
$LblAa2.ForeColor = $ColorDim

$ChkAaOn = New-Object System.Windows.Forms.CheckBox
$ChkAaOn.Text = 'Avisar automaticamente quando eu adicionar filme/serie'
$ChkAaOn.Location = New-Object System.Drawing.Point(14, 54)
$ChkAaOn.Size = New-Object System.Drawing.Size(420, 24)
$ChkAaOn.ForeColor = $ColorFg
$ChkAaOn.BackColor = $ColorBg

$LblAaMin = New-Object System.Windows.Forms.Label
$LblAaMin.Text = 'some depois de (minutos):'
$LblAaMin.Location = New-Object System.Drawing.Point(14, 88)
$LblAaMin.Size = New-Object System.Drawing.Size(180, 18)
$LblAaMin.AutoSize = $false
$LblAaMin.ForeColor = $ColorDim

$NudAaMin = New-Object System.Windows.Forms.NumericUpDown
$NudAaMin.Location = New-Object System.Drawing.Point(202, 84)
$NudAaMin.Size = New-Object System.Drawing.Size(70, 22)
$NudAaMin.Minimum = 1
$NudAaMin.Maximum = 120
$NudAaMin.Value = 5
$NudAaMin.BackColor = $ColorPanel
$NudAaMin.ForeColor = $ColorFg

$LblAaSoUm = New-Object System.Windows.Forms.Label
$LblAaSoUm.Text = 'So avisa quando entra UM titulo por vez (se entrar 2+, nao avisa).'
$LblAaSoUm.Location = New-Object System.Drawing.Point(290, 88)
$LblAaSoUm.Size = New-Object System.Drawing.Size(400, 18)
$LblAaSoUm.AutoSize = $false
$LblAaSoUm.ForeColor = $ColorDim

$ChkAaTrad = New-Object System.Windows.Forms.CheckBox
$ChkAaTrad.Text = 'Traduzir o nome do titulo para portugues na hora do aviso'
$ChkAaTrad.Location = New-Object System.Drawing.Point(470, 54)
$ChkAaTrad.Size = New-Object System.Drawing.Size(430, 24)
$ChkAaTrad.ForeColor = $ColorFg
$ChkAaTrad.BackColor = $ColorBg

$LblAaSerie = New-Object System.Windows.Forms.Label
$LblAaSerie.Text = 'texto para SERIE:'
$LblAaSerie.Location = New-Object System.Drawing.Point(14, 120)
$LblAaSerie.Size = New-Object System.Drawing.Size(120, 18)
$LblAaSerie.AutoSize = $false
$LblAaSerie.ForeColor = $ColorDim

$TxtAaSerie = New-Object System.Windows.Forms.TextBox
$TxtAaSerie.Location = New-Object System.Drawing.Point(140, 116)
$TxtAaSerie.Size = New-Object System.Drawing.Size(550, 24)
$TxtAaSerie.BackColor = $ColorPanel
$TxtAaSerie.ForeColor = $ColorFg
$TxtAaSerie.BorderStyle = 'FixedSingle'

$LblAaFilme = New-Object System.Windows.Forms.Label
$LblAaFilme.Text = 'texto para FILME:'
$LblAaFilme.Location = New-Object System.Drawing.Point(14, 152)
$LblAaFilme.Size = New-Object System.Drawing.Size(120, 18)
$LblAaFilme.AutoSize = $false
$LblAaFilme.ForeColor = $ColorDim

$TxtAaFilme = New-Object System.Windows.Forms.TextBox
$TxtAaFilme.Location = New-Object System.Drawing.Point(140, 148)
$TxtAaFilme.Size = New-Object System.Drawing.Size(550, 24)
$TxtAaFilme.BackColor = $ColorPanel
$TxtAaFilme.ForeColor = $ColorFg
$TxtAaFilme.BorderStyle = 'FixedSingle'

$LblAaAjuda = New-Object System.Windows.Forms.Label
$LblAaAjuda.Text = 'Use {nome} no texto: ele vira o nome do titulo. Ex.: NOVA SERIE ADICIONADA! ({nome})'
$LblAaAjuda.Location = New-Object System.Drawing.Point(14, 182)
$LblAaAjuda.Size = New-Object System.Drawing.Size(678, 18)
$LblAaAjuda.AutoSize = $false
$LblAaAjuda.ForeColor = $ColorDim

$BtnAaGravar = New-Object System.Windows.Forms.Button
$BtnAaGravar.Text = 'GRAVAR CONFIGURACAO'
$BtnAaGravar.Location = New-Object System.Drawing.Point(14, 212)
$BtnAaGravar.Size = New-Object System.Drawing.Size(210, 38)
$BtnAaGravar.BackColor = $ColorBlue
$BtnAaGravar.ForeColor = [Drawing.Color]::White
$BtnAaGravar.FlatStyle = 'Flat'

$BtnAaTestar = New-Object System.Windows.Forms.Button
$BtnAaTestar.Text = 'TESTAR AGORA NA TV'
$BtnAaTestar.Location = New-Object System.Drawing.Point(234, 212)
$BtnAaTestar.Size = New-Object System.Drawing.Size(210, 38)
$BtnAaTestar.BackColor = $ColorGreen
$BtnAaTestar.ForeColor = [Drawing.Color]::Black
$BtnAaTestar.FlatStyle = 'Flat'

$BtnAaLimpar = New-Object System.Windows.Forms.Button
$BtnAaLimpar.Text = 'TIRAR DA TELA AGORA'
$BtnAaLimpar.Location = New-Object System.Drawing.Point(454, 212)
$BtnAaLimpar.Size = New-Object System.Drawing.Size(236, 38)
$BtnAaLimpar.BackColor = $ColorPanel
$BtnAaLimpar.ForeColor = $ColorFg
$BtnAaLimpar.FlatStyle = 'Flat'

$LblAaStatus = New-Object System.Windows.Forms.Label
$LblAaStatus.Location = New-Object System.Drawing.Point(14, 260)
$LblAaStatus.Size = New-Object System.Drawing.Size(678, 40)
$LblAaStatus.ForeColor = $ColorDim

$LblAaHist = New-Object System.Windows.Forms.Label
$LblAaHist.Text = 'ultimos avisos automaticos enviados:'
$LblAaHist.Location = New-Object System.Drawing.Point(14, 306)
$LblAaHist.Size = New-Object System.Drawing.Size(678, 18)
$LblAaHist.AutoSize = $false
$LblAaHist.ForeColor = $ColorDim

$LstAaHist = New-Object System.Windows.Forms.ListBox
$LstAaHist.Location = New-Object System.Drawing.Point(14, 328)
$LstAaHist.Size = New-Object System.Drawing.Size(678, 150)
$LstAaHist.BackColor = $ColorPanel
$LstAaHist.ForeColor = $ColorFg
$LstAaHist.BorderStyle = 'FixedSingle'
$LstAaHist.IntegralHeight = $false

$TabAvAuto.Controls.AddRange(@($LblAa1,$LblAa2,$ChkAaOn,$ChkAaTrad,$LblAaMin,$NudAaMin,$LblAaSoUm,$LblAaSerie,$TxtAaSerie,$LblAaFilme,$TxtAaFilme,$LblAaAjuda,$BtnAaGravar,$BtnAaTestar,$BtnAaLimpar,$LblAaStatus,$LblAaHist,$LstAaHist))

function Atualiza-AvisoAuto {
  try {
    $at = Get-AvisoAutoAtivo
    if ($at) {
      $faltam = [int][Math]::Ceiling(($at.Ate - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 60000.0)
      $LblAaStatus.Text = "TEM aviso automatico na tela agora: '$($at.Texto)' (some em ~$faltam min)"
      $LblAaStatus.ForeColor = $ColorGreen
    } else {
      $LblAaStatus.Text = 'Nenhum aviso automatico na tela agora.'
      $LblAaStatus.ForeColor = $ColorDim
    }
    $LstAaHist.BeginUpdate()
    $LstAaHist.Items.Clear()
    foreach ($l in @(Get-AvisoAutoLog)) { [void]$LstAaHist.Items.Add($l) }
    $LstAaHist.EndUpdate()
  } catch { }
}

try {
  $cfg0 = Get-AvisoAutoCfg
  $ChkAaOn.Checked = [bool]$cfg0.On
  $ChkAaTrad.Checked = [bool]$cfg0.Traduzir
  $NudAaMin.Value = [int]$cfg0.Min
  $TxtAaSerie.Text = [string]$cfg0.Serie
  $TxtAaFilme.Text = [string]$cfg0.Filme
  Atualiza-AvisoAuto
} catch { }

$BtnAaGravar.Add_Click({
  try {
    $cfg = [PSCustomObject]@{
      On = [bool]$ChkAaOn.Checked
      Min = [int]$NudAaMin.Value
      Traduzir = [bool]$ChkAaTrad.Checked
      Serie = $TxtAaSerie.Text.Trim()
      Filme = $TxtAaFilme.Text.Trim()
    }
    if (-not $cfg.Serie) { $cfg.Serie = 'NOVA SERIE ADICIONADA! ({nome})' }
    if (-not $cfg.Filme) { $cfg.Filme = 'NOVO FILME ADICIONADO! ({nome})' }
    Set-AvisoAutoCfg $cfg
    $LblAaStatus.Text = 'Configuracao gravada.'
    $LblAaStatus.ForeColor = $ColorGreen
    Atualiza-AvisoAuto
  } catch {
    $LblAaStatus.Text = 'ERRO: ' + $_.Exception.Message
    $LblAaStatus.ForeColor = $ColorRed
  }
})

$BtnAaTestar.Add_Click({
  $BtnAaTestar.Enabled = $false
  $LblAaStatus.Text = 'Enviando aviso de teste...'
  $LblAaStatus.Refresh()
  try {
    Set-AvisoAutoCfg ([PSCustomObject]@{ On = [bool]$ChkAaOn.Checked; Min = [int]$NudAaMin.Value; Traduzir = [bool]$ChkAaTrad.Checked; Serie = $TxtAaSerie.Text.Trim(); Filme = $TxtAaFilme.Text.Trim() })
    Set-AvisoAuto 'TESTE DE AVISO AUTOMATICO' ([int]$NudAaMin.Value) | Out-Null
    $res = Sync-NoviplayJson -Force
    Agenda-LimpezaAvisoAuto
    $LblAaStatus.Text = 'Aviso de teste enviado. ' + $res
    $LblAaStatus.ForeColor = $ColorGreen
    Atualiza-AvisoAuto
  } catch {
    $LblAaStatus.Text = 'ERRO: ' + $_.Exception.Message
    $LblAaStatus.ForeColor = $ColorRed
  }
  $BtnAaTestar.Enabled = $true
})

$BtnAaLimpar.Add_Click({
  $BtnAaLimpar.Enabled = $false
  try {
    Limpa-AvisoAuto
    $LblAaStatus.Text = Sync-NoviplayJson -Force
    $LblAaStatus.ForeColor = $ColorGreen
    Atualiza-AvisoAuto
  } catch {
    $LblAaStatus.Text = 'ERRO: ' + $_.Exception.Message
    $LblAaStatus.ForeColor = $ColorRed
  }
  $BtnAaLimpar.Enabled = $true
})

# --------------


  $TabCtl.TabPages.Add($TabFilmes)
  $TabCtl.TabPages.Add($TabSin)
$TabCtl.TabPages.Add($TabFrost)
$TabCtl.TabPages.Add($TabFuturo)
$TabCtl.TabPages.Add($TabFenix)
$TabCtl.TabPages.Add($TabCanais)
$TabCtl.TabPages.Add($TabOrd)
$TabCtl.TabPages.Add($TabMinhaTV)
$TabCtl.TabPages.Add($TabAviso)
$TabCtl.TabPages.Add($TabAvAuto)

foreach ($_pg in $TabCtl.TabPages) {
  $_pg.Add_Paint({
    param($sender, $ev)
    $bg = $Form.BackgroundImage
    if (-not $bg) { return }
    $cw = $Form.ClientSize.Width
    $ch = $Form.ClientSize.Height
    if ($cw -le 0 -or $ch -le 0) { return }
    $po = $Form.PointToClient($sender.PointToScreen([System.Drawing.Point]::Empty))
    $sx = [double]$bg.Width / $cw
    $sy = [double]$bg.Height / $ch
    $srcX = [int][Math]::Round($po.X * $sx)
    $srcY = [int][Math]::Round($po.Y * $sy)
    $sw = [Math]::Max(1, [int][Math]::Round($sender.Width * $sx))
    $sh = [Math]::Max(1, [int][Math]::Round($sender.Height * $sy))
    $ev.Graphics.DrawImage($bg, 0, 0, $sender.Width, $sender.Height, $srcX, $srcY, $sw, $sh, 2)
    $ov = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(165, 8, 9, 12))
    $ev.Graphics.FillRectangle($ov, 0, 0, $sender.Width, $sender.Height)
    $ov.Dispose()
  })
}

$LblFoot = New-Object System.Windows.Forms.Label
$LblFoot.Text = 'Backup automatico sempre em um unico arquivo (channels.np.backup). O painel admin abre ja desbloqueado ao final.'
$LblFoot.ForeColor = $ColorDim
$LblFoot.Location = New-Object System.Drawing.Point(16, 716)
$LblFoot.Size = New-Object System.Drawing.Size(708, 18)

$Form.Controls.AddRange(@($LblTitulo,$LblSub,$LblProxima,$LblUltima,$LblSinc,$LblFalhasCap,$LstFalhas,$BtnFalha,$TabCtl,$LblFoot))

# ---------------- LAYOUT (10/10/2026) ----------------
# O painel foi desenhado para 740 px de largura e nada se mexia quando a janela
# mudava de tamanho: por isso os nomes ficavam cortados. Aqui os controles
# LARGOS (listas, caixas de busca, avisos) esticam junto com a janela, e os que
# estavam do lado DIREITO (botoes, contadores) vao para a borda direita. Os
# botoes do meio e as caixas de numero ficam onde estavam.
$script:EmLayout = $false
function Aplica-Layout {
  if ($script:EmLayout) { return }
  $script:EmLayout = $true
  try {
    # [int] e' obrigatorio: sem o cast o $ch/$larg viram Object[] e o
    # "New-Object Point($marg, $ch - 30)" quebrava com op_Subtraction.
    $cw = [int]$Form.ClientSize.Width
    $ch = [int]$Form.ClientSize.Height
    if ($cw -lt 500 -or $ch -lt 400) { return }

    $marg = 16
    $larg = [int]($cw - ($marg * 2))

    if ($LblSub) { $LblSub.Width = $larg }
    #atencao: New-Object Point(x, y - 30) quebra neste PowerShell (o virgula
    #monta o array antes da subtracao). Por isso a conta vem antes.
    $footY = [int]($ch - 30)
    if ($LblFoot) { $LblFoot.Width = $larg; $LblFoot.Location = New-Object System.Drawing.Point($marg, $footY) }

    if ($LstFalhas) {
      $falhaW = [int][Math]::Max(300, [int]($larg - $BtnFalha.Width - 12))
      $LstFalhas.Width = $falhaW
    }
    $btnX = [int]($cw - $marg - $BtnFalha.Width)
    $btnY = [int]$LstFalhas.Top
    if ($BtnFalha) { $BtnFalha.Location = New-Object System.Drawing.Point($btnX, $btnY) }

    $topoTabs = 196
    if ($TabCtl) {
      $tabH = [int][Math]::Max(200, [int]($ch - $topoTabs - 40))
      $TabCtl.Location = New-Object System.Drawing.Point($marg, $topoTabs)
      $TabCtl.Size = New-Object System.Drawing.Size($larg, $tabH)

      foreach ($pg in $TabCtl.TabPages) {
        # cada aba e' arrumada por conta propria: se uma der problema, as outras
        # continuam sendo arrumadas normally
        try {
        $pw = [int]$pg.ClientSize.Width
        $ph = [int]$pg.ClientSize.Height
        if ($pw -lt 500) { continue }
        $ctrls = @($pg.Controls)

        # 1a) DIREITA: quem esta do lado direito encosta na borda
        foreach ($c in $ctrls) {
          $l = [int]$c.Left; $w = [int]$c.Width
          if ($w -ge 250) { continue }
          if (($l + $w) -gt 560) {
            $nl = $pw - $w - 14
            if ($nl -gt $l) { $c.Location = New-Object System.Drawing.Point([int]$nl, [int]$c.Top) }
          }
        }

        # 1b) LARGURA: o que e' largo estica ate a borda, MAS PARA ANTES de
        #     qualquer coisa que esteja na mesma linha a sua direita (ex.: o
        #     botao BUSCAR do lado da caixa de busca - antes ele ficava
        #     escondido debaixo da caixa esticada).
        foreach ($c in $ctrls) {
          $l = [int]$c.Left; $t = [int]$c.Top; $w = [int]$c.Width
          if ($w -lt 250) { continue }
          $limite = $pw - 14
          foreach ($o in $ctrls) {
            if ($o -eq $c) { continue }
            if ([int]$o.Top -gt ($t + 20)) { continue }
            $ol = [int]$o.Left
            if ($ol -le $l) { continue }
            if ($ol -lt $limite) { $limite = $ol }
          }
          $nw = $limite - $l - 8
          if ($nw -ge 250 -and $nw -gt $w) { $c.Width = [int]$nw }
        }

        # 2) ALTURA: listas e caixas de texto ganham o espaco ate o proximo
        #    controle que estiver abaixo delas (nao invade nada).
        foreach ($c in $ctrls) {
          $cresce = ($c -is [System.Windows.Forms.ListBox]) -or
                    (($c -is [System.Windows.Forms.TextBox]) -and $c.Multiline)
          if (-not $cresce) { continue }
          $prox = $ph - 10
          foreach ($o in $ctrls) {
            if ($o -eq $c) { continue }
            # so conta o que esta abaixo E na mesma faixa horizontal
            if ([int]$o.Top -le ([int]$c.Top + 20)) { continue }
            if ([int]$o.Left -ge ([int]$c.Left + [int]$c.Width)) { continue }
            if (([int]$o.Left + [int]$o.Width) -le [int]$c.Left) { continue }
            if ([int]$o.Top -lt $prox) { $prox = [int]$o.Top }
          }
          $nova = $prox - [int]$c.Top - 8
          if ($nova -gt ([int]$c.Height + 30)) { $c.Height = [int]$nova }
        }
        } catch { }
      }
    }
  } catch { } finally { $script:EmLayout = $false }
}
$Form.Add_Shown({
  try { if ($Form.WindowState -ne 'Maximized') { $Form.WindowState = 'Maximized' } } catch { }
  Aplica-Tema
  Aplica-Layout
})
$Form.Add_Resize({ Aplica-Layout })

# ---------------- TEMA (10/10/2026) ----------------
# Passa por TODOS os controles do painel e deixa com a cara do app: botao
# vermelho, painel escuro, borda fina. Nenhum clique e mexido aqui - e' so
# cor, fonte e borda. Tudo que o painel ja fazia continua igual.
function Tema-Controle($c) {
  try {
    if ($c -is [System.Windows.Forms.Button]) {
      $c.FlatStyle = 'Flat'
      $c.FlatAppearance.BorderColor = $ColorBorda
      $c.FlatAppearance.BorderSize = 1
      $c.FlatAppearance.MouseOverBackColor = $ColorRed
      $c.FlatAppearance.MouseDownBackColor = $ColorVerm
      # o painel ja pinta cada botao com uma cor (verde=acao, azul=destaque);
      # aqui so entra no lugar do que NAO foi pintado a mao.
      if ($c.BackColor -eq [System.Drawing.Color]::Empty -or $c.BackColor.R -eq $c.BackColor.G) { }
      if ($c.BackColor -eq [System.Windows.Forms.SystemColors]::Control) { $c.BackColor = $ColorPanel }
      $c.ForeColor = $ColorFg
      return
    }
    if ($c -is [System.Windows.Forms.ListBox]) {
      $c.BackColor = $ColorPanel
      $c.ForeColor = $ColorFg
      $c.BorderStyle = 'FixedSingle'
      $c.HorizontalScrollbar = $true
      return
    }
    if ($c -is [System.Windows.Forms.TextBox]) {
      $c.BackColor = $ColorPanel
      $c.ForeColor = $ColorFg
      $c.BorderStyle = 'FixedSingle'
      return
    }
    if ($c -is [System.Windows.Forms.NumericUpDown]) {
      $c.BackColor = $ColorPanel
      $c.ForeColor = $ColorFg
      $c.BorderStyle = 'FixedSingle'
      return
    }
    if ($c -is [System.Windows.Forms.ComboBox]) {
      $c.BackColor = $ColorPanel
      $c.ForeColor = $ColorFg
      $c.FlatStyle = 'Flat'
      return
    }
    if ($c -is [System.Windows.Forms.CheckBox]) {
      $c.ForeColor = $ColorFg
      $c.BackColor = $ColorBg
      $c.FlatStyle = 'Flat'
      return
    }
    if ($c -is [System.Windows.Forms.Label]) {
      $c.ForeColor = $ColorFg
      $c.BackColor = $ColorBg
      return
    }
    if ($c -is [System.Windows.Forms.TabPage]) {
      $c.BackColor = $ColorBg
      $c.ForeColor = $ColorFg
      return
    }
  } catch { }
}

function Aplica-Tema {
  try {
    foreach ($c in @($Form.Controls)) { Tema-Controle $c }
    foreach ($pg in $TabCtl.TabPages) {
      $pg.BackColor = $ColorBg
      $pg.ForeColor = $ColorFg
      foreach ($c in @($pg.Controls)) { Tema-Controle $c }
    }
    # aba do tabcontrol tambem fica com a cor nova
    $TabCtl.DrawMode = 'OwnerDrawFixed'
    $TabCtl.Add_Resize({ param($s, $e) try { $TabCtl.Invalidate() } catch { } })
  } catch { }
}

# ---------------- LOGICA ----------------

function Atualiza-StatusUltima {
  $est = Ler-Estado
  $LstFalhas.BeginUpdate()
  $LstFalhas.Items.Clear()
  $itens = @()
  if ($est -and $est.itens) { $itens = @($est.itens) }
  if ($itens.Count -gt 0) {
    foreach ($i in $itens) {
      $src = [string]$i.src; $tipo = [string]$i.tipo; $nm = [string]$i.nome; $ep = [string]$i.ep
      $disp = "[$src] $nm"; if ($tipo -eq 'serie' -and $ep) { $disp = "$disp  [$ep]" }
      [void]$LstFalhas.Items.Add([PSCustomObject]@{ Display = $disp; Src = $src; Tipo = $tipo; Nome = $nm; Serie = $i.serie; Ep = $ep })
    }
  }
  $LstFalhas.EndUpdate()
  $BtnFalha.Enabled = ($itens.Count -gt 0)
  if (-not $est) { $LblUltima.Text = 'Ultima atualizacao automatica: nenhuma ainda'; $LblUltima.ForeColor = $ColorDim; return }
  $sigla = "$($est.status)"
  $inicio = [string]$est.inicio
  $pulso = [string]$est.pulso
  $fim = [string]$est.fim
  $falhasN = [int]$est.falhas
  $updN = [int]$est.atualizados
  if ($sigla -eq 'rodando') {
    $tInicio = [datetime]::MinValue; [void][datetime]::TryParse($inicio, [ref]$tInicio)
    $tPulso = [datetime]::MinValue; [void][datetime]::TryParse($pulso, [ref]$tPulso)
    $semPulso = ((Get-Date) - $tPulso).TotalMinutes
    $decorrido = ((Get-Date) - $tInicio).TotalMinutes
    $procVivo = $true
    $pidUp = 0; [void][int]::TryParse([string]$est.pid, [ref]$pidUp)
    if ($pidUp -gt 0 -and -not (Get-Process -Id $pidUp -ErrorAction SilentlyContinue)) { $procVivo = $false }
    if (($tInicio -eq [datetime]::MinValue) -or (-not $procVivo) -or $decorrido -gt 120 -or ($decorrido -gt 50 -and $semPulso -gt 10)) {
      $LblUltima.Text = "ULTIMA ATUALIZACAO TRAVOU: iniciada em $inicio, ultimo progresso ha $([int]$semPulso) min"
      $LblUltima.ForeColor = $ColorRed
    } else {
      $LblUltima.Text = "ULTIMA ATUALIZACAO AINDA EM EXECUCAO desde $inicio ($([int]$decorrido) min decorridos)..."
      $LblUltima.ForeColor = $ColorBlue
    }
} elseif ($sigla -eq 'sucesso') {
  $hh = $fim; if (-not $hh) { $hh = $pulso }
  # Usa a mensagem que a rodada gravou em vez de um texto fixo: o rodape ja
  # separa "link que nao abre" de "titulo sem link novo no catalogo".
  $det = [string]$est.msg
  if (-not $det) { $det = "concluida com sucesso ($updN links atualizados)" }
  $LblUltima.Text = "Ultima atualizacao de $($hh): CONCLUIDA - $det"
  $LblUltima.ForeColor = $ColorGreen
} elseif ($sigla -eq 'parcial') {
  $hh = $fim; if (-not $hh) { $hh = $pulso }
  $det = [string]$est.msg
  if (-not $det) { $det = "terminou com $falhasN titulo(s) sem link novo no catalogo" }
  $LblUltima.Text = "Ultima atualizacao de $($hh): $det"
$LblUltima.ForeColor = [Drawing.Color]::FromArgb(230, 160, 60)
} elseif ($sigla -eq 'erro') {
    $LblUltima.Text = "Ultima atualizacao de $($pulso): ERRO - $($est.msg)"
    $LblUltima.ForeColor = $ColorRed
  } else {
    $LblUltima.Text = 'Ultima atualizacao automatica: nenhuma ainda'
    $LblUltima.ForeColor = $ColorDim
  }
}

function Refresh-FuturoList {
  # Preserva o que estava selecionado: a lista se sozinha a cada minuto e nao
  # pode limpar a selecao de quem esta prestes a clicar em REMOVER.
  $chave = ''
  if ($LstFuturo.SelectedItem) {
    $chave = ([string]$LstFuturo.SelectedItem.Tipo + '|' + [string]$LstFuturo.SelectedItem.Id + '|' + [string]$LstFuturo.SelectedItem.Season)
  }
  $fila = @(Read-FuturoQueue)
  $LstFuturo.BeginUpdate()
  $LstFuturo.Items.Clear()
  $idx = -1
  foreach ($it in $fila) {
    [void]$LstFuturo.Items.Add($it)
    if ($idx -lt 0 -and $chave -ne '') {
      if (([string]$it.Tipo + '|' + [string]$it.Id + '|' + [string]$it.Season) -eq $chave) { $idx = $LstFuturo.Items.Count - 1 }
    }
  }
  $LstFuturo.EndUpdate()
  if ($idx -ge 0) { $LstFuturo.SelectedIndex = $idx }
  $LblFuCount.Text = "$($LstFuturo.Items.Count) item(ns) na fila. Processado pela atualizacao $(Get-FSIntervaloTexto) (ou no botao PROCESSAR AGORA)."
}

function Atualiza-AvisoProgramado {
  if (Test-Path -LiteralPath $AvisoProgFile) {
    $t = (Get-AvisoProgramado).Trim() -replace '\s+', ' '
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '...' }
    if ($t) { $LblAvProgramado.Text = 'PROGRAMADO PARA A PROXIMA ATUALIZACAO: ' + $t }
    else { $LblAvProgramado.Text = 'PROGRAMADO: a tela inicial fica SEM cartao de aviso na proxima atualizacao.' }
    $LblAvProgramado.ForeColor = $ColorGreen
  } else {
    $LblAvProgramado.Text = 'Nada programado. O aviso so muda se voce clicar em GRAVAR (agora) ou PROGRAMAR (na proxima atualizacao).'
    $LblAvProgramado.ForeColor = $ColorDim
  }
}

$script:AtualizaAgenda = {
  try {
    $info = Get-ScheduledTaskInfo -TaskName (Get-FSTarefaNome)
    if ($info -and $info.NextRunTime) { $LblProxima.Text = 'Proxima atualizacao automatica: ' + $info.NextRunTime.ToString('dd/MM/yyyy HH:mm') + '  (' + (Get-FSIntervaloTexto) + ')' }
    else { $LblProxima.Text = 'Proxima atualizacao automatica: nao agendada' }
  } catch { $LblProxima.Text = 'Proxima atualizacao automatica: indisponivel' }
  Atualiza-StatusUltima
  # Barra de sincronizacao: mostra QUEM fez a ultima atualizacao (PC,
  # Github ou celular) e quando sao as proximas rodadas de cada um.
  # So e lida do gist a cada 60s, para o painel nao travar esperando a net.
  try { Atualiza-BarraSincronizacao } catch { }
  # A fila se atualiza sozinha: se a atualizacao automatica ja pegou um
  # titulo da fila, ele some da lista em ate 1 minuto, sem clicar nada.
  Refresh-FuturoList
  Atualiza-AvisoProgramado
}
$TmrAgenda = New-Object System.Windows.Forms.Timer
$TmrAgenda.Interval = 60000
$TmrAgenda.Add_Tick({ & $script:AtualizaAgenda })
& $script:AtualizaAgenda
$TmrAgenda.Start()

function Refresh-FilmesList {
  $q = Normalize-Text $TxtFilterF.Text
  $ListF.BeginUpdate()
  $ListF.Items.Clear()
  if ($q -eq '') {
    foreach ($it in $global:Filmes) { [void]$ListF.Items.Add($it) }
  } else {
    foreach ($it in $global:Filmes) { if ((Normalize-Text $it.Display) -like "*$q*") { [void]$ListF.Items.Add($it) } }
  }
  $ListF.EndUpdate()
  $LblCountF.Text = "$($ListF.Items.Count) de $($global:Filmes.Count)"
}

function Refresh-SinopseCombo {
  $CmbSp.BeginUpdate()
  $CmbSp.Items.Clear()
  $seen = @{}
  foreach ($it in $global:Filmes) {
    if ($it.Cat -ne 'serie') { continue }
    $nome = $it.Serie
    if (-not $nome) { $nome = $it.Nome }
    if (-not $nome) { continue }
    $key = Normalize-Text $nome
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    [void]$CmbSp.Items.Add($nome)
  }
  $CmbSp.EndUpdate()
  $LblSpStatus.Text = "Series na lista: $($CmbSp.Items.Count) (selecione uma acima)."
}

function Refresh-CanaisList {
  $q = Normalize-Text $TxtFilterC.Text
  $ListC.BeginUpdate()
  $ListC.Items.Clear()
  if ($q -eq '') {
    foreach ($it in $global:Canais) { [void]$ListC.Items.Add($it) }
  } else {
    foreach ($it in $global:Canais) { if ((Normalize-Text $it.Display) -like "*$q*") { [void]$ListC.Items.Add($it) } }
  }
  $ListC.EndUpdate()
  $LblCountC.Text = "$($ListC.Items.Count) de $($global:Canais.Count)"
}

function Refresh-OrdCanaisList {
  $q = Normalize-Text $TxtOrdQ.Text
  if ($q -eq 'pesquisar canal nesta lista...') { $q = '' }
  $ListOrd.BeginUpdate()
  $ListOrd.Items.Clear()
  $n = 0
  foreach ($it in $global:Canais) {
    $n++
    if ($q -ne '' -and (Normalize-Text $it.Display) -notlike "*$q*" -and (Normalize-Text $it.Nome) -notlike "*$q*") { continue }
    $obj = [PSCustomObject]@{ Idx=$it.Idx; Nome=$it.Nome; Url=$it.Url; Cat=$it.Cat; Logo=$it.Logo; Display=("{0}. {1}   [{2}]" -f $n, $it.Nome, $it.Cat) }
    [void]$ListOrd.Items.Add($obj)
  }
  $ListOrd.EndUpdate()
  $LblOrdHead.Text = "Canais na ordem atual do channels.np (o de cima e o primeiro no APK). Total: $($global:Canais.Count) | exibindo: $($ListOrd.Items.Count)"
}

function Select-OrdByName([string]$nome, [string]$url) {
  for ($k = 0; $k -lt $ListOrd.Items.Count; $k++) {
    $o = $ListOrd.Items[$k]
    if ($o.Nome -eq $nome -and $o.Url -eq $url) {
      $ListOrd.SelectedIndex = $k
      $ListOrd.TopIndex = [Math]::Max(0, $k - 5)
      return
    }
  }
}

$TxtFilterF.Add_TextChanged({ Refresh-FilmesList })
$TxtFilterC.Add_TextChanged({ Refresh-CanaisList })

$CmbSp.Add_SelectedIndexChanged({
  if ($CmbSp.SelectedItem -eq $null) { return }
  $sn = Normalize-Text $CmbSp.SelectedItem
  $cur = ''
  if (Test-Path -LiteralPath $ChannelsPath) {
    foreach ($l in [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -ge 9 -and $p[4] -eq 'serie' -and (Normalize-Text $p[5]) -eq $sn) { $cur = $p[8]; break }
    }
  }
  $TxtSpSin.Text = $cur
  $LblSpStatus.Text = 'Serie: ' + $CmbSp.SelectedItem
})

$BtnSpRefresh.Add_Click({
  Read-Data
  Refresh-SinopseCombo
  Refresh-FilmesList
  Refresh-CanaisList
})

$BtnSpTraduz.Add_Click({
  if ($CmbSp.SelectedItem -eq $null) { $LblSpStatus.Text = 'Selecione uma serie primeiro.'; return }
  $nome = $CmbSp.SelectedItem
  $BtnSpTraduz.Enabled = $false
  $TxtSpSin.Text = 'Buscando sinopse em portugues...'
  $LblSpStatus.Text = "Buscando: $nome"
  $LblSpStatus.Refresh()
  try {
    $pt = Get-PtSinopse $nome
    if ($pt) {
      $TxtSpSin.Text = $pt
      $msg = Save-Sinopse $nome $pt
      $LblSpStatus.Text = 'Traduzido e JA ENVIADO ao GitHub. Detalhes: ' + $msg
      Read-Data
      Refresh-SinopseCombo
      Refresh-FilmesList
    } else {
      $TxtSpSin.Text = ''
      $LblSpStatus.Text = 'Nao achei automatico. Digite/cole a sinopse e clique SALVAR.'
    }
  } catch {
    $LblSpStatus.Text = 'ERRO: ' + $_.Exception.Message
  } finally {
    $BtnSpTraduz.Enabled = $true
  }
})

$BtnSpSalvar.Add_Click({
  if ($CmbSp.SelectedItem -eq $null) { $LblSpStatus.Text = 'Selecione uma serie primeiro.'; return }
  $nome = $CmbSp.SelectedItem
  $sin = $TxtSpSin.Text
  $BtnSpSalvar.Enabled = $false
  try {
    $msg = Save-Sinopse $nome $sin
    $LblSpStatus.Text = $msg
    Read-Data
    Refresh-SinopseCombo
    Refresh-FilmesList
  } catch {
    $LblSpStatus.Text = 'ERRO ao salvar: ' + $_.Exception.Message
  } finally {
    $BtnSpSalvar.Enabled = $true
  }
})

$ListF.Add_SelectedIndexChanged({
$sel = @($ListF.SelectedItems)
if ($sel.Count -eq 0) { $BtnUpdate.Enabled = $false; $BtnFDel.Enabled = $false; $BtnFUpd.Enabled = $false; return }
$BtnFDel.Enabled = $true
if ($sel.Count -eq 1) {
$it = $sel[0]
$LblInfoF.Text = "$($it.Display)   [tipo: $($it.Cat)]"
$TxtAtual.Text = $it.Url
$TxtNovo.Text = ''
$BtnUpdate.Enabled = $true
$BtnFUpd.Enabled = $true
} else {
$LblInfoF.Text = "$($sel.Count) itens selecionados. Use Ctrl/Shift para marcar varios."
$TxtAtual.Text = ''
$TxtNovo.Text = ''
$BtnUpdate.Enabled = $false
$BtnFUpd.Enabled = $true
}
$LblStatusF.Text = ''
$LblStatusF.ForeColor = $ColorGreen
})

$ListC.Add_SelectedIndexChanged({
  $sel = @($ListC.SelectedItems)
  $BtnDelete.Enabled = $sel.Count -gt 0
  $BtnRenomear.Enabled = ($sel.Count -eq 1)
  if ($sel.Count -eq 1) {
    $it = $sel[0]
    $LblInfoC.Text = "$($it.Display)  |  Logo: $($it.Logo)"
    $TxtUrlC.Text = $it.Url
    $TxtNomeC.Text = $it.Nome
    $TxtLogoC.Text = [string]$it.Logo
  } elseif ($sel.Count -gt 1) {
    $LblInfoC.Text = "$($sel.Count) canais selecionados."
    $TxtUrlC.Text = ''
    $TxtNomeC.Text = ''
    $TxtLogoC.Text = ''
  } else {
    $LblInfoC.Text = ''
    $TxtUrlC.Text = ''
    $TxtNomeC.Text = ''
    $TxtLogoC.Text = ''
  }
})

$TxtNovo.Add_KeyDown({
  if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    if ($BtnUpdate.Enabled) { $BtnUpdate.PerformClick() }
    $_.SuppressKeyPress = $true
  }
})

$BtnUpdate.Add_Click({
  $it = $ListF.SelectedItem
  if ($null -eq $it) { return }
  $novo = $TxtNovo.Text.Trim()
  if (-not $novo) { [System.Windows.Forms.MessageBox]::Show('Cole a nova URL do servidor primeiro.', 'Aviso', 'OK', 'Information'); return }
  if ($novo -notmatch '^https?://') { [System.Windows.Forms.MessageBox]::Show('A URL deve comecar com http:// ou https://', 'Aviso', 'OK', 'Information'); return }
  if ($novo -eq $it.Url) { $LblStatusF.Text = 'A URL ja e essa.'; $LblStatusF.ForeColor = $ColorGreen; return }

  $msg = "Trocar a URL de:" + [Environment]::NewLine + [Environment]::NewLine +
         '  ' + $it.Display + "   [$($it.Cat)]" + [Environment]::NewLine + [Environment]::NewLine +
         'ANTIGA:' + [Environment]::NewLine + $it.Url + [Environment]::NewLine + [Environment]::NewLine +
         'NOVA:' + [Environment]::NewLine + $novo
  $conf = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirmar atualizacao', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return }

  try {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -LiteralPath $ChannelsPath -Destination (Join-Path $NoviplayDir "channels.np.backup") -Force

    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $idx = $it.Idx
    if ($idx -lt 0 -or $idx -ge $lines.Count) { throw 'O arquivo mudou depois de abrir. Feche o programa e abra de novo.' }
    $line = $lines[$idx]
    if (-not (Test-VodLine $line)) { throw 'A linha selecionada mudou no arquivo. Feche e abra de novo.' }
    $parts = $line.Split([char]'|', [System.StringSplitOptions]::None)
    $parts[1] = $novo
    $lines[$idx] = $parts -join '|'
    Write-File $lines

    $it.Url = $novo
    $TxtAtual.Text = $novo
    $TxtNovo.Text = ''
    $jsonMsg = ''
    try { $jsonMsg = '  |  ' + (Sync-NoviplayJson) } catch { $jsonMsg = '  |  ERRO GitHub: ' + $_.Exception.Message }
    $LblStatusF.Text = ("OK! Atualizado. Backup: {0}{1}`r`nAbrindo o painel..." -f $ts, $jsonMsg)
    $LblStatusF.ForeColor = $ColorGreen
    $LblStatusF.Refresh()
    Open-Panel
  } catch {
    $LblStatusF.Text = 'Erro: ' + $_.Exception.Message
    $LblStatusF.ForeColor = $ColorRed
  }
})

$BtnFDel.Add_Click({
$sel = @($ListF.SelectedItems)
if ($sel.Count -eq 0) { return }
$names = @($sel | ForEach-Object { $_.Display } | Select-Object -First 5) -join ', '
if ($sel.Count -gt 5) { $names += ', ...' }
$conf = [System.Windows.Forms.MessageBox]::Show(
'Excluir ' + $sel.Count + ' item(ns) do channels.np?' + [Environment]::NewLine + [Environment]::NewLine + $names,
'Confirmar exclusao', 'YesNo', 'Warning')
if ($conf -ne 'Yes') { return }

try {
$ts = Backup-Channels

$lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
$remove = @{}
foreach ($it in $sel) { $remove[[int]$it.Idx] = $true }
$delLines = New-Object System.Collections.Generic.List[string]
$newLines = @()
for ($k = 0; $k -lt $lines.Count; $k++) {
  if ($remove.ContainsKey($k)) { $delLines.Add($lines[$k]); continue }
  $newLines += $lines[$k]
}
if ($delLines.Count -eq 0) { throw 'Nada encontrado para excluir. Recarregue o programa.' }
Write-File $newLines

$delNomes = @{}
foreach ($del in $delLines) {
  $pd = $del.Split([char]'|', [System.StringSplitOptions]::None)
  $n = ''
  if ($pd.Count -ge 5 -and $pd[4] -eq 'serie') {
    if ($pd.Count -ge 6) { $n = $pd[5] }
  } elseif ($pd.Count -ge 5 -and $pd[4] -eq 'filme') {
    $n = $pd[0]
  }
  if ($n) { $delNomes[(Normalize-Text $n)] = $n }
}
foreach ($delNome in $delNomes.Values) {
  $sobrou = @($newLines | Where-Object {
    $px = $_.Split([char]'|', [System.StringSplitOptions]::None)
    if ($px.Count -ge 5 -and $px[4] -eq 'serie') {
      return ($px.Count -ge 6 -and (Normalize-Text $px[5]) -eq (Normalize-Text $delNome))
    } elseif ($px.Count -ge 5 -and $px[4] -eq 'filme') {
      return ($px.Count -ge 2 -and (FSMatchName $px[0] $delNome))
    }
    return $false
  })
  if ($sobrou.Count -eq 0) {
    foreach ($regFile in @($FrostFile, $FenixFile)) {
      if (-not (Test-Path -LiteralPath $regFile)) { continue }
      $regLines = [IO.File]::ReadAllLines($regFile, [Text.Encoding]::UTF8)
      $regNovo = @($regLines | Where-Object {
        $pr = $_.Split([char]'|', [System.StringSplitOptions]::None)
        return (-not ($pr.Count -ge 1 -and (Normalize-Text $pr[0]) -eq (Normalize-Text $delNome)))
      })
      if ($regNovo.Count -ne $regLines.Count) {
        [IO.File]::WriteAllText($regFile, ($regNovo -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
      }
    }
  }
}

Read-Data
Refresh-FilmesList
Refresh-CanaisList
Refresh-OrdCanaisList
$BtnFDel.Enabled = $false
$BtnUpdate.Enabled = $false
$TxtAtual.Text = ''
$TxtNovo.Text = ''
$jsonMsg = ''
try { $jsonMsg = '  |  ' + (Sync-NoviplayJson) } catch { $jsonMsg = '  |  ERRO GitHub: ' + $_.Exception.Message }
$LblStatusF.Text = ("OK! {0} item(ns) excluido(s). Backup: {1}{2}`r`nAbrindo o painel..." -f $sel.Count, $ts, $jsonMsg)
$LblStatusF.ForeColor = $ColorGreen
$LblStatusF.Refresh()
Open-Panel
} catch {
$LblStatusF.Text = 'Erro: ' + $_.Exception.Message
$LblStatusF.ForeColor = $ColorRed
}
})

$BtnFUpd.Add_Click({
  $sel = @($ListF.SelectedItems)
  if ($sel.Count -eq 0) { return }
  $LblStatusF.Text = 'Procurando no addon... (pode demorar)'
  $LblStatusF.ForeColor = $ColorGreen
  $LblStatusF.Refresh()
  try {
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $fixes = @()
    $fails = @()
    foreach ($it in $sel) {
      if ($it.Src -ne 'Frost' -and $it.Src -ne 'Fenix') { $fails += "$($it.Display) [fonte desconhecida]"; continue }
      $idx = [int]$it.Idx
      if ($idx -lt 0 -or $idx -ge $lines.Count) { $fails += "$($it.Display) [arquivo mudou]"; continue }
      $line = $lines[$idx]
      if (-not (Test-VodLine $line)) { $fails += "$($it.Display) [linha mudou]"; continue }
      $p = $line.Split([char]'|', [System.StringSplitOptions]::None)
      if ($p.Count -lt 5) { $fails += "$($it.Display) [linha invalida]"; continue }

      if ($it.Src -eq 'Frost') { $reg = Read-FrostReg } else { $reg = Read-FenixReg }
    foreach ($r in $reg) {
        if ($it.Cat -eq 'serie') {
          if ($r.Type -eq 'series' -and $p.Count -ge 6 -and (Normalize-Text $r.Nome) -eq (Normalize-Text $p[5])) { $rec = $r; break }
        } else {
          if ($r.Type -eq 'movie' -and (FSMatchName $p[0] $r.Nome)) { $rec = $r; break }
        }
      }
      if ($null -eq $rec) { $fails += "$($it.Display) [sem registro no addon]"; continue }

      $s = $null
      $titCat = if ($it.Cat -eq 'serie') { [string]$p[5] } else { [string]$p[0] }
      if ($it.Cat -eq 'serie') {
        $tl = Parse-EpLabel $p[6]
        if (-not $tl.Ok) { $fails += "$($it.Display) [episodio nao reconhecido]"; continue }
        $rid = "$($rec.Id):$($tl.Season):$($tl.Ep)"
        if ($it.Src -eq 'Frost') { $s = Pick-FSStream (Get-FSStreams 'series' $rid) $titCat }
        else { $s = Pick-FenixStream (Get-FenixStreams 'series' $rid) $titCat }
      } else {
        if ($it.Src -eq 'Frost') { $s = Pick-FSStream (Get-FSStreams 'movie' $rec.Id) $titCat }
        else { $s = Pick-FenixStream (Get-FenixStreams 'movie' $rec.Id) $titCat }
      }
      if ($null -eq $s) { $fails += "$($it.Display) [sem stream no $($it.Src)]"; continue }

      $url = [string]$s.url
      $qual = [string]$s.name
      $lblAudio = ''
      if ($it.Src -eq 'Frost') { $lblAudio = Get-FSAudio $s } else { $lblAudio = Get-FenixAudio $s }
      $nomeFinal = $p[0]
      if ($it.Cat -eq 'serie') {
        $baseN = $p[5]
        if ($lblAudio) { $baseN = "$($p[5]) ($lblAudio)" }
        $nomeFinal = "$baseN $($p[6])"
      }
      $fixes += [PSCustomObject]@{ Idx = $idx; Parts = $p; Url = $url; Nome = $nomeFinal; Qual = $qual; Audio = $lblAudio; Disp = $it.Display }
    }

    if ($fixes.Count -eq 0) {
      $LblStatusF.Text = 'Nada para atualizar. ' + ($fails -join '; ')
      $LblStatusF.ForeColor = $ColorRed
      return
    }

    $msg = "Corrigir $($fixes.Count) item(ns) pelo addon:" + [Environment]::NewLine + [Environment]::NewLine
    foreach ($f in $fixes) {
      $msg += '  ' + $f.Disp + [Environment]::NewLine
      $msg += '    -> ' + $f.Qual + $(if ($f.Audio) { ' / ' + $f.Audio } else { '' }) + [Environment]::NewLine
    }
    if ($fails.Count -gt 0) { $msg += [Environment]::NewLine + 'SEM STREAM (nao mexidos):' + [Environment]::NewLine + ($fails -join [Environment]::NewLine) }
    $conf = [System.Windows.Forms.MessageBox]::Show($msg, 'Procurar atualizacao - confirmar', 'YesNo', 'Question')
    if ($conf -ne 'Yes') { $LblStatusF.Text = ''; return }

    $ts = Backup-Channels
    foreach ($f in $fixes) {
      $f.Parts[0] = $f.Nome
      $f.Parts[1] = $f.Url
      $lines[$f.Idx] = $f.Parts -join '|'
    }
    Write-File $lines

    Read-Data
    Refresh-FilmesList
    $jsonMsg = ''
    try { $jsonMsg = '  |  ' + (Sync-NoviplayJson) } catch { $jsonMsg = '  |  ERRO GitHub: ' + $_.Exception.Message }
    $LblStatusF.Text = ("OK! {0} link(s) atualizado(s) pelo addon. Backup: {1}{2}`r`nAbrindo o painel..." -f $fixes.Count, $ts, $jsonMsg)
    $LblStatusF.ForeColor = $ColorGreen
    $LblStatusF.Refresh()
    Open-Panel
  } catch {
    $LblStatusF.Text = 'Erro: ' + $_.Exception.Message
    $LblStatusF.ForeColor = $ColorRed
  }
})

$BtnFalha.Add_Click({
  $sel = @($LstFalhas.SelectedItems)
  if ($sel.Count -eq 0) {
    if ($LstFalhas.Items.Count -eq 0) { $LblUltima.Text = 'Caixinha vazia: nada a tentar agora.'; $LblUltima.ForeColor = $ColorDim; return }
    $sel = @($LstFalhas.Items)
  }
  $LblUltima.Text = 'Tentando atualizar itens selecionados... (pode demorar)'
  $LblUltima.ForeColor = $ColorBlue
  $LblUltima.Refresh()
  $ok = @(); $fail = @()
  foreach ($it in $sel) {
    $msg = Retentar-ItemFalha $it
    if ($msg -like 'OK*' -or $msg -like 'ja estava*') {
      $ok += $msg
      Remove-EstadoItem $it
    } else { $fail += $msg }
  }
  if ($ok.Count -gt 0) {
    try { Sync-NoviplayJson | Out-Null } catch { }
    Read-Data
    Refresh-FilmesList
  }
  Atualiza-StatusUltima
  if ($fail.Count -eq 0) {
    $LblUltima.Text = "Tentativa concluida: $($ok.Count) item(ns) resolvido(s)."
    $LblUltima.ForeColor = $ColorGreen
  } else {
    $LblUltima.Text = "Tentativa concluida: $($ok.Count) ok | $($fail.Count) falha(s)."
    $LblUltima.ForeColor = $ColorRed
  }
})

$LstFalhas.Add_DoubleClick({
  $sel = @($LstFalhas.SelectedItems)
  if ($sel.Count -eq 0) { return }
  $LblUltima.Text = 'Tentando atualizar... (pode demorar)'
  $LblUltima.ForeColor = $ColorBlue
  $LblUltima.Refresh()
  foreach ($it in $sel) {
    $msg = Retentar-ItemFalha $it
    if ($msg -like 'OK*' -or $msg -like 'ja estava*') { Remove-EstadoItem $it }
    $LblUltima.Text = $msg
    $LblUltima.ForeColor = $(if ($msg -like 'OK*' -or $msg -like 'ja estava*') { $ColorGreen } else { $ColorRed })
  }
  if ($LstFalhas.Items.Count -gt 0) { Sync-NoviplayJson | Out-Null }
  Read-Data
  Refresh-FilmesList
  Atualiza-StatusUltima
})

$BtnCUp.Add_Click({
  $sel = @($ListC.SelectedItems)
  if ($sel.Count -eq 0) { return }
  try {
    $ts = Backup-Channels
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $done = $false
    foreach ($it in ($sel | Sort-Object { $_.Idx })) {
      $i = [int]$it.Idx
      if ($i -le 0) { continue }
      $tmp = $lines[$i - 1]; $lines[$i - 1] = $lines[$i]; $lines[$i] = $tmp
      $done = $true
    }
    if (-not $done) { return "Ja esta no topo." }
    Write-File $lines
    Read-Data; Refresh-CanaisList
    $it = $null
    foreach ($n in $sel) {
      foreach ($k in $global:Canais) { if ((Normalize-Text $k.Display) -eq (Normalize-Text $n.Display)) { $it = $k; break } }
      if ($it) { [void]$ListC.Items.Add($it) }
    }
    $LblStatusC.Text = "OK! Movido(s) p/ cima. Backup: channels.np.backup"
    $LblStatusC.ForeColor = $ColorGreen
  } catch {
    $LblStatusC.Text = 'Erro: ' + $_.Exception.Message
    $LblStatusC.ForeColor = $ColorRed
  }
})

$BtnCDown.Add_Click({
  $sel = @($ListC.SelectedItems)
  if ($sel.Count -eq 0) { return }
  try {
    $ts = Backup-Channels
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $done = $false
    foreach ($it in ($sel | Sort-Object { $_.Idx } -Descending)) {
      $i = [int]$it.Idx
      if ($i -ge $lines.Count - 1) { continue }
      $tmp = $lines[$i + 1]; $lines[$i + 1] = $lines[$i]; $lines[$i] = $tmp
      $done = $true
    }
    if (-not $done) { return "Ja esta no fim." }
    Write-File $lines
    Read-Data; Refresh-CanaisList
    $it = $null
    foreach ($n in $sel) {
      foreach ($k in $global:Canais) { if ((Normalize-Text $k.Display) -eq (Normalize-Text $n.Display)) { $it = $k; break } }
      if ($it) { [void]$ListC.Items.Add($it) }
    }
    $LblStatusC.Text = "OK! Movido(s) p/ baixo. Backup: channels.np.backup"
    $LblStatusC.ForeColor = $ColorGreen
  } catch {
    $LblStatusC.Text = 'Erro: ' + $_.Exception.Message
    $LblStatusC.ForeColor = $ColorRed
  }
})

$BtnGit.Add_Click({
  $BtnGit.Enabled = $false
  $LblStatusC.Text = 'Gerando noviplay.json e enviando ao GitHub...'
  $LblStatusC.ForeColor = $ColorDim
  $LblStatusC.Refresh()
  try {
    $LblStatusC.Text = Sync-NoviplayJson
    $LblStatusC.ForeColor = $ColorGreen
  } catch {
    $LblStatusC.Text = 'ERRO GitHub: ' + $_.Exception.Message
    $LblStatusC.ForeColor = $ColorRed
  }
  $BtnGit.Enabled = $true
})

$BtnDelete.Add_Click({
  $sel = @($ListC.SelectedItems)
  if ($sel.Count -eq 0) { return }
  $names = @($sel | ForEach-Object { $_.Nome } | Select-Object -First 5) -join ', '
  if ($sel.Count -gt 5) { $names += ', ...' }
  $conf = [System.Windows.Forms.MessageBox]::Show(
    'Excluir ' + $sel.Count + ' canal(ais) do channels.np?' + [Environment]::NewLine + [Environment]::NewLine + $names,
    'Confirmar exclusao', 'YesNo', 'Warning')
  if ($conf -ne 'Yes') { return }

  try {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -LiteralPath $ChannelsPath -Destination (Join-Path $NoviplayDir "channels.np.backup") -Force

    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $remove = @{}
    foreach ($it in $sel) { $remove[[int]$it.Idx] = $true }
    $newLines = @()
    for ($k = 0; $k -lt $lines.Count; $k++) {
      if ($remove.ContainsKey($k)) { continue }
      $newLines += $lines[$k]
    }
    Write-File $newLines

    Read-Data
    Refresh-FilmesList
    Refresh-CanaisList
    Refresh-OrdCanaisList
    $LblStatusC.Text = ("OK! {0} canal(ais) excluido(s). Backup: {1}`r`nAbrindo o painel..." -f $sel.Count, $ts)
    $LblStatusC.ForeColor = $ColorGreen
    $LblStatusC.Refresh()
    Open-Panel
  } catch {
    $LblStatusC.Text = 'Erro: ' + $_.Exception.Message
    $LblStatusC.ForeColor = $ColorRed
  }
})

function Test-MinhaTVLocked([string]$Nome) {
  if (-not $Nome -or -not (Test-Path -LiteralPath $MtvMapFile)) { return $false }
  $key = Normalize-Text $Nome
  foreach ($l in [IO.File]::ReadAllLines($MtvMapFile, [Text.Encoding]::UTF8)) {
    if ($l.Trim() -eq '') { continue }
    if ($l.Split([char]'|')[0] -eq $key) { return $true }
  }
  return $false
}

$BtnRenomear.Add_Click({
  $it = $ListC.SelectedItem
  if ($null -eq $it) { return }
  $novoNome = $TxtNomeC.Text.Trim()
  $novoLogo = $TxtLogoC.Text.Trim()
  $mudaNome = ($novoNome -ne '' -and $novoNome -ne $it.Nome)
  $mudaLogo = ($novoLogo -ne '' -and $novoLogo -ne ([string]$it.Logo))
  if (-not $mudaNome -and -not $mudaLogo) {
    $LblStatusC.Text = 'Digite um nome e/ou uma logo diferente (deixe em branco o que nao quiser mudar).'
    $LblStatusC.ForeColor = $ColorDim
    return
  }

  if ($mudaNome -and (Test-MinhaTVLocked -Name $it.Nome)) {
    $LblStatusC.Text = 'Este canal pertence ao MinhaTV; renomeie-o por la para nao quebrar o mapa.'
    $LblStatusC.ForeColor = $ColorRed
    return
  }

  $msg = "Alteracoes no canal:" + [Environment]::NewLine
  if ($mudaNome) { $msg += ('  nome:  ' + $it.Nome + '   =>   ' + $novoNome) + [Environment]::NewLine }
  if ($mudaLogo) { $msg += '  logo:  ' + (if (-not $it.Logo) { '(vazio)' } else { $it.Logo }) + '   =>   ' + $novoLogo + [Environment]::NewLine }
  $conf = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirmar alteracao', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return }

  try {
    $ts = Backup-Channels
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $idx = [int]$it.Idx
    if ($idx -lt 0 -or $idx -ge $lines.Count) { throw 'O arquivo mudou depois de abrir. Feche o programa e abra de novo.' }
    $line = $lines[$idx]
    if (-not (Test-IsCanalLine $line)) { throw 'A linha selecionada mudou no arquivo. Feche e abra de novo.' }
    $parts = $line.Split([char]'|', [System.StringSplitOptions]::None)
    if ($parts[0] -ne $it.Nome) { throw 'O canal selecionado mudou no arquivo. Feche e abra de novo.' }
    if ($mudaNome) { $parts[0] = $novoNome }
    if ($mudaLogo) {
      if ($parts.Count -lt 4) { $parts += @('') * (4 - $parts.Count) }
      $parts[3] = $novoLogo
    }
    $lines[$idx] = $parts -join '|'
    Write-File $lines

    Read-Data
    Refresh-FilmesList
    Refresh-CanaisList
    Refresh-OrdCanaisList
    $it = $null
    foreach ($k in $global:Canais) {
      if ((Normalize-Text $k.Nome) -eq (Normalize-Text $novoNome)) { $it = $k; break }
    }
    if ($it) { $ListC.SelectedItem = $it }
    $TxtNomeC.Text = $novoNome
    $TxtLogoC.Text = $novoLogo
    $LblStatusC.Text = "OK! Salvo. Backup: channels.np.backup"
    $LblStatusC.ForeColor = $ColorGreen
  } catch {
    $LblStatusC.Text = 'Erro: ' + $_.Exception.Message
    $LblStatusC.ForeColor = $ColorRed
  }
})

$TxtNomeC.Add_KeyDown({
  if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    if ($BtnRenomear.Enabled) { $BtnRenomear.PerformClick() }
    $_.SuppressKeyPress = $true
  }
})
$TxtLogoC.Add_KeyDown({
  if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    if ($BtnRenomear.Enabled) { $BtnRenomear.PerformClick() }
    $_.SuppressKeyPress = $true
  }
})

# ---------------- LOGICA ORDENAR CANAIS ----------------

function Test-IsCanalLine([string]$l) {
  if ([string]::IsNullOrWhiteSpace($l)) { return $false }
  if (Test-VodLine $l) { return $false }
  $p = $l.Split([char]'|', [System.StringSplitOptions]::None)
  return $p.Count -ge 2 -and $p[0]
}

function Move-OrdCanal([int]$targetSlot, [switch]$BySlot) {
  $it = $ListOrd.SelectedItem
  if ($null -eq $it) { return }
  try {
    $lines = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $cidx = New-Object System.Collections.Generic.List[int]
    for ($k = 0; $k -lt $lines.Count; $k++) { if (Test-IsCanalLine $lines[$k]) { $cidx.Add($k) } }
    $i = -1
    for ($k = 0; $k -lt $lines.Count; $k++) {
      if (-not (Test-IsCanalLine $lines[$k])) { continue }
      $p = $lines[$k].Split([char]'|', [System.StringSplitOptions]::None)
      if ($p[0] -eq $it.Nome -and $p[1] -eq $it.Url) { $i = $k; break }
    }
    if ($i -lt 0) { throw 'Canal nao encontrado no arquivo. Recarregue o programa.' }
    $slot = $cidx.IndexOf($i)
    if ($slot -lt 0) { throw 'Canal fora da lista de canais.' }
    $total = $cidx.Count
    if ($total -lt 1) { return }
    if ($BySlot) { $t = $targetSlot } else { $t = $slot + $targetSlot }
    $t = [Math]::Max(0, [Math]::Min($t, $total - 1))
    if ($t -eq $slot) {
      $LblOrdStatus.ForeColor = $ColorDim
      $LblOrdStatus.Text = "'$($it.Nome)' ja esta na posicao $($slot + 1)."
      return
    }
    $ts = Backup-Channels
    $new = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $lines.Count; $k++) { if ($k -ne $i) { $new.Add($lines[$k]) } }
    $line = $lines[$i]
    $ins = $new.Count
    $seen = 0
    for ($k = 0; $k -lt $new.Count; $k++) {
      if ($seen -eq $t) { $ins = $k; break }
      if (Test-IsCanalLine $new[$k]) { $seen++ }
    }
    $new.Insert($ins, $line)
    Write-File $new.ToArray()
    Read-Data
    Refresh-FilmesList
    Refresh-CanaisList
    Refresh-OrdCanaisList
    Select-OrdByName $it.Nome $it.Url
    $LblOrdStatus.ForeColor = $ColorGreen
    $LblOrdStatus.Text = "OK! '$($it.Nome)' movido para a posicao $($t + 1). Backup: channels.np.backup"
  } catch {
    $LblOrdStatus.ForeColor = $ColorRed
    $LblOrdStatus.Text = 'Erro: ' + $_.Exception.Message
  }
}

$ListOrd.Add_SelectedIndexChanged({
  $it = $ListOrd.SelectedItem
  $en = $null -ne $it
  $BtnOrdUp.Enabled = $en; $BtnOrdDown.Enabled = $en; $BtnOrdTop.Enabled = $en; $BtnOrdEnd.Enabled = $en; $BtnOrdGo.Enabled = $en
  if ($en) {
    $head = ($it.Display -split '\.')[0]
    $pos = 0
    if ([int]::TryParse($head, [ref]$pos)) { $NudOrdPos.Value = [Math]::Max(1, $pos) }
  }
})

$TxtOrdQ.Add_TextChanged({ Refresh-OrdCanaisList })
$TxtOrdQ.Add_GotFocus({
  if ($TxtOrdQ.Text -eq 'Pesquisar canal nesta lista...') {
    $TxtOrdQ.Text = ''
    $TxtOrdQ.ForeColor = $ColorFg
  }
})
$TxtOrdQ.Add_Leave({
  if ([string]::IsNullOrWhiteSpace($TxtOrdQ.Text)) {
    $TxtOrdQ.Text = 'Pesquisar canal nesta lista...'
    $TxtOrdQ.ForeColor = $ColorDim
  }
})

$BtnOrdUp.Add_Click({ Move-OrdCanal -1 })
$BtnOrdDown.Add_Click({ Move-OrdCanal 1 })
$BtnOrdTop.Add_Click({ Move-OrdCanal (-999999) })
$BtnOrdEnd.Add_Click({ Move-OrdCanal 999999 })
$BtnOrdGo.Add_Click({ Move-OrdCanal ([int]$NudOrdPos.Value - 1) -BySlot })

$BtnOrdGit.Add_Click({
  $BtnOrdGit.Enabled = $false
  $LblOrdStatus.ForeColor = $ColorDim
  $LblOrdStatus.Text = 'Gerando noviplay.json e enviando ao GitHub...'
  $LblOrdStatus.Refresh()
  try {
    $LblOrdStatus.Text = Sync-NoviplayJson -Force
    $LblOrdStatus.ForeColor = $ColorGreen
  } catch {
    $LblOrdStatus.Text = 'ERRO GitHub: ' + $_.Exception.Message
    $LblOrdStatus.ForeColor = $ColorRed
  }
  $BtnOrdGit.Enabled = $true
})

$BtnFSBuscar.Add_Click({
  $q = $TxtFS.Text.Trim()
  if (-not $q) { [System.Windows.Forms.MessageBox]::Show('Digite o nome do filme/serie.', 'Aviso', 'OK', 'Information'); return }
  $ListFS.Items.Clear()
  $LblFSStatus.ForeColor = $ColorGreen
  $LblFSStatus.Text = 'Buscando no Cinemeta/FrostStream...'
  $LblFSStatus.Refresh()
  $res = Search-FSNames $q
  if ($res.Count -eq 0) { $LblFSStatus.Text = 'Nada encontrado no Cinemeta para: ' + $q; $LblFSStatus.ForeColor = $ColorRed; return }
  $ListFS.BeginUpdate()
  foreach ($it in $res) { [void]$ListFS.Items.Add($it) }
  $ListFS.EndUpdate()
  $LblFSStatus.Text = "$($res.Count) resultado(s). Selecione um e cadastre abaixo."
  $LblFSStatus.ForeColor = $ColorGreen
})

$ListFS.Add_SelectedIndexChanged({
  $it = $ListFS.SelectedItem
  if ($null -eq $it) { return }
  $LblFSInfo.Text = "Selecionado: $($it.Name) ($($it.Year))  [ID $($it.Id)]  tipo: $($it.Type)"
  $BtnFSCadFilme.Enabled = ($it.Type -eq 'movie')
  $BtnFSCadSerie.Enabled = ($it.Type -eq 'series')
  $BtnFSFuturo.Enabled = $true
})

$BtnFSCadFilme.Add_Click({
  $it = $ListFS.SelectedItem
  if ($null -eq $it) { return }
  $BtnFSCadFilme.Enabled = $false
  $LblFSStatus.ForeColor = $ColorGreen
  $LblFSStatus.Text = 'Resolvendo stream...'
  $LblFSStatus.Refresh()
  $msg = Register-FSMovie $it
  if ($msg) { $LblFSStatus.Text = $msg }
  $BtnFSCadFilme.Enabled = $true
})

$BtnFSCadSerie.Add_Click({
  $it = $ListFS.SelectedItem
  if ($null -eq $it) { return }
  $startEp = [int]$NudEpsIni.Value
  $endEp = [int]$NudEps.Value
  if ($startEp -gt $endEp) {
    $LblFSStatus.ForeColor = $ColorRed
    $LblFSStatus.Text = "Ep. inicial ($startEp) nao pode ser maior que o ep. final ($endEp)."
    return
  }
  $BtnFSCadSerie.Enabled = $false
  $LblFSStatus.ForeColor = $ColorGreen
  $LblFSStatus.Text = 'Resolvendo episodios da serie... (pode demorar)'
  $LblFSStatus.Refresh()
  $msg = Register-FSSeries $it ([int]$NudTemp.Value) $startEp $endEp (Get-FSCatEscolhida)
  if ($msg) { $LblFSStatus.Text = $msg }
  $BtnFSCadSerie.Enabled = $true
})

$BtnFSGit.Add_Click({
  $BtnFSGit.Enabled = $false
  $LblFSStatus.ForeColor = $ColorGreen
  $LblFSStatus.Text = 'Gerando noviplay.json e enviando ao GitHub...'
  $LblFSStatus.Refresh()
  try {
    $LblFSStatus.Text = Sync-NoviplayJson
    $LblFSStatus.ForeColor = $ColorGreen
  } catch {
    $LblFSStatus.Text = 'ERRO GitHub: ' + $_.Exception.Message
    $LblFSStatus.ForeColor = $ColorRed
  }
  $BtnFSGit.Enabled = $true
})

$BtnFSAtualizar.Add_Click({
  $BtnFSAtualizar.Enabled = $false
  $LblFSStatus.ForeColor = $ColorGreen
  $LblFSStatus.Text = 'Atualizando links do FrostStream... (pode demorar)'
  $LblFSStatus.Refresh()
  $msg = Update-AllFS
  $LblFSStatus.Text = 'Atualizando links do FrostStream...'
  $LblFSStatus.Refresh()
  try {
    $LblFSStatus.Text = $msg + '  |  ' + (Sync-NoviplayJson)
  } catch {
    $LblFSStatus.Text = $msg + '  |  ERRO ao enviar GitHub: ' + $_.Exception.Message
  }
  $BtnFSAtualizar.Enabled = $true
})

# Botao FUTURO LANCAMENTOS: nao cadastra agora, so deixa o titulo na fila.
$BtnFSFuturo.Add_Click({
  $it = $ListFS.SelectedItem
  if ($null -eq $it) { return }
  $BtnFSFuturo.Enabled = $false
  $LblFSStatus.ForeColor = $ColorGreen
  $LblFSStatus.Text = 'Colocando na fila de futuros lancamentos...'
  $LblFSStatus.Refresh()
  $msg = Add-FuturoItem $it ([int]$NudTemp.Value) ([int]$NudEpsIni.Value) ([int]$NudEps.Value) (Get-FSCatEscolhida)
  $LblFSStatus.Text = $msg
  Refresh-FuturoList
  $TabCtl.SelectedTab = $TabFuturo
  $LblFuStatus.ForeColor = $ColorGreen
  $LblFuStatus.Text = $msg
  $BtnFSFuturo.Enabled = $true
})

$BtnFuAtualizar.Add_Click({
  Refresh-FuturoList
  $LblFuStatus.ForeColor = $ColorDim
  $LblFuStatus.Text = "Lista recarregada: $($LstFuturo.Items.Count) item(ns) na fila."
})

$BtnFuRemover.Add_Click({
  $it = $LstFuturo.SelectedItem
  if ($null -eq $it) { [System.Windows.Forms.MessageBox]::Show('Selecione um item da fila.', 'Aviso', 'OK', 'Information'); return }
  $conf = [System.Windows.Forms.MessageBox]::Show("Tirar da fila de futuros lancamentos:" + [Environment]::NewLine + '  ' + $it.Nome, 'Fila', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return }
  $LblFuStatus.ForeColor = $ColorGreen
  $LblFuStatus.Text = Remove-FuturoItem $it
  Refresh-FuturoList
})

$BtnFuProcessar.Add_Click({
  $fila = @(Read-FuturoQueue)
  if ($fila.Count -eq 0) {
    $LblFuStatus.ForeColor = $ColorDim
    $LblFuStatus.Text = 'A fila esta vazia. Use a aba FrostStream para colocar um filme/serie na fila.'
    return
  }
  $conf = [System.Windows.Forms.MessageBox]::Show("Processar $($fila.Count) item(ns) da fila agora?" + [Environment]::NewLine + [Environment]::NewLine + 'O que o addon ja tiver entra em canais e e enviado ao GitHub. O que ainda nao saiu continua na fila.' + $(if (Test-Path -LiteralPath $AvisoProgFile) { [Environment]::NewLine + [Environment]::NewLine + 'ATENCAO: tem aviso PROGRAMADO. Ele sai junto neste envio.' } else { '' }), 'Futuros lancamentos', 'YesNo', 'Question')
  if ($conf -ne 'Yes') { return }
  $BtnFuProcessar.Enabled = $false
  $LblFuStatus.ForeColor = $ColorGreen
  $LblFuStatus.Text = 'Procurando os titulos da fila no addon... (pode demorar)'
  $LblFuStatus.Refresh()
  try {
    $r = Process-FuturoQueue 12
    $LblFuStatus.Text = $r.Msg
    $LblFuStatus.Refresh()
    if ($r.Added -gt 0) {
      $LblFuStatus.Text = $r.Msg + '  |  Gerando noviplay.json e enviando ao GitHub...'
      $LblFuStatus.Refresh()
      # O aviso programado tambem sai junto aqui: e uma atualizacao igual as
      # outras, entao o app recebe os filmes novos e o aviso no mesmo envio.
      $extra = ''
      try { $aMsg = Aplicar-AvisoProgramado; if ($aMsg) { $extra = '  |  Aviso: ' + $aMsg } } catch { $extra = '  |  ERRO no aviso programado: ' + $_.Exception.Message }
      try { $LblFuStatus.Text = $r.Msg + $extra + '  |  ' + (Sync-NoviplayJson) }
      catch { $LblFuStatus.Text = $r.Msg + $extra + '  |  ERRO ao enviar GitHub: ' + $_.Exception.Message }
      Atualiza-AvisoProgramado
    }
    Refresh-FilmesList
    Refresh-FuturoList
  } catch {
    $LblFuStatus.ForeColor = $ColorRed
    $LblFuStatus.Text = 'ERRO: ' + $_.Exception.Message
  }
  $BtnFuProcessar.Enabled = $true
})

$BtnFxBuscar.Add_Click({
  $q = $TxtFx.Text.Trim()
  if (-not $q) { [System.Windows.Forms.MessageBox]::Show('Digite o nome do filme/serie.', 'Aviso', 'OK', 'Information'); return }
  $ListFx.Items.Clear()
  $LblFxStatus.ForeColor = $ColorGreen
  $LblFxStatus.Text = 'Buscando no Cinemeta/Fenix...'
  $LblFxStatus.Refresh()
  $res = Search-FSNames $q
  if ($res.Count -eq 0) { $LblFxStatus.Text = 'Nada encontrado no Cinemeta para: ' + $q; $LblFxStatus.ForeColor = $ColorRed; return }
  $ListFx.BeginUpdate()
  foreach ($it in $res) { [void]$ListFx.Items.Add($it) }
  $ListFx.EndUpdate()
  $LblFxStatus.Text = "$($res.Count) resultado(s). Selecione um e cadastre abaixo."
  $LblFxStatus.ForeColor = $ColorGreen
})

$ListFx.Add_SelectedIndexChanged({
  $it = $ListFx.SelectedItem
  if ($null -eq $it) { return }
  $LblFxInfo.Text = "Selecionado: $($it.Name) ($($it.Year))  [ID $($it.Id)]  tipo: $($it.Type)"
  $BtnFxCadFilme.Enabled = ($it.Type -eq 'movie')
  $BtnFxCadSerie.Enabled = ($it.Type -eq 'series')
})

$BtnFxCadFilme.Add_Click({
  $it = $ListFx.SelectedItem
  if ($null -eq $it) { return }
  $BtnFxCadFilme.Enabled = $false
  $LblFxStatus.ForeColor = $ColorGreen
  $LblFxStatus.Text = 'Resolvendo stream...'
  $LblFxStatus.Refresh()
  $msg = Register-FenixMovie $it
  if ($msg) { $LblFxStatus.Text = $msg }
  if ($msg -like 'OK!*') {
    Read-Data
    Refresh-FilmesList
    Refresh-CanaisList
  }
  $LblFxStatus.Refresh()
  $BtnFxCadFilme.Enabled = $true
})

$BtnFxCadSerie.Add_Click({
  $it = $ListFx.SelectedItem
  if ($null -eq $it) { return }
  $startEp = [int]$NudFxEpsIni.Value
  $endEp = [int]$NudFxEps.Value
  if ($startEp -gt $endEp) {
    $LblFxStatus.ForeColor = $ColorRed
    $LblFxStatus.Text = "Ep. inicial ($startEp) nao pode ser maior que o ep. final ($endEp)."
    return
  }
  $BtnFxCadSerie.Enabled = $false
  $LblFxStatus.ForeColor = $ColorGreen
  $LblFxStatus.Text = 'Resolvendo episodios da serie... (pode demorar)'
  $LblFxStatus.Refresh()
  $msg = Register-FenixSeries $it ([int]$NudFxTemp.Value) $startEp $endEp
  if ($msg) { $LblFxStatus.Text = $msg }
  if ($msg -like 'OK!*') {
    Read-Data
    Refresh-FilmesList
    Refresh-CanaisList
  }
  $LblFxStatus.Refresh()
  $BtnFxCadSerie.Enabled = $true
})

$BtnFxAtualizar.Add_Click({
  $BtnFxAtualizar.Enabled = $false
  $LblFxStatus.ForeColor = $ColorGreen
  $LblFxStatus.Text = 'Atualizando links do Fenix... (pode demorar)'
  $LblFxStatus.Refresh()
  try {
    $msg = Update-AllFenix
    $LblFxStatus.Text = $msg + '  |  ' + (Sync-NoviplayJson)
  } catch {
    $LblFxStatus.Text = 'ERRO ao atualizar Fenix: ' + $_.Exception.Message
    $LblFxStatus.ForeColor = $ColorRed
  }
  $LblFxStatus.Refresh()
  $BtnFxAtualizar.Enabled = $true
})

$BtnFxGit.Add_Click({
  $BtnFxGit.Enabled = $false
  $LblFxStatus.ForeColor = $ColorGreen
  $LblFxStatus.Text = 'Gerando noviplay.json e enviando ao GitHub...'
  $LblFxStatus.Refresh()
  try {
    $LblFxStatus.Text = Sync-NoviplayJson -Force
    $LblFxStatus.ForeColor = $ColorGreen
  } catch {
    $LblFxStatus.Text = 'ERRO GitHub: ' + $_.Exception.Message
    $LblFxStatus.ForeColor = $ColorRed
  }
  $BtnFxGit.Enabled = $true
})

$BtnMTVBuscar.Add_Click({
  $q = $TxtMTVQ.Text.Trim()
  if ($q -eq '') { $LblMTVStatus.Text = 'Digite parte do nome do canal (ex.: globo, premiere, h&h).'; return }
  $BtnMTVBuscar.Enabled = $false
  $LblMTVStatus.ForeColor = $ColorGreen
  $LblMTVStatus.Text = 'Buscando no addon MinhaTV (1a vez carrega a lista de canais)...'
  $LblMTVStatus.Refresh()
  try {
    $res = MTV-Buscar $q
    $ListMTV.Items.Clear()
    foreach ($r in $res) { [void]$ListMTV.Items.Add($r) }
    $LblMTVCount.Text = [string]$res.Count
    if ($res.Count -eq 0) { $LblMTVStatus.Text = 'Nenhum canal encontrado para "' + $q + '". Tente outro nome (sem acento, 1 palavra).' }
    else { $LblMTVStatus.Text = $res.Count.ToString() + ' canal(ais) encontrado(s). Selecione 1 e clique em Adicionar canal.' }
  } catch {
    $LblMTVStatus.Text = 'ERRO ao buscar: ' + $_.Exception.Message
  }
  $BtnMTVBuscar.Enabled = $true
})

$ListMTV.Add_SelectedIndexChanged({
  $it = $ListMTV.SelectedItem
  $BtnMTVAdd.Enabled = ($it -ne $null)
  if ($it -and $it.Grupo) {
    $global:MTVGrupoManual = $false
    if ($CmbMTVGrupo.Items -contains $it.Grupo) { $CmbMTVGrupo.SelectedItem = $it.Grupo }
    else { $CmbMTVGrupo.SelectedItem = 'Abertos e Variedades' }
  }
})

$CmbMTVGrupo.Add_SelectedIndexChanged({
  $global:MTVGrupoManual = $true
})

$TxtMTVPasteNome.Add_TextChanged({
  if ($null -eq $CmbMTVGrupo) { return }
  if (-not $global:MTVGrupoManual -and $TxtMTVPasteNome.Text.Trim() -ne '') {
    $g = MTV-GrupoDeNome $TxtMTVPasteNome.Text.Trim()
    if ($CmbMTVGrupo.Items -contains $g) { $global:MTVGrupoManual = $false; $CmbMTVGrupo.SelectedItem = $g }
  }
})

$BtnMTVAdd.Add_Click({
  $it = $ListMTV.SelectedItem
  if ($null -eq $it) { return }
  $BtnMTVAdd.Enabled = $false
  $LblMTVStatus.ForeColor = $ColorGreen
  $LblMTVStatus.Text = 'Buscando a URL do canal no addon (o servidor MinhaTV as vezes demora ~90s ou da 504)...'
  $LblMTVStatus.Refresh()
  try {
    $msg = Add-MinhaTv $it $CmbMTVGrupo.SelectedItem $TxtMTVLogo.Text.Trim() $ChkMTVRelay.Checked
    if ($msg -like 'OK!*') {
      Read-Data
      Refresh-FilmesList
      Refresh-CanaisList
      try { $msg += '  |  ' + (Sync-NoviplayJson) } catch { $msg += '  |  ERRO GitHub: ' + $_.Exception.Message }
    }
    $LblMTVStatus.Text = $msg
  } catch {
    $LblMTVStatus.Text = 'ERRO ao adicionar: ' + $_.Exception.Message
  }
  $LblMTVStatus.Refresh()
  $BtnMTVAdd.Enabled = ($ListMTV.SelectedItem -ne $null)
})

$BtnMTVPaste.Add_Click({
  $nome = $TxtMTVPasteNome.Text.Trim()
  $url = $TxtMTVPaste.Text.Trim()
  if ($url -eq '') { $LblMTVStatus.Text = 'Cole a URL do canal (copiada do Stremio/addon) antes de clicar.'; return }
  $BtnMTVPaste.Enabled = $false
  $LblMTVStatus.ForeColor = $ColorGreen
  $LblMTVStatus.Text = 'Adicionando "' + $nome + '" direto no channels.np (sem teste)...'
  $LblMTVStatus.Refresh()
  try {
    $logo = $TxtMTVLogo.Text.Trim()
    if (-not $logo) {
      if ($ChkMTVLogo.Checked) {
        $LblMTVStatus.Text += '  buscando logo no addon...'
        $LblMTVStatus.Refresh()
        $logo = MTV-LogoDoNome $nome
      }
    }
    $msg = Add-MinhaTvUrl $nome $url $CmbMTVGrupo.SelectedItem $logo $ChkMTVRelay.Checked
    Read-Data
    Refresh-FilmesList
    Refresh-CanaisList
    try { $msg += '  |  ' + (Sync-NoviplayJson) } catch { $msg += '  |  ERRO GitHub: ' + $_.Exception.Message }
    $LblMTVStatus.Text = $msg
  } catch {
    $LblMTVStatus.Text = 'ERRO ao adicionar: ' + $_.Exception.Message
  }
  $LblMTVStatus.Refresh()
  $BtnMTVPaste.Enabled = $true
})

Normalize-TvCapa
Normalize-TvGrupos
Read-Data
Refresh-FilmesList
Refresh-CanaisList
Refresh-SinopseCombo
Refresh-OrdCanaisList
Refresh-FuturoList
if ($global:Filmes.Count -eq 0 -and $global:Canais.Count -eq 0) {
  $LblInfoF.Text = 'Nada encontrado. Confira se channels.np existe em ' + $NoviplayDir
}
if ($SoCanais) {
  # Atualiza SO os canais de TV e publica. Nao toca em filme/serie: essa parte
  # (FrostStream) e' a que leva 30-45 min, porque sonda ~226 links com timeout
  # de rede. Para renovar canal, nao ha razao para pagar esse tempo.
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $script:EstadoInicio = $ts
  $logPath = Join-Path $NoviplayDir 'froststream.log'
  $travaC = $null
  $temTravaC = $false
  try {
    $travaC = New-Object System.Threading.Mutex($false, 'Global\NoviPlay_Atualizacao_Unica')
    $temTravaC = -not $travaC.WaitOne(0)
  } catch { $travaC = $null; $temTravaC = $false }
  if ($temTravaC) {
    [IO.File]::AppendAllText($logPath, "[$ts] SoCanais ignorado: ja existe uma atualizacao em andamento.`r`n")
    Write-Output 'Ja existe uma atualizacao em andamento. Tente de novo em alguns minutos.'
    return
  }
  try {
    [IO.File]::AppendAllText($logPath, "[$ts] SoCanais: Starting`r`n")
    $r1 = Update-MinhaTvUrls
    [IO.File]::AppendAllText($logPath, "[$ts] SoCanais - Canais MinhaTV: $r1`r`n")
    $r2 = Sync-NoviplayJson
    [IO.File]::AppendAllText($logPath, "[$ts] SoCanais - JSON/GitHub: $r2`r`n")
    if ($Janela) { [void][System.Windows.Forms.MessageBox]::Show("$r1`r`n`r`n$r2", 'NoviPlay - So canais') }
    else { Write-Output "CANAIS: $r1"; Write-Output "GIT: $r2" }
  } finally {
    if ($travaC) { try { $travaC.ReleaseMutex() } catch {} }
  }
  return
}
if ($SoJson) {
  # Publica SO o noviplay.json, sem refazer a busca de links. A busca completa
  # leva 30-45 min (ela sonda ~226 links com timeout de rede); so para mudar
  # uma categoria nao faz sentido esperar tudo isso: o JSON e gerado a partir do
  # channels.np, que ja esta com a mudanca gravada.
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $script:EstadoInicio = $ts
  $logPath = Join-Path $NoviplayDir 'froststream.log'
  try { Write-Log "JSON apenas: Starting" } catch {}
  $r = Sync-NoviplayJson
  try { Write-Log "JSON apenas: $r" } catch {}
  if ($Janela) { [void][System.Windows.Forms.MessageBox]::Show($r, 'NoviPlay') }
  else { Write-Output $r }
  return
}
if ($Rechecar) {
  # Zera a espera das series frias: todas voltam a ser procuradas na proxima
  # rodada. Use depois de conferir no Stremio que o titulo voltou.
  $global:SeriesFria = @{}
  $script:SoSeriesOnly = $false
    $script:SoFilmesOnly = $false
  $global:RechecarFeito = $true
  Write-SeriesFriasRelatorio
}
if ($SoTesteFrost) {
  # Teste de robustez da busca: chama o Get-FSStreams REAL do painel em varios
  # episodios e mostra quantos voltaram com link, quantos streams vieram e de
  # quais provedores. Serve para conferir se a juncao das respostas esta
  # segurando quando o add-on troca de fonte no meio da caminho.
  $alvo = @(
    'series|tt2661044:1:1','series|tt2661044:1:5','series|tt2661044:2:1','series|tt2661044:2:8',
    'series|tt1196946:1:1','series|tt1196946:1:5','series|tt1196946:2:2',
    'movie|tt32093575','movie|tt17490712','movie|tt2356777'
  )
  $global:FSCache = @{}
  $global:FSLastCall = Get-Date
  $comLink = 0; $vazio = 0
  foreach ($a in $alvo) {
    $q = $a.Split('|')
    $t0 = Get-Date
    $arr = Get-FSStreams $q[0] $q[1]
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    $n = @($arr).Count
    if ($n -gt 0) { $comLink++ } else { $vazio++ }
    $pv = @($arr | ForEach-Object { $l3 = ([string]$_.title) -split "`r?`n"; (Get-StreamProvedor $_) + ' ' + $l3[3] }) -join ' ; '
    Write-Output ("  {0,-22} {1,2} stream(s)  {2,5} ms  [{3}]" -f $q[1], $n, $ms, $pv)
  }
  Write-Output ''
  Write-Output "com link: $comLink / $($alvo.Count)   |   sem nada: $vazio"
  return
}
if ($SoCong) {
  # -SoCong                        : so mostra as listas congeladas
  # -SoCong -CongItem "The 100 T1" -CongProv Nova
  #                                 : roda a MESMA atualizacao dirigida do botao
  #                                   da aba, sem abrir a janela (teste)
  if ($CongItem) {
    $provT = if ($CongProv) { [string]$CongProv } else { 'Todos' }
    Write-Output "Atualizacao dirigida: $CongItem  |  provedor: $provT"
    try {
      Write-Output ''
      Write-Output ([string](Find-TituloNosProvedores @($CongItem) -soVerbose))
      Write-Output ''
      Write-Output ([string](Update-FriosEscolhidos @($CongItem) $provT))
    } catch {
      Write-Output "ERRO: $($_.Exception.Message)  [linha $($_.InvocationInfo.ScriptLineNumber)]"
    }
    return
  }
  # Modo de conferencia: mostra no console o que a aba de Congelamento esta
  # exibindo, sem abrir a janela. Serve para conferir se a lista carregou e,
  # se nao carregou, ver o erro exato.
  try {
    Normalize-SeriesFrias
    $d = Get-FriasParaAba
    Write-Output "SERIES CONGELADAS ($($d.Series.Count)):"
    foreach ($x in $d.Series) { Write-Output "  $x" }
    Write-Output ""
    Write-Output "FILMES CONGELADOS ($($d.Filmes.Count)):"
    foreach ($x in $d.Filmes) { Write-Output "  $x" }
    Write-Output ""
    Write-Output "EPISODIOS AVULSOS CONGELADOS ($($d.Episodios.Count)):"
    foreach ($x in $d.Episodios) { Write-Output "  $x" }
    $c = Get-SeriesFria
    Write-Output ""

    Write-Output "No arquivo: $($c.Count) registro(s). Agora: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
    Write-Output "Detalhe de cada registro:"
    foreach ($kv in $c.GetEnumerator()) {
      $faltam = if ($kv.Value.Prox) { [math]::Round(($kv.Value.Prox - (Get-Date)).TotalHours, 2) } else { 'sem data' }
      Write-Output ("  chave='{0}'  nome='{1}'  volta em {2} h  (na lista: {3})" -f $kv.Key, $kv.Value.Nome, $faltam, (($kv.Value.Prox -gt (Get-Date)) -and $kv.Value.Nome))
    }
  } catch {
    Write-Output "ERRO ao montar a lista: $($_.Exception.Message)"
    Write-Output "  linha $($_.InvocationInfo.ScriptLineNumber)"
  }
  return
}
if ($Autoupdate -or $SoSeries) {
  $logPath = Join-Path $NoviplayDir 'froststream.log'
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $script:EstadoInicio = $ts
  # Trava de instancia unica: se voce clica em Atualizar na hora em que a
  # tarefa horaria dispara, as duas rodavam juntas e uma perdia o
  # channels.np.backup ("o arquivo esta sendo usado por outro processo").
  $global:SoSeriesOnly = $SoSeries
  $global:SoFilmesOnly = ($SomenteFilmes -and -not $SoSeries)
  $trava = $null
  $temTrava = $false
  try {
    $trava = New-Object System.Threading.Mutex($false, 'Global\NoviPlay_Atualizacao_Unica')
    $temTrava = -not $trava.WaitOne(0)
  } catch { $trava = $null; $temTrava = $false }
  if ($temTrava) {
    [IO.File]::AppendAllText($logPath, "[$ts] Atualizacao ignorada: ja existe uma atualizacao em andamento.`r`n")
    return
  }
  $watchdog = $null
  # ===========================================================================
# RENOVACAO EM MASSA DE TOKEN (01/10/2026 - pedido do usuario)
# ===========================================================================
# POR QUE EXISTE
# Os links do Nova sao /vauth/ID.mp4?token=TOKEN. O TOKEN tem prazo curto: o
# app recebe um token NOVO a cada vez que o jogador pede, mas o painel grava o
# token no arquivo. Passado o prazo, o servidor responde 200 no HEAD (por isso
# os testes antigos davam "tudo bom") mas derruba a conexao quando o player
# baixa os bytes - que e' exatamente o sintoma de "no Stremio abre, no painel
# falha ao carregar".
#
# CONFIRMADO: depois desta renovacao manual (32 filmes + 120 episodios de serie),
# o usuario testou e TODOS os filmes e TODAS as series abriram.
#
# POR QUE RENOVA TUDO, SEM TESTAR ANTES
# O pedido e' explicito: renovar TODO item a cada atualizacao, mesmo o que ainda
# esta funcionando. Se so renovasse o que falhou, (a) exigiria baixar o video
# inteiro para provar que esta morto - caro e lento, e (b) um token que vence
# as 03:05 voltaria a quebrar as 04:05 se nao fosse pego na rodada anterior.
# Renovar por prevencao e' mais barato que descobrir a queda depois.
#
# O QUE NAO E' TOCADO
# - The 100 (SeriesProtegidas): o usuario esta assistindo, nao renova.
# - Titulo sem ID no registro do add-on (ex.: Pursuit of Jade): fica como esta.
# - O que o add-on nao devolve stream: fica como esta, nao apaga nada.
function Renewar-TokenEmMassa([switch]$SoFilmes) {
  $arq = $ChannelsPath
  $reg = Read-FrostReg
  $regMap = @{}
  foreach ($r in $reg) {
    if ($r.Type -ne 'series' -and $r.Type -ne 'movie') { continue }
    $k = Normalize-Text $r.Nome
    if ($k -and -not $regMap.ContainsKey($k)) { $regMap[$k] = $r.Id }
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  [IO.File]::ReadAllLines($arq, [Text.Encoding]::UTF8) | ForEach-Object { $lines.Add($_) }

  $nUpd = 0; $nIgual = 0; $nSem = 0; $nProt = 0; $nSemId = 0; $nMant = 0; $nNaoTest = 0; $nFenix = 0
  $semLink = New-Object System.Collections.Generic.List[string]

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -notmatch '\|\|\|filme\||\|\|\|serie\|') { continue }
    $p = $l.Split([char]'|', [StringSplitOptions]::None)
    $isSerie = ($l -match '\|\|\|serie\|')
    if ($SoFilmes -and $isSerie) { continue }
    $serieNm = if ($isSerie -and $p.Count -ge 6) { [string]$p[5] } else { '' }

    # The 100 e as demais protegidas: nao renova.
    if ($serieNm -and (Test-SerieProtegida $serieNm)) { $nProt++; continue }

    $chaveTit = if ($isSerie) { $serieNm } else { [string]$p[0] }
    $k = Normalize-Text $chaveTit
    if (-not $k -or -not $regMap.ContainsKey($k)) { $nSemId++; continue }
    $rid = $regMap[$k]

    $tipo = 'movie'; $t = 0; $e = 0
    if ($isSerie) {
      $tipo = 'series'
      if ($p.Count -lt 7) { $nSemId++; continue }
      $ep = [string]$p[6]
      if ($ep -match '^T(\d+)E(\d+)$') { $t = [int]$Matches[1]; $e = [int]$Matches[2] }
      elseif ($ep -match '^S(\d+)E(\d+)$') { $t = [int]$Matches[1]; $e = [int]$Matches[2] }
      elseif ($ep -match '^T(\d+)$') { $t = [int]$Matches[1]; $e = 1 }
      else { $nSemId++; continue }
    }

    $chaveAddon = if ($tipo -eq 'series') { "${rid}:${t}:${e}" } else { $rid }
    $arr = @(Get-FSStreams $tipo $chaveAddon)
    if ($arr.Count -eq 0) { $nSem++; if ($semLink.Count -lt 12) { $semLink.Add($p[0]) }; continue }

    # ESCOLHA TESTADA (01/10/2026). Antes pegava $rank[0].url sem testar NADA: o
    # Nova devolve 3 a 4 links por titulo e o primeiro da fila nem sempre entrega
    # video. Em 01/10 o Nova passou a servir o host morto 84.17.40.2, a renovacao
    # copiou esse host para 37 itens de uma vez (Kingsman, Minions 2, Werewolves,
    # Materialists...) e o resultado foi o oposto do que ela promete: '152
    # renovados' com os filmes quebrados. A ordem agora:
    #   1) link do Nova que ENTREGA VIDEO -> usa. E' o duravel (mp4 do proprio
    #      provedor, token que o Nova continua renovando).
    #   2) nenhum do Nova entrega video, mas o link ATUAL entrega -> mantem o
    #      atual. Nunca trocar link que funciona por link nao testado.
    #   3) nem o atual entrega -> resgate no Fenix. E' CURATIVO: o link do
    #      Fenix expira em poucas horas e vem em .m3u8, serve para o titulo
    #      voltar a abrir hoje, nao e' solucao definitiva.
    $rank = @(Get-FSRankedStreams $arr "$chaveTit $ep")
    $escolhido = $null
    foreach($c in $rank){
      if(Test-LinkEntregaVideo ([string]$c.url) (Get-StreamProbeHeaders $c) 8) { $escolhido = $c; break }
    }
    if(-not $escolhido){
      # o link que ja esta no catalogo ainda entrega video? entao fica.
      if((Test-LinkEntregaVideo ([string]$p[1]) $null 8)) { $nMant++; continue }
      # nem o atual serve: so ai busca o resgate. Tenta as DUAS funcoes de
      # Fenix que existem no script: Get-FenixStreams (1 chamada) e
      # Get-FenixRescue (ate 3 tentativas com espera). So com a segunda o
      # Dragão Ball Super: Broly voltou, porque a primeira devolve vazio
      # pra ele - o addon as vezes responde vazio na primeira e preenche na
      # segunda, e antes dessa parte o resgate era a UNICA coisa separando
      # o titulo de ficar sem link.
      try {
        foreach($c in @(Get-FenixStreams $tipo $chaveAddon)){
          if(Test-LinkEntregaVideo ([string]$c.url) (Get-StreamProbeHeaders $c) 8) { $escolhido = $c; break }
        }
        if(-not $escolhido){
          foreach($c in @(Get-FenixRescue $tipo $chaveAddon)){
            if(Test-LinkEntregaVideo ([string]$c.url) (Get-StreamProbeHeaders $c) 8) { $escolhido = $c; break }
          }
        }
      } catch { }
      if(-not $escolhido) { $nNaoTest++; continue }
      $nFenix++
    }

    $novo = [string]$escolhido.url
    if ([string]$p[1] -eq $novo) { $nIgual++; continue }
    $p[1] = $novo
    $lines[$i] = ($p -join '|')
    $nUpd++
  }

  if ($nUpd -gt 0) {
    Backup-Channels | Out-Null
    [IO.File]::WriteAllText($arq, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-MergeDisco $lines.ToArray()
  }

  # Estatisticas separadas para o painel. So $NaoTest interessa para o usuario:
  # e' o numero de titulos que terminaram a rodada SEM nenhum link que abra.
  # O resto ($nSem/$nProt/$nSemId) e' normal e nao quebra nada.
  $global:LastRenStats = @{ Upd=$nUpd; Igual=$nIgual; Mant=$nMant; SemLink=$nSem; Prot=$nProt; SemId=$nSemId; Fenix=$nFenix; NaoTest=$nNaoTest }
  $msg = "Renovacao de token: $nUpd renovad(s), $nIgual sem mudanca, $nMant mantido(s) (o atual ainda entrega video), $nSem sem link do add-on, $nProt protegido(s), $nSemId sem ID, $nFenix resgatado(s) no Fenix, $nNaoTest sem nenhum link que entregue video."
  if ($semLink.Count -gt 0) { $msg += " Sem link: " + ($semLink -join ', ') }
  return $msg
}

  try {
    # 150 minutos: sondagem real de cada filme (+ cache desligado agora) leva
    # ~60-90 min por ciclo; o limite de 1h matava a rodada no meio.
    #
    # CORRECAO DE 30/09/2026: o watchdog matava so o PID do pai. O script
    # abre processos PowerShell filhos (ex.: 10264) que ficam vivos e
    # seguram o mutex 'Global\NoviPlay_Atualizacao_Unica'. Resultado no log:
    # "Atualizacao ignorada: ja existe uma atualizacao em andamento" as 15:05,
    # 16:05 e 17:05 - 3 horas de fila travada. Agora mata a ARVORE INTEIRA,
    # do mais novo para o mais antigo, e so depois o proprio pai.
    $watchdog = Start-Job -ScriptBlock {
      param($pidAlvo)
      Start-Sleep -Seconds 9000
      $alvo = Get-Process -Id $pidAlvo -ErrorAction SilentlyContinue
      if ($alvo) {
        # Filhos primeiro (o mais novo antes do mais velho), e so entao o pai:
        # o filho e' quem segura o mutex da proxima rodada.
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$pidAlvo" -ErrorAction SilentlyContinue |
          Sort-Object CreationDate -Descending |
          ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $pidAlvo -Force -ErrorAction SilentlyContinue
      }
    } -ArgumentList $PID
  } catch { $watchdog = $null }

  Write-Estado 'rodando' 'iniciando atualizacao automatica' 0 0 0 @() 'frost'
  $itensTodas = @()
  $updTotal = 0; $encTotal = 0; $falTotal = 0
  # Batimento: avisa o painel Android que o PC esta ligado e assumiu esta
  # rodada. Enquanto o PC bater, o Android sabe que NAO deve tocar em nada.
  try { $null = Add-Pulso -Quem 'PC' } catch { }

  # ---------------- TRAVA E REGRA PC x NUVEM ----------------
  # Este mesmo script roda no PC e na nuvem (GitHub Actions), entao os dois
  # entram por aqui. Aqui decidimos QUEM deve atualizar agora, sem os dois
  # brigarem pelo mesmo catalogo.
  #   - Nuvem: so atualiza se o PC estiver DESLIGADO (se o PC bateu no
  #     quadro nas ultimas ~2h, o PC esta bem e a nuvem sai fora).
  #   - Trava: os dois nunca trabalham ao mesmo tempo. Quem chega primeiro
  #     segura a trava; o outro ve e sai sem mexer. A trava expira sozinha
  #     se o dono morrer, para nao travar o sistema para sempre.
  $script:EuSou = 'PC'
  if ($env:NOVIPLAY_RODANDO_NA_NUVEM -eq '1') { $script:EuSou = 'Nuvem' }
  $tenhoTrava = $true
  try {
    . (Join-Path $NoviplayDir 'Trava.ps1')
    $t = Set-TravaAtiva $script:EuSou
    if (-not $t.Pegou) {
      $tenhoTrava = $false
      $motivoSaida = "outro lado esta atualizando ($($t.Motivo)). Esta rodada foi cancelada para nao brigar pelo catalogo."
      [IO.File]::AppendAllText($logPath, "[$ts] TRAVA: $motivoSaida`r`n")
      Write-Estado 'parcial' "Rodada cancelada: $($t.Motivo)" 0 0 0 @() ''
      if ($script:EuSou -eq 'Nuvem') {
        Write-Host "Nuvem: nao atualizou porque $($t.Motivo)."
      }
      if ($watchdog) { try { Stop-Job $watchdog -ErrorAction SilentlyContinue; Remove-Job $watchdog -Force -ErrorAction SilentlyContinue } catch { } }
      [Environment]::Exit(0)
    } else {
      [IO.File]::AppendAllText($logPath, "[$ts] TRAVA: esta lado pegou a trava.`r`n")
    }
  } catch {
    # Se der erro ao tentar travar, NAO bloqueia a atualizacao do PC
    # (historico: o painel nao pode parar de funcionar por causa disso).
    [IO.File]::AppendAllText($logPath, "[$ts] TRAVA: nao deu para usar a trava: $($_.Exception.Message) - seguindo assim mesmo.`r`n")
  }

  # REGRA DA NUVEM: se o PC esta ligado e respondendo, a nuvem nao mexe.
  if ($script:EuSou -eq 'Nuvem') {
    try {
      if (Test-PcLigado) {
        $motivo = "o PC esta ligado (respondeu no quadro). A nuvem nao precisa atualizar agora."
        [IO.File]::AppendAllText($logPath, "[$ts] REGRA: $motivo`r`n")
        Write-Host "Nuvem: pulando - $motivo"
        Write-Estado 'parcial' "Nuvem pulou: $motivo" 0 0 0 @() ''
        try { Remove-Trava } catch { }
        if ($watchdog) { try { Stop-Job $watchdog -ErrorAction SilentlyContinue; Remove-Job $watchdog -Force -ErrorAction SilentlyContinue } catch { } }
        [Environment]::Exit(0)
      } else {
        Write-Host "Nuvem: PC desligado - a nuvem assume a atualizacao."
        [IO.File]::AppendAllText($logPath, "[$ts] REGRA: PC desligado, a nuvem assume.`r`n")
      }
    } catch {
      [IO.File]::AppendAllText($logPath, "[$ts] REGRA: nao deu para checar o PC: $($_.Exception.Message) - a nuvem assume.`r`n")
    }
  }

  # RENOVACAO DE LINK (01/10/2026). ENTRA PRIMEIRO, antes da busca de catalogo.
  # Antes rodava depois do Frost/Fenix/MinhaTV, e a busca de catalogo leva quase
  # uma hora: se ela travasse (aconteceu as 19:05, 55 min e contando), a
  # renovacao nunca chegava a rodar e os filmes ficavam quebrados a noite toda.
  # Sendo a PRIMEIRA etapa, o catalogo ja entra no GitHub com os links conferidos
  # ainda no comeco da rodada; se a busca demorar ou falhar depois, os filmes ja
  # estao bons. Este e o unico ponto da rodada que decide o que ABRE no app.
  try {
    Write-Estado 'rodando' 'conferindo e consertando os links de filmes e series' 0 0 0 @() 'renov'
    $renMsg = Renewar-TokenEmMassa
    [IO.File]::AppendAllText($logPath, "[$ts] $renMsg`r`n")
    $rs = $global:LastRenStats
    if ($rs) { Write-Estado 'rodando' $renMsg 0 0 0 @() 'frost' }
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO Renovacao de token: $($_.Exception.Message)  [linha $($_.InvocationInfo.ScriptLineNumber)]`r`n")
    Write-Estado 'erro' "ERRO na renovacao de link: $($_.Exception.Message)" 0 0 0 @() 'renov'
  }
  # BUSCA DE CATALOGO: AGORA SO 1X POR DIA (01/10/2026).
  # Ela levava ~38 min e rodava de hora em hora. Medindo o que ela realmente
  # faz, NAO existe nenhuma parte do sistema que 'ache episodio novo sozinho':
  # episodio novo entra so quando o usuario adiciona pelo painel ou quando o
  # titulo sai da fila de futuros lancamentos. O que sobrava dela era (a)
  # consertar link - que a renovacao acima ja faz, com teste e resgate, e (b)
  # Repair-MissingVods, que restaura linha de VOD perdida do backup.
  # Entao: Repair-MissingVods (barato) continua SEMPRE, e a varredura completa
  # Update-AllFS/Update-AllFenix roda 1x por dia, na primeira rodada do dia.
  # O que ANTES era Justificado aqui - "descobrir episodio novo" - foi removido:
  # essa funcao nao existe no codigo.
  try {
    $regHoje = Read-FrostReg
    $linesHoje = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
    $repHoje = Repair-MissingVods $linesHoje $regHoje
    if ($repHoje.Added -gt 0) {
      [IO.File]::WriteAllLines($ChannelsPath, $repHoje.Lines, (New-Object System.Text.UTF8Encoding($false)))
      Backup-Channels | Out-Null
      [IO.File]::AppendAllText($logPath, "[$ts] VOD recuperado do backup: $($repHoje.Added) linha(s)`r`n")
    }
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO ao recuperar VOD do backup: $($_.Exception.Message)`r`n")
  }
  # ENVIO PRO GIST AQUI, E NAO SO NO FIM DA RODADA (01/10/2026).
  # Ate aqui a rodada era: confere links -> busca de catalogo (38 min) -> ...
  # -> manda pro Gist. Ou seja, os links consertados ficavam só no disco até o
  # fim: se a busca travasse ou o processo fosse morto (aconteceu às 19:05, com
  # 55 min rodando), o catalogo ficava bom aqui e a TV continuava vendo o link
  # velho - era esse o furo que fazia a atualizacao "terminar bem" e ainda assim
  # o filme ficar quebrado na tela.
  # Mandando aqui, o app recebe os links conferidos em ~15 min e nenhuma etapa
  # posterior consegue segurar esse resultado. O envio do fim da rodada continua
  # existindo, para levar junto o que a busca de catalogo achar depois.
  try {
    Write-Estado 'rodando' 'enviando os links conferidos para o servidor' 0 0 0 @() 'json'
    $earlyMsg = Sync-NoviplayJson
    [IO.File]::AppendAllText($logPath, "[$ts] ENVIO ANTECIPADO (links conferidos): $earlyMsg`r`n")
    Write-Estado 'rodando' "links conferidos ja enviados para o servidor" 0 0 0 @() 'frost'
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO no envio antecipado: $($_.Exception.Message)`r`n")
  }
  $querCompleta = [bool]$BuscaCompleta
  if (-not $querCompleta) {
    $ultima = [datetime]::MinValue
    if (Test-Path -LiteralPath $FullSearchFile) {
      $try = $false
      try { $ultima = [datetime]::Parse((Get-Content -LiteralPath $FullSearchFile -Raw).Trim()); $try = $true } catch { $try = $false }
      if (-not $try) { $ultima = [datetime]::MinValue }
    }
    if (((Get-Date) - $ultima).TotalDays -ge 1) { $querCompleta = $true }
  }
  if ($querCompleta) {
    try {
      $msg = Update-AllFS
      [IO.File]::AppendAllText($logPath, "[$ts] $msg`r`n")
      $stF = $global:LastFSStats
      if ($stF) { $updTotal += [int]$stF.Updated; $encTotal += [int]$stF.Found; $falTotal += [int]$stF.Fails }
      $itensTodas = @($global:LastFailList)
      Write-Estado 'rodando' $msg $updTotal $encTotal $falTotal $itensTodas 'fenix'
    } catch {
      # Inclui a linha do script no log: sem isso, um erro de nome de variavel
      # aparece so como "O termo 'x' nao e reconhecido", sem dizer ONDE.
      $errMsg = "ERRO Frost: $($_.Exception.Message)  [linha $($_.InvocationInfo.ScriptLineNumber)]"
      [IO.File]::AppendAllText($logPath, "[$ts] $errMsg`r`n")
      Write-Estado 'erro' $errMsg 0 0 0 $itensTodas 'fenix'
    }
  } else {
    [IO.File]::AppendAllText($logPath, "[$ts] Busca de catalogo completa pulada (ja rodou hoje).`r`n")
  }
  if ($querCompleta) {
    try {
      $fenixMsg = Update-AllFenix
      [IO.File]::AppendAllText($FenixLog, "[$ts] Fenix: $fenixMsg`r`n")
      $stX = $global:LastFenixStats
      if ($stX) { $updTotal += [int]$stX.Updated; $encTotal += [int]$stX.Found; $falTotal += [int]$stX.Fails }
      $itensTodas = @($itensTodas) + @($global:LastFenixFailList)
      Write-Estado 'rodando' $fenixMsg $updTotal $encTotal $falTotal $itensTodas 'mtv'
    } catch {
      $errMsg = "ERRO Fenix: $($_.Exception.Message)"
      [IO.File]::AppendAllText($FenixLog, "[$ts] $errMsg`r`n")
      Write-Estado 'erro' $errMsg $updTotal $encTotal $falTotal $itensTodas 'mtv'
    }
    # so grava a data DEPOIS que as duas varreduras terminaram sem quebrar
    [IO.File]::WriteAllText($FullSearchFile, (Get-Date).ToString('o'))
  }
  try {
    # A fila de FUTURO LANCAMENTOS entra aqui, depois do Frost/Fenix e antes
    # do GitHub: o que o addon ja tiver vai para o channels.np e sai no
    # noviplay.json desta mesma atualizacao. O que ainda nao saiu continua
    # na fila para a proxima atualizacao.
    Write-Estado 'rodando' 'processando a fila de futuros lancamentos' $updTotal $encTotal $falTotal $itensTodas 'futuro'
    $fuRes = Process-FuturoQueue 12
    [IO.File]::AppendAllText($logPath, "[$ts] $($fuRes.Msg)`r`n")
    Write-Estado 'rodando' $fuRes.Msg $updTotal $encTotal $falTotal $itensTodas 'mtv'
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO Futuros lancamentos: $($_.Exception.Message)`r`n")
  }
  try {
    $mtvMsg = Update-MinhaTvUrls
    [IO.File]::AppendAllText($logPath, "[$ts] Canais MinhaTV: $mtvMsg`r`n")
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO Canais MinhaTV: $($_.Exception.Message)`r`n")
  }
  # AVISO PROGRAMADO: aplicado aqui, logo antes do envio, para o aviso e os
  # filmes/series novos chegarem juntos no mesmo noviplay.json.
  try {
    $avisoMsg = Aplicar-AvisoProgramado
    if ($avisoMsg) { [IO.File]::AppendAllText($logPath, "[$ts] Aviso: $avisoMsg`r`n") }
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO Aviso programado: $($_.Exception.Message)`r`n")
  }
  try {
    $jsonMsg = Sync-NoviplayJson
    [IO.File]::AppendAllText($logPath, "[$ts] JSON/GitHub: $jsonMsg`r`n")
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] ERRO JSON/GitHub: $($_.Exception.Message)`r`n")
  }
  # RODAPE: o que decide se o app abre e' a renovacao de link, nao a busca de
  # catalogo. Antes o rodape usava $falTotal (titulos que a busca NAO achou link
  # NOVO para) e escrevia "concluida com 99 falha(s)" em laranja - o usuario
  # lia como "a atualizacao inteira falhou", sendo que os links estavam bons.
  # Agora: o numero grande e' o de titulos que sobraram sem link que abra; a
  # busca de catalogo entra so como informacao, entre parenteses.
  $rs = $global:LastRenStats
  $semAbrir = 0
  $parteLink = ''
  if ($rs) {
    $semAbrir = [int]$rs.NaoTest
    $parteLink = "$([int]$rs.Upd) link(s) conferido(s) e trocado(s), $([int]$rs.Mant) mantido(s) por ainda abrirem, $([int]$rs.Fenix) resgatado(s) no Fenix"
  }
  $parteCatalogo = "$updTotal link(s) novo(s) no catalogo, $falTotal titulo(s) sem link novo"
  # Fecha a rodada uma unica vez: o mesmo status/texto vai para o arquivo
  # local (painel do PC) e para o Gist (painel do Android). Assim os dois
  # lados mostram exatamente a mesma coisa.
  $stFinal = 'sucesso'
  $msgFinal = "todos os links conferidos e Delivery OK - $parteLink; $parteCatalogo"
  if ($semAbrir -gt 0) {
    $stFinal = 'parcial'
    $msgFinal = "$semAbrir filme(s)/serie(s) acabaram a rodada sem nenhum link que abra ($parteLink; $parteCatalogo)"
  }
  Write-Estado $stFinal $msgFinal $updTotal $encTotal $falTotal $itensTodas ''
  # Registro no quadro compartilhado: "a ultima atualizacao foi no PC".
  try { $null = Set-Atualizacao -Quem 'PC' -Status $stFinal -Msg $msgFinal } catch { }
  # Alerta no celular: avisa que a rodada acabou, quantos links foram
  # trocados e se o NoviPlay esta firme. Se o alerta falhar, a rodada
  # NAO e interrompida - e so uma notificacao.
  try {
    . (Join-Path $NoviplayDir 'Alerta_Celular.ps1')
    $null = Send-AlertaCelular
  } catch {
    [IO.File]::AppendAllText($logPath, "[$ts] Alerta no celular falhou: $($_.Exception.Message)`r`n")
  }
  # Solta a trava: a rodada acabou, o outro lado pode rodar a dele.
  try { Remove-Trava } catch { }
  if ($watchdog) { try { Stop-Job $watchdog -ErrorAction SilentlyContinue; Remove-Job $watchdog -Force -ErrorAction SilentlyContinue } catch { } }
  [Environment]::Exit(0)
}

if ($TestMTV) {
  $flat = MTV-FlatCatalogo
  "Canais no catalogo plano: $($flat.Count)"
  foreach ($q in @('h&h','home','cartoon','nickelodeon','premiere','globo','band')) {
    $res = MTV-Buscar $q
    "  busca '$q': $($res.Count) -> " + (($res | Select-Object -First 3 | ForEach-Object { $_.Name + ' [' + $_.Grupo + ']' }) -join ' | ')
  }
  $u = 'http://nille121.com:80/live/11510295/p883A3269U/244074.m3u8'
  "Test-StreamUrl URL conhecida: " + (Test-StreamUrl $u)
  "Test-StreamUrl URL quebrada: " + (Test-StreamUrl 'http://127.0.0.1:9/x.m3u8')
  [Environment]::Exit(0)
}

if ($TestFenixRepair) {
  # stub do addon: so o id 'tt_tem_stream' devolve streams
  $global:FenixCache = @{}
  function Get-FenixStreams([string]$type, [string]$rid) {
    if ($rid -eq 'tt_tem_stream') {
      return @(
        [PSCustomObject]@{ name = '720p'; title = 'Legendado PT-BR'; url = 'https://exemplo/leg.m3u8' },
        [PSCustomObject]@{ name = '1080p'; title = 'Dublado PT-BR'; url = 'https://exemplo/dub.m3u8' }
      )
    }
    return @()
  }
  function Find-VodLineInBackups([string]$tipo, [string]$nome) {
    if ($tipo -eq 'filme') { return $null }
    return @()
  }

  $linhas = @(
    'Frost Filme A|https://ex/frost-a|FROST||filme|||',
    'Frost Serie B|https://ex/frost-b|FROST||serie|Frost Serie B|S01E01|',
    'Fenix Filme C (Dublado PT-BR)|https://ex/fenix-c-antigo|FENIX||filme|||'
  )
  $reg = @(
    [PSCustomObject]@{ Nome = 'Fenix Filme C (Dublado PT-BR)'; Type = 'movie'; Id = 'tt_ja_existe'; Season = '' },
    [PSCustomObject]@{ Nome = 'Fenix Filme D'; Type = 'movie'; Id = 'tt_tem_stream'; Season = '' },
    [PSCustomObject]@{ Nome = 'Fenix Filme E'; Type = 'movie'; Id = 'tt_sem_stream'; Season = '' },
    [PSCustomObject]@{ Nome = 'Fenix Serie F'; Type = 'series'; Id = 'tt_serie_f'; Season = '1' }
  )

  "--- 1a passagem ---"
  $r1 = Repair-MissingFenix $linhas $reg
  "  adicionadas: $($r1.Added)   (esperado 1)"
  "  pendentes:   $($r1.Pending -join ', ')"
  "  total de linhas: $($linhas.Count) -> $($r1.Lines.Count)"
  foreach ($l in $r1.Lines) { if ($l -like '*FENIX*') { "    $l" } }

  "--- 2a passagem (idempotencia: nao pode duplicar) ---"
  $r2 = Repair-MissingFenix $r1.Lines $reg
  "  adicionadas: $($r2.Added)   (esperado 0)"
  "  total de linhas: $($r1.Lines.Count) -> $($r2.Lines.Count)"

  "--- checagens ---"
  $c = @($r1.Lines | Where-Object { $_ -like '*FENIX*' })
  "  linhas FENIX depois: $($c.Count)   (esperado 2)"
  $dbl = @($r1.Lines | Where-Object { $_ -like '*Fenix Filme D*' })
  "  Fenix Filme D aparece $($dbl.Count)x   (esperado 1x)"
  if ($r1.Added -eq 1 -and $r2.Added -eq 0 -and $dbl.Count -eq 1) { "  RESULTADO: OK" } else { "  RESULTADO: FALHOU" }
  [Environment]::Exit(0)
}

if ($TestPickStream) {
  function ST([string]$nome, [string]$prov, [string]$aud, [int]$pos) {
    return [PSCustomObject]@{
      name = $nome
      title = "x`n$prov`n$aud"
      url = "https://x/$pos"
      headers = $null
      _pos = $pos
    }
  }
  function Chk([string]$titulo, $arr, [string]$esperado) {
    $b = Pick-FSStream $arr
    if ($null -eq $b) {
      if ($esperado -eq 'SEM LINK (Space desligado)') { "  OK   $titulo -> sem link (provedor desligado)" }
      else { "  FALHOU $titulo -> o seletor nao achou NENHUM link utilizavel (esperava '$esperado')" }
      return
    }
    $ls = ([string]$b.title) -split "`r?`n"
    $resp = "$($ls[1].Trim()) $($ls[2].Trim()) [$($b.name)]"
    if ($resp -eq $esperado) { "  OK   $titulo -> $resp" } else { "  FALHOU $titulo -> pegou '$resp', esperava '$esperado'" }
  }

  '--- ordem de preferencia (regra do usuario) ---'
  '--- ATUALIZADO 10/10/2026: ordem AZURE -> NOVA (Space desligado) ---'

  Chk '720p dublado vence 4K, seja no Azure ou no Nova' @(
    ST 'FrostStream 4K' 'Nova' 'Dublado' 0
    ST 'FrostStream 1080p' 'Azure' 'Dublado' 1
    ST 'FrostStream 720p' 'Azure' 'Dublado' 2
  ) 'Azure Dublado [FrostStream 720p]'

  Chk 'Azure 720 dublado vence Azure 1080 dublado' @(
    ST 'FrostStream 1080p' 'Azure' 'Dublado' 0
    ST 'FrostStream 720p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 720p]'

  Chk 'Azure 720 dublado vence Azure 720 legendado' @(
    ST 'FrostStream 720p' 'Azure' 'Legendado' 0
    ST 'FrostStream 720p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 720p]'

  Chk 'AZURE 720 ANTES do NOVA 720 (o Azure passou para a frente)' @(
    ST 'FrostStream 720p' 'Nova' 'Dublado' 0
    ST 'FrostStream 720p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 720p]'

  Chk 'AZURE 1080 ANTES do NOVA 720' @(
    ST 'FrostStream 720p' 'Nova' 'Dublado' 0
    ST 'FrostStream 1080p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 1080p]'

  Chk 'AZURE 720 ANTES do NOVA 1080' @(
    ST 'FrostStream 1080p' 'Nova' 'Dublado' 0
    ST 'FrostStream 720p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 720p]'

  Chk 'DUBLADO sempre ganha de LEGENDADO (Azure 720 Dub > Nova 1080 Leg)' @(
    ST 'FrostStream 1080p' 'Nova' 'Legendado' 0
    ST 'FrostStream 720p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 720p]'

  Chk 'AZURE 4K dublado ANTES do NOVA 4K dublado' @(
    ST 'FrostStream 4K' 'Nova' 'Dublado' 0
    ST 'FrostStream 4K' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 4K]'

  Chk 'SPACE DESLIGADO: fica sem link em vez de gravar link ruim' @(
    ST 'FrostStream 720p' 'Space' 'Dublado' 0
    ST 'FrostStream 1080p' 'Space' 'Dublado' 1
  ) 'SEM LINK (Space desligado)'

  Chk 'SPACE fora, mas o Azure entrega: usa o Azure' @(
    ST 'FrostStream 720p' 'Space' 'Dublado' 0
    ST 'FrostStream 1080p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 1080p]'

  Chk 'DNSPlay DESLIGADO tambem' @(
    ST 'FrostStream 720p' 'DNSPlay' 'Dublado' 0
    ST 'FrostStream 720p' 'Nova' 'Dublado' 1
  ) 'Nova Dublado [FrostStream 720p]'

  Chk 'NUNCA ficar sem link: so um stream, ele escolhe' @(
    ST 'FrostStream 4K' 'Azure' 'Dublado' 0
  ) 'Azure Dublado [FrostStream 4K]'

  Chk 'ordem do addon (posicao) desempatena' @(
    ST 'FrostStream 720p' 'Azure' 'Dublado' 0
    ST 'FrostStream 720p' 'Azure' 'Dublado' 1
  ) 'Azure Dublado [FrostStream 720p]'

  '--- o provedor e lido de qualquer linha do title ---'
  $s1 = [PSCustomObject]@{ name = 'FrostStream 1080p'; title = "Filme`nNova`nLegendado"; url = 'u'; headers = $null }
  $s2 = [PSCustomObject]@{ name = 'FrostStream 1080p'; title = "Filme`nAzure`nDublado"; url = 'u'; headers = $null }
  $venc = Pick-FSStream @($s2, $s1)
  if ($null -ne $venc -and ([string]$venc.title) -match 'Azure') { '  OK   dublado do Azure ganha do legendado do Nova' } else { '  FALHOU' }
  $s3 = [PSCustomObject]@{ name = 'FrostStream 1080p'; title = "Titulo`nT01-E01`nAzure`nPortugues"; url = 'u'; headers = $null }
  if ((Get-StreamProvedor $s3) -eq 'Azure') { '  OK   Azure encontrado na 3a linha do title' } else { '  FALHOU' }
  [Environment]::Exit(0)
}

if ($TestFuturo) {
  # Teste offline da fila: stubs de addon, arquivos temporarios e nada de
  # GitHub. Confere: add na fila, gravacao das linhas, saida da fila quando
  # entra e idempotencia (rodar duas vezes nao duplica nada).
  $tmp = Join-Path $env:TEMP 'novifuturo_teste'
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  [void](New-Item -ItemType Directory -Path $tmp)
  $FuturoFile = Join-Path $tmp 'futuro.np'
  $FrostFile = Join-Path $tmp 'froststream.np'
  $ChannelsPath = Join-Path $tmp 'channels.np'
  $global:FS_SoHD = @()
  [IO.File]::WriteAllText($ChannelsPath, "Canal Teste|https://ex/canal|CAT|||`r`n", (New-Object System.Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($FrostFile, '', (New-Object System.Text.UTF8Encoding($false)))

  # stub: tt_filme_1 e a serie T1E1..T1E3 ja tem stream; tt_filme_2 so tem
  # depois que $global:StubLiberado virar $true (simula o "lancou na hora").
  $global:FSCache = @{}
  $global:StubCalls = 0
  $global:StubLiberado = $false
  function Get-FSStreams([string]$type, [string]$rid) {
    $global:StubCalls++
    if ($rid -eq 'tt_filme_1') {
      return @([PSCustomObject]@{ name = 'FrostStream 720p'; title = "Filme`nSpace`nDublado"; url = 'https://ex/filme1.m3u8'; headers = $null })
    }
    if ($rid -eq 'tt_filme_2' -and $global:StubLiberado) {
      return @([PSCustomObject]@{ name = 'FrostStream 1080p'; title = "Filme`nNova`nDublado"; url = 'https://ex/filme2.m3u8'; headers = $null })
    }
    if ($rid -match '^tt_serie_1:1:([123])$') {
      return @([PSCustomObject]@{ name = 'FrostStream 1080p'; title = "Serie`nSpace`nDublado"; url = ("https://ex/s1e" + $Matches[1] + '.m3u8'); headers = $null })
    }
    return @()
  }
  function Get-FenixRescue([string]$type, [string]$rid) { return @() }
  function Get-FSMetaEps([string]$id) {
    if ($id -eq 'tt_serie_2') { return @(1..2 | ForEach-Object { [PSCustomObject]@{ Season = 1; Ep = $_ } }) }
    if ($id -eq 'tt_serie_1') { return @(1..5 | ForEach-Object { [PSCustomObject]@{ Season = 1; Ep = $_ } }) }
    return @()
  }

  $filme = [PSCustomObject]@{ Type = 'movie'; Id = 'tt_filme_1'; Name = 'Vingadores'; Year = '2026'; Poster = 'https://ex/p1.jpg' }
  $filme2 = [PSCustomObject]@{ Type = 'movie'; Id = 'tt_filme_2'; Name = 'Ainda Nao Saiu'; Year = '2027'; Poster = '' }
  $serie = [PSCustomObject]@{ Type = 'series'; Id = 'tt_serie_1'; Name = 'Serie Teste'; Year = '2026'; Poster = 'https://ex/p2.jpg' }
  $serie2 = [PSCustomObject]@{ Type = 'series'; Id = 'tt_serie_2'; Name = 'Serie Parcial'; Year = '2026'; Poster = '' }

  '--- 0) diagnostico dos stubs ---'
  $arrTest = @(Get-FSStreams 'movie' 'tt_filme_1')
  "  Get-FSStreams devolveu: $($arrTest.Count) stream(s)  |  chamadas ao stub: $global:StubCalls"
  $pickTest = Select-FutureStream $arrTest 'Vingadores'
  "  Select-FutureStream devolveu: $(if ($pickTest) { [string]$pickTest.url } else { 'NADA' })"
  "  Test-FutureMovieLine (vazio esperado): $(Test-FutureMovieLine @('Canal|https://ex/c|CAT|||') 'Vingadores')"

  '--- 1) add na fila ---'
  Add-FuturoItem $filme 1 1 10 | ForEach-Object { "  $_" }
  Add-FuturoItem $filme 1 1 10 | ForEach-Object { "  duplicado: $_" }
  Add-FuturoItem $serie 1 1 5 'Anime' | ForEach-Object { "  $_" }
  Add-FuturoItem $serie 0 0 0 | ForEach-Object { "  $_" }
  Add-FuturoItem $filme2 1 1 10 | ForEach-Object { "  $_" }
  "  fila: $((@(Read-FuturoQueue)).Count) item(ns) (esperado 4)"
  foreach ($i in (Read-FuturoQueue)) { "    $($i.Display)" }
  $catNaFila = @(@(Read-FuturoQueue) | Where-Object { $_.Nome -eq 'Serie Teste' -and $_.Cat -eq 'Anime' }).Count
  "  a serie ficou com categoria na fila? $catNaFila (esperado 1)"

  '--- 2) processar: o que o addon tem entra, o resto fica ---'
  $r1 = Process-FuturoQueue 5
  "  $($r1.Msg)"
  $linhas = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  foreach ($l in $linhas) { if ($l -match '\|\|\|(filme|serie)\|') { "    $l" } }
  "  fila depois: $((@(Read-FuturoQueue)).Count) item(ns) (esperado 3: 2 x Serie Teste + o filme que nao saiu)"

  '--- 3) idempotencia: processar de novo nao duplica ---'
  $r2 = Process-FuturoQueue 5
  $linhas2 = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $vod1 = @($linhas | Where-Object { $_ -match '\|\|\|(filme|serie)\|' }).Count
  $vod2 = @($linhas2 | Where-Object { $_ -match '\|\|\|(filme|serie)\|' }).Count
  "  linhas de VOD: $vod1 -> $vod2 (esperado 4 -> 4)   |  added na 2a vez: $($r2.Added) (esperado 0)"

  '--- 4) remover da fila ---'
  $alvo = @(Read-FuturoQueue)[0]
  Remove-FuturoItem $alvo | ForEach-Object { "  $_" }
  "  fila final: $((@(Read-FuturoQueue)).Count) item(ns) (esperado 2)"

  '--- 5) o titulo LANCou: a proxima passada inclui e tira da fila ---'
  $global:StubLiberado = $true
  $r3 = Process-FuturoQueue 5
  "  $($r3.Msg)"
  $linhas3 = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  foreach ($l in $linhas3) { if ($l -match '\|\|\|filme\|') { "    $l" } }
  $temLancado = @($linhas3 | Where-Object { $_ -like '*Ainda Nao Saiu*' }).Count
  "  linhas do filme que lancar: $temLancado (esperado 1)"
  $restouNaFila = @(@(Read-FuturoQueue) | Where-Object { $_.Nome -eq 'Ainda Nao Saiu' }).Count
  "  o filme que lancar continua na fila? $restouNaFila (esperado 0)"

  '--- 6) registro no froststream.np (o que mantem o link renovando todo dia) ---'
  foreach ($l in [IO.File]::ReadAllLines($FrostFile, [Text.Encoding]::UTF8)) { if ($l.Trim()) { "    $l" } }

  '--- 7) categoria da serie (vai para o noviplay.json -> aba SERIES do app) ---'
  $linhasCat = [IO.File]::ReadAllLines($ChannelsPath, [Text.Encoding]::UTF8)
  $epComCat = @($linhasCat | Where-Object { $_ -like '*Serie Teste T1E1*' })[0]
  $pCat = $epComCat.Split([char]'|', [System.StringSplitOptions]::None)
  "  linha: $epComCat"
  "  10o campo (categoria): '$($pCat[9])' (esperado Anime)   |  campos: $($pCat.Count)"
  $TvBoxFile = Join-Path $tmp 'tvbox.np'
  [IO.File]::WriteAllText($TvBoxFile, '', (New-Object System.Text.UTF8Encoding($false)))
  $jsonCat = Build-NoviPlayJson
  $iCat = $jsonCat.IndexOf('"serie":"Serie Teste"')
  "  no noviplay.json: $($jsonCat.Substring([Math]::Max(0,$iCat-160), 190))"
  $catNoJson = ($jsonCat -match '"categoria":"Anime","serie":"Serie Teste"')
  "  a serie saiu com categoria Anime no json? $catNoJson (esperado True)"
  $serieSemCat = [PSCustomObject]@{ Type='series'; Id='tt_serie_2'; Name='Serie Parcial'; Year='2026'; Poster='' }
  $setCat = Set-FutureEpCat $linhasCat 'Serie Teste' 'Doramas'
  $nCat = $setCat.Changed
  "  Set-FutureEpCat mudou $nCat linha(s) (esperado 3: os 3 episodios de Serie Teste)"
  $primeiraEp = @(0..($setCat.Lines.Count-1) | Where-Object { $setCat.Lines[$_] -like '*Serie Teste T1E1*' })[0]
  $p2 = $setCat.Lines[$primeiraEp].Split([char]'|', [System.StringSplitOptions]::None)
  "  linha do 1o episodio depois: $($setCat.Lines[$primeiraEp])"
  "  10o campo agora: '$($p2[9])' (esperado Doramas)   |  campos: $($p2.Count)"

  $vod3 = @($linhas3 | Where-Object { $_ -match '\|\|\|(filme|serie)\|' }).Count
  $ok = ($r1.Added -eq 4) -and ($r1.Done -eq 1) -and ($r1.Pendentes -eq 3) -and ($vod1 -eq 4) -and ($vod2 -eq 4) -and ($r2.Added -eq 0) -and ($r3.Added -eq 1) -and ($temLancado -eq 1) -and ($restouNaFila -eq 0) -and ($vod3 -eq 5) -and ($catNaFila -eq 1) -and ($pCat[9] -eq 'Anime') -and ($pCat.Count -eq 10) -and $catNoJson -and ($nCat -eq 3) -and ($p2[9] -eq 'Doramas')
  if ($ok) { '  RESULTADO: OK' } else { "  RESULTADO: FALHOU (r1=$($r1.Added)/$($r1.Done)/$($r1.Pendentes) vod=$vod1/$vod2 r2=$($r2.Added) r3=$($r3.Added) lanc=$temLancado fila=$restouNaFila vod3=$vod3 catFila=$catNaFila catLinha=$($pCat[9])/campos$($pCat.Count) catJson=$catNoJson setCat=$nCat catDepois=$($p2[9]))" }
  [Environment]::Exit(0)
}

if ($TestAviso) {
  # Teste offline do aviso programado: grava, mostra no noviplay.json e
  # aplica (que e o que a atualizacao automatica faz antes do GitHub).
  $tmp = Join-Path $env:TEMP 'noviaviso_teste'
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  [void](New-Item -ItemType Directory -Path $tmp)
  $AvisoFile = Join-Path $tmp 'aviso.np'
  $AvisoProgFile = Join-Path $tmp 'aviso_pendente.np'
  # o aviso AUTOMATICO tambem aponta para a pasta de teste: se o painel estiver
  # com um aviso automatico na tela (ex.: um filme novo que acabou de entrar),
  # ele tem prioridade sobre o manual e este teste acusaria erro falso.
  $AvisoAutoAtual = Join-Path $tmp 'aviso_auto_atual.np'
  $AvisoAutoCfg = Join-Path $tmp 'aviso_auto.np'
  $ChannelsPath = Join-Path $tmp 'channels.np'
  $TvBoxFile = Join-Path $tmp 'tvbox.np'
  [IO.File]::WriteAllText($ChannelsPath, "Filme|https://ex/f|||filme|||`r`n", (New-Object System.Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($TvBoxFile, '', (New-Object System.Text.UTF8Encoding($false)))

  '--- 1) nada programado ---'
  "  programmed:  '$((Get-AvisoProgramado))'"
  "  aplicar devolve: '$(Aplicar-AvisoProgramado)' (vazio = nao tinha nada)"
  $j = Build-NoviPlayJson
  "  aviso no json: $($j.Substring(0, 30))..."

  '--- 2) programa um aviso (NAO envia agora) ---'
  Set-AvisoProgramado 'Manutencao hoje as 4:05. Volto ja.' | Out-Null
  "  programmed: '$(Get-AvisoProgramado)'"
  "  aviso.np continua vazio? '$(Get-AvisoTexto)' (nao mandou nada)"

  '--- 3) a atualizacao aplica e monta o json ---'
  $r = Aplicar-AvisoProgramado
  "  aplicar devolveu: $r"
  $j = Build-NoviPlayJson
  $i = $j.IndexOf('"aviso"')
  "  no noviplay.json: $($j.Substring($i, 60))..."
  $jsonTemAviso = ($j -match '"aviso":"Manutencao hoje as 4:05\. Volto ja\."')
  "  aviso chegou no json? $jsonTemAviso (esperado True)"
  "  arquivo do programado ainda existe? $(Test-Path -LiteralPath $AvisoProgFile) (esperado False)"

  '--- 4) programar de novo (troca a mensagem) + cancelar ---'
  Set-AvisoProgramado 'Nova mensagem' | Out-Null
  "  programado: '$(Get-AvisoProgramado)'"
  Cancelar-AvisoProgramado
  "  depois de cancelar existe? $(Test-Path -LiteralPath $AvisoProgFile) (esperado False)"
  "  aplicar devolve: '$(Aplicar-AvisoProgramado)' (vazio = cancelado nao mexe no aviso)"
  $j2 = Build-NoviPlayJson
  "  aviso no json continua o antigo? $($j2 -match 'Manutencao hoje as 4:05') (esperado True)"

  '--- 5) programar VAZIO = limpar o aviso na proxima atualizacao ---'
  Set-AvisoProgramado '' | Out-Null
  $r = Aplicar-AvisoProgramado
  "  aplicar devolveu: $r"
  $j3 = Build-NoviPlayJson
  $i3 = $j3.IndexOf('"aviso"')
  "  no noviplay.json: $($j3.Substring($i3, 20))..."
  $limpo = ($j3 -match '"aviso":"","devices"')
  "  aviso ficou vazio no json? $limpo (esperado True)"

  if ($jsonTemAviso -and $limpo) { '  RESULTADO: OK' } else { '  RESULTADO: FALHOU' }
  [Environment]::Exit(0)
}

# ---------------- ABAS VERMELHAS (10/10/2026) ----------------
# As cabecalhos das abas tambem entram na cor do app: aba selecionada em
# vermelho, as outras em cinza escuro.
try {
  $TabCtl.DrawMode = 'OwnerDrawFixed'
  $TabCtl.Add_DrawItem({
    param($s, $e)
    try {
      $r = $s.GetTabRect($e.Index)
      $sel = ($e.Index -eq $s.SelectedIndex)
      $corFundo = if ($sel) { $ColorBlue } else { $ColorCard }
      $corTexto = if ($sel) { [Drawing.Color]::White } else { $ColorDim }
      $br = New-Object System.Drawing.SolidBrush($corFundo)
      $e.Graphics.FillRectangle($br, $r)
      $br.Dispose()
      $pen = New-Object System.Drawing.Pen($ColorBorda)
      $e.Graphics.DrawRectangle($pen, $r)
      $pen.Dispose()
      $br2 = New-Object System.Drawing.SolidBrush($corTexto)
      $ff = [System.Drawing.StringFormat]::new()
      try {
        $ff.Alignment = [System.Drawing.StringAlignment]::Center
        $ff.LineAlignment = [System.Drawing.StringAlignment]::Center
        $e.Graphics.DrawString($s.TabPages[$e.Index].Text, [System.Drawing.SystemFonts]::DefaultFont, $br2, [System.Drawing.RectangleF]::new($r.X, $r.Y, $r.Width, $r.Height), $ff)
      } finally { $ff.Dispose(); $br2.Dispose() }
    } catch { }
  })
} catch { }

Aplica-Tema
$Form.WindowState = 'Maximized'
Aplica-Layout

[void]$Form.ShowDialog()
