$LogFile = "$env:SystemRoot\Temp\Launch-PowerShell-System.log"

function Write-Log {
    param([string]$Message)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$time] $Message"
}

Write-Log "==== Inicio ===="
Write-Log "Script corre como: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class NativeMethods
{
    public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    public const uint CREATE_NEW_CONSOLE = 0x00000010;
    public const uint MAXIMUM_ALLOWED = 0x02000000;

    public const int TokenPrimary = 1;
    public const int SecurityImpersonation = 2;
    public const int TokenSessionId = 12;

    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(
        IntPtr ProcessHandle,
        UInt32 DesiredAccess,
        out IntPtr TokenHandle
    );

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool DuplicateTokenEx(
        IntPtr hExistingToken,
        UInt32 dwDesiredAccess,
        IntPtr lpTokenAttributes,
        int ImpersonationLevel,
        int TokenType,
        out IntPtr phNewToken
    );

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool SetTokenInformation(
        IntPtr TokenHandle,
        int TokenInformationClass,
        ref UInt32 TokenInformation,
        UInt32 TokenInformationLength
    );

    [DllImport("userenv.dll", SetLastError=true)]
    public static extern bool CreateEnvironmentBlock(
        out IntPtr lpEnvironment,
        IntPtr hToken,
        bool bInherit
    );

    [DllImport("userenv.dll", SetLastError=true)]
    public static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(
        IntPtr hToken,
        string lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation
    );

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }
}
"@

    $psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $workdir = "$env:WINDIR\System32\WindowsPowerShell\v1.0"

    Write-Log "PowerShell: $psExe"
    Write-Log "WorkDir: $workdir"

    if (!(Test-Path -LiteralPath $psExe)) {
        Write-Log "ERROR: No existe powershell.exe"
        exit 1
    }

    if (!(Test-Path -LiteralPath $workdir)) {
        Write-Log "ERROR: No existe WorkDir"
        exit 2
    }

    # === CAMBIO: SessionId fijo a 2 ===
    $sessionId = [uint32]2
    Write-Log "SessionId forzado: $sessionId"

    $currentToken = [IntPtr]::Zero
    $systemToken = [IntPtr]::Zero
    $envBlock = [IntPtr]::Zero

    $ok = [NativeMethods]::OpenProcessToken(
        [NativeMethods]::GetCurrentProcess(),
        [NativeMethods]::MAXIMUM_ALLOWED,
        [ref]$currentToken
    )

    if (!$ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "ERROR OpenProcessToken. Win32Error: $err"
        exit 4
    }

    Write-Log "Token actual obtenido."

    $ok = [NativeMethods]::DuplicateTokenEx(
        $currentToken,
        [NativeMethods]::MAXIMUM_ALLOWED,
        [IntPtr]::Zero,
        [NativeMethods]::SecurityImpersonation,
        [NativeMethods]::TokenPrimary,
        [ref]$systemToken
    )

    if (!$ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "ERROR DuplicateTokenEx. Win32Error: $err"
        exit 5
    }

    Write-Log "Token SYSTEM duplicado."

    $sid = [uint32]$sessionId

    $ok = [NativeMethods]::SetTokenInformation(
        $systemToken,
        [NativeMethods]::TokenSessionId,
        [ref]$sid,
        4
    )

    if (!$ok) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "ERROR SetTokenInformation. Win32Error: $err"
        exit 6
    }

    Write-Log "Token SYSTEM asignado a SessionId: $sessionId"

    $envOk = [NativeMethods]::CreateEnvironmentBlock(
        [ref]$envBlock,
        $systemToken,
        $false
    )

    if (!$envOk) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "ADVERTENCIA CreateEnvironmentBlock falló. Win32Error: $err"
        $envBlock = [IntPtr]::Zero
    } else {
        Write-Log "EnvironmentBlock creado correctamente."
    }

    $si = New-Object NativeMethods+STARTUPINFO
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
    $si.lpDesktop = "winsta0\default"
    $si.dwFlags = 1
    $si.wShowWindow = 1

    $pi = New-Object NativeMethods+PROCESS_INFORMATION

    # Solo abre PowerShell. No ejecuta ningún comando interno.
    $cmdLine = "`"$psExe`" -NoExit"

    Write-Log "CommandLine: $cmdLine"

    $flags = [NativeMethods]::CREATE_UNICODE_ENVIRONMENT -bor [NativeMethods]::CREATE_NEW_CONSOLE

    $result = [NativeMethods]::CreateProcessAsUser(
        $systemToken,
        $psExe,
        $cmdLine,
        [IntPtr]::Zero,
        [IntPtr]::Zero,
        $false,
        $flags,
        $envBlock,
        $workdir,
        [ref]$si,
        [ref]$pi
    )

    if (!$result) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "ERROR CreateProcessAsUser. Win32Error: $err"
        exit 7
    }

    Write-Log "PowerShell SYSTEM creado correctamente. PID: $($pi.dwProcessId)"

    Start-Sleep -Seconds 3

    $proc = Get-Process -Id $pi.dwProcessId -ErrorAction SilentlyContinue

    if ($null -eq $proc) {
        Write-Log "ADVERTENCIA: El proceso se creó pero se cerró."
        exit 8
    } else {
        Write-Log "Proceso sigue activo: $($proc.ProcessName), PID: $($proc.Id)"
    }

    if ($pi.hProcess -ne [IntPtr]::Zero) {
        [NativeMethods]::CloseHandle($pi.hProcess) | Out-Null
    }

    if ($pi.hThread -ne [IntPtr]::Zero) {
        [NativeMethods]::CloseHandle($pi.hThread) | Out-Null
    }

    if ($envBlock -ne [IntPtr]::Zero) {
        [NativeMethods]::DestroyEnvironmentBlock($envBlock) | Out-Null
    }

    if ($systemToken -ne [IntPtr]::Zero) {
        [NativeMethods]::CloseHandle($systemToken) | Out-Null
    }

    if ($currentToken -ne [IntPtr]::Zero) {
        [NativeMethods]::CloseHandle($currentToken) | Out-Null
    }

    Write-Log "==== Fin OK ===="
    exit 0
}
catch {
    Write-Log "EXCEPCION: $($_.Exception.Message)"
    Write-Log "STACK: $($_.ScriptStackTrace)"
    exit 99
}