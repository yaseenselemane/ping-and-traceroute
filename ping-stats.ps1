# ping-stats.ps1 - what ping.exe doesn't tell you: jitter, spread and loss in one line.
# Usage:  powershell -File ping-stats.ps1 -Target 1.1.1.1 -Count 50
#         powershell -File ping-stats.ps1 -SelfTest
param([string]$Target = "1.1.1.1", [int]$Count = 50, [switch]$SelfTest)

function Get-PingStats([object[]]$times) {
  # $times: one entry per probe, $null = lost
  $ok = @($times | Where-Object { $_ -ne $null })
  $lost = $times.Count - $ok.Count
  if ($ok.Count -eq 0) { return [pscustomobject]@{ Sent = $times.Count; Lost = $lost; LossPct = 100 } }
  $avg = ($ok | Measure-Object -Average).Average
  $sd = [math]::Sqrt((($ok | ForEach-Object { ($_ - $avg) * ($_ - $avg) }) | Measure-Object -Sum).Sum / $ok.Count)
  # Jitter = average change between consecutive replies (the idea behind RFC 3550's estimate).
  $diffs = for ($i = 1; $i -lt $ok.Count; $i++) { [math]::Abs($ok[$i] - $ok[$i - 1]) }
  $jitter = if ($diffs) { ($diffs | Measure-Object -Average).Average } else { 0 }
  $sorted = $ok | Sort-Object
  [pscustomobject]@{
    Sent = $times.Count; Lost = $lost; LossPct = [math]::Round(100 * $lost / $times.Count, 1)
    Min = $sorted[0]; Avg = [math]::Round($avg, 1); Max = $sorted[-1]
    P95 = $sorted[[math]::Min($sorted.Count - 1, [math]::Ceiling(0.95 * $sorted.Count) - 1)]
    StdDev = [math]::Round($sd, 1); Jitter = [math]::Round($jitter, 1)
  }
}

if ($SelfTest) {
  $s = Get-PingStats @(10, 20, $null, 10, 20)
  if ($s.Lost -ne 1 -or $s.LossPct -ne 20 -or $s.Avg -ne 15 -or $s.Jitter -ne 10 -or $s.Min -ne 10 -or $s.Max -ne 20) { throw "self-test failed: $($s | Out-String)" }
  $z = Get-PingStats @($null, $null)
  if ($z.LossPct -ne 100) { throw "self-test failed: all lost" }
  "self-test passed"; return
}

$times = foreach ($i in 1..$Count) {
  $out = ping.exe -n 1 -w 1000 $Target | Out-String
  if ($out -match 'time[=<](\d+)ms') { [int]$Matches[1] } else { $null }
}
Get-PingStats $times | Format-List
