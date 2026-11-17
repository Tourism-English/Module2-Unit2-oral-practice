# ============================================================
# 酒店英语口语练习 - 本地一体化服务器
#   1. 静态文件服务（index.html 等）        → http://localhost:8080/
#   2. POST /api/tts  Speechify 在线 TTS 代理（密钥仅存 .env，前端不可见）
#   3. GET  /api/health  健康检查
# 无需 Python / Node，纯 PowerShell 5.1 + .NET Framework 运行
# ============================================================

$root = $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- 读取 .env（不依赖任何第三方库） ----------
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $name = $matches[1]
            $val = $matches[2].Trim('"').Trim("'")
            Set-Item -Path ("Env:" + $name) -Value $val
        }
    }
}

$apiKey        = $env:SPEECHIFY_API_KEY
$defaultVoice  = if ($env:SPEECHIFY_VOICE_ID) { $env:SPEECHIFY_VOICE_ID } else { "geffen_32" }
$model         = if ($env:SPEECHIFY_MODEL)    { $env:SPEECHIFY_MODEL }    else { "simba-3.2" }
$speechifyUrl  = "https://api.speechify.ai/v1/audio/speech"
$maxTextLength = 2000   # 单条文本长度上限，防止误传长文本消耗额度

# ---------- 内存缓存：key = sha1(text|voiceId|model) ----------
$audioCache = @{}
$sha1 = [System.Security.Cryptography.SHA1]::Create()

function Get-CacheKey([string]$text, [string]$voice, [string]$mdl) {
    $raw = [Text.Encoding]::UTF8.GetBytes($text + "|" + $voice + "|" + $mdl)
    (($sha1.ComputeHash($raw)) | ForEach-Object { $_.ToString("x2") }) -join ''
}

function Write-Json([System.Net.HttpListenerResponse]$resp, [int]$code, [string]$json) {
    $resp.StatusCode = $code
    $resp.ContentType = "application/json; charset=utf-8"
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

# ---------- 启动监听 ----------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8080/")
$listener.Start()
Write-Host "Serving on http://localhost:8080/ root=$root"
Write-Host ("Speechify proxy: voice={0} model={1} key={2}" -f $defaultVoice, $model, $(if ($apiKey) { "loaded" } else { "MISSING(.env)" }))

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $req = $context.Request
    $resp = $context.Response
    $path = $req.Url.AbsolutePath

    # ---------- 健康检查 ----------
    if ($path -eq "/api/health" -and $req.HttpMethod -eq "GET") {
        $payload = @{ status = "ok"; provider = "speechify"; voice = $defaultVoice; model = $model; keyLoaded = [bool]$apiKey } | ConvertTo-Json -Compress
        Write-Json $resp 200 $payload
        continue
    }

    # ---------- TTS 代理 ----------
    if ($path -eq "/api/tts" -and $req.HttpMethod -eq "POST") {
        if (-not $apiKey) {
            Write-Json $resp 500 '{"error":"SPEECHIFY_API_KEY 未配置，请检查 .env"}'
            continue
        }

        # 读取并解析请求体
        $reader = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
        $bodyRaw = $reader.ReadToEnd()
        $reader.Close()
        try { $payloadIn = $bodyRaw | ConvertFrom-Json } catch {
            Write-Json $resp 400 '{"error":"请求体不是合法 JSON"}'
            continue
        }

        $text  = if ($payloadIn.text) { [string]$payloadIn.text } else { "" }
        $voice = if ($payloadIn.voiceId) { [string]$payloadIn.voiceId } else { $defaultVoice }
        $text = $text.Trim()

        if ([string]::IsNullOrEmpty($text)) {
            Write-Json $resp 400 '{"error":"text 参数不能为空"}'
            continue
        }
        if ($text.Length -gt $maxTextLength) {
            Write-Json $resp 400 (@{ error = "text 超过长度上限 $maxTextLength 字符（当前 $($text.Length)）" } | ConvertTo-Json -Compress)
            continue
        }

        $cacheKey = Get-CacheKey $text $voice $model

        # 缓存命中：直接返回，不再请求 Speechify，不消耗额度
        if ($audioCache.ContainsKey($cacheKey)) {
            $cached = $audioCache[$cacheKey]
            $resp.ContentType = "audio/mpeg"
            $resp.AddHeader("X-TTS-Cache", "HIT")
            $resp.ContentLength64 = $cached.Length
            $resp.OutputStream.Write($cached, 0, $cached.Length)
            $resp.OutputStream.Close()
            Write-Host "[TTS] HIT  chars=$($text.Length) voice=$voice"
            continue
        }

        # 缓存未命中：请求 Speechify（返回 JSON，audio_data 为 base64）
        try {
            $sfBody = @{ input = $text; voice_id = $voice; model = $model; audio_format = "mp3" } | ConvertTo-Json -Compress
            $sfResp = Invoke-WebRequest -Uri $speechifyUrl -Method Post `
                -Headers @{ Authorization = "Bearer $apiKey"; "Content-Type" = "application/json" } `
                -Body $sfBody -TimeoutSec 60 -UseBasicParsing
            $sfJson = $sfResp.Content | ConvertFrom-Json
            $audioBytes = [Convert]::FromBase64String([string]$sfJson.audio_data)
            if ($audioBytes.Length -eq 0) { throw "audio_data 为空" }

            $audioCache[$cacheKey] = $audioBytes
            $billable = $sfJson.billable_characters_count

            $resp.ContentType = "audio/mpeg"
            $resp.AddHeader("X-TTS-Cache", "MISS")
            if ($billable) { $resp.AddHeader("X-Billable-Characters", [string]$billable) }
            $resp.ContentLength64 = $audioBytes.Length
            $resp.OutputStream.Write($audioBytes, 0, $audioBytes.Length)
            $resp.OutputStream.Close()
            Write-Host "[TTS] MISS chars=$($text.Length) billable=$billable voice=$voice cached=$($audioCache.Count)"
        } catch {
            $msg = $_.Exception.Message -replace '"', "'"
            Write-Host "[TTS] ERROR $msg"
            Write-Json $resp 502 (@{ error = "Speechify 合成失败: $msg" } | ConvertTo-Json -Compress)
        }
        continue
    }

    # ---------- 静态文件 ----------
    if ($path -eq "/") { $path = "/index.html" }
    $child = $path.TrimStart("/")
    $filePath = Join-Path $root $child
    $fullRoot = [IO.Path]::GetFullPath($root)
    $fullFile = [IO.Path]::GetFullPath($filePath)
    $leaf = [IO.Path]::GetFileName($fullFile)
    $ext = [IO.Path]::GetExtension($fullFile).ToLower()

    # 安全：禁止目录穿越；禁止访问 .env / .git* / *.ps1 / *.zip 等敏感文件
    $blocked = (-not $fullFile.StartsWith($fullRoot)) -or $leaf.StartsWith(".") -or ($ext -eq ".ps1") -or ($ext -eq ".zip")
    if ($blocked) {
        $resp.StatusCode = 404
        $blockMsg = [Text.Encoding]::UTF8.GetBytes("404 Not Found")
        $resp.OutputStream.Write($blockMsg, 0, $blockMsg.Length)
        $resp.OutputStream.Close()
        continue
    }

    if ((Test-Path $fullFile -PathType Leaf)) {
        $mime = switch ($ext) {
            ".html" { "text/html; charset=utf-8" }
            ".css"  { "text/css; charset=utf-8" }
            ".js"   { "application/javascript; charset=utf-8" }
            ".json" { "application/json; charset=utf-8" }
            ".mp3"  { "audio/mpeg" }
            ".png"  { "image/png" }
            ".jpg"  { "image/jpeg" }
            ".svg"  { "image/svg+xml" }
            ".ico"  { "image/x-icon" }
            default { "application/octet-stream" }
        }
        $bytes = [System.IO.File]::ReadAllBytes($fullFile)
        $resp.ContentType = $mime
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $resp.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
        $resp.OutputStream.Write($msg, 0, $msg.Length)
    }
    $resp.OutputStream.Close()
}
