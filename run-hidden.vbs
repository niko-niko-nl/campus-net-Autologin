' ===========================================================================
'  run-hidden.vbs
'  Launched by Task Scheduler. Starts CampusNet.ps1 fully hidden (no console
'  window flash every few minutes).
'
'  GAME GUARD (layer 1 of 2):
'  If any process listed in "gameguard.lst" is running, this script exits
'  immediately and PowerShell is NEVER started. That keeps the footprint of
'  this tool at zero while a game / anti-cheat is active.
'  Layer 2 is the same check inside CampusNet.ps1 (covers manual runs).
'
'  gameguard.lst is generated from config.json (field "gameProcesses").
'  Delete that file to disable the guard at this layer.
'
'  Log file: %LOCALAPPDATA%\CampusNet\login.log
' ===========================================================================
Option Explicit

Dim sh, fso, basePath, blockedBy, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

basePath = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))

blockedBy = GameGuardHit(fso, basePath)
If Len(blockedBy) > 0 Then
    LogLine fso, basePath, blockedBy
    WScript.Quit 0
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
      " -WindowStyle Hidden -File """ & basePath & "CampusNet.ps1"" -Mode ensure -Quiet"

sh.Run cmd, 0, False
WScript.Quit 0

' ===========================================================================
'  Returns the name of the first watched process found, or "" if none.
' ===========================================================================
Function GameGuardHit(fso, basePath)
    Dim lstPath, ts, line, names, lower, wmi, col, proc, pname
    GameGuardHit = ""

    lstPath = basePath & "gameguard.lst"
    If Not fso.FileExists(lstPath) Then Exit Function

    names = "|"
    On Error Resume Next
    Set ts = fso.OpenTextFile(lstPath, 1)
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    Do Until ts.AtEndOfStream
        line = Trim(ts.ReadLine)
        If Len(line) > 0 Then
            If Left(line, 1) <> "#" Then
                lower = LCase(line)
                If Right(lower, 4) = ".exe" Then lower = Left(lower, Len(lower) - 4)
                names = names & lower & "|"
            End If
        End If
    Loop
    ts.Close
    On Error GoTo 0

    If names = "|" Then Exit Function

    On Error Resume Next
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    Set col = wmi.ExecQuery("SELECT Name FROM Win32_Process")
    On Error GoTo 0

    For Each proc In col
        pname = LCase(proc.Name)
        If Right(pname, 4) = ".exe" Then pname = Left(pname, Len(pname) - 4)
        If InStr(names, "|" & pname & "|") > 0 Then
            GameGuardHit = pname
            Exit Function
        End If
    Next
End Function

' ===========================================================================
'  Append one ASCII-only line to login.log (compatible with the UTF-8 log).
' ===========================================================================
Sub LogLine(fso, basePath, pname)
    Dim ts, stamp
    On Error Resume Next
    stamp = Year(Now) & "-" & Pad2(Month(Now)) & "-" & Pad2(Day(Now)) & " " & _
            Pad2(Hour(Now)) & ":" & Pad2(Minute(Now)) & ":" & Pad2(Second(Now))
    Set ts = fso.OpenTextFile(basePath & "login.log", 8, True)
    ts.WriteLine stamp & " [WARN ] game guard: " & pname & " is running, skipped (PowerShell not launched)"
    ts.Close
    On Error GoTo 0
End Sub

Function Pad2(n)
    Pad2 = Right("0" & n, 2)
End Function
