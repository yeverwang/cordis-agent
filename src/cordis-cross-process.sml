(* ============================================================
   cordis-cross-process.sml   -- v4: OS-level supervisor tree
   -----------------------------------------------------------
   Field Manual No.04 -- companion to v3.

   IMPORTANT DESIGN NOTE
   ---------------------
   Poly/ML's runtime pools GC threads. Calling Posix.Process.fork
   from a running Poly/ML image can leak these threads into the
   child and hang. The portable fix used by real projects (and
   what we do here) is:

     - compile TWO independent binaries
     - the SUPERVISOR fork()s and then execve()s the WORKER
       binary, replacing its address space entirely -- no shared
       GC threads, no leaked handles

   This mode is set by an environment variable CORDIS_MODE:
     supervisor  -- default, does the forking + signalling
     worker      -- runs a heartbeat loop; used as the exec target

   Build:  make cordis
   Run  :  ./bin/cordis

   Compatible with Linux/macOS (Poly/ML 5.7+, POSIX).
   ============================================================ *)

(* ---------- 0. Logging with pid ---------- *)
val tick = ref 0
fun pidToInt p = SysWord.toInt (Posix.Process.pidToWord p)
fun myPid () = pidToInt (Posix.ProcEnv.getpid ())

fun log s =
  ( tick := !tick + 1
  ; print (concat ["[t=", Int.toString (!tick),
                   " pid=", Int.toString (myPid ()), "] ", s, "\n"])
  ; TextIO.flushOut TextIO.stdOut )

fun section t =
  ( print "\n============================================================\n"
  ; print ("  " ^ t ^ "\n")
  ; print   "============================================================\n"
  ; TextIO.flushOut TextIO.stdOut )

(* ---------- 1. Child registry (parent side only) ---------- *)
type childRec = { name : string, pid : Posix.Process.pid }
val children : childRec list ref = ref []

(* ---------- 2. Fork + exec a worker binary ----------------
   Precondition: the running executable path is knowable via
   argv[0]; we re-exec the SAME binary with CORDIS_MODE=worker.
   This is the same trick systemd, docker-runc and many
   supervisors use to bootstrap sandboxed children.
   ---------------------------------------------------------- *)
fun forkExecWorker (self : string, name : string, iters : int) : unit =
  case Posix.Process.fork () of
      NONE => (* CHILD *)
        let val env = [
              "CORDIS_MODE=worker",
              "CORDIS_NAME=" ^ name,
              "CORDIS_ITERS=" ^ Int.toString iters,
              "PATH=" ^ Option.getOpt (OS.Process.getEnv "PATH", "/usr/bin:/bin")
            ]
        in
          (* join parent's process group *)
          (Posix.ProcEnv.setpgid { pid = NONE, pgid = NONE })
            handle _ => ();
          (* execve replaces this process entirely *)
          Posix.Process.exece (self, [self, name], env)
            handle e =>
              ( TextIO.output (TextIO.stdErr,
                  "exec failed: " ^ exnMessage e ^ "\n")
              ; Posix.Process.exit 0w127 )
        end
    | SOME pid => (* PARENT *)
        let val parentPid = Posix.ProcEnv.getpid ()
            val _ = Posix.ProcEnv.setpgid
                      { pid = SOME pid, pgid = SOME parentPid }
                    handle _ => ()
        in log ("[FORK] '" ^ name ^ "' pid=" ^ Int.toString (pidToInt pid))
         ; children := { name = name, pid = pid } :: !children
        end

(* ---------- 3. Signal broadcast ----------------------------
   NOTE: `kill(-pgid, sig)` sends to every process in the group
   INCLUDING the sender. In production one either:
     (a) install a SIG_IGN handler on the parent before the
         broadcast (real supervisors do this), or
     (b) iterate over tracked child pids and send K_PROC per pid
   Poly/ML 5.7 does not expose sigaction, so we use (b) here.
   Semantically identical for our tree; loses the "one syscall"
   optimization but is portable across SML implementations.
   ---------------------------------------------------------- *)
fun broadcastSignal sig' =
  ( log ("[BROADCAST] signal to " ^ Int.toString (length (!children))
         ^ " child(ren)")
  ; List.app (fn c =>
      (Posix.Process.kill (Posix.Process.K_PROC (#pid c), sig'))
        handle e => log ("  kill err for " ^ #name c ^ ": " ^ exnMessage e))
      (!children) )

(* ---------- 4. Reap ---------- *)
fun reapAllOnce () =
  case Posix.Process.waitpid_nh (Posix.Process.W_ANY_CHILD, [])
       handle _ => NONE
    of NONE => 0
     | SOME (pid, _) =>
         ( log ("[REAP] pid=" ^ Int.toString (pidToInt pid))
         ; 1 + reapAllOnce () )

(* Track reaped pids so we can compute how many are still alive.
   waitpid_nh returns NONE both for "no children exited yet" and
   for "no children at all" -- we cannot distinguish, so we keep
   our own alive count. *)
val reapedCount = ref 0
fun reapAllOnceTracked () =
  case Posix.Process.waitpid_nh (Posix.Process.W_ANY_CHILD, [])
       handle _ => NONE
    of NONE => 0
     | SOME (pid, _) =>
         ( log ("[REAP] pid=" ^ Int.toString (pidToInt pid))
         ; reapedCount := !reapedCount + 1
         ; 1 + reapAllOnceTracked () )

fun aliveCount () = length (!children) - !reapedCount

fun reapWithDeadline maxIters =
  let fun loop i =
        if i <= 0 orelse aliveCount () = 0 then ()
        else ( OS.Process.sleep (Time.fromMilliseconds 200)
             ; ignore (reapAllOnceTracked ())
             ; loop (i - 1) )
      val _ = loop maxIters
  in aliveCount () end

(* ---------- 5. Graceful shutdown ---------- *)
fun gracefulShutdown graceIters =
  ( section ("SHUTDOWN -- grace " ^ Int.toString (graceIters * 200) ^ "ms")
  ; broadcastSignal Posix.Signal.term
  ; log "  waiting for graceful exits ..."
  ; let val leftover = reapWithDeadline graceIters
    in if leftover = 0
       then log "[OK] all children reaped gracefully"
       else ( log ("[TIMEOUT] " ^ Int.toString leftover
                   ^ " child(ren) still alive -- SIGKILL")
            ; broadcastSignal Posix.Signal.kill
            ; ignore (reapWithDeadline 5)
            ; log "[OK] hard-killed remainder" )
    end )

(* ---------- 6. Worker body ---------- *)
fun runWorker () =
  let val name = Option.getOpt (OS.Process.getEnv "CORDIS_NAME", "anon")
      val iters = Option.getOpt (
                    Option.mapPartial Int.fromString
                       (OS.Process.getEnv "CORDIS_ITERS"), 5)
      fun tick i =
        if i > iters then ()
        else ( log ("  [worker " ^ name ^ "] tick "
                    ^ Int.toString i ^ "/" ^ Int.toString iters)
             ; OS.Process.sleep (Time.fromMilliseconds 300)
             ; tick (i + 1) )
  in log ("[WORKER START] name=" ^ name ^ " iters=" ^ Int.toString iters)
   ; tick 1
   ; log "[WORKER DONE]"
   ; Posix.Process.exit 0w0
  end

(* ---------- 7. Supervisor body ---------- *)
fun runSupervisor (self : string) =
  let val () = section "PHASE 1 -- parent bootstrap"
      val () = log ("parent pid=" ^ Int.toString (myPid ()))
      val _  = Posix.ProcEnv.setpgid { pid = NONE, pgid = NONE }
               handle _ => ()

      val () = section "PHASE 2 -- fork+exec three workers"
      val () = forkExecWorker (self, "math",     3)
      val () = forkExecWorker (self, "research", 3)
      val () = forkExecWorker (self, "slow",     20)  (* will need killing *)

      val () = log ("tracked: "
                    ^ String.concatWith ","
                        (map (fn c => #name c ^ "@"
                                       ^ Int.toString (pidToInt (#pid c)))
                             (!children)))

      val () = section "PHASE 3 -- supervise for ~1s"
      val () = OS.Process.sleep (Time.fromMilliseconds 1000)

      val () = section "PHASE 4 -- graceful shutdown"
      val () = gracefulShutdown 5    (* 5 * 200ms = 1s grace, then SIGKILL *)

      val () = section "DONE"
  in () end

(* ---------- 8. Entry ---------- *)
fun main () =
  let val mode = Option.getOpt (OS.Process.getEnv "CORDIS_MODE", "supervisor")
      val self = case CommandLine.arguments () of
                     _ => CommandLine.name ()
  in case mode of
        "worker"     => runWorker ()
      | "supervisor" => runSupervisor self
      | other        => ( log ("unknown mode: " ^ other)
                        ; OS.Process.exit OS.Process.failure )
  end

val _ = PolyML.export ("cordis-cross-process", main)
