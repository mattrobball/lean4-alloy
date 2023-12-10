/-
Copyright (c) 2022 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
import Alloy.Util.ShimElab
import Alloy.C.Server

open Lean Lsp Elab Command

register_option Alloy.shimDiagnostics : Bool := {
  defValue := false
  descr := "Whether Alloy should fetch shim language server diagnostics"
}

register_option Alloy.shimDiagnosticsTimeout : Nat := {
  defValue := 1000
  descr :=
    "Max time Alloy should delay command elaboration " ++
    "to wait for shim language server diagnostics"
}

namespace Alloy

def LsWorker.collectClangdDiagnostics
 (ls : LsWorker) (uri : DocumentUri) (text languageId : String) (version := 0)
 (timeout : UInt32 := 1000)
: IO (Array Diagnostic) := do
  let diagnostics ← IO.Mutex.new #[]
  ls.withNotificationHandler "textDocument/publishDiagnostics"
    (fun ps => diagnostics.atomically fun ref => ref.set ps.diagnostics) do
  let ready ← IO.Promise.new
  ls.withNotificationHandler "textDocument/clangd.fileStatus"
    (fun {uri:=uri',state} => do if uri = uri' ∧ state = "idle" then ready.resolve true) do
  ls.withTextDocument uri text languageId (version := version) do
  discard <| IO.asTask do IO.sleep timeout; ready.resolve false
  unless (← IO.wait ready.result) do
    throw <| .userError <| "clangd took too long to load the shim"
  diagnostics.atomically (·.get)

namespace C

/-! ## Shim Elaboration -/

/-- Elaborate some shim code at the end of the C shim. -/
@[inline] def elabShimSyntax (stx : Syntax) : ShimElabM ShimSyntax := do
  elabShimSyntaxCore shimExt stx

/-- Reprint a command and add it verbatim to the module's C shim. -/
def addCommandToShim [Monad m] [MonadEnv m] [MonadError m] (cmd : Syntax) : m Unit := do
  let env ← getEnv
  let shim := shimExt.getState env
  if let some shim := shim.pushCmd? cmd then
    setEnv <| shimExt.setState env shim
  else
    throwError s!"command '{cmd.getKind}' could not reprinted and add raw to the C shim"

/-- Extract shim diagnostics from `clangd` and log them as Lean messages. -/
def logDiagnosticsAfter (iniPos : String.Pos) : CommandElabM Unit := do
  let some ls ← getLs?
    | return
  let opts ← getOptions
  let shim := getLocalShim (← getEnv)
  let fileName ← getFileName; let fileMap ← getFileMap
  let timeout := shimDiagnosticsTimeout.get opts
  let warningSeverity := if warningAsError.get opts then .error else .warning
  match (← ls.collectClangdDiagnostics nullUri shim.text.source "c" timeout |>.toBaseIO) with
  | .ok diagnostics =>
    for diagnostic in diagnostics do
      let range := lspRangeToUtf8Range shim.text diagnostic.range
      unless iniPos ≤ range.stop do
        continue
      let range := shim.utf8RangeToLean? range |>.getD ⟨0, 0⟩
      let severity :=
        match diagnostic.severity? with
        | some .error => .error
        | some .warning => warningSeverity
        | _ => .information
      logMessage {
        fileName, severity
        pos := fileMap.toPosition range.start
        endPos := fileMap.toPosition range.stop
        data := filterMessage diagnostic.message
      }
  | .error e =>
    logWarning <| toString e -- report `clangd` failures as warnings
where
  filterMessage (msg : String) :=
    let lns := msg.splitOn "\n" |>.filterMap fun ln => do
      let ln := ln.trim
      guard <| ¬ ln.startsWith "nul" -- fake file name: `nul` or `null`
      let suff := "(fix available)"
      return if ln.endsWith suff then ln.dropRight suff.length else ln
    "\n".intercalate lns |>.trim

/--
Elaborate a C command. The steps are as follows:
1. Unpack null nodes and expand macros.
2. Attempt to find and apply a standard Lean `command` elaborator.
3. Otherwise, visit each node of the syntax, expanding macros along the way.
4. For each node, attempt to find and apply an Alloy elaborator for its kind.
If successful, elaborate the node into a `ShimSyntax` and then add it to the shim.
6. For nodes lacking any elaborator or raw tokens, attempt to reprint
the syntax (via `Alloy.reprint`) and add it verbatim to the shim.
7. After elaborating the commands, check the shim with `clangd` and log any
diagnostics within the new code (if `Alloy.shimDiagnostics` is set to `true`).
-/
def elabShimCommand (cmd : Syntax) : CommandElabM Unit := do
  let iniPos := getLocalShim (← getEnv) |>.text.source.endPos
  elabEachCommand cmd fun cmd => do
    let elabFns := commandElabAttribute.getEntries (← getEnv) cmd.getKind
    unless (← elabCommandUsing cmd elabFns) do
      let stx ← elabShimSyntax cmd
      modifyEnv (shimExt.modifyState · (·.addCmd stx))
  if (shimDiagnostics.get (← getOptions)) then
    logDiagnosticsAfter iniPos

/--
A section of C code to elaborate.
See `elabShimConmand` for details on the elaboration process.
-/
scoped elab (name := sectionCmd)
"alloy " &"c " &"section" ppLine cmds:cCmd+ ppLine "end" : command => do
  cmds.forM elabShimCommand

/-! ## Extra Utilities -/

/--
Include the provided C header files in the module's shim.
A convenience macro to create multiple `#include` directives at once.
-/
scoped macro (name := includeCmd)
"alloy " &"c " &"include " hdrs:header+ : command => do
  let cmds ← MonadRef.withRef Syntax.missing <|
    hdrs.mapM fun hdr => `(cCmd|#include $hdr)
  `(alloy c section $cmds* end)
