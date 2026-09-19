<#
    Windows Debloat - rimozione bloatware da PC preassemblati / OEM
    ---------------------------------------------------------------
    Uso rapido (PowerShell come amministratore):

        irm https://raw.githubusercontent.com/Sante96/Tools/main/debloat.ps1 | iex

    Variabili d'ambiente opzionali (per uso non interattivo):

        $env:DEBLOAT_MODE   = 'scan' | 'appx' | 'oem' | 'win32' | 'tasks' | 'block' | 'all' | 'unblock'
        $env:DEBLOAT_DRYRUN = '1'    -> mostra cosa farebbe, senza toccare nulla
        $env:DEBLOAT_NORESTORE = '1' -> salta la creazione del punto di ripristino
        $env:DEBLOAT_FORCEWIN32 = '1'-> tenta anche le disinstallazioni non silenziose

    Nota: le app Microsoft rimosse si reinstallano dallo Store, le attivita'
    pianificate vengono solo disattivate, i blocchi del punto 6 sono reversibili
    dal punto 8. Le disinstallazioni Win32 (McAfee, trial, updater OEM) NON sono
    reversibili senza reinstallare il programma.
#>

$ErrorActionPreference = 'Stop'

$script:Version   = '1.0.6'
# Cambia questo URL con il tuo raw GitHub: serve solo per la ri-esecuzione come admin.
$script:ScriptUrl = 'https://raw.githubusercontent.com/Sante96/Tools/main/debloat.ps1'
$script:LogFile   = Join-Path $env:TEMP ("debloat-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$script:DryRun    = ($env:DEBLOAT_DRYRUN -eq '1')
$script:Stats     = [ordered]@{ AppxRemoved = 0; ProvisionedRemoved = 0; Win32Removed = 0; TasksDisabled = 0; Failed = 0; Skipped = 0 }
$script:SysInfo   = $null
$script:UserName  = $null

#region --------------------------------------------------------------------- tui

# Il sorgente resta ASCII puro: i caratteri grafici nascono dai code point, cosi'
# il file funziona anche se PowerShell 5.1 lo legge senza BOM (codepage ANSI).
$script:E = [string][char]27

$script:Glyphs = @{
    TopLeft     = @{ U = 0x256D; A = '+' }
    TopRight    = @{ U = 0x256E; A = '+' }
    BottomLeft  = @{ U = 0x2570; A = '+' }
    BottomRight = @{ U = 0x256F; A = '+' }
    Horizontal  = @{ U = 0x2500; A = '-' }
    Vertical    = @{ U = 0x2502; A = '|' }
    Block       = @{ U = 0x2588; A = '#' }
    Shade       = @{ U = 0x2591; A = '.' }
    Dot         = @{ U = 0x25CF; A = '*' }
    Check       = @{ U = 0x2713; A = 'v' }
    Cross       = @{ U = 0x2717; A = 'x' }
    Arrow       = @{ U = 0x279C; A = '>' }
    Warn        = @{ U = 0x25B2; A = '!' }
}

# Palette: viola -> ciano, come i CLI moderni.
$script:Pal = @{
    Brand1  = @(167, 139, 250)
    Brand2  = @(34, 211, 238)
    Text    = @(228, 228, 231)
    Muted   = @(113, 113, 122)
    Ok      = @(74, 222, 128)
    Warn    = @(251, 191, 36)
    Err     = @(248, 113, 113)
    Sel     = @(39, 39, 42)
}

function Initialize-Ui {
    $script:Ui = @{ Vt = $false; Uni = $false; Width = 80; Height = 30; Anim = $true; Keys = $true }

    # ANSI: utile solo su console vera. Se l'output e' rediretto gli escape
    # finirebbero nel file, quindi in quel caso si scrive in chiaro.
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if (-not $redirected) {
        try { $script:Ui.Vt = [bool]$Host.UI.SupportsVirtualTerminal } catch { }
    }

    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $script:Ui.Uni = $true
    } catch { }

    try {
        $size = $Host.UI.RawUI.WindowSize
        if ($size.Width -ge 40) { $script:Ui.Width = [int]$size.Width }
        if ($size.Height -ge 10) { $script:Ui.Height = [int]$size.Height }
    } catch { }

    if ($redirected -or $env:DEBLOAT_NOANIM -eq '1') { $script:Ui.Anim = $false }

    $inRedir = $false
    try { $inRedir = [Console]::IsInputRedirected } catch { }
    if ($inRedir) { $script:Ui.Keys = $false }
}

function G {
    param([string]$Name)
    $g = $script:Glyphs[$Name]
    if ($null -eq $g) { return '?' }
    if ($script:Ui.Uni) { return [string][char]$g.U }
    return $g.A
}

function Ansi {
    param(
        [string]$Text,
        [int[]]$Fg,
        [int[]]$Bg,
        [switch]$Bold,
        [switch]$Dim
    )
    if (-not $script:Ui.Vt) { return $Text }
    $s = ''
    if ($Bold) { $s += "$($script:E)[1m" }
    if ($Dim)  { $s += "$($script:E)[2m" }
    if ($Fg)   { $s += "$($script:E)[38;2;$($Fg[0]);$($Fg[1]);$($Fg[2])m" }
    if ($Bg)   { $s += "$($script:E)[48;2;$($Bg[0]);$($Bg[1]);$($Bg[2])m" }
    if ($s -eq '') { return $Text }
    return $s + $Text + "$($script:E)[0m"
}

function Get-Gradient {
    param([int[]]$From, [int[]]$To, [int]$Steps)
    $out = New-Object System.Collections.ArrayList
    if ($Steps -le 1) { [void]$out.Add($From); return $out }
    for ($i = 0; $i -lt $Steps; $i++) {
        $t = $i / ($Steps - 1)
        [void]$out.Add(@(
            [int][Math]::Round($From[0] + ($To[0] - $From[0]) * $t)
            [int][Math]::Round($From[1] + ($To[1] - $From[1]) * $t)
            [int][Math]::Round($From[2] + ($To[2] - $From[2]) * $t)
        ))
    }
    return $out
}

function Get-GradientText {
    # Restituisce la stringa colorata invece di scriverla: serve al loader, che
    # deve ridisegnare la stessa riga molte volte.
    param([string]$Text, [int[]]$From, [int[]]$To)
    if (-not $script:Ui.Vt) { return $Text }
    $chars = $Text.ToCharArray()
    if ($chars.Count -eq 0) { return '' }
    $g = @(Get-Gradient -From $From -To $To -Steps $chars.Count)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $chars.Count; $i++) {
        $c = $g[$i]
        [void]$sb.Append("$($script:E)[38;2;$($c[0]);$($c[1]);$($c[2])m$($chars[$i])")
    }
    [void]$sb.Append("$($script:E)[0m")
    return $sb.ToString()
}

function Write-GradientLine {
    param([string]$Text, [int[]]$From, [int[]]$To, [string]$Indent = '  ')
    if (-not $script:Ui.Vt) { Write-Host ($Indent + $Text); return }
    Write-Host ($Indent + (Get-GradientText -Text $Text -From $From -To $To))
}

function Clear-Screen {
    try { Clear-Host } catch { Write-Host '' }
}

function Hide-Cursor {
    if ($script:Ui.Vt) { Write-Host "$($script:E)[?25l" -NoNewline }
}

function Show-Cursor {
    if ($script:Ui.Vt) { Write-Host "$($script:E)[?25h" -NoNewline }
}

function Start-Pause {
    param([int]$Ms)
    if ($script:Ui.Anim) { Start-Sleep -Milliseconds $Ms }
}

# Wordmark 5 righe: 'X' diventa blocco pieno, cosi' il sorgente resta ASCII.
$script:WordMark = @(
    'XXXX  XXXXX XXXX  X     XXXXX  XXXX  XXXXX'
    'X   X X     X   X X     X   X X   X    X  '
    'X   X XXXX  XXXX  X     X   X XXXXX    X  '
    'X   X X     X   X X     X   X X   X    X  '
    'XXXX  XXXXX XXXX  XXXXX XXXXX X   X    X  '
)

function Show-WordMark {
    $block = G 'Block'
    $shade = G 'Shade'
    $rows = @($script:WordMark)
    if ($script:Ui.Width -lt 50) {
        Write-GradientLine -Text 'D E B L O A T' -From $script:Pal.Brand1 -To $script:Pal.Brand2
        return
    }
    foreach ($r in $rows) {
        $line = $r.Replace('X', $block)
        Write-GradientLine -Text $line -From $script:Pal.Brand1 -To $script:Pal.Brand2
        Start-Pause 110
    }
    Write-Host ''
    $barW = [Math]::Min(42, $script:Ui.Width - 6)
    Write-GradientLine -Text ($shade * $barW) -From $script:Pal.Brand2 -To $script:Pal.Brand1
    Start-Pause 200
}

function Show-Loader {
    # Barra che si riempie con le fasi che avanzano. E' solo presentazione: il
    # lavoro vero e' altrove, quindi la durata e' decisa qui.
    param([string[]]$Steps, [int]$Ms = 2800)

    $steps = @($Steps)
    if ($steps.Count -eq 0) { return }

    if (-not $script:Ui.Anim) {
        foreach ($s in $steps) { Write-Host ('  ' + (Ansi -Text $s -Fg $script:Pal.Muted)) }
        return
    }

    $block = G 'Block'
    $shade = G 'Shade'
    $barW = [Math]::Min(32, [Math]::Max(10, $script:Ui.Width - 26))

    $spin = @('|', '/', '-', '\')
    if ($script:Ui.Uni) {
        $spin = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) |
                ForEach-Object { [string][char]$_ }
    }

    # Etichetta piu' lunga: serve per allineare la percentuale su tutte le fasi.
    $labW = 0
    foreach ($s in $steps) { if ($s.Length -gt $labW) { $labW = $s.Length } }
    $labW = [Math]::Min($labW, [Math]::Max(8, $script:Ui.Width - $barW - 16))

    $frameMs = 60
    $total = [Math]::Max(1, [int]($Ms / $frameMs))
    $sw = [Diagnostics.Stopwatch]::StartNew()

    for ($f = 0; $f -le $total; $f++) {
        $t = $f / $total
        $done = [int][Math]::Round($barW * $t)
        $bar = ($block * $done) + ($shade * ($barW - $done))

        $si = [Math]::Min($steps.Count - 1, [int]($t * $steps.Count))
        $label = Get-Fit $steps[$si] $labW

        $pct = ('{0,3}%' -f [int][Math]::Round($t * 100))
        $sp = $spin[$f % $spin.Count]

        $line = '  ' + (Ansi -Text $sp -Fg $script:Pal.Brand2) + '  ' +
                (Get-GradientText -Text $bar -From $script:Pal.Brand1 -To $script:Pal.Brand2) + '  ' +
                (Ansi -Text $pct -Fg $script:Pal.Text) + '  ' +
                (Ansi -Text $label.PadRight($labW) -Fg $script:Pal.Muted)

        Write-Host ("`r" + $line) -NoNewline

        $target = ($f + 1) * $frameMs
        $wait = $target - $sw.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
    $sw.Stop()

    # Riga finale: barra piena e spunta al posto dello spinner.
    $line = '  ' + (Ansi -Text (G 'Check') -Fg $script:Pal.Ok) + '  ' +
            (Get-GradientText -Text ($block * $barW) -From $script:Pal.Brand1 -To $script:Pal.Brand2) + '  ' +
            (Ansi -Text '100%' -Fg $script:Pal.Text) + '  ' +
            (Ansi -Text 'pronto'.PadRight($labW) -Fg $script:Pal.Ok)
    Write-Host ("`r" + $line)
}

function Write-Typed {
    # Scrive a macchina, con la coda in un secondo colore (serve per il nome).
    param(
        [string]$Text,
        [int[]]$Fg,
        [string]$Tail = '',
        [int[]]$TailFg,
        [string]$Indent = '  ',
        [int]$Ms = 18
    )
    if (-not $TailFg) { $TailFg = $Fg }

    if (-not $script:Ui.Anim) {
        Write-Host ($Indent + (Ansi -Text $Text -Fg $Fg) + (Ansi -Text $Tail -Fg $TailFg -Bold))
        return
    }
    Write-Host $Indent -NoNewline
    foreach ($c in $Text.ToCharArray()) {
        Write-Host (Ansi -Text ([string]$c) -Fg $Fg) -NoNewline
        Start-Sleep -Milliseconds $Ms
    }
    foreach ($c in $Tail.ToCharArray()) {
        Write-Host (Ansi -Text ([string]$c) -Fg $TailFg -Bold) -NoNewline
        Start-Sleep -Milliseconds $Ms
    }
    Write-Host ''
}

function Get-DisplayName {
    # Nome utente leggibile: prima il nome completo dell'account, poi il login.
    # Il valore resta in cache: il menu si ridisegna a ogni tasto e la query CIM
    # costa troppo per rifarla ogni volta.
    if ($script:UserName) { return $script:UserName }

    $n = ''
    try {
        $full = (Get-CimInstance Win32_UserAccount -Filter "Name='$env:USERNAME'" -ErrorAction SilentlyContinue |
                 Select-Object -First 1).FullName
        if ($full) { $n = [string]$full }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$env:USERNAME }
    if ([string]::IsNullOrWhiteSpace($n)) { $n = 'utente' }
    $n = $n.Trim()
    if ($n -match '^(\S+)') { $n = $Matches[1] }
    $script:UserName = $n
    return $n
}

function Show-Splash {
    Clear-Screen
    Hide-Cursor
    Write-Host ''
    Show-WordMark
    Write-Host ''
    $name = Get-DisplayName
    Write-Typed -Text 'Bentornato, ' -Fg $script:Pal.Muted `
                -Tail $name -TailFg $script:Pal.Brand2 -Ms 34
    Start-Pause 260
    Write-Host ('  ' + (Ansi -Text "pulizia bloatware  $(G 'Dot')  v$($script:Version)" -Fg $script:Pal.Muted))
    Write-Host ''
    Start-Pause 420

    # L'ultima fase non e' 'pronto': quella parola la dice la riga finale del
    # loader, quando la barra e' davvero piena.
    Show-Loader -Steps @(
        'avvio'
        'lettura configurazione'
        'controllo ambiente'
        'inventario applicazioni'
        'ultimi controlli'
    ) -Ms 3200
    Write-Host ''
    Start-Pause 400
}

function Write-Step {
    param([string]$Label, [string]$Value, [string]$State = 'ok')
    $glyph = G 'Check'
    $col = $script:Pal.Ok
    if ($State -eq 'warn') { $glyph = G 'Warn'; $col = $script:Pal.Warn }
    if ($State -eq 'err')  { $glyph = G 'Cross'; $col = $script:Pal.Err }
    $line = '  ' + (Ansi -Text $glyph -Fg $col) + '  ' +
            (Ansi -Text $Label.PadRight(26) -Fg $script:Pal.Text) +
            (Ansi -Text $Value -Fg $script:Pal.Muted)
    Write-Host $line
}

function Format-Size {
    # Byte in una forma leggibile: 68302901248 -> '64 GB'.
    param([double]$Bytes, [int]$Decimals = 0)
    if ($Bytes -le 0) { return '' }
    $u = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($u.Count - 1)) { $Bytes = $Bytes / 1024; $i++ }
    $d = if ($i -le 2) { 0 } else { $Decimals }
    return ('{0:N' + $d + '} {1}') -f $Bytes, $u[$i]
}

function Initialize-SysInfo {
    # Raccoglie l'hardware una volta sola. Win32_Processor costa oltre un secondo,
    # quindi la chiamata vive dentro il loader, dove l'attesa e' gia' mascherata.
    if ($null -ne $script:SysInfo) { return }

    # Con -Property si chiedono solo i campi che servono. Su Win32_Processor non e'
    # un'ottimizzazione qualsiasi: la classe completa include LoadPercentage, che
    # interroga i contatori di prestazioni e da sola costa oltre un secondo.
    $q = {
        param($Class, $Filter, $Props)
        try {
            $a = @{ ClassName = $Class; ErrorAction = 'SilentlyContinue' }
            if ($Filter) { $a.Filter = $Filter }
            if ($Props)  { $a.Property = $Props }
            return @(Get-CimInstance @a)
        } catch { return @() }
    }

    $cs   = @(& $q 'Win32_ComputerSystem')   | Select-Object -First 1
    $os   = @(& $q 'Win32_OperatingSystem')  | Select-Object -First 1
    $cpu  = @(& $q 'Win32_Processor' $null @('Name', 'NumberOfCores', 'NumberOfLogicalProcessors')) |
            Select-Object -First 1
    $bb   = @(& $q 'Win32_BaseBoard')        | Select-Object -First 1
    $bios = @(& $q 'Win32_BIOS')             | Select-Object -First 1
    $mem  = @(& $q 'Win32_PhysicalMemory')
    $gpu  = @(& $q 'Win32_VideoController')
    $disk = @(& $q 'Win32_DiskDrive')
    $sysDrive = "$($env:SystemDrive)"
    $ld   = @(& $q 'Win32_LogicalDisk' "DeviceID='$sysDrive'") | Select-Object -First 1

    # --- CPU: nome compatto piu' core e thread.
    $cpuLabel = ''
    if ($cpu) {
        $n = [string]$cpu.Name
        $n = $n -replace '\(R\)|\(TM\)|\(tm\)', ''
        $n = $n -replace '\s+CPU\s*', ' '
        $n = $n -replace '\s+Processor\s*', ' '
        $n = ($n -replace '\s+', ' ').Trim()
        $cpuLabel = $n
        if ($cpu.NumberOfCores) {
            $t = $cpu.NumberOfLogicalProcessors
            if (-not $t) { $t = $cpu.NumberOfCores }
            $cpuLabel += "  $($cpu.NumberOfCores)C/$($t)T"
        }
    }

    # --- RAM: totale dal sistema, velocita' e numero di moduli dai banchi.
    $ramLabel = ''
    $totalRam = 0
    if ($cs -and $cs.TotalPhysicalMemory) { $totalRam = [double]$cs.TotalPhysicalMemory }
    if ($totalRam -le 0 -and $mem.Count -gt 0) {
        foreach ($m in $mem) { $totalRam += [double]$m.Capacity }
    }
    if ($totalRam -gt 0) {
        # Il totale riportato da Windows e' poco sotto la taglia nominale: si arrotonda.
        $gb = [int][Math]::Round($totalRam / 1GB)
        $ramLabel = "$gb GB"
        if ($mem.Count -gt 0) {
            $sp = ($mem | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 } |
                   Sort-Object -Descending | Select-Object -First 1)
            if (-not $sp) {
                $sp = ($mem | ForEach-Object { [int]$_.Speed } | Where-Object { $_ -gt 0 } |
                       Sort-Object -Descending | Select-Object -First 1)
            }
            if ($sp) { $ramLabel += "  $sp MT/s" }
            $ramLabel += "  $($mem.Count) moduli"
        }
    }

    # --- GPU: si scartano gli adattatori virtuali (monitor remoti, visori, capture).
    $gpuNames = New-Object System.Collections.ArrayList
    foreach ($g in $gpu) {
        $gn = ([string]$g.Name).Trim()
        if (-not $gn) { continue }
        if ($gn -match 'virtual|remote|meta |parsec|idd |mirror|oray|spacedesk|citrix|vmware|basic display') { continue }
        if ($gpuNames -notcontains $gn) { [void]$gpuNames.Add($gn) }
    }
    # AdapterRAM va in overflow sopra i 4 GB, quindi la VRAM non viene mostrata.
    $gpuLabel = ($gpuNames -join ' + ')

    # --- Disco di sistema piu' conteggio delle unita' fisiche.
    $diskLabel = ''
    if ($ld -and $ld.Size) {
        $free = Format-Size ([double]$ld.FreeSpace)
        $tot = Format-Size ([double]$ld.Size)
        $diskLabel = "$sysDrive $free liberi su $tot"
    }
    if ($disk.Count -gt 0) {
        $n = $disk.Count
        $w = if ($n -eq 1) { 'unita' } else { 'unita' }
        if ($diskLabel) { $diskLabel += "  $(G 'Dot')  $n $w" } else { $diskLabel = "$n $w" }
    }

    # --- Scheda madre e BIOS.
    $boardLabel = ''
    if ($bb) { $boardLabel = "$($bb.Manufacturer) $($bb.Product)".Trim() }
    if (-not $boardLabel -and $cs) { $boardLabel = "$($cs.Manufacturer) $($cs.Model)".Trim() }
    if ($bios -and $bios.SMBIOSBIOSVersion) { $boardLabel += "  BIOS $($bios.SMBIOSBIOSVersion)" }

    # --- Modello del PC: sui preassemblati e' il dato che conta piu' della mainboard.
    # Sugli assemblati invece Win32_ComputerSystem riporta la stessa stringa della
    # scheda madre: in quel caso la riga 'Modello' sarebbe un doppione e si omette.
    $modelLabel = ''
    if ($cs) { $modelLabel = "$($cs.Manufacturer) $($cs.Model)".Trim() }
    if ($modelLabel -and $bb) {
        $bare = "$($bb.Manufacturer) $($bb.Product)".Trim()
        if ($modelLabel -eq $bare) { $modelLabel = '' }
    }

    $osLabel = ''
    if ($os) {
        $osLabel = [string]$os.Caption
        $osLabel = ($osLabel -replace 'Microsoft ', '').Trim()
        $osLabel += " build $($os.BuildNumber)"
    }

    $script:SysInfo = @{
        Cs = $cs; Os = $os
        Model = $modelLabel; OsLabel = $osLabel; Board = $boardLabel
        Cpu = $cpuLabel; Ram = $ramLabel; Gpu = $gpuLabel; Disk = $diskLabel
    }
}

# Ordine di visualizzazione delle righe hardware: serve a rimetterle in fila dopo
# che il filtro per priorita' ne ha scartate alcune.
$script:SysOrder = @('Modello', 'Scheda madre', 'Processore', 'Memoria', 'Grafica', 'Archiviazione', 'Windows')

function Get-SysRows {
    # Righe dell'hardware in ordine di visualizzazione. 'P' e' la priorita': su
    # console basse si tengono solo le prime, cosi' il menu non esce dallo schermo.
    # Con -All tornano anche le voci non rilevate, che l'avvio segnala come warning.
    param([switch]$All)

    Initialize-SysInfo
    $i = $script:SysInfo

    # Attenzione al nome: in PowerShell le variabili non distinguono maiuscole,
    # quindi una locale '$all' sovrascriverebbe il parametro '-All'.
    # 'Opt' distingue il dato assente dal dato omesso di proposito: 'Modello' su un
    # PC assemblato ripete la scheda madre, e in quel caso non e' un rilevamento
    # mancato, quindi l'avvio non deve segnalarlo.
    $list = @(
        @{ L = 'Modello';       V = $i.Model;   P = 6; Opt = $true }
        @{ L = 'Scheda madre';  V = $i.Board;   P = 7 }
        @{ L = 'Processore';    V = $i.Cpu;     P = 1 }
        @{ L = 'Memoria';       V = $i.Ram;     P = 2 }
        @{ L = 'Grafica';       V = $i.Gpu;     P = 3 }
        @{ L = 'Archiviazione'; V = $i.Disk;    P = 4 }
        @{ L = 'Windows';       V = $i.OsLabel; P = 5 }
    )
    if ($All) { return $list }
    return @($list | Where-Object { -not [string]::IsNullOrWhiteSpace($_.V) })
}

function Show-InitSteps {
    Write-Host ('  ' + (Ansi -Text 'SISTEMA' -Fg $script:Pal.Brand2 -Bold))
    Write-Host ''

    $rows = @(Get-SysRows -All)

    foreach ($r in $rows) {
        if ([string]::IsNullOrWhiteSpace($r.V)) {
            # Una riga opzionale vuota e' stata omessa di proposito, non e' un errore.
            if ($r.Opt) { continue }
            Write-Step $r.L 'non rilevato' 'warn'
        } else {
            Write-Step $r.L $r.V
        }
        Start-Pause 150
    }

    Write-Host ''
    Start-Pause 700
}

#endregion

#region ---------------------------------------------------------------- logging

function Write-Log {
    param(
        [string]$Message = '',
        [ValidateSet('Info', 'Ok', 'Warn', 'Err', 'Step', 'Dim')]
        [string]$Level = 'Info'
    )
    $colors = @{ Info = 'White'; Ok = 'Green'; Warn = 'Yellow'; Err = 'Red'; Step = 'Cyan'; Dim = 'DarkGray' }
    $prefix = @{ Info = '[*]'; Ok = '[+]'; Warn = '[!]'; Err = '[x]'; Step = '==>'; Dim = '   ' }

    # Il file di log resta sempre in ASCII semplice, cosi' e' leggibile da chiunque.
    $plain = "$($prefix[$Level]) $Message"
    try {
        Add-Content -LiteralPath $script:LogFile -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $plain) -Encoding utf8
    } catch { }

    if (-not $script:Ui.Vt) {
        Write-Host $plain -ForegroundColor $colors[$Level]
        return
    }

    $glyph = @{
        Info = (G 'Dot');   Ok   = (G 'Check'); Warn = (G 'Warn')
        Err  = (G 'Cross'); Step = (G 'Arrow'); Dim  = ' '
    }
    $tone = @{
        Info = $script:Pal.Muted; Ok   = $script:Pal.Ok;     Warn = $script:Pal.Warn
        Err  = $script:Pal.Err;   Step = $script:Pal.Brand2; Dim  = $script:Pal.Muted
    }

    if ($Level -eq 'Step') {
        Write-Host ''
        Write-Host ('  ' + (Ansi -Text (G 'Arrow') -Fg $script:Pal.Brand2) + ' ' +
                    (Ansi -Text $Message -Fg $script:Pal.Brand2 -Bold))
        return
    }

    $body = if ($Level -eq 'Dim') { $script:Pal.Muted } else { $script:Pal.Text }
    $ind  = if ($Level -eq 'Dim') { '      ' } else { '  ' }
    Write-Host ($ind + (Ansi -Text $glyph[$Level] -Fg $tone[$Level]) + ' ' +
                (Ansi -Text $Message -Fg $body))
}

function Write-Banner {
    # Intestazione compatta: la schermata d'apertura vera e' Show-Splash.
    Write-Host ''
    Write-GradientLine -Text "debloat v$($script:Version)" -From $script:Pal.Brand1 -To $script:Pal.Brand2
    Write-Log "Log: $($script:LogFile)" 'Dim'
    if ($script:DryRun) { Write-Log 'DRY-RUN attivo: nessuna modifica verra applicata.' 'Warn' }
}

#endregion

#region ------------------------------------------------------------ prerequisiti

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (Test-Admin) { return }

    Write-Host ''
    Write-Log 'Privilegi amministratore richiesti. Riavvio elevato...' 'Warn'

    if ($PSCommandPath) {
        $inner = "& '$PSCommandPath'"
    } elseif ($script:ScriptUrl -notmatch 'UTENTE/REPO') {
        $inner = "irm '$($script:ScriptUrl)' | iex"
    } else {
        Write-Log 'Riapri PowerShell come amministratore e rilancia il comando.' 'Err'
        exit 1
    }

    # Le variabili d'ambiente non passano al processo elevato: le reinietto.
    $pre = ''
    foreach ($n in 'DEBLOAT_MODE', 'DEBLOAT_DRYRUN', 'DEBLOAT_NORESTORE', 'DEBLOAT_FORCEWIN32') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n='$v'; " }
    }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', "$pre$inner"
        )
    } catch {
        Write-Log "Elevazione annullata: $($_.Exception.Message)" 'Err'
    }
    exit
}

function Initialize-AppxModule {
    # Su PowerShell 7 il modulo Appx va caricato in compatibilita' Windows PowerShell.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        try {
            Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
        } catch {
            Write-Log 'Modulo Appx non caricabile su PowerShell 7: usa powershell.exe 5.1.' 'Err'
            exit 1
        }
    }
}

function New-RestorePoint {
    if ($env:DEBLOAT_NORESTORE -eq '1' -or $script:DryRun) {
        Write-Log 'Punto di ripristino saltato.' 'Dim'
        return
    }
    Write-Log 'Creazione punto di ripristino...' 'Step'
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $old = $null
        try { $old = (Get-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency } catch { }
        New-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null

        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Prima di debloat $($script:Version)" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Punto di ripristino creato.' 'Ok'

        if ($null -ne $old) {
            Set-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value $old -Force
        } else {
            Remove-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Punto di ripristino non creato ($($_.Exception.Message.Trim())). Continuo comunque." 'Warn'
    }
}

#endregion

#region ------------------------------------------------------------- definizioni

# Pacchetti che non vanno MAI toccati: framework, runtime, codec, UI di sistema.
$script:ProtectedAppx = @(
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.DesktopAppInstaller'
    'Microsoft.WindowsTerminal*'
    'Microsoft.VCLibs.*'
    'Microsoft.UI.Xaml.*'
    'Microsoft.NET.*'
    'Microsoft.Services.Store.Engagement'
    'Microsoft.WindowsNotepad'
    'Microsoft.Paint'
    'Microsoft.ScreenSketch'
    'Microsoft.Windows.Photos'
    'Microsoft.WindowsCalculator'
    'Microsoft.SecHealthUI'
    'Microsoft.WindowsCamera'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.MicrosoftEdge*'
    'Microsoft.Win32WebViewHost'
    'Microsoft.XboxGameCallableUI'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.AsyncTextService'
    'Microsoft.AccountsControl'
    'Microsoft.CredDialogHost'
    'Microsoft.ECApp'
    'Microsoft.LockApp'
    # UI e componenti di sistema: elencati per nome, non con wildcard, perche'
    # Microsoft.Windows.* prenderebbe anche pacchetti rimovibili come DevHome.
    'Microsoft.Windows.Apprep.ChxApp'
    'Microsoft.Windows.AssignedAccessLockApp'
    'Microsoft.Windows.AugLoop.CBS'
    'Microsoft.Windows.CapturePicker'
    'Microsoft.Windows.CloudExperienceHost'
    'Microsoft.Windows.ContentDeliveryManager'
    'Microsoft.Windows.NarratorQuickStart'
    'Microsoft.Windows.OOBENetworkCaptivePortal'
    'Microsoft.Windows.OOBENetworkConnectionFlow'
    'Microsoft.Windows.ParentalControls'
    'Microsoft.Windows.PeopleExperienceHost'
    'Microsoft.Windows.PinningConfirmationDialog'
    'Microsoft.Windows.PrintQueueActionCenter'
    'Microsoft.Windows.SecureAssessmentBrowser'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'Microsoft.Windows.XGpuEjectDialog'
    'Microsoft.Windows.Search'
    'MicrosoftWindows.Client.CBS'
    'MicrosoftWindows.Client.Core'
    'MicrosoftWindows.Client.CoreAI'
    'MicrosoftWindows.Client.FileExp'
    'MicrosoftWindows.Client.OOBE'
    'MicrosoftWindows.Client.Photon'
    'MicrosoftWindows.Voice.*'
    'MicrosoftWindows.UndockedDevKit'
    'windows.immersivecontrolpanel'
    'c5e2524a-ea46-4f67-841f-6a9465d9d515'  # File Picker
    'E2A4F912-2574-4A75-9BB0-0D023378592B'  # AppResolverUX
    'F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE'  # Add Suggested Folders
    '*HEIFImageExtension*'
    '*WebpImageExtension*'
    '*RawImageExtension*'
    '*VP9VideoExtensions*'
    '*AV1VideoExtension*'
    '*HEVCVideoExtension*'
    '*MPEG2VideoExtension*'
    '*WebMediaExtensions*'
    '*DolbyAudio*'                        # legato ai driver audio su molti OEM
    '*RealtekAudio*'
    '*NahimicCompanion*'
    '*WavesAudio*'
)

# AppX consumer Microsoft: pubblicita', giochi, app che nessuno usa.
$script:AppxMicrosoft = @(
    'Microsoft.3DBuilder'
    'Microsoft.549981C3F5F10'             # Cortana
    'Microsoft.BingFinance'
    'Microsoft.BingFoodAndDrink'
    'Microsoft.BingHealthAndFitness'
    'Microsoft.BingNews'
    'Microsoft.BingSearch'
    'Microsoft.BingSports'
    'Microsoft.BingTranslator'
    'Microsoft.BingTravel'
    'Microsoft.BingWeather'
    'Microsoft.Copilot'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftJournal'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftPowerBIForWindows'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.MixedReality.Portal'
    'Microsoft.NetworkSpeedTest'
    'Microsoft.News'
    'Microsoft.Office.OneNote'
    'Microsoft.Office.Sway'
    'Microsoft.OneConnect'
    'Microsoft.Print3D'
    'Microsoft.SkypeApp'
    'Microsoft.Todos'
    'Microsoft.Wallet'
    'Microsoft.Whiteboard'
    'Microsoft.WindowsAlarms'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsPhone'
    'Microsoft.WindowsReadingList'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.Messaging'
    'Microsoft.MSPaint'                   # Paint 3D (diverso da Microsoft.Paint)
    'Microsoft.People'
    'Microsoft.PowerAutomateDesktop'
    'MicrosoftCorporationII.MicrosoftFamily'
    'MicrosoftCorporationII.QuickAssist'
    'MicrosoftTeams'                      # Teams consumer / Chat
    'MSTeams'
    'Clipchamp.Clipchamp'
    'MicrosoftWindows.Client.WebExperience' # Widget
    'Microsoft.Windows.DevHome'
)

# AppX di terze parti e OEM: trial, giochi sponsorizzati, suite dei produttori.
$script:AppxOem = @(
    '*ACGMediaPlayer*'
    '*ActiproSoftware*'
    '*AdobePhotoshopExpress*'
    '*Amazon*'
    '*AutodeskSketchBook*'
    '*BubbleWitch*'
    '*CandyCrush*'
    '*CyberLink*'
    '*Disney*'
    '*Dropbox*'
    '*DuolingoLearnLanguages*'
    '*EclipseManager*'
    '*Facebook*'
    '*FarmVille*'
    '*Fitbit*'
    '*Flipboard*'
    '*HiddenCity*'
    '*Hulu*'
    '*iHeartRadio*'
    '*Instagram*'
    '*king.com*'
    '*LinkedIn*'
    '*MarchOfEmpires*'
    '*McAfee*'
    '*Netflix*'
    '*NYTCrossword*'
    '*OneCalendar*'
    '*PandoraMedia*'
    '*Plex*'
    '*PicsArt*'
    '*PolarrPhotoEditor*'
    '*Prime*Video*'
    '*RoyalRevolt*'
    '*Shazam*'
    '*Sidia.LiveWallpaper*'
    '*SlingTV*'
    '*Speedtest*'
    '*Spotify*'
    '*Sway*'
    '*TikTok*'
    '*Twitter*'
    '*Viber*'
    '*WhatsApp*'
    '*WinZip*'
    '*Wunderlist*'
    # produttori
    '*AcerCollection*'
    '*AcerJumpstart*'
    '*AcerRegistration*'
    '*ArmouryCrate*'
    '*B9ECED6F.ArmouryCrate*'
    # ASUS: solo app di upsell/registrazione. NON '*ASUS*', che prende
    # anche componenti driver tipo ASUSAmbientHAL (sensori/retroilluminazione).
    '*ASUSGIFTBOX*'
    '*ASUSPCAssistant*'
    '*ASUSProductRegistration*'
    '*ASUSWebStorage*'
    '*ASUSZenLink*'
    '*MyASUS*'
    '*Booking.com*'
    '*DellCustomerConnect*'
    '*DellDigitalDelivery*'
    '*DellMobileConnect*'
    '*DellPowerManager*'
    '*DellSupportAssist*'
    '*DellUpdate*'
    '*GIGABYTE*'
    '*HPJumpStart*'
    '*HPPCHardwareDiagnostics*'
    '*HPPrinterControl*'
    '*HPPrivacySettings*'
    '*HPQuickDrop*'
    '*HPSupportAssistant*'
    '*HPWorkWell*'
    '*myHP*'
    '*LenovoCompanion*'
    '*LenovoSettings*'
    '*LenovoUtility*'
    '*LenovoVantage*'
    '*LenovoWelcome*'
    '*E046963F.LenovoCompanion*'
    '*MSI*Center*'
    '*DragonCenter*'
    '*Nahimic*'
    '*PowerDirector*'
    '*ScreenRecorder*'
    '*SamsungNotes*'
    '*ToshibaBookplace*'
)

# Win32: nome visualizzato o publisher da cercare nel registro di disinstallazione.
$script:Win32Patterns = @(
    # antivirus e trial
    'McAfee', 'WebAdvisor', 'Norton', 'NortonLifeLock', 'Avast', 'AVG ', 'Avira',
    'Kaspersky Free', 'Total ?AV', 'Segurazo', 'PC ?App ?Store',
    # updater, toolbar, "ottimizzatori"
    'Driver ?Booster', 'Driver ?Easy', 'CCleaner', 'WinZip', 'WinRAR Trial',
    'Ask Toolbar', 'Bing Bar', 'Yahoo', 'Wild ?Tangent', 'Candy ?Crush',
    'ExpressVPN Trial', 'Opera Browser Assistant',
    # suite OEM non essenziali
    'Acer Care Center', 'Acer Collection', 'Acer Jumpstart', 'Acer Product Registration',
    'ASUS GIFTBOX', 'ASUS Product Register', 'ASUS Splendid', 'ASUS ZenLink', 'ASUS WebStorage',
    'Dell Customer Connect', 'Dell Digital Delivery', 'Dell SupportAssist OS Recovery',
    'Dell Mobile Connect', 'Dell Digital Locker',
    'HP Documentation', 'HP JumpStart', 'HP Registration', 'HP Support Solutions',
    'HP Sure', 'HP Wolf Security', 'HP Connection Optimizer', 'HP Notifications',
    'Lenovo Vantage Service', 'Lenovo Welcome', 'Lenovo Migration Assistant',
    'Lenovo Utility', 'Lenovo Smart', 'Lenovo Now',
    'GIGABYTE APP Center', 'GIGABYTE Control Center', 'Norton Utilities',
    'MSI Center', 'Dragon Center', 'Nahimic', 'Killer Control Center',
    'Booking.com', 'Power2Go', 'PowerDirector', 'PhotoDirector', 'PowerDVD',
    'CyberLink Media Suite', 'Nero ', 'Roxio', 'Evernote Trial'
    # Nota: lo stub trial di Office/Microsoft 365 NON e' in lista. Il suo
    # DisplayName e' identico a quello di un Office regolarmente attivato,
    # quindi non e' distinguibile in modo affidabile: rimuovilo a mano.
)

# Attivita' pianificate OEM tipiche (telemetria, updater, popup di upsell).
# Nota: solo disattivate, non eliminate -> riattivabili da Utilita di pianificazione.
# Deliberatamente esclusi gli updater di app che installa l'utente (Chrome, Edge,
# OneDrive, Dropbox): disattivarli blocca gli aggiornamenti di sicurezza.
$script:TaskPatterns = @(
    'Acer', 'ASUS', 'Dell', 'HP ', 'HPCustomer', 'Lenovo', 'GIGABYTE',
    'MSI Center', 'MSICompanion', 'Dragon Center',
    'McAfee', 'Norton', 'CCleaner', 'Booking', 'CyberLink', 'Nahimic'
)

#endregion

#region ----------------------------------------------------------------- utility

function Test-PatternMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Test-Protected {
    param([string]$Name)
    return (Test-PatternMatch -Name $Name -Patterns $script:ProtectedAppx)
}

function Get-TargetAppx {
    param([string[]]$Patterns)

    $result = New-Object System.Collections.ArrayList
    $installed = @()
    $provisioned = @()

    # -AllUsers e -Online richiedono privilegi elevati: senza admin tornano vuoti
    # (non in errore), quindi ripiego sull'utente corrente per non dare falsi "0".
    try { $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } catch { }
    if ($installed.Count -eq 0) {
        try { $installed = @(Get-AppxPackage -ErrorAction SilentlyContinue) } catch { }
    }
    try { $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) } catch { }

    foreach ($pkg in $installed) {
        if (Test-Protected $pkg.Name) { continue }
        if (-not (Test-PatternMatch -Name $pkg.Name -Patterns $Patterns)) { continue }
        [void]$result.Add([pscustomobject]@{
            Kind        = 'Installed'
            Name        = $pkg.Name
            FullName    = $pkg.PackageFullName
            NonRemovable = [bool]$pkg.NonRemovable
        })
    }
    foreach ($pkg in $provisioned) {
        if (Test-Protected $pkg.DisplayName) { continue }
        if (-not (Test-PatternMatch -Name $pkg.DisplayName -Patterns $Patterns)) { continue }
        [void]$result.Add([pscustomobject]@{
            Kind        = 'Provisioned'
            Name        = $pkg.DisplayName
            FullName    = $pkg.PackageName
            NonRemovable = $false
        })
    }
    return $result
}

function Get-InstalledWin32 {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        $items = @()
        try { $items = @(Get-ItemProperty -Path $r -ErrorAction SilentlyContinue) } catch { }
        foreach ($i in $items) {
            $name = ''
            try { $name = [string]$i.DisplayName } catch { }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $sys = 0
            try { if ($null -ne $i.SystemComponent) { $sys = [int]$i.SystemComponent } } catch { }
            if ($sys -eq 1) { continue }

            $quiet = ''; $uninst = ''; $publisher = ''
            try { $quiet = [string]$i.QuietUninstallString } catch { }
            try { $uninst = [string]$i.UninstallString } catch { }
            try { $publisher = [string]$i.Publisher } catch { }

            [void]$apps.Add([pscustomobject]@{
                Name      = $name.Trim()
                Publisher = $publisher
                Quiet     = $quiet
                Uninstall = $uninst
                Key       = $i.PSChildName
            })
        }
    }
    return $apps
}

function Get-TargetWin32 {
    $all = Get-InstalledWin32
    $hits = New-Object System.Collections.ArrayList
    foreach ($app in $all) {
        $text = "$($app.Name) $($app.Publisher)"
        foreach ($p in $script:Win32Patterns) {
            if ($text -match $p) {
                [void]$hits.Add($app)
                break
            }
        }
    }
    return $hits
}

function Get-TargetTasks {
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue) } catch { return @() }
    $hits = New-Object System.Collections.ArrayList
    foreach ($t in $tasks) {
        if ($t.TaskPath -like '\Microsoft\Windows\*') { continue }
        if ($t.State -eq 'Disabled') { continue }
        $text = "$($t.TaskPath)$($t.TaskName) $($t.Author)"
        foreach ($p in $script:TaskPatterns) {
            if ($text -match [regex]::Escape($p)) {
                [void]$hits.Add($t)
                break
            }
        }
    }
    return $hits
}

#endregion

#region ------------------------------------------------------------------ azioni

function Remove-TargetAppx {
    param([string]$Title, [string[]]$Patterns)

    Write-Log $Title 'Step'
    $targets = @(Get-TargetAppx -Patterns $Patterns)
    if ($targets.Count -eq 0) {
        Write-Log 'Niente da rimuovere.' 'Ok'
        return
    }

    foreach ($t in $targets) {
        $label = "$($t.Name) [$($t.Kind)]"
        if ($t.NonRemovable) {
            Write-Log "$label - pacchetto di sistema, salto." 'Dim'
            $script:Stats.Skipped++
            continue
        }
        if ($script:DryRun) {
            Write-Log "rimuoverei $label" 'Warn'
            continue
        }
        try {
            if ($t.Kind -eq 'Installed') {
                Remove-AppxPackage -Package $t.FullName -AllUsers -ErrorAction Stop
                $script:Stats.AppxRemoved++
            } else {
                Remove-AppxProvisionedPackage -Online -PackageName $t.FullName -ErrorAction Stop | Out-Null
                $script:Stats.ProvisionedRemoved++
            }
            Write-Log "rimosso $label" 'Ok'
        } catch {
            $msg = $_.Exception.Message.Trim()
            if ($msg -match '0x80073CFA|non rimovibile|cannot be removed') {
                Write-Log "$label - non rimovibile dal sistema." 'Dim'
                $script:Stats.Skipped++
            } else {
                Write-Log "$label - errore: $msg" 'Err'
                $script:Stats.Failed++
            }
        }
    }
}

function Invoke-Win32Uninstall {
    param([pscustomobject]$App)

    $cmd = ''
    $cmdArgs = ''

    if ($App.Uninstall -match 'msiexec') {
        $guid = ''
        if ($App.Uninstall -match '(\{[0-9A-Fa-f\-]{36}\})') { $guid = $Matches[1] }
        if (-not $guid) { return 'no-silent' }
        $cmd = 'msiexec.exe'
        $cmdArgs = "/x $guid /qn /norestart"
    } elseif ($App.Quiet) {
        $cmd = 'cmd.exe'
        $cmdArgs = "/c `"$($App.Quiet)`""
    } elseif ($env:DEBLOAT_FORCEWIN32 -eq '1' -and $App.Uninstall) {
        $cmd = 'cmd.exe'
        $cmdArgs = "/c `"$($App.Uninstall)`""
    } else {
        return 'no-silent'
    }

    $p = Start-Process -FilePath $cmd -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(300000)) {
        try { $p.Kill() } catch { }
        return 'timeout'
    }
    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641) { return 'ok' }
    return "exit $($p.ExitCode)"
}

function Remove-TargetWin32 {
    Write-Log 'Programmi Win32 (trial, antivirus OEM, updater)' 'Step'
    $targets = @(Get-TargetWin32)
    if ($targets.Count -eq 0) {
        Write-Log 'Nessun programma sospetto trovato.' 'Ok'
        return
    }

    Write-Log "Trovati $($targets.Count) programmi:" 'Info'
    foreach ($t in $targets) { Write-Log $t.Name 'Dim' }

    if (-not $script:DryRun) {
        Write-Host ''
        Write-Log 'La disinstallazione Win32 NON e reversibile senza reinstallare.' 'Warn'
        $ans = Read-Host '    Procedo con la disinstallazione? (s/N)'
        if ($ans -notmatch '^(s|S|y|Y)$') {
            Write-Log 'Sezione Win32 annullata.' 'Info'
            return
        }
    }

    foreach ($t in $targets) {
        if ($script:DryRun) {
            Write-Log "disinstallerei $($t.Name)" 'Warn'
            continue
        }
        Write-Log "disinstallo $($t.Name)..." 'Info'
        try {
            $res = Invoke-Win32Uninstall -App $t
            if ($res -eq 'ok') {
                Write-Log "rimosso $($t.Name)" 'Ok'
                $script:Stats.Win32Removed++
            } elseif ($res -eq 'no-silent') {
                Write-Log "$($t.Name) - nessuna disinstallazione silenziosa, rimuovilo a mano (o usa DEBLOAT_FORCEWIN32=1)." 'Warn'
                $script:Stats.Skipped++
            } else {
                Write-Log "$($t.Name) - esito: $res" 'Err'
                $script:Stats.Failed++
            }
        } catch {
            Write-Log "$($t.Name) - errore: $($_.Exception.Message.Trim())" 'Err'
            $script:Stats.Failed++
        }
    }
}

function Disable-TargetTasks {
    Write-Log 'Attivita pianificate OEM (disattivazione, reversibile)' 'Step'
    $targets = @(Get-TargetTasks)
    if ($targets.Count -eq 0) {
        Write-Log 'Nessuna attivita da disattivare.' 'Ok'
        return
    }
    foreach ($t in $targets) {
        $label = "$($t.TaskPath)$($t.TaskName)"
        if ($script:DryRun) {
            Write-Log "disattiverei $label" 'Warn'
            continue
        }
        try {
            Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
            Write-Log "disattivata $label" 'Ok'
            $script:Stats.TasksDisabled++
        } catch {
            Write-Log "$label - errore: $($_.Exception.Message.Trim())" 'Err'
            $script:Stats.Failed++
        }
    }
}

# Chiavi che bloccano il ritorno automatico di app suggerite e pubblicita'.
$script:BlockKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableConsumerAccountStateContent'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Value = 0 }
)

function Block-BloatReinstall {
    Write-Log 'Blocco reinstallazione automatica app suggerite' 'Step'
    foreach ($k in $script:BlockKeys) {
        if ($script:DryRun) {
            Write-Log "imposterei $($k.Path)\$($k.Name) = $($k.Value)" 'Warn'
            continue
        }
        try {
            if (-not (Test-Path $k.Path)) { New-Item -Path $k.Path -Force | Out-Null }
            New-ItemProperty -Path $k.Path -Name $k.Name -Value $k.Value -PropertyType DWord -Force | Out-Null
            Write-Log "$($k.Name) = $($k.Value)" 'Ok'
        } catch {
            Write-Log "$($k.Name) - errore: $($_.Exception.Message.Trim())" 'Err'
            $script:Stats.Failed++
        }
    }
    Write-Log 'Nota: alcune policy CloudContent valgono su Pro/Enterprise.' 'Dim'
}

function Unblock-BloatReinstall {
    Write-Log 'Ripristino impostazioni predefinite (rimozione blocchi)' 'Step'
    foreach ($k in $script:BlockKeys) {
        if ($script:DryRun) {
            Write-Log "rimuoverei $($k.Path)\$($k.Name)" 'Warn'
            continue
        }
        try {
            if (Test-Path $k.Path) {
                Remove-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction SilentlyContinue
            }
            Write-Log "ripristinato $($k.Name)" 'Ok'
        } catch {
            Write-Log "$($k.Name) - errore: $($_.Exception.Message.Trim())" 'Err'
        }
    }
}

function Invoke-Scan {
    Write-Log 'Analisi del sistema (nessuna modifica)' 'Step'

    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "PC: $($cs.Manufacturer) $($cs.Model)" 'Info'
    Write-Log "OS: $($os.Caption) build $($os.BuildNumber)" 'Info'
    Write-Host ''

    $ms = @(Get-TargetAppx -Patterns $script:AppxMicrosoft)
    $oem = @(Get-TargetAppx -Patterns $script:AppxOem)
    $w32 = @(Get-TargetWin32)
    $tsk = @(Get-TargetTasks)

    function Show-Group {
        param([string]$Title, $Items, [string]$Prop)
        Write-Log "$Title : $($Items.Count)" 'Info'
        foreach ($i in $Items) {
            $text = $i.$Prop
            if ($Prop -eq 'TaskName') { $text = "$($i.TaskPath)$($i.TaskName)" }
            if ($Prop -eq 'Name' -and $i.PSObject.Properties.Name -contains 'Kind') { $text = "$($i.Name) [$($i.Kind)]" }
            Write-Log $text 'Dim'
        }
        Write-Host ''
    }

    Show-Group 'AppX Microsoft consumer' $ms 'Name'
    Show-Group 'AppX OEM / terze parti' $oem 'Name'
    Show-Group 'Programmi Win32 sospetti' $w32 'Name'
    Show-Group 'Attivita pianificate OEM attive' $tsk 'TaskName'

    $blocked = 0
    foreach ($k in $script:BlockKeys) {
        try {
            $v = Get-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction Stop
            if ([int]$v.$($k.Name) -eq $k.Value) { $blocked++ }
        } catch { }
    }
    Write-Log "Blocchi anti-reinstallazione attivi: $blocked / $($script:BlockKeys.Count)" 'Info'
}

function Show-Summary {
    Write-Host ''
    Write-Log 'Riepilogo' 'Step'
    foreach ($k in $script:Stats.Keys) {
        Write-Log ("{0,-20} {1}" -f $k, $script:Stats[$k]) 'Info'
    }
    Write-Log "Log completo: $($script:LogFile)" 'Dim'
    if (-not $script:DryRun -and ($script:Stats.AppxRemoved + $script:Stats.Win32Removed) -gt 0) {
        Write-Log 'Riavvia il PC per completare la pulizia.' 'Warn'
    }
}

#endregion

#region -------------------------------------------------------------------- main

function Invoke-Stage {
    param([string]$Stage)

    switch ($Stage) {
        'scan'   { Invoke-Scan }
        'appx'   { New-RestorePoint; Remove-TargetAppx 'AppX Microsoft consumer' $script:AppxMicrosoft }
        'oem'    { New-RestorePoint; Remove-TargetAppx 'AppX OEM / terze parti' $script:AppxOem }
        'win32'  { New-RestorePoint; Remove-TargetWin32 }
        'tasks'  { Disable-TargetTasks }
        'block'  { Block-BloatReinstall }
        'unblock'{ Unblock-BloatReinstall }
        'all'    {
            New-RestorePoint
            Remove-TargetAppx 'AppX Microsoft consumer' $script:AppxMicrosoft
            Remove-TargetAppx 'AppX OEM / terze parti' $script:AppxOem
            Remove-TargetWin32
            Disable-TargetTasks
            Block-BloatReinstall
        }
        default  { Write-Log "Modalita sconosciuta: $Stage" 'Err' }
    }
}

#region ------------------------------------------------------------------- menu

# Voci del menu debloat. 'Danger' segna cio' che non e' reversibile.
$script:MenuItems = @(
    @{ Key = '1'; Stage = 'scan';    Label = 'Analizza il sistema';        Hint = 'solo lettura, non modifica niente' }
    @{ Key = '2'; Stage = 'appx';    Label = 'AppX Microsoft consumer';    Hint = 'Xbox, Bing, Copilot, widget' }
    @{ Key = '3'; Stage = 'oem';     Label = 'AppX OEM e terze parti';     Hint = 'giochi sponsorizzati, suite del produttore' }
    @{ Key = '4'; Stage = 'win32';   Label = 'Programmi Win32';            Hint = 'McAfee, trial, updater OEM'; Danger = $true }
    @{ Key = '5'; Stage = 'tasks';   Label = 'Attivita pianificate OEM';   Hint = 'solo disattivate, reversibile' }
    @{ Key = '6'; Stage = 'block';   Label = 'Blocca app suggerite';       Hint = 'impedisce il ritorno del bloatware' }
    @{ Key = '7'; Stage = 'all';     Label = 'Esegui tutto';               Hint = 'dalla 2 alla 6, in sequenza'; Danger = $true; Accent = $true }
    @{ Key = '8'; Stage = 'unblock'; Label = 'Annulla i blocchi';          Hint = 'ripristina i valori predefiniti'; Muted = $true }
)

function Get-MenuKey {
    # RawUI.ReadKey e' piu' affidabile di [Console]::ReadKey sotto PowerShell 5.1.
    try {
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return @{ Code = [int]$k.VirtualKeyCode; Char = [string]$k.Character }
    } catch {
        return $null
    }
}

function Get-Fit {
    # Taglia il testo perche' stia nello spazio dato, senza mai andare a capo.
    param([string]$Text, [int]$Max)
    if ($Max -le 0) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return $Text.Substring(0, $Max) }
    return $Text.Substring(0, $Max - 1) + '.'
}

function Get-BoxWidth {
    # Larghezza della cornice: due spazi di rientro a sinistra e a destra.
    $w = $script:Ui.Width - 4
    if ($w -gt 58) { $w = 58 }
    if ($w -lt 24) { $w = 24 }
    return [int]$w
}

function Write-Frame {
    param([string]$Title, [string]$Right = '')

    $w = Get-BoxWidth
    $h = (G 'Horizontal')
    $top = (G 'TopLeft') + ($h * ($w - 2)) + (G 'TopRight')
    $bot = (G 'BottomLeft') + ($h * ($w - 2)) + (G 'BottomRight')
    $v = (G 'Vertical')

    $inner = $w - 4
    $left = Get-Fit $Title $inner
    $pad = $inner - $left.Length - $Right.Length
    if ($pad -lt 1) { $Right = ''; $pad = $inner - $left.Length }
    if ($pad -lt 0) { $pad = 0 }

    Write-Host ('  ' + (Ansi -Text $top -Fg $script:Pal.Brand1))
    Write-Host ('  ' + (Ansi -Text $v -Fg $script:Pal.Brand1) + ' ' +
                (Ansi -Text $left -Fg $script:Pal.Brand2 -Bold) +
                (' ' * $pad) +
                (Ansi -Text $Right -Fg $script:Pal.Muted) + ' ' +
                (Ansi -Text $v -Fg $script:Pal.Brand1))
    Write-Host ('  ' + (Ansi -Text $bot -Fg $script:Pal.Brand1))
}

function Show-MenuScreen {
    param([int]$Index)

    Clear-Screen
    Write-Host ''
    Write-GradientLine -Text ("DEBLOAT  " + (G 'Dot') + "  v$($script:Version)") `
                       -From $script:Pal.Brand1 -To $script:Pal.Brand2

    # Saluto anche qui: il menu e' la schermata su cui si torna sempre, lo splash
    # lo si vede una volta sola.
    $name = Get-DisplayName
    $box = Get-BoxWidth
    # Il nome va in colore brand: e' la parola che deve saltare all'occhio.
    $name = Get-Fit $name ($box - 12)
    Write-Host ('  ' + (Ansi -Text 'Bentornato, ' -Fg $script:Pal.Muted) +
                (Ansi -Text $name -Fg $script:Pal.Brand2 -Bold))
    Write-Host ''

    # Scheda hardware: quante righe stanno dipende dall'altezza della console,
    # perche' il menu sotto deve restare visibile per intero.
    $rows = @(Get-SysRows)
    $fixed = 14 + $script:MenuItems.Count   # intestazione, cornice, voci, aiuti
    $room = $script:Ui.Height - $fixed
    if ($room -lt $rows.Count) {
        if ($room -lt 2) { $room = 2 }
        $rows = @($rows | Sort-Object { $_.P } | Select-Object -First $room |
                  Sort-Object { $script:SysOrder.IndexOf($_.L) })
    }

    $labW = 0
    foreach ($r in $rows) { if ($r.L.Length -gt $labW) { $labW = $r.L.Length } }
    foreach ($r in $rows) {
        $val = Get-Fit $r.V ($script:Ui.Width - $labW - 8)
        Write-Host ('   ' + (Ansi -Text $r.L.PadRight($labW + 2) -Fg $script:Pal.Muted) +
                    (Ansi -Text $val -Fg $script:Pal.Text))
    }
    Write-Host ''

    $mode = if ($script:DryRun) { 'DRY-RUN' } else { 'LIVE' }
    Write-Frame -Title 'Cosa vuoi fare' -Right $mode
    Write-Host ''

    for ($i = 0; $i -lt $script:MenuItems.Count; $i++) {
        $it = $script:MenuItems[$i]
        $sel = ($i -eq $Index)

        $tone = $script:Pal.Text
        if ($it.Muted)  { $tone = $script:Pal.Muted }
        if ($it.Accent) { $tone = $script:Pal.Warn }
        if ($it.Danger -and -not $it.Accent) { $tone = $script:Pal.Text }

        $mark = if ($sel) { (G 'Arrow') } else { ' ' }
        $box = Get-BoxWidth

        if ($sel) {
            # La riga selezionata e' larga come la cornice, per dare il blocco pieno.
            $label = Get-Fit "$($it.Key)  $($it.Label)" ($box - 4)
            $plain = " $mark  " + $label.PadRight($box - 4)
            Write-Host ('  ' + (Ansi -Text $plain -Fg $script:Pal.Brand2 -Bg $script:Pal.Sel -Bold))
            Write-Host ('      ' + (Ansi -Text (Get-Fit $it.Hint ($script:Ui.Width - 7)) -Fg $script:Pal.Muted))
        } else {
            $label = Get-Fit "$($it.Key)  $($it.Label)" ($box - 4)
            Write-Host ('   ' + (Ansi -Text "   $label" -Fg $tone))
        }
    }

    Write-Host ''
    # La riga dei comandi ha due versioni: si sceglie la lunga solo se ci sta
    # davvero, misurandola, perche' 80 colonne e' la larghezza di default.
    $sep = '  ' + (G 'Dot') + '  '
    if ($script:Ui.Keys) {
        $long  = 'frecce per muoverti' + $sep + 'invio per confermare' + $sep +
                 'D dry-run' + $sep + 'L log' + $sep + 'Q esci'
        $short = 'frecce' + $sep + 'invio' + $sep + 'D' + $sep + 'L' + $sep + 'Q'
    } else {
        $long  = 'digita il numero della voce' + $sep + 'D dry-run' + $sep + 'L log' + $sep + 'Q esci'
        $short = 'numero voce' + $sep + 'D' + $sep + 'L' + $sep + 'Q'
    }
    $keys = if (($long.Length + 2) -le ($script:Ui.Width - 1)) { $long } else { $short }
    Write-Host ('  ' + (Ansi -Text $keys -Fg $script:Pal.Muted))
    Write-Host ''
}

function Confirm-Action {
    param([string]$Text, [string]$Question = 'Confermo')

    Write-Host ''
    Write-Log $Text 'Warn'
    Show-Cursor
    $ans = Read-Host "      $Question (s/N)"
    Hide-Cursor
    return ($ans -match '^\s*(s|si|y|yes)\s*$')
}

function Invoke-MenuItem {
    param([hashtable]$Item)

    Clear-Screen
    Write-Host ''
    Write-GradientLine -Text $Item.Label.ToUpper() -From $script:Pal.Brand1 -To $script:Pal.Brand2
    Write-Host ''

    if ($Item.Danger -and -not $script:DryRun) {
        $msg = if ($Item.Stage -eq 'all') {
            'Verranno rimossi app e programmi preinstallati.'
        } else {
            'La disinstallazione Win32 non e reversibile senza reinstallare.'
        }
        if (-not (Confirm-Action $msg)) {
            Write-Log 'Annullato.' 'Info'
            Wait-Enter
            return
        }
    }

    Invoke-Stage $Item.Stage
    if ($Item.Stage -ne 'scan' -and $Item.Stage -ne 'block' -and $Item.Stage -ne 'unblock') {
        Show-Summary
    }
    Wait-Enter
}

function Wait-Enter {
    Write-Host ''
    Write-Host ('  ' + (Ansi -Text 'premi un tasto per tornare al menu' -Fg $script:Pal.Muted))
    if ($script:Ui.Keys) { [void](Get-MenuKey) } else { [void](Read-Host) }
}

function Start-Interactive {
    $idx = 0
    $empty = 0
    $count = $script:MenuItems.Count

    try {
        Hide-Cursor
        while ($true) {
            Show-MenuScreen -Index $idx

            if (-not $script:Ui.Keys) {
                # Senza tastiera diretta (input rediretto) si torna alla scelta numerica.
                Show-Cursor
                $typed = Read-Host '  Scelta'
                Hide-Cursor
                if ($null -eq $typed) { return }
                $c = $typed.Trim().ToUpper()
                # Con lo stdin esaurito Read-Host torna vuoto all'infinito: si esce.
                if ($c -eq '') {
                    $empty++
                    if ($empty -ge 3) { return }
                    continue
                }
                $empty = 0
                if ($c -eq 'Q') { return }
                if ($c -eq 'D') { $script:DryRun = -not $script:DryRun; continue }
                if ($c -eq 'L') { Open-Log; continue }
                $hit = $script:MenuItems | Where-Object { $_.Key -eq $c } | Select-Object -First 1
                if ($hit) { Invoke-MenuItem $hit }
                continue
            }

            $k = Get-MenuKey
            if ($null -eq $k) { return }

            # Niente switch qui: in PowerShell 'continue' dentro uno switch non
            # salta il codice che segue, quindi i tasti freccia ricadrebbero
            # anche nella gestione dei caratteri.
            $code = $k.Code
            if ($code -eq 38) { $idx = ($idx - 1 + $count) % $count; continue }  # su
            if ($code -eq 40) { $idx = ($idx + 1) % $count; continue }           # giu
            if ($code -eq 36) { $idx = 0; continue }                             # home
            if ($code -eq 35) { $idx = $count - 1; continue }                    # fine
            if ($code -eq 13) { Invoke-MenuItem $script:MenuItems[$idx]; continue }  # invio
            if ($code -eq 27) { return }                                         # esc

            $ch = $k.Char.ToUpper()
            if ($ch -eq 'Q') { return }
            if ($ch -eq 'K') { $idx = ($idx - 1 + $count) % $count; continue }
            if ($ch -eq 'J') { $idx = ($idx + 1) % $count; continue }
            if ($ch -eq 'D') { $script:DryRun = -not $script:DryRun; continue }
            if ($ch -eq 'L') { Open-Log; continue }

            $hit = $script:MenuItems | Where-Object { $_.Key -eq $ch } | Select-Object -First 1
            if ($hit) { Invoke-MenuItem $hit }
        }
    } finally {
        Show-Cursor
    }
}

function Open-Log {
    try { Start-Process notepad.exe $script:LogFile } catch { }
}

#endregion

function Main {
    Initialize-Ui

    # L'elevazione avviene prima dello splash: senza privilegi il processo
    # corrente termina subito e l'animazione sarebbe solo tempo perso.
    Assert-Admin
    Initialize-AppxModule

    if ($env:DEBLOAT_MODE) {
        Write-Banner
        Write-Log "Modalita non interattiva: $($env:DEBLOAT_MODE)" 'Info'
        Invoke-Stage ($env:DEBLOAT_MODE.Trim().ToLower())
        Show-Summary
        return
    }

    if (-not [Environment]::UserInteractive -or -not $script:Ui.Keys) {
        Write-Banner
        Write-Log 'Sessione non interattiva: eseguo solo l analisi.' 'Warn'
        Invoke-Scan
        return
    }

    Show-Splash
    Show-InitSteps
    Start-Interactive
}

try {
    Main
} catch {
    Show-Cursor
    Write-Log "Errore non gestito: $($_.Exception.Message)" 'Err'
    Write-Log $_.ScriptStackTrace 'Dim'
    exit 1
} finally {
    Show-Cursor
}

#endregion
