#! /usr/bin/guile \
-e main -s
!#
;; Simple telnet chat server in Guile Scheme
;; v1.0 by Joe Eib 09/2016
;;
;;     This simple telnet chat server was made as a way to explore
;; Guile's capabilities as well as to get a bit of lisp practice.
;; An attempt was made at conisistency, generality, and extensibility
;; but since there wasn't really any planned architecture going in
;; there are almost undoubtedly many oversights and deviations.
;; Features include a basic user system, a basic command system with
;; a few essentials, ANSI color for both the terminal and clients,
;; and separate threads for each client. It is not known how the server
;; will behave when the terminal or client doesn't support ANSI color.
;; Anything defined by the make-parameter procedure is a per-thread
;; parameter and thus may be overridden in any thread by using the form
;; (param-name new-value)
;; Potential issues:
;; - There is absolutely no name validation or censorship. It's possible
;; to make usernames with invisible characters.
;; - It's possible that disconnections at certain points might cause
;; errors and zombie users in the user-list.
;; - No exception handling of any kind

(use-modules (srfi srfi-1)
             (srfi srfi-9)
             (ice-9 getopt-long)
             (ice-9 rdelim)
             (ice-9 receive))

;; Command data type
;;     Used for server commands, which are invoked by users with a
;; preceeding slash e.g. /help.
;;
;; name : string
;; admin-only : boolean
;; helptext : string
;; action : procedure
(define-record-type <command>
  (make-command name admin-only helptext action)
  command?
  (name command-name)
  (admin-only command-admin-only?)
  (helptext command-helptext)
  (action command-action))

;; User data type
;;    Used by the server for storing info about connected users.
;; The addr field is currently unused but it could be used to
;; implement a kick/ban system
;;
;; name : string
;; admin : boolean
;; port : socket port
;; addr : (socket-port . socket-address)
(define-record-type <user>
  (make-user name admin port addr)
  user?
  (name user-name set-user-name!)
  (admin user-admin? set-user-admin!)
  (port user-port)
  (addr user-addr))

;; Server data and settings
(define server-input-port (make-parameter 6788))
(define server-input-socket (socket PF_INET SOCK_STREAM 0))
(define server-max-listen (make-parameter 5))
(define server-username "SERVER")
(define server-user (make-user server-username
                               #t
                               (current-output-port)
                               #f))
(define thread-user (make-parameter server-user))
(define user-list (list server-user))
(define user-prompt (make-parameter "> "))

;; Command line option spec
(define getopt-spec
  '((port (single-char #\p) (value #t))))

;; Color settings and data
;;     I *believe* these require 32 color support
(define color-blue (string-append (string #\esc) "[0;94m"))
(define color-charcoal (string-append (string #\esc) "[0;90m"))
(define color-cyan (string-append (string #\esc) "[0;96m"))
(define color-default (string-append (string #\esc) "[0m"))
(define color-green (string-append (string #\esc) "[0;32m"))
(define color-grey (string-append (string #\esc) "[0;37m"))
(define color-lime (string-append (string #\esc) "[0;92m"))
(define color-magenta (string-append (string #\esc) "[0;95m"))
(define color-navy (string-append (string #\esc) "[0;34m"))
(define color-orange (string-append (string #\esc) "[0;33m"))
(define color-purple (string-append (string #\esc) "[0;35m"))
(define color-red (string-append (string #\esc) "[0;91m"))
(define color-ruby (string-append (string #\esc) "[0;31m"))
(define color-teal (string-append (string #\esc) "[0;36m"))
(define color-white (string-append (string #\esc) "[0;97m"))
(define color-yellow (string-append (string #\esc) "[0;93m"))

(define color-username color-cyan)
(define color-server-username color-ruby)
(define color-speech color-grey)
(define color-greeting color-green)
(define color-info color-yellow)

(define (colorize str color)
  (string-append color str color-default))

;; Messages
;;     These should define both the content and the color. Use
;; procedures when dynamicity is required.
(define msg-motd (colorize "Welcome to the flippin server m8"
                           color-greeting))
(define (msg-connect name) (colorize (simple-format #f
                                                    "~A has connected."
                                                    name)
                                     color-info))
(define (msg-disconnect name) (colorize (simple-format #f
                                                       "~A has disconnected."
                                                       name)
                                        color-info))
(define msg-logout (colorize "Goodbye!" color-greeting))
(define msg-shutdown (colorize "Server is going down NOW." color-red))

;; Commands
;;     Direct lambdas are used rather than discreet defines in the
;; action field to prevent issues with the order in which top-level
;; defines are executed.
(define command-help
  (make-command "help"
                #f
                (string-append "\tUsage: /help or /help [command]\n"
                               "\tShows a list of commands or info about a specific command.")
                (lambda (arg)
                  (let ((where (user-port (thread-user))))
                    (if (string-null? arg)
                        (begin
                          (send-to "List of commands: " where)
                          (send-to (command-list-string) where))
                        (let ((found-command (find-command arg)))
                          (if (command? found-command)
                              (begin
                                (send-to
                                 (simple-format #f
                                                "Command \"~A\":"
                                                (command-name found-command))
                                 where)
                                (send-to (command-helptext found-command)
                                         where))
                              (command-error arg))))))))

(define command-quit
  (make-command "quit"
                #f
                "\tQuits the server."
                (lambda (arg)
                  (if (eqv? (thread-user) server-user)
                      (shutdown-server)
                      (user-logout)))))

(define command-who
  (make-command "who"
                #f
                "\tShow who's currently on the server."
                (lambda (arg)
                  (let ((where (user-port (thread-user))))
                    (send-to "Users online: " where)
                    (send-to (user-list-string) where)))))

;; Note: The order of these will affect what happens when you
;; use a shorter prefix of the command's name. E.G. if you have
;; a command called "foo1" and another called "foo2", entering the
;; comand "/f" on the server will match whichever is listed first.
(define command-list (list command-help command-quit command-who))

;; Procedures
(define (command-error command)
  "command-error :: <command> -> side-effect
Called when an entered user command is not recognized. Uses
the thread-user parameter."
  (send-to (simple-format #f "Command \"~A\" not recognized."
                          command)
           (user-port (thread-user))))

(define (command-list-string)
  "command-list-string :: none -> string
Results in a string containing a tabulated list of all available
user commands. Any admin-only commands are omitted for non-admin
users. Uses the implicit parameter thread-user"
  (apply string-append
         (map (lambda (x)
                (if (command-admin-only? x)
                    (when (user-admin? (thread-user))
                      (string-append "\t" (command-name x)))
                    (string-append "\t" (command-name x))))
              command-list)))

(define (find-command search-string)
  "find-command :: string -> <command> or #f
Return the first command for which search-string is a prefix of
its name or #f if no match is found"
  (find (lambda (x) (string-prefix? search-string (command-name x)))
        command-list))

(define (get-input)
  "get-input :: side-effect -> string
Wait for input from the port bound to the implicit parameter thread-user.
The procedure's result is the input string trimmed of any leading or
trailing whitespace. If thread-user is the server-user then
current-input-port must be used because server-user has separate
input and output ports. If the user suddenly disconnects while the
server waits for input, they are appropriately handled with user-kill"
  (let ((input-port (if (eqv? (thread-user) server-user)
                        (current-input-port)
                        (user-port (thread-user)))))
    (show-prompt)
    (while (char-ready? input-port) #f) ; wait for input
    (string-trim-both (let ((line (read-line input-port)))
                        (if (eof-object? line)
                          (user-kill)
                          line)))))

(define (handle-command)
  "handle-command :: infinitely-recursive procedure
The main event loop for each thread. It calls a procedure that returns
multiple values with which it decides which command to execute. This
procedure only exits when the thread itself is closed by another procedure."
  (receive (command arg) (parse-command (get-input))
    (if (not (string-null? command))
        (let ((found-command (find-command command)))
          (if (command? found-command)
              ((command-action found-command) arg)
              (command-error command)))
        (say arg))
    (handle-command)))

(define (main args)
  "main :: string -> infinitely-recusive procedure
Prepares the server input socket, spawns a new thread to start accepting
connections, then begins handling server-user commands"
  (let* ((options (getopt-long args getopt-spec))
         (option-port (option-ref options 'port #f)))
    (when option-port (server-input-port (string->number option-port))))

  (setsockopt server-input-socket SOL_SOCKET SO_REUSEADDR 1)
  (bind server-input-socket AF_INET INADDR_ANY (server-input-port))
  (listen server-input-socket (server-max-listen))

  (send-to (simple-format #f
                          "Now listening on port ~A in pid ~A"
                          (server-input-port)
                          (getpid))
           (user-port server-user))

  ;; Start accepting connections
  (call-with-new-thread run-server-thread)

  (handle-command))

(define (parse-command str)
  "parse-command :: string -> string string
Accepts a user input string and results in two values: one corresponding
to any slash-preceeded command (the shash is stripped for the output) and
the other representing any remaining text which is interpereted as the
command's argument. If there's no command, the entire input is passed as
the argument. Any lack of command or argument results in an empty string
for that value"
  (if (string-prefix? "/" str)
      (let ((space (string-index str #\ )))
        (if (number? space)
            (values (substring str 1 space) (substring str (+ 1 space)))
            (values (substring str 1) "")))
      (values "" str)))

(define (run-server-thread)
  "run-server-thread :: side-effect -> infinitely-recursive procedure
Acquires a new user to replace this thread's thread-user parameter and
begins interpreting user commands."
  ;; Set this thread's parameters
  (thread-user (user-login (accept server-input-socket)))
  (set-thread-cleanup! (current-thread) user-logout)

  (handle-command))

(define (say msg)
  "say :: string -> side-effect
Sends a chat message to all users on the server"
  (let ((name (user-name (thread-user)))
        (name-color (if (eqv? (thread-user) server-user)
                        color-server-username
                        color-username)))
    (send-to-users (simple-format #f "~A: ~A"
                                  (colorize name name-color)
                                  (colorize msg color-grey))
                   user-list)))

(define (send-to msg where)
  "send-to :: string, port -> side-effect
Convenience procedure so that every message doesn't have to end in \\n"
  (display msg where)
  (newline where))

(define (send-to-users msg userlist)
  "send-to-users :: string, (<user>) -> side-effect
Send a message to multiple users"
  (map (lambda (x) (send-to msg x)) (map user-port userlist)))

(define (show-prompt)
  "show-prompt :: none -> side-effect
Show the implict parameter user-prompt to the implicit thread-user"
    (display (user-prompt) (user-port (thread-user))))

(define (shutdown-server)
  "shutdown-server :: none -> side-effect
Gracefully closes all threads and exits the program"
  (let ((server-port (user-port server-user)))
    (send-to "Shutting down server..." server-port)
    (send-to-users msg-shutdown user-list)

    (send-to "Stopping all threads..." server-port)
    (map cancel-thread (delete (current-thread) (all-threads)))

    (close server-input-socket)
    (display "Server shutdown successful" server-port)
    (newline server-port))
  (exit EXIT_SUCCESS))

(define (user-kill)
  "user-kill :: none -> side-effect
Used when a user has disconnected unexpectedly to remove their <user> from
the user-list and gracefully exit their thread."
  (set! user-list (delete (thread-user) user-list))
  (send-to-users (msg-disconnect (user-name (thread-user)))
                 user-list)
  (while (not (thread-exited? (current-thread)))
    (cancel-thread (current-thread))))

(define (user-list-string)
  "user-list-string :: none -> string
Results in a tabulated string containing a list of all current users"
  (string-join (map user-name user-list) "\t" 'prefix))

(define (user-login conn-info)
  "user-login :: socket-address -> <user>
First spawns another thread to immediately begin accepting new connections.
Then the new user must select a unique user name. If the connection is
interrupted during this process, the thread is closed gracefully. Result
is the new <user>"
  (let ((client (car conn-info)) (addr (cdr conn-info)))
    ;; Start another client-handler thread
    (call-with-new-thread run-server-thread)

    (display "Please choose a username: " client)
    (while (char-ready? client) #f) ; wait for input
    (let* ((line (read-line client))
           (name (string-trim-right (if (eof-object? line)
                                        (while (not (thread-exited?
                                                     (current-thread)))
                                          (cancel-thread (current-thread)))
                                        line))))
      (if (not (member name (map user-name user-list)))
          (begin
            (let ((user (make-user name #f client addr)))
              (set! user-list (append user-list (list user)))
              (send-to-users (msg-connect name)
                             (delete user user-list))
              (send-to msg-motd client)
              user))
          (begin
            (display (simple-format #f "The name \"~A\" is already in use.\n" name) client)
            (user-login conn-info))))))

(define (user-logout)
  "user-logout :: none -> side-effect
Displays the logout message for the implicit thread-user, closes their
connection and gracefully terminates their thread."
  (send-to msg-logout (user-port (thread-user)))
  (set! user-list (delete (thread-user) user-list))
  (close (user-port (thread-user)))
  (send-to-users (msg-disconnect (user-name (thread-user)))
                 user-list)
  (while (not (thread-exited? (current-thread)))
    (cancel-thread (current-thread))))
