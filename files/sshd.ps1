<#
.SYNOPSIS
PowerShell 版模拟 SSH 服务端，完全复刻 simulated_sshd.py 逻辑
默认账号：root / password，监听端口：2222
#>

# ========== 配置项 ==========
$listenPort = 2222
$validUsername = "root"
$validPassword = "password"
$hostKeyPath = Join-Path $PWD.Path "host_rsa.key"
$shellPath = "powershell.exe"  # Windows 可改为 cmd.exe；Linux PowerShell 改为 /bin/bash

# ========== 自动加载 SSH.NET 依赖 ==========
$libDir = Join-Path $PWD.Path "ps_ssh_lib"
$dllPath = Join-Path $libDir "Renci.SshNet.dll"

if (-not (Test-Path $dllPath)) {
    Write-Host "[*] 首次运行，正在下载 SSH.NET 依赖库..."
    $null = New-Item -ItemType Directory -Path $libDir -Force
    $nugetUrl = "https://www.nuget.org/api/v2/package/SSH.NET/2024.0.0"
    $tempZip = Join-Path $libDir "temp.nupkg"
    Invoke-WebRequest -Uri $nugetUrl -OutFile $tempZip -UseBasicParsing
    Expand-Archive -Path $tempZip -DestinationPath $libDir -Force
    Copy-Item -Path (Join-Path $libDir "lib/netstandard2.0/Renci.SshNet.dll") -Destination $dllPath -Force
    Remove-Item $tempZip -ErrorAction SilentlyContinue
}
Add-Type -Path $dllPath

# ========== 加载/生成主机 RSA 密钥 ==========
if (Test-Path $hostKeyPath) {
    Write-Host "[*] 加载已有主机密钥: $hostKeyPath"
    $hostKey = [Renci.SshNet.PrivateKeyFile]::new($hostKeyPath)
}
else {
    Write-Host "[*] 正在生成 2048 位 RSA 主机密钥..."
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $rsaParams = $rsa.ExportParameters($true)
    $rsaKey = [Renci.SshNet.Security.RsaKey]::new(
        $rsaParams.Modulus, $rsaParams.Exponent,
        $rsaParams.D, $rsaParams.P, $rsaParams.Q
    )
    $privateKey = [Renci.SshNet.PrivateKeyFile]::new($rsaKey)
    $privateKey.Save($hostKeyPath)
    $hostKey = $privateKey
    Write-Host "[+] 密钥已保存到: $hostKeyPath"
}

# ========== 初始化 SSH 服务端 ==========
$server = [Renci.SshNet.SshServer]::new([System.Net.IPAddress]::Any, $listenPort)
$server.AddHostKey($hostKey)

# 注册密码认证逻辑
$passwordAuth = [Renci.SshNet.PasswordAuthenticationMethod]::new({
    param($ctx)
    return $ctx.Username -eq $validUsername -and $ctx.Password -eq $validPassword
})
$server.AddAuthenticationMethod($passwordAuth)

# ========== 处理客户端连接 ==========
$connMsgData = @{
    ShellPath = $shellPath
}

Register-ObjectEvent -InputObject $server -EventName ConnectionAccepted `
    -MessageData $connMsgData -Action {
    param($sender, $e)
    $session = $e.Session
    $clientIP = $session.ConnectionInfo.ClientIpAddress
    $shellExe = $event.MessageData.ShellPath
    Write-Host "[*] 新客户端连接: $clientIP"

    # 同意所有 PTY 终端请求，对齐原脚本逻辑
    Register-ObjectEvent -InputObject $session -EventName PtyRequested -Action {
        param($s, $args)
        $args.IsAccepted = $true
    } | Out-Null

    # 处理交互式 Shell 请求
    Register-ObjectEvent -InputObject $session -EventName ShellRequested `
        -MessageData $shellExe -Action {
        param($s, $shellArgs)
        $shell = $shellArgs.Shell
        $sshInput = $shell.InputStream
        $sshOutput = $shell.OutputStream
        $shellPath = $event.MessageData

        try {
            # 启动本地 Shell 进程
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $shellPath
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $psi.WorkingDirectory = [Environment]::CurrentDirectory

            $proc = [System.Diagnostics.Process]::Start($psi)

            # 线程共享状态
            $state = [PSCustomObject]@{
                SshIn  = $sshInput
                SshOut = $sshOutput
                Proc   = $proc
            }

            # 线程1：SSH 客户端输入 -> 本地进程标准输入
            $inThread = [System.Threading.Thread]::new([System.Threading.ParameterizedThreadStart]{
                param($st)
                try {
                    $buf = New-Object byte[] 1024
                    while ($true) {
                        $read = $st.SshIn.Read($buf, 0, $buf.Length)
                        if ($read -le 0) { break }
                        $st.Proc.StandardInput.BaseStream.Write($buf, 0, $read)
                        $st.Proc.StandardInput.BaseStream.Flush()
                    }
                } catch {}
            })
            $inThread.IsBackground = $true
            $inThread.Start($state)

            # 线程2：本地进程标准输出 -> SSH 客户端
            $outThread = [System.Threading.Thread]::new([System.Threading.ParameterizedThreadStart]{
                param($st)
                try {
                    $buf = New-Object byte[] 1024
                    while ($true) {
                        $read = $st.Proc.StandardOutput.BaseStream.Read($buf, 0, $buf.Length)
                        if ($read -le 0) { break }
                        $st.SshOut.Write($buf, 0, $read)
                        $st.SshOut.Flush()
                    }
                } catch {}
            })
            $outThread.IsBackground = $true
            $outThread.Start($state)

            # 线程3：本地进程错误输出 -> SSH 客户端
            $errThread = [System.Threading.Thread]::new([System.Threading.ParameterizedThreadStart]{
                param($st)
                try {
                    $buf = New-Object byte[] 1024
                    while ($true) {
                        $read = $st.Proc.StandardError.BaseStream.Read($buf, 0, $buf.Length)
                        if ($read -le 0) { break }
                        $st.SshOut.Write($buf, 0, $read)
                        $st.SshOut.Flush()
                    }
                } catch {}
            })
            $errThread.IsBackground = $true
            $errThread.Start($state)

            # 等待 Shell 进程退出
            $proc.WaitForExit()
        }
        catch {
            Write-Host "[!] 会话异常: $($_.Exception.Message)"
        }
        finally {
            if ($proc -and !$proc.HasExited) { $proc.Kill() }
            $shell.Close()
            Write-Host "[*] 客户端会话已断开"
        }
    } | Out-Null
} | Out-Null

# ========== 启动服务 ==========
try {
    $server.Start()
    Write-Host "`n====================================="
    Write-Host "  模拟 SSH 服务端已启动"
    Write-Host "  监听地址: 0.0.0.0:$listenPort"
    Write-Host "  登录账号: $validUsername / $validPassword"
    Write-Host "  按 Ctrl+C 停止服务"
    Write-Host "=====================================`n"

    while ($server.IsRunning) {
        Start-Sleep -Seconds 1
    }
}
finally {
    $server.Stop()
    Write-Host "`n[*] 服务已停止"
}
