unit FileUtils;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

function CopyFile(ASourceFileName, ADestFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
procedure DumpExceptionCallStack(var F: Text; E: Exception);
function LockFile(handle, start, length: LongInt): LongInt;
function OpenFileForAppend(out F: Text; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
function OpenFileForOverwrite(out F: File; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
function OpenFileForOverwrite(out F: Text; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
function OpenFileForRead(out F: Text; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
function OpenFileForReadWrite(out F: File; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
function ReadFile(AFileName: String; var ASL: TStringList; ATimeoutInMilliseconds: Integer): Boolean;
function RenameFile(AOldFileName, ANewFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
function TrimTopLines(AFileName: String; ALineCount, ATimeoutInMilliseconds: Integer): Boolean;
function UnLockFile(handle, start, length: LongInt): LongInt;
function WriteFile(AFileName: String; var ASL: TStringList; ATimeoutInMilliseconds: Integer): Boolean;

implementation

{$IFDEF UNIX}
uses BaseUnix;
{$ENDIF}

{ Attempt to acquire an exclusive advisory lock on an already-open file descriptor.
  Returns false immediately (non-blocking) if another process holds the lock, so
  callers can close the file and retry within their timeout loop.
  Lock is automatically released when the file is closed.
  On Windows the lock is enforced at open time via FileMode; this always returns true. }
function TryLockFd(fd: {$IFDEF UNIX}cint{$ELSE}LongWord{$ENDIF}): boolean;
{$IFDEF UNIX}
var
  fl: TFlock;
{$ENDIF}
begin
{$IFDEF UNIX}
  FillChar(fl, SizeOf(fl), 0);
  fl.l_type   := F_WRLCK; { exclusive write lock }
  fl.l_whence := 0;        { SEEK_SET }
  fl.l_start  := 0;
  fl.l_len    := 0;        { 0 = lock entire file }
  Result := fpfcntl(fd, F_SetLk, fl) = 0; { F_SetLk = non-blocking }
{$ELSE}
  Result := true; { Windows: exclusive access enforced at open time via FileMode }
{$ENDIF}
end;

function LockFile(handle, start, length: LongInt): LongInt;
{$IFDEF UNIX}
var
  fl: TFlock;
{$ENDIF}
begin
{$IFDEF UNIX}
  FillChar(fl, SizeOf(fl), 0);
  fl.l_type   := F_WRLCK;
  fl.l_whence := 0;
  fl.l_start  := start;
  fl.l_len    := length;
  Result := fpfcntl(handle, F_SetLkW, fl); { F_SetLkW = blocking wait }
{$ELSE}
  Result := 0;
{$ENDIF}
end;

function UnLockFile(handle, start, length: LongInt): LongInt;
{$IFDEF UNIX}
var
  fl: TFlock;
{$ENDIF}
begin
{$IFDEF UNIX}
  FillChar(fl, SizeOf(fl), 0);
  fl.l_type   := F_UNLCK;
  fl.l_whence := 0;
  fl.l_start  := start;
  fl.l_len    := length;
  Result := fpfcntl(handle, F_SetLk, fl);
{$ELSE}
  Result := 0;
{$ENDIF}
end;

function CopyFile(ASourceFileName, ADestFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  Buffer: Array[1..1024] of Byte;
  DestF, SourceF: File;
  NumRead, NumWritten: LongInt;
begin
  Result := false;

  if ((ASourceFileName <> '') AND (ADestFileName <> '') AND (FileExists(ASourceFileName))) then
  begin
    if (OpenFileForReadWrite(SourceF, ASourceFileName, 2500)) then
    begin
      if (OpenFileForOverwrite(DestF, ADestFileName, 2500)) then
      begin
        Buffer[1] := 0; // Make the "does not seem to be initialized" hint go away
        NumRead := 0;
        NumWritten := 0;

        repeat
          BlockRead(SourceF, Buffer, SizeOf(Buffer), NumRead);
          BlockWrite(DestF, Buffer, NumRead, NumWritten);

          if (NumRead <> NumWritten) then
          begin
            // This shouldn't happen, but we should bail instead of retrying if it does
            Exit;
          end;
        until (NumRead = 0);

        Close(SourceF);
        Close(DestF);

        Result := true;
        Exit;
      end else
      begin
        Close(SourceF);
      end;
    end;
  end;
end;

// From: http://wiki.freepascal.org/Logging_exceptions#Dump_exception_call_stack
procedure DumpExceptionCallStack(var F: Text; E: Exception);
var
  I: Integer;
  Frames: PPointer;
  Report: string;
begin
  Report := 'Program exception! ' + LineEnding +
    'Stacktrace:' + LineEnding + LineEnding;
  if E <> nil then begin
    Report := Report + 'Exception class: ' + E.ClassName + LineEnding +
    'Message: ' + E.Message + LineEnding;
  end;
  Report := Report + BackTraceStrFunc(ExceptAddr);
  Frames := ExceptFrames;
  for I := 0 to ExceptFrameCount - 1 do
    Report := Report + LineEnding + BackTraceStrFunc(Frames[I]);
  WriteLn(F, Report);
end;

function OpenFileForAppend(out F: Text; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  if (FileExists(AFileName)) then
  begin
    for I := 1 to ATimeoutInMilliseconds div 100 do
    begin
{$IFDEF WINDOWS}
      FileMode := fmOpenReadWrite or fmShareExclusive;
{$ENDIF}
      Assign(F, AFileName);
      {$I-}Append(F);{$I+}
      if (IOResult = 0) then
      begin
        if TryLockFd(TextRec(F).Handle) then
        begin
          Result := true;
          Exit;
        end;
        Close(F); { lock not available — close and retry }
      end;

      Sleep(100); // Wait 1/10th of a second before retrying
    end;
  end else
  begin
    Result := OpenFileForOverwrite(F, AFileName, ATimeoutInMilliseconds);
  end;
end;

function OpenFileForOverwrite(out F: File; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  for I := 1 to ATimeoutInMilliseconds div 100 do
  begin
{$IFDEF WINDOWS}
    FileMode := fmOpenReadWrite or fmShareExclusive;
{$ENDIF}
    Assign(F, AFileName);
    {$I-}ReWrite(F, 1);{$I+}
    if (IOResult = 0) then
    begin
      if TryLockFd(FileRec(F).Handle) then
      begin
        Result := true;
        Exit;
      end;
      Close(F);
    end;

    Sleep(100); // Wait 1/10th of a second before retrying
  end;
end;

function OpenFileForOverwrite(out F: Text; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  for I := 1 to ATimeoutInMilliseconds div 100 do
  begin
{$IFDEF WINDOWS}
    FileMode := fmOpenReadWrite or fmShareExclusive;
{$ENDIF}
    Assign(F, AFileName);
    {$I-}ReWrite(F);{$I+}
    if (IOResult = 0) then
    begin
      if TryLockFd(TextRec(F).Handle) then
      begin
        Result := true;
        Exit;
      end;
      Close(F);
    end;

    Sleep(100); // Wait 1/10th of a second before retrying
  end;
end;

function OpenFileForRead(out F: Text; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  for I := 1 to ATimeoutInMilliseconds div 100 do
  begin
    Assign(F, AFileName);
    {$I-}Reset(F);{$I+}
    if (IOResult = 0) then
    begin
      Result := true;
      Exit;
    end;

    Sleep(100); // Wait 1/10th of a second before retrying
  end;
end;

function OpenFileForReadWrite(out F: File; AFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  if (FileExists(AFileName)) then
  begin
    for I := 1 to ATimeoutInMilliseconds div 100 do
    begin
{$IFDEF WINDOWS}
      FileMode := fmOpenReadWrite or fmShareExclusive;
{$ENDIF}
      Assign(F, AFileName);
      {$I-}Reset(F, 1);{$I+}
      if (IOResult = 0) then
      begin
        if TryLockFd(FileRec(F).Handle) then
        begin
          Result := true;
          Exit;
        end;
        Close(F); { lock not available — close and retry }
      end;

      Sleep(100); // Wait 1/10th of a second before retrying
    end;
  end else
  begin
    Result := OpenFileForOverwrite(F, AFileName, ATimeoutInMilliseconds);
  end;
end;

function ReadFile(AFileName: String; var ASL: TStringList; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  for I := 1 to ATimeoutInMilliseconds div 100 do
  begin
    try
      ASL.LoadFromFile(AFileName);
      Result := true;
      Exit;
    except
      on E: Exception do
      begin
        Sleep(100); // Wait 1/10th of a second before retrying
      end;
    end;
  end;
end;

function RenameFile(AOldFileName, ANewFileName: String; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  if ((AOldFileName <> '') AND (ANewFileName <> '') AND (FileExists(AOldFileName))) then
  begin
    for I := 1 to ATimeoutInMilliseconds div 100 do
    begin
      if (SysUtils.RenameFile(AOldFileName, ANewFileName)) then
      begin
        Result := true;
        Exit;
      end;

      Sleep(100); // Wait 1/10th of a second before retrying
    end;
  end;
end;

function TrimTopLines(AFileName: String; ALineCount, ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
  SL: TStringList;
begin
  Result := false;

  if (FileExists(AFileName)) then
  begin
    for I := 1 to ATimeoutInMilliseconds div 100 do
    begin
      try
        SL := TStringList.Create;
        SL.LoadFromFile(AFileName);
        if (SL.Count > ALineCount) then
        begin
          while (SL.Count > ALineCount) do
          begin
            SL.Delete(0);
          end;
          SL.SaveToFile(AFileName);
          SL.Free;

          Result := true;
          Exit;
        end;
      except
        on E: Exception do
        begin
          Sleep(100); // Wait 1/10th of a second before retrying
        end;
      end;
    end;
  end;
end;

function WriteFile(AFileName: String; var ASL: TStringList; ATimeoutInMilliseconds: Integer): Boolean;
var
  I: Integer;
begin
  Result := false;

  for I := 1 to ATimeoutInMilliseconds div 100 do
  begin
    try
      ASL.SaveToFile(AFileName);
      Result := true;
      Exit;
    except
      on E: Exception do
      begin
        Sleep(100); // Wait 1/10th of a second before retrying
      end;
    end;
  end;
end;

end.
