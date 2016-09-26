# lambdachat

This is a simple [i.e. naive] hobby project undertaken to explore the capabilities of GNU Guile as well as gain a bit of progamming experience. It implements a vey basisc, low-frills telnet chat server with ANSI color, a system of users, and chat commands. An attempt was made to make it easily hackable and for once actually includes a completely documented source. It is presented here in the hope that it may be useful. Perhaps as an example of what [not] to do.

## Usage:
./lambdachat [-p --port portnumber]

Note: lambdachat expects the guile binary to be located at /usr/bin/guile

## System Requirements:
- GNU Guile
- 32 color support for the server terminal as well as clients

## Ideas for the future:
- Remove ugly global state in userlist
- Remove ugly mutation by set!
- Separate things into multiple files and use load?
- Save/read user info in sexp form to/from a separate Scheme file.
