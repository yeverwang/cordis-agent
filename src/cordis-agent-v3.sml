(* ============================================================
   cordis-agent-v3.sml   -- Poly/ML version (v3)
   -----------------------------------------------------------
   New in v3 (on top of v2):
     (A) Explicit `fork` primitive:  spawn a child agent under a
         parent's scope; parent dispose -> child cascade dispose,
         strongly consistent.
     (B) Supervisor tree with a Supervisor agent that spawns
         Worker agents dynamically via the ReAct action Spawn.
     (C) Partial dispose demo: kill ONE worker mid-tree while
         siblings continue.
     (D) Full dispose demo: kill the supervisor -> every worker
         and every worker's tools vanish in one atomic sweep.

   Structural change vs v2:
     - Reasoner is now a REUSABLE plugin, invoked per-agent.
     - Each agent carries its own `agentId` + independent scope.

   Run:
     poly --use cordis-agent-v3.sml
   ============================================================ *)

(* ============================================================
   0. Utilities
   ============================================================ *)
structure AList = struct
  type ('k, 'v) t = ('k * 'v) list ref
  fun new () : ('k, 'v) t = ref []
  fun find (t : (''k, 'v) t) k =
    case List.find (fn (k', _) => k' = k) (!t) of
        SOME (_, v) => SOME v | NONE => NONE
  fun put (t : (''k, 'v) t) (k, v) =
    t := (k, v) :: List.filter (fn (k', _) => k' <> k) (!t)
  fun remove (t : (''k, 'v) t) k =
    t := List.filter (fn (k', _) => k' <> k) (!t)
  fun keys (t : ('k, 'v) t) = List.map #1 (!t)
end

val tick = ref 0
fun log s =
  ( tick := !tick + 1
  ; print (concat ["[t=", Int.toString (!tick), "] ", s, "\n"]) )
fun section t =
  ( print "\n============================================================\n"
  ; print ("  " ^ t ^ "\n")
  ; print   "============================================================\n" )

fun trim s =
  let val n = String.size s
      fun ls i = if i < n andalso Char.isSpace (String.sub (s, i)) then ls (i+1) else i
      fun rs i = if i > 0 andalso Char.isSpace (String.sub (s, i-1)) then rs (i-1) else i
      val a = ls 0 val b = rs n
  in if a >= b then "" else String.substring (s, a, b - a) end

(* 0b. Minimal JSON string escaping for building the request body. The
       LLM driver posts to an OpenAI-compatible /chat/completions gateway
       via a JSON body, so user-supplied text (task, history) must be
       escaped before interpolation.

       Only the JSON-significant ASCII bytes are escaped (quote, backslash,
       and the printable control chars). Everything >= 0x80 is left raw —
       Poly/ML strings are byte sequences, and the model's replies are
       UTF-8; the gateway itself accepts raw UTF-8 in the body. Escaping
       those bytes with \u would emit sequences the gateway rejects. *)
fun jsonEscape s =
  let
    (* String.str keeps >= 0x80 bytes RAW (Char.toString would turn them
       into \226-style Poly/ML escapes, which are invalid JSON). *)
    fun ch c = String.str c
    fun hex n =
      let val h = "0123456789abcdef"
      in String.str (String.sub (h, n div 16))
          ^ String.str (String.sub (h, n mod 16)) end
    fun esc c =
      let val n = Char.ord c in
        (if c = #"\"" then "\\\"" else
         if c = #"\\" then "\\\\" else
         if c = #"\n" then "\\n" else
         if c = #"\r" then "\\r" else
         if c = #"\t" then "\\t" else
         if n < 32 then "\\u00" ^ hex n else ch c)
      end
  in String.concat (List.map esc (String.explode s)) end

(* Put a string in quotes and strip it: parse the first JSON string value
   token. Used to pull the assistant's `content` out of the endpoint's
   JSON response. *)
fun jsonStrip (s : string) : string =
  let
    val t = trim s
    val n = String.size t
    fun loop i acc =
      if i >= n then implode (rev acc) else
      (case String.sub (t, i) of
           #"\"" => implode (rev acc)
         | #"\\" => if i + 1 < n then loop (i + 2) (String.sub (t, i + 1) :: acc) else implode (rev acc)
         | c     => loop (i + 1) (c :: acc))
  in if n >= 2 andalso String.sub (t, 0) = #"\"" then loop 1 [] else t end

(* ============================================================
   1. Cordis core (as in v2)
   ============================================================ *)
datatype scope = Scope of {
  name : string, parent : scope option,
  children : scope list ref, disposers : (unit -> unit) list ref,
  active : bool ref
}
fun newScope name parent =
  let val s = Scope { name = name, parent = parent, children = ref [],
                      disposers = ref [], active = ref true }
  in case parent of
        SOME (Scope p) => (#children p := s :: !(#children p))
      | NONE => ()
   ; s end
fun scopeName (Scope {name, ...}) = name
fun scopeActive (Scope {active, ...}) = !active
fun onDispose (Scope s) f = #disposers s := f :: !(#disposers s)
fun disposeScope (Scope s) =
  if not (!(#active s)) then () else
  ( log ("  [DISPOSE] scope <" ^ #name s ^ ">")
  ; List.app disposeScope (!(#children s))
  ; List.app (fn f => f ()) (!(#disposers s))
  ; #children s := []; #disposers s := []; #active s := false )
fun scopeDepth (Scope {parent, ...}) =
  case parent of NONE => 0 | SOME p => 1 + scopeDepth p

structure Svc = struct
  type slot = { value : exn option ref, subs : (unit -> unit) list ref }
  val table : (string, slot) AList.t = AList.new ()
  fun slot n =
    case AList.find table n of
        SOME s => s
      | NONE   =>
          let val s : slot = { value = ref NONE, subs = ref [] }
          in AList.put table (n, s); s end
  fun get n = !(#value (slot n))
  fun subscribe n f = #subs (slot n) := f :: !(#subs (slot n))
  fun provide n v =
    let val s = slot n
        val kind = case !(#value s) of NONE => "provide" | _ => "replace"
    in log ("  [SVC] " ^ kind ^ " '" ^ n ^ "'")
     ; #value s := SOME v
     ; List.app (fn f => f ()) (!(#subs s)) end
  fun retract n =
    ( log ("  [SVC] retract '" ^ n ^ "'")
    ; #value (slot n) := NONE
    ; List.app (fn f => f ()) (!(#subs (slot n))) )
end

type eventBucket = (unit ref * (exn -> unit)) list ref
datatype ctx = Ctx of {
  scope  : scope,
  events : (string, eventBucket) AList.t
}
fun ctxScope (Ctx {scope, ...}) = scope
fun rootCtx () = Ctx { scope = newScope "root" NONE, events = AList.new () }
fun childCtx (Ctx {events, ...}) newScopeVal =
  Ctx { scope = newScopeVal, events = events }

fun on (Ctx {scope, events}) name handler =
  let val b = case AList.find events name of
                  SOME b => b
                | NONE => let val b : eventBucket = ref []
                          in AList.put events (name, b); b end
      val tok = ref ()
      val _ = b := (tok, handler) :: !b
      fun off () = b := List.filter (fn (t, _) => t <> tok) (!b)
  in onDispose scope off; off end

fun emit (Ctx {events, ...}) name payload =
  case AList.find events name of
      NONE => () | SOME b => List.app (fn (_, h) => h payload) (!b)

type 'cfg plugin = {
  name : string, inject : string list,
  apply : ctx -> 'cfg -> unit
}

fun plugin (parent as Ctx {scope=pscope, events=_}) (p : 'cfg plugin) (cfg : 'cfg) =
  let val childScope = ref (newScope (#name p) (SOME pscope))
      val running    = ref false
      fun ready () = List.all (fn n => Option.isSome (Svc.get n)) (#inject p)
      fun missing () = List.filter (fn n => not (Option.isSome (Svc.get n))) (#inject p)
      fun run () =
        if !running then () else
        if not (ready ()) then
          log ("  [WAIT] '" ^ #name p ^ "' waits: ["
               ^ String.concatWith "," (missing ()) ^ "]")
        else
          ( log ("  [APPLY] '" ^ #name p ^ "' in <"
                 ^ scopeName (!childScope) ^ ">")
          ; running := true
          ; #apply p (childCtx parent (!childScope)) cfg )
      fun reload () =
        ( log ("  [RELOAD] '" ^ #name p ^ "'")
        ; disposeScope (!childScope)
        ; childScope := newScope (#name p) (SOME pscope)
        ; running := false; run () )
  in List.app (fn n => Svc.subscribe n reload) (#inject p); run ();
     (fn () => disposeScope (!childScope)) end

exception Logger of { info : string -> unit }
fun useLogger () =
  case Svc.get "logger" of
      SOME (Logger l) => l | _ => raise Fail "no logger"

val loggerPlugin : unit plugin = {
  name = "logger", inject = [],
  apply = fn ctx => fn () =>
    ( Svc.provide "logger"
        (Logger { info = fn s => log ("      [LOG] " ^ s) })
    ; onDispose (ctxScope ctx) (fn () => Svc.retract "logger") )
}

(* ============================================================
   2. Tool signature + functor (from v2)
   ============================================================ *)
signature TOOL_SPEC = sig
  val name    : string  val version : string
  type input   type output
  val parse_input : string -> input
  val show_output : output -> string
end

functor MakeToolSlot(S : TOOL_SPEC) = struct
  type input  = S.input   type output = S.output
  type impl   = { invoke : input -> output }
  exception Box of impl
  val key      = S.name ^ "@" ^ S.version
  val slotName = "tool/" ^ key
  fun provide (imp : impl) =
    ( Svc.provide slotName (Box imp)
    ; fn () => Svc.retract slotName )
  fun get () : impl option =
    case Svc.get slotName of
        SOME (Box imp) => SOME imp | _ => NONE
  fun invokeStr (arg : string) : string =
    case get () of
        NONE => "error: tool " ^ key ^ " not loaded"
      | SOME {invoke} =>
          (S.show_output (invoke (S.parse_input arg))
           handle e => "error: " ^ exnMessage e)
end

structure CalcSpec = struct
  val name = "calc" val version = "v1"
  type input = string  type output = int
  fun parse_input s = s
  fun show_output n = "result=" ^ Int.toString n
end
structure Calc = MakeToolSlot(CalcSpec)

structure SearchSpec = struct
  val name = "search" val version = "v1"
  type input = string  type output = string
  fun parse_input s = s  fun show_output s = s
end
structure Search = MakeToolSlot(SearchSpec)

structure WriteSpec = struct
  val name = "write" val version = "v1"
  type input = string  type output = string
  fun parse_input s = s  fun show_output s = s
end
structure Write = MakeToolSlot(WriteSpec)

(* --- Provider plugins for the tools --- *)
val calcPlugin : unit plugin = {
  name = "tool:calc", inject = ["logger"],
  apply = fn ctx => fn () =>
    let val {info} = useLogger ()
        fun eval s =
          let val sepPlus = String.isSubstring "+" s
              val sepMul  = String.isSubstring "*" s
              val parts =
                if sepPlus then String.tokens (fn c => c = #"+") s
                else if sepMul then String.tokens (fn c => c = #"*") s
                else [s]
              val ns = List.mapPartial (fn t => Int.fromString (trim t)) parts
          in if sepPlus then foldl (op +) 0 ns
             else if sepMul then foldl (op * ) 1 ns
             else (case ns of [x] => x | _ => 0) end
        val stop = Calc.provide { invoke = fn s =>
                     ( info ("calc (" ^ s ^ ")"); eval s ) }
    in onDispose (ctxScope ctx) (fn () => stop ()) end
}

val searchPlugin : unit plugin = {
  name = "tool:search", inject = ["logger"],
  apply = fn ctx => fn () =>
    let val {info} = useLogger ()
        val kb = [("cordis", "Cordis: reactive IoC plugin meta-framework"),
                  ("react",  "ReAct = Reason + Act"),
                  ("functor","functor: SML module parameterized by another module"),
                  ("agent",  "agent: an autonomous LLM loop with tools + memory"),
                  ("sml",    "SML: Standard ML, statically typed functional lang")]
        fun search q =
          let val ql = String.map Char.toLower q in
            case List.find (fn (k,_) => String.isSubstring k ql) kb of
                SOME (_, v) => v | NONE => "no hit"
          end
        val stop = Search.provide { invoke = fn s =>
                     ( info ("search (" ^ s ^ ")"); search s ) }
    in onDispose (ctxScope ctx) (fn () => stop ()) end
}

(* An artifact store shared across agents. Cleared with root scope. *)
val artifacts : (string, string) AList.t = AList.new ()

val writePlugin : unit plugin = {
  name = "tool:write", inject = ["logger"],
  apply = fn ctx => fn () =>
    let val {info} = useLogger ()
        val stop = Write.provide { invoke = fn s =>
          let val parts = String.tokens (fn c => c = #"|") s
              val (key, body) = case parts of
                                   [k, b] => (trim k, trim b)
                                 | _ => ("_", s)
          in AList.put artifacts (key, body)
           ; info ("write [" ^ key ^ "] = " ^ body)
           ; "wrote:" ^ key
          end }
    in onDispose (ctxScope ctx) (fn () => stop ()) end
}

(* ============================================================
   3. Agent action ADT (+ Spawn)
   ============================================================ *)
datatype action =
    Thought  of string
  | LoadTool of string
  | CallTool of string * string
  | Spawn    of { childId : string, task : string, script : action list }
  | WaitAll                   (* wait for all live children to finish *)
  | Finish   of string

type reactState = { task : string, history : string list }
exception LLM of { next : reactState -> action }

(* ============================================================
   4. Uniform tool registry
   ============================================================ *)
type toolEntry = {
  mount     : ctx -> unit,
  invokeStr : string -> string
}
val toolRegistry : (string, toolEntry) AList.t = AList.new ()
val () = AList.put toolRegistry ("calc",
           { mount = fn ctx => (plugin ctx calcPlugin (); ()),
             invokeStr = Calc.invokeStr })
val () = AList.put toolRegistry ("search",
           { mount = fn ctx => (plugin ctx searchPlugin (); ()),
             invokeStr = Search.invokeStr })
val () = AList.put toolRegistry ("write",
           { mount = fn ctx => (plugin ctx writePlugin (); ()),
             invokeStr = Write.invokeStr })

(* ============================================================
   5. Fork: explicit supervisor primitive
   -----------------------------------------------------------
   `fork parentCtx {id, plugin=p, cfg}` gives a NEW ctx whose
   scope is a child of parentCtx's scope. Anything done through
   the returned ctx (mount tools, subscribe events, spawn
   grand-children) sits BELOW that scope, so parent dispose
   cascades atomically.

   Returns a `childHandle` with:
     - ctx   : the child's own context
     - kill  : dispose just this child (siblings survive)
     - alive : whether the child is still active
   ============================================================ *)
type childHandle = {
  id    : string,
  ctx   : ctx,
  kill  : unit -> unit,
  alive : unit -> bool
}

fun fork (parent as Ctx {events, ...}) (name : string) : childHandle =
  let val cs = newScope name (SOME (ctxScope parent))
      val childCtxV = childCtx parent cs
  in log ("  [FORK] child <" ^ name ^ "> under <"
          ^ scopeName (ctxScope parent) ^ ">")
   ; { id    = name,
       ctx   = childCtxV,
       kill  = (fn () => disposeScope cs),
       alive = (fn () => scopeActive cs) }
  end

(* Supervisor state: track live children for WaitAll / broadcast *)
type supervisorState = {
  children : childHandle list ref
}

(* ============================================================
   6. LLM script driver
   -----------------------------------------------------------
   Instead of one hard-coded mock, LLM = a scripted sequence of
   actions. Each agent can be launched with its own script; the
   ReAct loop is oblivious to whether the script came from a
   human, a real LLM, or a supervisor's `Spawn` directive.
   ============================================================ *)
fun scriptedNext (scriptRef : action list ref) (_ : reactState) : action =
  case !scriptRef of
      []      => Finish "script exhausted"
    | a :: rest => (scriptRef := rest; a)

(* ============================================================
   6b. LLM driver — real endpoint via subprocess
   -----------------------------------------------------------
   scriptedNext drives an agent from a fixed script. llmNext drives it
   from a real OpenAI-compatible /chat/completions gateway instead.

   Auth + endpoint come from the ENVIRONMENT, never hardcoded:
     - ANTHROPIC_AUTH_TOKEN -> the platform's bearer token (the "authtopic"
                               value; falls back to AUTH_TOPIC if unset).
     - ANTHROPIC_BASE_URL   -> e.g. https://llm-api.mcisaas.com
     - CORDIS_LLM_MODEL    -> optional model id override (default
                              "claude-opus-5")

   The gateway is reached through a one-shot subprocess (`curl`) writing
   to a temp file — no FFI, no reentrancy, and the rest of the runtime
   stays pure SML + POSIX. The model answers with a single directive
   line that we parse back into an `action`:
       THOUGHT:    <text>           -> Thought
       CALL_TOOL:  <name>|<arg>     -> CallTool
       LOAD:       <name>           -> LoadTool
       FINISH:     <reason>         -> Finish   (implicit if parse fails)

   Environment variables are read once per process via OS.Process.getEnv.
   ============================================================ *)

val llmBase : string option = OS.Process.getEnv "ANTHROPIC_BASE_URL"
(* The platform token: prefer ANTHROPIC_AUTH_TOKEN, fall back to AUTH_TOPIC. *)
val llmToken : string option =
  (case OS.Process.getEnv "ANTHROPIC_AUTH_TOKEN" of
       SOME t => SOME t
     | NONE   => OS.Process.getEnv "AUTH_TOPIC")
val llmModel : string option = OS.Process.getEnv "CORDIS_LLM_MODEL"

fun envOf (name : string) (def : string) : string =
  case OS.Process.getEnv name of SOME v => v | NONE => def

(* Build an OpenAI-compatible chat/completions request body. *)
fun llmBody (model : string) (task : string) (history : string list) : string =
  let
    (* The model only sees tools that are actually registered in the
       toolRegistry, so it can't hallucinate a tool name. *)
    val tools = String.concatWith " " (AList.keys toolRegistry)
    val sys =
      "You are a ReAct agent inside a Cordis supervisor tree. " ^
      "Available tools (must CALL_TOOL or LOAD one of these exactly): " ^
      tools ^ ".\n" ^
      "Use the ReAct loop: THOUGHT -> LOAD a tool -> CALL_TOOL <- observe, repeat. " ^
      "When the task is complete, emit FINISH."
    val hist = String.concatWith "\n" (map (fn h => "- " ^ h) history)
    val usr =
      "Task: " ^ task ^ "\n" ^
      (if hist = "" then "No history yet.\n" else "History:\n" ^ hist ^ "\n") ^
      "Respond with EXACTLY ONE of these directives, nothing else:\n" ^
      "THOUGHT: <text>\n" ^
      "LOAD: <tool-name>\n" ^
      "CALL_TOOL: <name>|<argument>\n" ^
      "FINISH: <done-reason>"
  in
    "{\"model\":\"" ^ jsonEscape model ^ "\",\"messages\":[" ^
      "{\"role\":\"system\",\"content\":\"" ^ jsonEscape sys ^ "\"}," ^
      "{\"role\":\"user\",\"content\":\"" ^ jsonEscape usr ^ "\"}" ^
      "],\"max_tokens\":512}"
  end

(* Parse a single directive line into an `action`. *)
fun parseDirective (line : string) : action option =
  let
    val l = trim line
    fun after (pfx : string) : string option =
      let val pl = String.size pfx
          val nl = String.size l
      in if nl >= pl andalso String.extract (l, 0, SOME pl) = pfx
         then SOME (trim (String.substring (l, pl, nl - pl))) else NONE end
  in
    (case after "THOUGHT:" of
        SOME t => SOME (Thought (if t = "" then line else t))
      | NONE =>
        case after "CALL_TOOL:" of
            SOME s =>
              (case String.fields (fn c => c = #"|") s of
                   [n, a] => SOME (CallTool (trim n, trim a))
                 | [n]    => SOME (CallTool (trim n, ""))
                 | _      => SOME (Thought line))
          | NONE =>
            case after "LOAD:" of
                SOME t => SOME (LoadTool (trim t))
              | NONE =>
                case after "FINISH:" of
                    SOME t => SOME (Finish t)
                  | NONE   => SOME (Thought line))
  end

(* Block until a forked child is reaped. The exit status is ignored:
   we read the curl output file regardless, and degrade to a Finish if
   the gateway failed. *)
fun reapChild (pid : Posix.Process.pid) : unit =
  case Posix.Process.waitpid_nh (Posix.Process.W_CHILD (pid), []) of
      NONE => ( OS.Process.sleep (Time.fromMilliseconds 150); reapChild pid )
    | SOME _ => ()

(* Run one curl request in a forked child, write the response to `out`.
   Using fork + exece (not Posix.Process.system, which this basis layer
   does not expose) — and, per v4's design note, exece immediately so
   the child never inherits the parent's GC threads. A minimal env
   (PATH + HOME=/tmp) keeps curl from reading the user's ~/.curlrc. *)
fun curlOnce (base : string) (token : string) (bodyFile : string)
             (out : string) : unit =
  let
    val url = base ^ "/v1/chat/completions"
    val env = ["PATH=/usr/bin:/bin", "HOME=/tmp"]
    val args = ["/usr/bin/curl", "-sS", "-m", "30",
                "-X", "POST", url,
                "-H", "Content-Type: application/json",
                "-H", "Authorization: Bearer " ^ token,
                "-H", "ANTHROPIC_AUTH_TOKEN: " ^ token,
                "-d", "@" ^ bodyFile,
                "-o", out]
  in
    case Posix.Process.fork () of
        NONE =>
          ( Posix.Process.exece ("/usr/bin/curl", args, env)
              handle _ => ( Posix.Process.exit 0w1 ) )
      | SOME pid => reapChild pid
  end

(* The `next` function that drives one ReAct step from a real gateway. *)
fun llmNext (base : string) (token : string) (model : string)
            (state : reactState) : action =
  let
    (* Unique temp file names for this process, so concurrent calls
       (unlikely here — ReAct is sequential) never clobber each other. *)
    val pid      = Posix.ProcEnv.getpid ()
    val counter  = !tick
    val stamp    = Int.toString (SysWord.toInt (Posix.Process.pidToWord pid))
                 ^ "-" ^ Int.toString counter
    val bodyFile = "/tmp/cordis-llm-" ^ stamp ^ ".body"
    val outFile  = "/tmp/cordis-llm-" ^ stamp ^ ".out"
    val body     = llmBody model (#task state) (#history state)
    val bfd      = TextIO.openOut bodyFile
    val _        = TextIO.output (bfd, body)
    val _        = TextIO.closeOut bfd
    val _ = curlOnce base token bodyFile outFile
    (* CORDIS_LLM_KEEP_BODY=1 keeps the request body on disk for debugging. *)
    val _ = if envOf "CORDIS_LLM_KEEP_BODY" "" = "" then
              (OS.FileSys.remove bodyFile) handle _ => ()
            else ()
    val raw =
      ( let val fd = TextIO.openIn outFile
            val b = TextIO.inputAll fd
            val _ = TextIO.closeIn fd
        in b end )
      handle _ => ""
    val _ = (OS.FileSys.remove outFile) handle _ => ()
    (* The endpoint wraps its answer in JSON:
         {"content":"..."} or the chat-completions shape
         {"choices":[{"message":{"content":"..."}}]}.
       We pull out the first quoted string after `"content"`. Tolerates
       whitespace left by the gateway, e.g. `"content": "..."`. *)
    val cl = String.size raw
    fun findSub (i : int) (needle : string) : int option =
      let val nl = String.size needle
          fun try j = if j + nl <= cl
                         andalso String.extract (raw, j, SOME nl) = needle
                      then SOME j else NONE
          fun scan j = if j + nl > cl then NONE
                       else (case try j of SOME _ => SOME j | NONE => scan (j + 1))
      in scan i end
    (* From the position right after `"content"`, skip whitespace and a
       colon, then expect the opening `"`. *)
    fun afterOpen (pos : int) : string option =
      let fun skipWs j = if j < cl andalso Char.isSpace (String.sub (raw, j))
                         then skipWs (j + 1) else j
          val j0 = skipWs pos
          val j1 = if j0 < cl andalso String.sub (raw, j0) = #":" then j0 + 1 else j0
          val j2 = skipWs j1
      in if j2 < cl andalso String.sub (raw, j2) = #"\"" then
           SOME (jsonStrip (String.substring (raw, j2, cl - j2)))
         else NONE end
    val directive =
      case findSub 0 "\"content\"" of
          SOME pos => (case afterOpen (pos + 9) of
                           SOME d => d
                         | NONE   => raw)
        | NONE   => raw
  in
    (case parseDirective directive of
         SOME a => a
       | NONE   => Finish ("no action parsed: " ^ trim directive))
  end

(* ============================================================
   7. Reasoner: reusable for supervisor AND workers
   -----------------------------------------------------------
   Takes an explicit `next` function so we can inject different
   scripts per fork without going through Svc.
   ============================================================ *)
fun runReasoner
      { ctx        : ctx,
        agentId    : string,
        task       : string,
        maxSteps   : int,
        next       : reactState -> action,
        sup        : supervisorState }
      : unit =
  let
    val history = ref ([] : string list)
    fun push s = history := s :: !history
    fun prefix () = "[" ^ agentId ^ "] "

    fun step n =
      if n > maxSteps then log ("  " ^ prefix () ^ "[WARN] maxSteps") else
      let val act = next { task = task, history = List.rev (!history) }
      in case act of
           Thought s =>
             ( log ("  " ^ prefix () ^ "[THINK] " ^ s)
             ; push ("thought: " ^ s); step (n + 1) )
         | LoadTool name =>
             ( log ("  " ^ prefix () ^ "[ACT] load(" ^ name ^ ")")
             ; case AList.find toolRegistry name of
                   NONE =>
                     ( log ("  " ^ prefix () ^ "[ERR] unknown tool"); step (n + 1) )
                 | SOME {mount, ...} =>
                     ( mount ctx; push ("loaded: " ^ name); step (n + 1) ) )
         | CallTool (name, arg) =>
             ( log ("  " ^ prefix () ^ "[ACT] call(" ^ name ^ ", \"" ^ arg ^ "\")")
             ; case AList.find toolRegistry name of
                   NONE => ( log ("  " ^ prefix () ^ "[ERR] unknown tool"); step (n + 1) )
                 | SOME {invokeStr, ...} =>
                     let val obs = invokeStr arg
                     in log ("  " ^ prefix () ^ "[OBS] " ^ obs)
                      ; push ("obs: " ^ obs); step (n + 1) end )
         | Spawn {childId, task=ctask, script} =>
             ( log ("  " ^ prefix () ^ "[SPAWN] " ^ childId ^ " task=\"" ^ ctask ^ "\"")
             ; let val ch = fork ctx childId
                   val childScript = ref script
                   val _ = #children sup := ch :: !(#children sup)
                   val _ = runReasoner
                             { ctx = #ctx ch, agentId = childId,
                               task = ctask, maxSteps = 20,
                               next = scriptedNext childScript,
                               sup = { children = ref [] } }
               in push ("spawned: " ^ childId); step (n + 1) end )
         | WaitAll =>
             let val live = List.filter (fn c => #alive c ()) (!(#children sup))
             in log ("  " ^ prefix () ^ "[WAIT] live children: "
                     ^ Int.toString (length live))
              ; push ("waited: " ^ Int.toString (length live))
              ; step (n + 1)
             end
         | Finish s =>
             ( log ("  " ^ prefix () ^ "[FINISH] " ^ s)
             ; emit ctx "agent/done" (Fail (agentId ^ ": " ^ s)) )
      end
  in
    log ("  " ^ prefix () ^ "[START] task=\"" ^ task
         ^ "\" scope=<" ^ scopeName (ctxScope ctx)
         ^ "> depth=" ^ Int.toString (scopeDepth (ctxScope ctx)));
    step 0
  end

(* ============================================================
   8. Supervisor scripts
   ============================================================ *)

(* Two worker scripts used by the supervisor *)
val mathWorkerScript = [
  Thought "worker/math: I compute 7*8",
  LoadTool "calc",
  CallTool ("calc", "7*8"),
  LoadTool "write",
  CallTool ("write", "math_answer | 7*8=56"),
  Finish "math done"
]

val researchWorkerScript = [
  Thought "worker/research: I look up cordis + functor",
  LoadTool "search",
  CallTool ("search", "cordis"),
  CallTool ("search", "functor"),
  LoadTool "write",
  CallTool ("write", "research_note | cordis+functor collected"),
  Finish "research done"
]

(* A worker we will KILL mid-flight to prove partial dispose *)
val longRunningScript = [
  Thought "worker/slow: pretend I'd loop forever",
  LoadTool "calc",
  CallTool ("calc", "1+1"),
  Thought "still working...",
  CallTool ("calc", "2+2"),
  Thought "you should never see me because I get killed",
  CallTool ("calc", "3+3"),
  Finish "slow done"
]

val supervisorScript = [
  Thought "supervisor plan: spawn math + research + slow, then wait",
  Spawn { childId = "math",     task = "compute 7*8", script = mathWorkerScript },
  Spawn { childId = "research", task = "explain cordis+functor", script = researchWorkerScript },
  Spawn { childId = "slow",     task = "a slow worker",          script = longRunningScript },
  WaitAll,
  Finish "supervisor finished orchestration"
]

(* ============================================================
   8b. Select the `next` used by the top supervisor.
   -----------------------------------------------------------
   Default (CORDIS_LLM_REAL unset): scriptedNext, the original demo.
   When CORDIS_LLM_REAL=1 AND both the token (ANTHROPIC_AUTH_TOKEN,
   or AUTH_TOPIC) + ANTHROPIC_BASE_URL are set: llmNext reads them
   from the environment (never hardcoded) and drives the supervisor
   through the real gateway.
   ============================================================ *)
fun realLLMNext () : reactState -> action =
  case (llmToken, llmBase) of
      (SOME tok, SOME base) =>
        llmNext base tok (envOf "CORDIS_LLM_MODEL" "claude-opus-5")
    | _ => scriptedNext (ref supervisorScript)

val llmEnabled : bool =
  case OS.Process.getEnv "CORDIS_LLM_REAL" of
      SOME "1" => true | SOME "true" => true | _ => false

(* A concrete task for the LLM-driven supervisor. The scripted demo's task
   ("orchestrate math + research + slow workers") is meaningless to a real
   model with no target; give it something it can actually do with the
   registered tools. Override with CORDIS_LLM_TASK. *)
val supTask : string =
  envOf "CORDIS_LLM_TASK"
        ("Work on these three things, using the calc, search and write tools:\n" ^
         "1. Compute 7*8 and record it as a note named math_answer.\n" ^
         "2. Look up 'cordis' and 'functor', then record a research_note.\n" ^
         "3. When done, finish with a short summary of all three results.")

(* ============================================================
   9. Main
   ============================================================ *)
fun listArtifacts () =
  ( log ("  [ARTIFACTS] count=" ^ Int.toString (length (!artifacts)))
  ; List.app (fn (k, v) => log ("    - " ^ k ^ " = " ^ v)) (!artifacts) )

fun main () =
  let
    val () = section "PHASE 1 - root: install logger"
    val root = rootCtx ()
    val _ = plugin root loggerPlugin ()

    val () = section "PHASE 2 - launch Supervisor (own scope, own children list)"
    val supScope = newScope "agent:supervisor" (SOME (ctxScope root))
    val supCtx   = childCtx root supScope
    val supState : supervisorState = { children = ref [] }
    val supScript = ref supervisorScript
    val supTaskV = if llmEnabled then supTask else "orchestrate math + research + slow workers"
    val supNext =
      if llmEnabled then realLLMNext ()
      else scriptedNext supScript
    val () = runReasoner
               { ctx = supCtx, agentId = "supervisor",
                 task = supTaskV,
                 maxSteps = 30,
                 next = supNext,
                 sup = supState }

    val () = section "PHASE 3 - inspect supervisor tree"
    val _ = log ("  supervisor has " ^ Int.toString (length (!(#children supState)))
                 ^ " tracked children:")
    val _ = List.app (fn c =>
              log ("    - " ^ #id c ^ " alive=" ^ Bool.toString (#alive c ())
                   ^ " scope=<" ^ scopeName (ctxScope (#ctx c)) ^ ">"))
              (!(#children supState))

    val () = section "PHASE 4 - artifacts written so far"
    val _ = listArtifacts ()

    val () = section "PHASE 5 - PARTIAL DISPOSE: kill only the 'slow' worker"
    val _ = case List.find (fn c => #id c = "slow") (!(#children supState)) of
              SOME slow => #kill slow ()
            | NONE => log "  slow not found"
    val _ = log "  after kill, sibling status:"
    val _ = List.app (fn c =>
              log ("    - " ^ #id c ^ " alive=" ^ Bool.toString (#alive c ())))
              (!(#children supState))

    val () = section "PHASE 6 - spawn a LATE worker under supervisor"
    val lateScript = ref [
      Thought "worker/late: I was spawned after the initial batch",
      LoadTool "search",
      CallTool ("search", "agent"),
      Finish "late done"
    ]
    val lateCh = fork supCtx "late"
    val _ = #children supState := lateCh :: !(#children supState)
    val _ = runReasoner
              { ctx = #ctx lateCh, agentId = "late",
                task = "run after the fact", maxSteps = 20,
                next = scriptedNext lateScript,
                sup = { children = ref [] } }

    val () = section "PHASE 7 - FULL DISPOSE: kill the supervisor"
    (* Observe: every surviving child (math, research, late) goes with it. *)
    val _ = disposeScope supScope
    val _ = log "  after supervisor dispose, tracked children:"
    val _ = List.app (fn c =>
              log ("    - " ^ #id c ^ " alive=" ^ Bool.toString (#alive c ())))
              (!(#children supState))

    val () = section "PHASE 8 - verify: tools retracted, root still healthy"
    val _ = List.app (fn n =>
              case Svc.get n of
                  SOME _ => log ("  [+] " ^ n ^ " still live")
                | NONE   => log ("  [-] " ^ n ^ " gone"))
              ["tool/calc@v1", "tool/search@v1", "tool/write@v1", "logger"]

    val () = section "PHASE 9 - dispose root (final)"
    val _ = disposeScope (ctxScope root)

    val () = section "DONE"
  in () end

val _ = main ()
val _ = OS.Process.exit OS.Process.success
