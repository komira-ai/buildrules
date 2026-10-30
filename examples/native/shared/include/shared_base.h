#ifndef SHARED_BASE_H
#define SHARED_BASE_H

/* 10 */
int shared_base_value(void);

/* How many times the constructor of this library ran: 1 in a program with one copy of it. */
int shared_init_count(void);

#endif
