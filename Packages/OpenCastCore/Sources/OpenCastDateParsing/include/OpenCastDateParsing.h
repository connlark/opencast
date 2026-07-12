#ifndef OPENCAST_DATE_PARSING_H
#define OPENCAST_DATE_PARSING_H

#include <stdbool.h>
#include <stdint.h>

bool OpenCastParseInternetDate(const char *input, int64_t *seconds_since_1970);

#endif
