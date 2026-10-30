/* libsqlite.a: SQLite, built from the amalgamation that BUCK pins (`native_build` of mojo_package) and renamed by the prefix header the rules force-include, so
   every symbol it defines starts with upsql_sqlite3_. The amalgamation is on the include path; nothing of it is in this directory. */
#include "sqlite3.c"
