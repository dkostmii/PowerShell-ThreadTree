class Vertex {
  [string]$Name;
  [Vertex[]]$Children;

  Vertex([string]$Name, [Vertex[]]$Children) {
    $this.Name = $Name;
    $this.Children = $Children;
  }
};

$VerbosePreference = 'Continue';

class Thread {
  [powershell] $Thread
  $Handle
  [string] $Name

  Thread([powershell] $Thread, $Handle, [string] $Name) {
    $this.Thread = $Thread;
    $this.Handle = $Handle;
    $this.Name = $Name;
  }
}

$filename = "result.txt";
$location = Get-Location;
$filepath = (Join-Path $location $filename)

if (Test-Path -Path $filepath -PathType Leaf) {
  Remove-Item $filepath;
}

$MaxThreads = 4;
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads);
$RunspacePool.Open();
$Jobs = New-Object System.Collections.ArrayList;

$root = [Vertex]::New(
  "T1",
  @(
    [Vertex]::New("T3", @(
      [Vertex]::New("T5", @())
    )),
    [Vertex]::New("T2", @(
      [Vertex]::New("T4", @()),
      [Vertex]::New("T6", @())
    ))
  )
);

$mutex = New-Object -TypeName System.Threading.Mutex($false, "FileAccessMutex");

function New-Thread {
  param(
    [Vertex] $Vertex
  )

  Write-Verbose "Creating thread `"$($Vertex.Name)`""
  $Thread = [powershell]::Create();
  $Thread.RunspacePool = $RunspacePool;

  $Thread.AddScript({
    param(
      $Vertex,
      $FileName,
      $NewThreadCallback,
      $WriteToFileCallback
    )

    $VerbosePreference = 'Continue';

    function Get-Number {
      param(
        [string] $Name
      )
    
      try {
        return [int]::Parse($Name.Replace("T", ""));
      }
      catch {
        Write-Error "Expected name of vertex to have format T0, but got $($Vertex.Name)";
        throw "Expected name of vertex to have format T0, but got $($Vertex.Name)";
      }
    }

    Write-Verbose "Script executed.";
    try {
      Write-Verbose "Attempting to write `"$($Vertex.Name)`" to file $FileName...";
      $mutex = [System.Threading.Mutex]::OpenExisting("FileAccessMutex");

      $number = Get-Number -Name $Vertex.Name;
      if (Test-Path $FileName -PathType Leaf) {
        $prevNumber = Get-Number (Get-Content $FileName -Tail 1);
      }
      else {
        $prevNumber = 0;
      }

      Write-Verbose "Current number: $number";
      Write-Verbose "Previous number: $prevNumber";
  
      $done = $false;
  
      while (-not $done) {
        $mutex.WaitOne()
        if (Test-Path $FileName -PathType Leaf) {
          $prevNumber = Get-Number (Get-Content $FileName -Tail 1);
        }
        else {
          $prevNumber = 0;
        }

        if ($number - $prevNumber -eq 1) {
          Write-Verbose "Writing content `"$($Vertex.Name)`" to file $FileName..."
          Add-Content -Path $FileName -Value $Vertex.Name;
          $done = $true;
        }
        else {
          $mutex.ReleaseMutex();
        }
      }
      $mutex.ReleaseMutex();
    }
    catch {
      Write-Error "Error occurred"
      Write-Error $Error;
      $mutex.ReleaseMutex();
      exit;
    }

    $Vertex.Children | ForEach-Object {
      Invoke-Command $NewThreadCallback -ArgumentList $_;
    };
  });

  $Thread.AddArgument($Vertex);
  $Thread.AddArgument($filepath);
  # Passing a callback here
  $Thread.AddArgument(${function:\New-Thread});
  $Thread.AddArgument(${function:\Write-ToFile});

  $Jobs.Add(
    [Thread]::New($Thread, $Thread.BeginInvoke(), $Vertex.Name)) | Out-Null;
}

New-Thread $root | Out-Null;

function Get-Threads {
  return $Jobs | Where-Object {
    $_.Handle.IsCompleted -eq $false;
  };
}

$remainingJobs = Get-Threads;
Write-Verbose ("Remaining jobs: {0}" -f $remainingJobs.Count);

while ($remainingJobs.Count -gt 0) {
  Write-Verbose ("Remaining jobs {0}" -f $remainingJobs.Count);
  Start-Sleep -Milliseconds 200;

  $remainingJobs = Get-Threads;
}

$Jobs | ForEach-Object {
  Write-Verbose "Closing thread `"$($_.Name)`"";

  $_.Thread.EndInvoke($_.Handle) | Out-Null;
  $_.Thread.Dispose() | Out-Null;
}

$Jobs.Clear() | Out-Null;
$mutex.Dispose() | Out-Null;
