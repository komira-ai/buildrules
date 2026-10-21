# toolbox

The small programs a test expects on its `PATH`, as one static Zig executable: `rm`, `mkdir`, `sleep`, `echo`, `cat`, `env`, `printenv`,
`true` and `false`. It is chosen by how it is called: a link named for an applet runs that applet, and `toolbox <applet> ARG...` runs it by
name; `toolbox --list` names them. An unknown name is `applet not found` (exit 127).

No rule uses it yet. It exists so that a test's `PATH` can be a directory of links to one pinned, reproducible binary.

| applet | what it does |
|---|---|
| `rm [-r] [-R] [-f] [--] PATH...` | removes files; `-r` directories too. A missing path is an error unless `-f`; `rm -rf` of a missing path is quiet. `.`, `..` and `/` are refused. Every operand is tried; status 1 if any failed. |
| `mkdir [-p] [--] DIR...` | makes directories; `-p` makes parents and accepts one that is there. |
| `sleep TIME...` | waits for the sum; `TIME` is decimal (`30`, `0.3`, `.5`) with an optional `s`, `m`, `h` or `d`. Nothing is waited for unless every operand is valid. |
| `echo [-n] [-e] [-E] [ARG...]` | the arguments joined by a space and a newline; `-e` replaces `\\ \a \b \e \f \n \r \t \v \0NNN \xHH \c`. A first word that is not those flags is text (`echo --plan`). |
| `cat [FILE...]` | files in order; `-` and no operand read stdin. |
| `env [-i] [-u NAME]... [NAME=VALUE]... [COMMAND [ARG]...]` | lists the environment, or runs the command in the changed one and gives its status (127 not found, 126 not runnable). A command without `/` is looked for in the `PATH` of the environment it builds. |
| `printenv [NAME]...` | the values, a line each (status 1 if one is unset), or the whole environment. |
| `true`, `false` | 0 and 1. |

## Tests

`toolbox_test.zig` runs every applet in-process through `entry` (streams, clock and process spawner are injected, so each case reads back exact
bytes, messages and statuses). `toolbox_exe_test.zig` runs the built executable: dispatch by a link's name, the real clock (`sleep 0.3` takes
0.3 s), stdin, the real environment, a flushed or closed stdout, and the real start of a child by `env`. The floor in `coverage_floor.txt` is
exact, as everywhere (`rules/coverage/README.md`).
