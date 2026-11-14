<#
  Desktop capsule for DeepSeek Harness.

  Renders the agent status that the desktop-capsule plugin writes to
  <Root>\status.json: a small always-on-top pill plus corner notifications for
  approvals, questions, completions and failures. Clicking anywhere activates
  the DeepSeek Harness window.

  This file is deliberately ASCII-only: Windows PowerShell 5.1 decodes a
  BOM-less script as ANSI. Localized copy lives in strings.json.

  Launched by the host plugin; standalone use for testing is:
    powershell -NoProfile -ExecutionPolicy Bypass -File capsule.ps1 -Root <dir> -TargetPid <pid>
#>
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$TargetPid = 0
)

$ErrorActionPreference = 'Stop'
$script:statusPath = Join-Path $Root 'status.json'
$script:logPath = Join-Path $Root 'capsule.log'
$script:prefsPath = Join-Path $Root 'prefs.json'
$script:targetPid = $TargetPid
$script:lastKey = ''
$script:toast = $null
$script:toastTimer = $null
$script:app = $null
$script:pulse = $null

# English fallbacks; strings.json overrides them when present and readable.
$strings = @{    connected            = 'Desktop capsule connected'
    idle                 = 'Idle'
    running              = 'Working'
    runningTurn          = 'Working - turn {0}'
    approval             = 'Waiting for approval - {0}'
    approvalPlain        = 'Waiting for approval'
    question             = 'Waiting for your answer - {0}'
    questionPlain        = 'Waiting for your answer'
    error                = 'Failed - {0}'
    errorPlain           = 'Failed'
    done                 = 'This turn is done'
    clickMe              = 'Click to open'
    moreSessions         = ' - {0} more sessions'
    notifyApprovalTitle  = 'Approval needed'
    notifyQuestionTitle  = 'Answer needed'
    notifyErrorTitle     = 'Failed'
    notifyDoneTitle      = 'Turn finished'
    notifyClick          = 'Click to return to DSH'
    notifyApprovalBody   = '{0} - click to return to DSH'
    notifyDoneBody       = 'Took {0} - click to return to DSH'
}

function Write-CapsuleLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -Encoding UTF8
    } catch {
        # Logging is best effort.
    }
}

try {
    $stringsPath = Join-Path $PSScriptRoot 'strings.json'
    if (Test-Path -LiteralPath $stringsPath) {
        $overrides = Get-Content -LiteralPath $stringsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $overrides.PSObject.Properties) {
            $strings[$property.Name] = [string]$property.Value
        }
    }
} catch {
    Write-CapsuleLog "cannot read strings.json: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $Root)) {
    try { New-Item -ItemType Directory -Force -Path $Root | Out-Null } catch { exit 0 }
}

# --- single instance ------------------------------------------------------
$lockPath = Join-Path $Root 'capsule.pid'
try {
    if (Test-Path -LiteralPath $lockPath) {
        $old = (Get-Content -LiteralPath $lockPath -Raw).Trim()
        if ($old -match '^\d+$' -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {
            Write-CapsuleLog "another capsule (pid $old) is already running; exiting"
            exit 0
        }
    }
    Set-Content -LiteralPath $lockPath -Value $PID -Encoding ASCII
} catch {
    # A lock we cannot write must not prevent the capsule from starting.
}

Write-CapsuleLog "capsule start pid=$PID targetPid=$script:targetPid root=$Root"

# --- assemblies and native helpers ---------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DshCapsuleWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO info);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public struct RECT { public int Left, Top, Right, Bottom; }
    public struct POINT { public int X, Y; }
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
}
"@

try { [DshCapsuleWin32]::SetProcessDPIAware() | Out-Null } catch { }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DshCapsuleGlass {
    [StructLayout(LayoutKind.Sequential)]
    public struct AccentPolicy {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct CompositionAttributeData {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }
    [DllImport("user32.dll")]
    public static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref CompositionAttributeData data);
}
"@

function Enable-Glass {
    # ACCENT_ENABLE_ACRYLICBLURBEHIND: the DWM blurs whatever is behind the
    # window, so the pill reads as frosted glass instead of a flat panel.
    param([IntPtr]$Handle, [int]$Tint)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    $pointer = [IntPtr]::Zero
    try {
        $policy = New-Object DshCapsuleGlass+AccentPolicy
        $policy.AccentState = 4
        $policy.AccentFlags = 2
        $policy.GradientColor = $Tint
        $policy.AnimationId = 0
        $size = 16
        $pointer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        [System.Runtime.InteropServices.Marshal]::StructureToPtr($policy, $pointer, $false)
        $data = New-Object DshCapsuleGlass+CompositionAttributeData
        $data.Attribute = 19
        $data.Data = $pointer
        $data.SizeOfData = $size
        $result = [DshCapsuleGlass]::SetWindowCompositionAttribute($Handle, [ref]$data)
        if ($result -eq 0) {
            Write-CapsuleLog "acrylic glass rejected by this desktop (tint $Tint)"
            return $false
        }
        return $true
    } catch {
        Write-CapsuleLog "glass failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
    }
}

# 0xAABBGGRR acrylic tint: dark smoked glass at ~60% opacity. PowerShell may
# read a high-bit hex literal as signed already, so normalise to Int32.
# DWM acrylic fills the window rectangle, which paints a dark box outside the
# pill; keep it off until a shape-respecting backdrop is available.
$script:useAcrylic = $false
$script:glassTintValue = [int64]0x7A241E19
if ($script:glassTintValue -gt 2147483647) { $script:glassTintValue -= 4294967296 }
if ($script:glassTintValue -lt -2147483648) { $script:glassTintValue += 4294967296 }
$script:glassTint = [int]$script:glassTintValue

function Set-RoundedWindowRegion {
    # A window region gives rounded corners without a layered window, which
    # some desktops fail to composite for a hidden-console child process.
    param([System.Windows.Window]$Target, [int]$Radius)
    try {
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($Target)
        $hwnd = $helper.Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $rect = New-Object DshCapsuleWin32+RECT
        [DshCapsuleWin32]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -le 0 -or $height -le 0) { return }
        $region = [DshCapsuleWin32]::CreateRoundRectRgn(0, 0, $width + 1, $height + 1, $Radius, $Radius)
        [DshCapsuleWin32]::SetWindowRgn($hwnd, $region, $true) | Out-Null
    } catch {
        Write-CapsuleLog "rounded region failed: $($_.Exception.Message)"
    }
}

function Get-Brush {
    param([string]$Hex)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
}

function Activate-Window {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    try {
        if ([DshCapsuleWin32]::IsIconic($Handle)) { [DshCapsuleWin32]::ShowWindow($Handle, 9) | Out-Null }
        [DshCapsuleWin32]::BringWindowToTop($Handle) | Out-Null
        if ([DshCapsuleWin32]::SetForegroundWindow($Handle)) { return $true }
        # The foreground lock refuses cross-process activation; attach to the
        # foreground thread's input queue for one attempt.
        $foreground = [DshCapsuleWin32]::GetForegroundWindow()
        $ignored = 0
        $foregroundThread = [DshCapsuleWin32]::GetWindowThreadProcessId($foreground, [ref]$ignored)
        $currentThread = [DshCapsuleWin32]::GetCurrentThreadId()
        if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread) {
            [DshCapsuleWin32]::AttachThreadInput($currentThread, $foregroundThread, $true) | Out-Null
            try {
                [DshCapsuleWin32]::SetForegroundWindow($Handle) | Out-Null
                [DshCapsuleWin32]::BringWindowToTop($Handle) | Out-Null
            } finally {
                [DshCapsuleWin32]::AttachThreadInput($currentThread, $foregroundThread, $false) | Out-Null
            }
        }
        return $true
    } catch {
        Write-CapsuleLog "activation failed: $($_.Exception.Message)"
        return $false
    }
}

function Focus-Harness {
    $handles = New-Object System.Collections.Generic.List[IntPtr]
    if ($script:targetPid -gt 0) {
        try {
            $own = [System.Diagnostics.Process]::GetProcessById($script:targetPid)
            if ($own.MainWindowHandle -ne [IntPtr]::Zero) { $handles.Add($own.MainWindowHandle) }
        } catch {
            # The host pid may not own the visible window.
        }
    }
    try {
        foreach ($candidate in @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
            if ($candidate.MainWindowHandle -ne [IntPtr]::Zero -and -not $handles.Contains($candidate.MainWindowHandle)) {
                $handles.Add($candidate.MainWindowHandle)
            }
        }
    } catch {
        Write-CapsuleLog "window lookup failed: $($_.Exception.Message)"
    }
    if ($handles.Count -eq 0) {
        if ($script:targetPid -gt 0) {
            try { [Microsoft.VisualBasic.Interaction]::AppActivate($script:targetPid) | Out-Null } catch { }
        }
        Write-CapsuleLog 'no DeepSeek Harness window found to activate'
        return
    }
    foreach ($handle in $handles) {
        if (Activate-Window -Handle $handle) { return }
    }
}

function Format-Elapsed {
    param([double]$Ms)
    $total = [math]::Max(0, [math]::Floor($Ms / 1000))
    if ($total -ge 3600) {
        return ('{0}:{1:00}:{2:00}' -f [math]::Floor($total / 3600), [math]::Floor(($total % 3600) / 60), ($total % 60))
    }
    if ($total -ge 60) {
        return ('{0:00}:{1:00}' -f [math]::Floor($total / 60), ($total % 60))
    }
    return ('0:{0:00}' -f $total)
}

# --- capsule window -------------------------------------------------------
$app = [System.Windows.Application]::new()
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:app = $app

$window = [System.Windows.Window]::new()
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.Width = 340
$window.Height = 56
$window.Left = 600
$window.Top = 400
$window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual

function New-GlassBrush {
    param([string]$Top, [string]$Middle, [string]$Bottom)
    $brush = [System.Windows.Media.LinearGradientBrush]::new()
    $brush.StartPoint = [System.Windows.Point]::new(0.5, 0)
    $brush.EndPoint = [System.Windows.Point]::new(0.5, 1)
    $topColor = ([System.Windows.Media.BrushConverter]::new().ConvertFromString($Top)).Color
    $middleColor = ([System.Windows.Media.BrushConverter]::new().ConvertFromString($Middle)).Color
    $bottomColor = ([System.Windows.Media.BrushConverter]::new().ConvertFromString($Bottom)).Color
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($topColor, 0.0))
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($middleColor, 0.45))
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($bottomColor, 1.0))
    return $brush
}

# Three stacked layers inside one pill: a smoked base for legibility, a white
# sheen for the glass read, and a hairline rim. Nothing paints the rectangle
# outside the pill, so the desktop stays visible around and through it.
$stack = [System.Windows.Controls.Grid]::new()

$base = [System.Windows.Controls.Border]::new()
$base.CornerRadius = [System.Windows.CornerRadius]::new(28)
$base.Background = Get-Brush '#7A0B0E14'

$sheen = [System.Windows.Controls.Border]::new()
$sheen.CornerRadius = [System.Windows.CornerRadius]::new(28)
$sheen.Background = New-GlassBrush -Top '#33FFFFFF' -Middle '#0FFFFFFF' -Bottom '#04FFFFFF'

$rim = [System.Windows.Controls.Border]::new()
$rim.CornerRadius = [System.Windows.CornerRadius]::new(28)
$rim.BorderThickness = [System.Windows.Thickness]::new(1)
$rim.BorderBrush = Get-Brush '#59FFFFFF'

$grid = [System.Windows.Controls.Grid]::new()
$autoColumn = [System.Windows.Controls.ColumnDefinition]::new()
$autoColumn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
$growColumn = [System.Windows.Controls.ColumnDefinition]::new()
$growColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$grid.ColumnDefinitions.Add($autoColumn)
$grid.ColumnDefinitions.Add($growColumn)

$dot = [System.Windows.Shapes.Ellipse]::new()
$dot.Width = 10
$dot.Height = 10
$dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$dot.Margin = [System.Windows.Thickness]::new(0, 0, 11, 0)
$dot.Fill = Get-Brush '#6B7280'
[System.Windows.Controls.Grid]::SetColumn($dot, 0)

$label = [System.Windows.Controls.TextBlock]::new()
$label.FontSize = 13
$label.FontWeight = [System.Windows.FontWeights]::SemiBold
$label.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI, Segoe UI')
$label.Foreground = Get-Brush '#FFF7FAFD'
$label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$label.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
$label.Text = $strings.connected
$textShadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
$textShadow.BlurRadius = 6
$textShadow.ShadowDepth = 0
$textShadow.Opacity = 0.75
$textShadow.Color = [System.Windows.Media.Colors]::Black
$label.Effect = $textShadow
[System.Windows.Controls.Grid]::SetColumn($label, 1)

$grid.Children.Add($dot) | Out-Null
$grid.Children.Add($label) | Out-Null
$grid.Margin = [System.Windows.Thickness]::new(16, 0, 16, 0)

$stack.Children.Add($base) | Out-Null
$stack.Children.Add($sheen) | Out-Null
$stack.Children.Add($grid) | Out-Null
$stack.Children.Add($rim) | Out-Null
$window.Content = $stack

# Positions are applied in physical pixels through Win32 after the HWND
# exists: WPF's device-independent units double-scale on a non-96-DPI desktop
# and can place the window off-screen.
function Get-CapsuleHandle {
    param([System.Windows.Window]$Target)
    try {
        return [System.Windows.Interop.WindowInteropHelper]::new($Target).Handle
    } catch {
        return [IntPtr]::Zero
    }
}

function Move-WindowPx {
    param([IntPtr]$Handle, [int]$X, [int]$Y)
    if ($Handle -eq [IntPtr]::Zero) { return }
    [DshCapsuleWin32]::SetWindowPos($Handle, [IntPtr](-1), $X, $Y, 0, 0, 0x0001 -bor 0x0010) | Out-Null
}

function Get-MonitorWorkArea {
    param([IntPtr]$Handle)
    $info = New-Object DshCapsuleWin32+MONITORINFO
    $info.cbSize = 40
    $monitor = [DshCapsuleWin32]::MonitorFromWindow($Handle, 2)
    if ([DshCapsuleWin32]::GetMonitorInfo($monitor, [ref]$info)) { return $info }
    return $null
}

function Restore-CapsulePosition {
    $handle = Get-CapsuleHandle $window
    if ($handle -eq [IntPtr]::Zero) { return }
    $rect = New-Object DshCapsuleWin32+RECT
    [DshCapsuleWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $info = Get-MonitorWorkArea $handle
    if ($null -eq $info) { return }
    $x = $info.rcWork.Right - $width - 18
    $y = $info.rcWork.Bottom - $height - 14
    try {
        if (Test-Path -LiteralPath $script:prefsPath) {
            $prefs = Get-Content -LiteralPath $script:prefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $prefs.left -and $null -ne $prefs.top) {
                $x = [int]$prefs.left
                $y = [int]$prefs.top
            }
        }
    } catch {
        Write-CapsuleLog "cannot read prefs: $($_.Exception.Message)"
    }
    $x = [math]::Max($info.rcWork.Left, [math]::Min($x, $info.rcWork.Right - $width))
    $y = [math]::Max($info.rcWork.Top, [math]::Min($y, $info.rcWork.Bottom - $height))
    Move-WindowPx -Handle $handle -X $x -Y $y
}

# --- dragging -------------------------------------------------------------
$script:dragActive = $false
$script:dragStart = $null
$script:dragOrigin = $null
$script:dragged = $false

$stack.Add_MouseLeftButtonDown({
    $cursor = New-Object DshCapsuleWin32+POINT
    [DshCapsuleWin32]::GetCursorPos([ref]$cursor) | Out-Null
    $handle = Get-CapsuleHandle $window
    $rect = New-Object DshCapsuleWin32+RECT
    [DshCapsuleWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
    $script:dragStart = $cursor
    $script:dragOrigin = @{ Left = $rect.Left; Top = $rect.Top }
    $script:dragActive = $true
    $script:dragged = $false
})

$stack.Add_MouseMove({
    if (-not $script:dragActive) { return }
    if ($_.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    $cursor = New-Object DshCapsuleWin32+POINT
    [DshCapsuleWin32]::GetCursorPos([ref]$cursor) | Out-Null
    $deltaX = $cursor.X - $script:dragStart.X
    $deltaY = $cursor.Y - $script:dragStart.Y
    if ([math]::Abs($deltaX) -gt 4 -or [math]::Abs($deltaY) -gt 4) { $script:dragged = $true }
    if ($script:dragged) {
        Move-WindowPx -Handle (Get-CapsuleHandle $window) -X ($script:dragOrigin.Left + $deltaX) -Y ($script:dragOrigin.Top + $deltaY)
    }
})

$stack.Add_MouseLeftButtonUp({
    $script:dragActive = $false
    if ($script:dragged) {
        try {
            $handle = Get-CapsuleHandle $window
            $rect = New-Object DshCapsuleWin32+RECT
            [DshCapsuleWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
            @{ left = $rect.Left; top = $rect.Top } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $script:prefsPath -Encoding UTF8
        } catch {
            Write-CapsuleLog "cannot save prefs: $($_.Exception.Message)"
        }
    } else {
        Focus-Harness
    }
    $script:dragged = $false
})

# --- notifications --------------------------------------------------------
function Show-Notification {
    param(
        [string]$Title,
        [string]$Body,
        [string]$Accent,
        [string]$Sound
    )
    try {
        if ($null -ne $script:toast) {
            if ($null -ne $script:toastTimer) { $script:toastTimer.Stop() }
            try { $script:toast.Close() } catch { }
            $script:toast = $null
        }

        $toast = [System.Windows.Window]::new()
        $toast.WindowStyle = [System.Windows.WindowStyle]::None
        $toast.AllowsTransparency = $true
        $toast.Background = [System.Windows.Media.Brushes]::Transparent
        $toast.Topmost = $true
        $toast.ShowInTaskbar = $false
        $toast.ShowActivated = $false
        $toast.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $toast.Width = 330
        $toast.Height = 92
        $toast.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $toast.Opacity = 1

        $toastBorder = [System.Windows.Controls.Border]::new()
        $toastBorder.CornerRadius = [System.Windows.CornerRadius]::new(20)
        $toastBorder.Background = New-GlassBrush -Top '#C0242C38' -Middle '#C0161B23' -Bottom '#C00B0E14'
        $toastBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        $toastBorder.BorderBrush = Get-Brush '#2AFFFFFF'

        $toastGrid = [System.Windows.Controls.Grid]::new()
        $accentColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $accentColumn.Width = [System.Windows.GridLength]::new(4, [System.Windows.GridUnitType]::Pixel)
        $bodyColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $bodyColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $toastGrid.ColumnDefinitions.Add($accentColumn)
        $toastGrid.ColumnDefinitions.Add($bodyColumn)

        $stripe = [System.Windows.Controls.Border]::new()
        $stripe.Background = Get-Brush $Accent
        $stripe.CornerRadius = [System.Windows.CornerRadius]::new(14, 0, 0, 14)
        [System.Windows.Controls.Grid]::SetColumn($stripe, 0)

        $textStack = [System.Windows.Controls.StackPanel]::new()
        $textStack.Margin = [System.Windows.Thickness]::new(16, 12, 16, 12)
        $textStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($textStack, 1)

        $titleBlock = [System.Windows.Controls.TextBlock]::new()
        $titleBlock.Text = $Title
        $titleBlock.FontSize = 13
        $titleBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
        $titleBlock.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI, Segoe UI')
        $titleBlock.Foreground = Get-Brush '#FFF4F6F9'

        $bodyBlock = [System.Windows.Controls.TextBlock]::new()
        $bodyBlock.Text = $Body
        $bodyBlock.FontSize = 11.5
        $bodyBlock.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        $bodyBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $bodyBlock.MaxHeight = 34
        $bodyBlock.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI, Segoe UI')
        $bodyBlock.Foreground = Get-Brush '#FFA7B0BD'

        $textStack.Children.Add($titleBlock) | Out-Null
        $textStack.Children.Add($bodyBlock) | Out-Null
        $toastGrid.Children.Add($stripe) | Out-Null
        $toastGrid.Children.Add($textStack) | Out-Null
        $toastBorder.Child = $toastGrid
        $toast.Content = $toastBorder

        $toast.Add_MouseLeftButtonUp({ Focus-Harness })

        $toast.Show()
        $script:toast = $toast
        $toastHandle = Get-CapsuleHandle $toast
        if ($script:useAcrylic) { Enable-Glass -Handle $toastHandle -Tint $script:glassTint | Out-Null }
        $capsuleRect = New-Object DshCapsuleWin32+RECT
        [DshCapsuleWin32]::GetWindowRect((Get-CapsuleHandle $window), [ref]$capsuleRect) | Out-Null
        $toastRect = New-Object DshCapsuleWin32+RECT
        [DshCapsuleWin32]::GetWindowRect($toastHandle, [ref]$toastRect) | Out-Null
        $toastWidth = $toastRect.Right - $toastRect.Left
        $toastHeight = $toastRect.Bottom - $toastRect.Top
        Move-WindowPx -Handle $toastHandle -X ($capsuleRect.Right - $toastWidth) -Y ($capsuleRect.Top - $toastHeight - 8)
        Set-RoundedWindowRegion -Target $toast -Radius 20

        if ($Sound -ne '') {
            try {
                if ($Sound -eq 'error') { [System.Media.SystemSounds]::Exclamation.Play() }
                elseif ($Sound -eq 'ask') { [System.Media.SystemSounds]::Asterisk.Play() }
                else { [System.Media.SystemSounds]::Beep.Play() }
            } catch { }
        }

        $script:toastTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:toastTimer.Interval = [TimeSpan]::FromMilliseconds(6200)
        $script:toastTimer.Add_Tick({
            $script:toastTimer.Stop()
            if ($null -ne $script:toast) {
                try { $script:toast.Close() } catch { }
                $script:toast = $null
            }
        })
        $script:toastTimer.Start()
    } catch {
        Write-CapsuleLog "notification failed: $($_.Exception.Message)"
    }
}

# --- state rendering ------------------------------------------------------
$priority = @{ approval = 5; question = 5; error = 4; running = 3; done = 2; idle = 1 }
$accents = @{
    approval = '#FFB020'; question = '#FFB020'; error = '#FF5C5C'
    running  = '#6C8CFF'; done = '#35C46A'; idle = '#6B7280'
}

function Update-Capsule {
    try {
        if (-not (Test-Path -LiteralPath $script:statusPath)) { return }
        $raw = Get-Content -LiteralPath $script:statusPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $doc = $raw | ConvertFrom-Json
        if ($null -eq $doc) { return }

        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $age = $now - [double]$doc.updatedAt
        if ($age -gt 30000) {
            Write-CapsuleLog "heartbeat stale (${age}ms); host is gone, exiting"
            if ($null -ne $script:toast) { try { $script:toast.Close() } catch { } }
            $script:app.Shutdown()
            return
        }

        $best = $null
        $bestScore = -1
        $count = 0
        foreach ($session in @($doc.sessions)) {
            if ($null -eq $session) { continue }
            $state = [string]$session.state
            if ($state -ne 'idle' -and $state -ne 'done') { $count += 1 }
            $score = 1
            if ($priority.ContainsKey($state)) { $score = $priority[$state] }
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $session
            }
        }
        if ($null -eq $best) { return }

        $state = [string]$best.state
        $elapsed = $now - [double]$best.since

        $text = $strings.idle
        $right = ''
        switch ($state) {
            'running' {
                $turn = [int]$best.turn
                if ($turn -gt 0) { $text = $strings.runningTurn -f $turn } else { $text = $strings.running }
                $right = Format-Elapsed $elapsed
            }
            'approval' {
                $detail = [string]$best.detail
                if ($detail -ne '') { $text = $strings.approval -f $detail } else { $text = $strings.approvalPlain }
                $right = Format-Elapsed $elapsed
            }
            'question' {
                $detail = [string]$best.detail
                if ($detail -ne '') { $text = $strings.question -f $detail } else { $text = $strings.questionPlain }
                $right = Format-Elapsed $elapsed
            }
            'error' {
                $message = [string]$best.error
                if ($message -ne '') { $text = $strings.error -f $message } else { $text = $strings.errorPlain }
                $right = $strings.clickMe
            }
            'done' {
                $text = $strings.done
                $right = Format-Elapsed ([double]$best.durationMs)
            }
            default {
                $text = $strings.idle
                $right = ''
            }
        }
        if ($right -ne '') { $text = $text + $strings.sep + $right }
        if ($count -gt 1) { $text = $text + ($strings.moreSessions -f ($count - 1)) }

        $label.Text = $text
        $accent = '#6B7280'
        if ($accents.ContainsKey($state)) { $accent = $accents[$state] }
        $dot.Fill = Get-Brush $accent

        if ($state -eq 'running' -or $state -eq 'approval' -or $state -eq 'question') {
            if ($null -eq $script:pulse) {
                $pulse = [System.Windows.Media.Animation.DoubleAnimation]::new(0.3, 1.0)
                $pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(900))
                $pulse.AutoReverse = $true
                $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $script:pulse = $pulse
                $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
            }
        } elseif ($null -ne $script:pulse) {
            $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $dot.Opacity = 1
            $script:pulse = $null
        }

        $key = "$state|$($best.sessionId)|$($best.since)"
        if ($key -ne $script:lastKey) {
            Write-CapsuleLog ("render state={0} text='{1}' right='{2}' count={3}" -f $state, $text, $right, $count)
        }
        if ($script:lastKey -ne '' -and $key -ne $script:lastKey) {
            switch ($state) {
                'approval' {
                    $body = $strings.notifyClick
                    if ([string]$best.detail -ne '') { $body = $strings.notifyApprovalBody -f ([string]$best.detail) }
                    Show-Notification -Title $strings.notifyApprovalTitle -Body $body -Accent '#FFB020' -Sound 'ask'
                }
                'question' {
                    $body = $strings.notifyClick
                    if ([string]$best.detail -ne '') { $body = $strings.notifyApprovalBody -f ([string]$best.detail) }
                    Show-Notification -Title $strings.notifyQuestionTitle -Body $body -Accent '#FFB020' -Sound 'ask'
                }
                'error' {
                    $body = [string]$best.error
                    if ($body -eq '') { $body = $strings.notifyClick }
                    Show-Notification -Title $strings.notifyErrorTitle -Body $body -Accent '#FF5C5C' -Sound 'error'
                }
                'done' {
                    if ([double]$best.durationMs -ge 15000) {
                        Show-Notification -Title $strings.notifyDoneTitle -Body ($strings.notifyDoneBody -f (Format-Elapsed ([double]$best.durationMs))) -Accent '#35C46A' -Sound 'done'
                    }
                }
            }
        }
        $script:lastKey = $key
    } catch {
        Write-CapsuleLog "update failed: $($_.Exception.Message)"
    }
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({ Update-Capsule })
$timer.Start()

$app.Add_Exit({
    try { Remove-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue } catch { }
})

Write-CapsuleLog "window shown"
$window.Show()
if ($script:useAcrylic) { Enable-Glass -Handle (Get-CapsuleHandle $window) -Tint $script:glassTint | Out-Null }
Restore-CapsulePosition
Set-RoundedWindowRegion -Target $window -Radius 28
$app.Run() | Out-Null
Write-CapsuleLog 'capsule exit'
