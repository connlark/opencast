/***************************************************************************
 *                                  _   _ ____  _
 *  Project                     ___| | | |  _ \| |
 *                             / __| | | | |_) | |
 *                            | (__| |_| |  _ <| |___
 *                             \___|\___/|_| \_\_____|
 *
 * Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution. The terms
 * are also available at https://curl.se/docs/copyright.html.
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYING file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 * SPDX-License-Identifier: curl
 *
 ***************************************************************************/

/*
 * Derived from curl's lib/parsedate.c at
 * d169ad68faa5ed5ba2375e7502307a6262466d88.
 *
 * OpenCast modifications:
 * - extracted the date parser into a standalone C file;
 * - replaced curl-internal helpers with local standard-C equivalents;
 * - exposed only OpenCastParseInternetDate for Swift;
 * - made pre-1970 and overflow results fail at the public boundary.
 */

#include "OpenCastDateParsing.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define PARSEDATE_OK 0
#define PARSEDATE_FAIL (-1)

#define OPENCAST_ARRAYSIZE(array) (sizeof(array) / sizeof((array)[0]))
#define OPENCAST_ISLOWER(x) (((x) >= 'a') && ((x) <= 'z'))
#define OPENCAST_ISUPPER(x) (((x) >= 'A') && ((x) <= 'Z'))
#define OPENCAST_ISALPHA(x) (OPENCAST_ISLOWER(x) || OPENCAST_ISUPPER(x))
#define OPENCAST_ISDIGIT(x) (((x) >= '0') && ((x) <= '9'))
#define OPENCAST_ISALNUM(x) (OPENCAST_ISDIGIT(x) || OPENCAST_ISALPHA(x))

static const char * const opencast_wkday[] = {
  "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"
};

static const char * const opencast_month[] = {
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

static const char * const weekday[] = {
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
};

struct tzinfo {
  char name[5];
  int16_t offset; /* +/- in minutes */
};

#define tDAYZONE (-60)         /* offset for daylight savings time */

/* alpha-sorted list of time zones */
static const struct tzinfo tz[] = {
  { "A", -1 * 60 },            /* Alpha */
  { "ADT",   240 + tDAYZONE }, /* Atlantic Daylight */
  { "AHST",  600 },            /* Alaska-Hawaii Standard */
  { "AST",   240 },            /* Atlantic Standard */
  { "B", -2 * 60 },            /* Bravo */
  { "BST",     0 + tDAYZONE }, /* British Summer */
  { "C", -3 * 60 },            /* Charlie */
  { "CAT",   600 },            /* Central Alaska */
  { "CCT",  -480 },            /* China Coast, USSR Zone 7 */
  { "CDT",   360 + tDAYZONE }, /* Central Daylight */
  { "CEST",  -60 + tDAYZONE }, /* Central European Summer */
  { "CET",   -60 },            /* Central European */
  { "CST",   360 },            /* Central Standard */
  { "D", -4 * 60 },            /* Delta */
  { "E", -5 * 60 },            /* Echo */
  { "EADT", -600 + tDAYZONE }, /* Eastern Australian Daylight */
  { "EAST", -600 },            /* Eastern Australian Standard */
  { "EDT",   300 + tDAYZONE }, /* Eastern Daylight */
  { "EET",  -120 },            /* Eastern Europe, USSR Zone 1 */
  { "EST",   300 },            /* Eastern Standard */
  { "F", -6 * 60 },            /* Foxtrot */
  { "FST",   -60 + tDAYZONE }, /* French Summer */
  { "FWT",   -60 },            /* French Winter */
  { "G", -7 * 60 },            /* Golf */
  { "GMT",     0 },            /* Greenwich Mean */
  { "GST",  -600 },            /* Guam Standard, USSR Zone 9 */
  { "H", -8 * 60 },            /* Hotel */
  { "HDT",   600 + tDAYZONE }, /* Hawaii Daylight */
  { "HST",   600 },            /* Hawaii Standard */
  { "I", -9 * 60 },            /* India */
  { "IDLE", -720 },            /* International Date Line East */
  { "IDLW",  720 },            /* International Date Line West */
  { "JST",  -540 },            /* Japan Standard, USSR Zone 8 */
  { "K", -10 * 60 },           /* Kilo */
  { "L", -11 * 60 },           /* Lima */
  { "M", -12 * 60 },           /* Mike */
  { "MDT",   420 + tDAYZONE }, /* Mountain Daylight */
  { "MEST",  -60 + tDAYZONE }, /* Middle European Summer */
  { "MESZ",  -60 + tDAYZONE }, /* Middle European Summer */
  { "MET",   -60 },            /* Middle European */
  { "MEWT",  -60 },            /* Middle European Winter */
  { "MST",   420 },            /* Mountain Standard */
  { "N",      60 },            /* November */
  { "NT",    660 },            /* Nome */
  { "NZDT", -720 + tDAYZONE }, /* New Zealand Daylight */
  { "NZST", -720 },            /* New Zealand Standard */
  { "NZT",  -720 },            /* New Zealand */
  { "O",  2 * 60 },            /* Oscar */
  { "P",  3 * 60 },            /* Papa */
  { "PDT",   480 + tDAYZONE }, /* Pacific Daylight */
  { "PST",   480 },            /* Pacific Standard */
  { "Q",  4 * 60 },            /* Quebec */
  { "R",  5 * 60 },            /* Romeo */
  { "S",  6 * 60 },            /* Sierra */
  { "T",  7 * 60 },            /* Tango */
  { "U",  8 * 60 },            /* Uniform */
  { "UT",      0 },            /* Universal Time */
  { "UTC",     0 },            /* Universal (Coordinated) */
  { "V",  9 * 60 },            /* Victor */
  { "W", 10 * 60 },            /* Whiskey */
  { "WADT", -420 + tDAYZONE }, /* West Australian Daylight */
  { "WAST", -420 },            /* West Australian Standard */
  { "WAT",    60 },            /* West Africa */
  { "WET",     0 },            /* Western European */
  { "X", 11 * 60 },            /* X-ray */
  { "Y", 12 * 60 },            /* Yankee */
  { "YDT",   540 + tDAYZONE }, /* Yukon Daylight */
  { "YST",   540 },            /* Yukon Standard */
  { "Z",       0 },            /* Zulu, zero meridian, a.k.a. UTC */
};

struct when {
  int wday;  /* day of the week, 0-6 (mon-sun) */
  int mon;   /* month of the year, 0-11 */
  int mday;  /* day of month, 1 - 31 */
  int hour;  /* hour of day, 0 - 23 */
  int min;   /* minute of hour, 0 - 59 */
  int sec;   /* second of minute, 0 - 60 (leap second) */
  int year;  /* year, >= 1583 */
  int tzoff; /* time zone offset in seconds */
};

enum assume {
  DATE_MDAY,
  DATE_YEAR,
  DATE_TIME
};

static char opencast_ascii_toupper(char c)
{
  if(OPENCAST_ISLOWER(c))
    return (char)(c - ('a' - 'A'));
  return c;
}

static bool opencast_strnequal(const char *first, const char *second, size_t max)
{
  while(*first && max) {
    if(opencast_ascii_toupper(*first) != opencast_ascii_toupper(*second))
      return false;
    max--;
    first++;
    second++;
  }

  if(max == 0)
    return true;

  return opencast_ascii_toupper(*first) == opencast_ascii_toupper(*second);
}

static int opencast_str_number(const char **linep, int64_t *nump, int64_t max)
{
  int64_t num = 0;
  const char *p = *linep;

  *nump = 0;

  if(!OPENCAST_ISDIGIT(*p))
    return PARSEDATE_FAIL;

  do {
    int n = *p++ - '0';
    if(num > ((max - n) / 10))
      return PARSEDATE_FAIL;
    num = (num * 10) + n;
  } while(OPENCAST_ISDIGIT(*p));

  *nump = num;
  *linep = p;
  return PARSEDATE_OK;
}

static int checkday(const char *check, size_t len)
{
  int i;
  const char * const *what;
  if(len > 3)
    what = &weekday[0];
  else if(len == 3)
    what = &opencast_wkday[0];
  else
    return -1;

  for(i = 0; i < 7; i++) {
    size_t ilen = strlen(what[0]);
    if((ilen == len) && opencast_strnequal(check, what[0], len))
      return i;
    what++;
  }

  return -1;
}

static int checkmonth(const char *check, size_t len)
{
  int i;
  const char * const *what = &opencast_month[0];

  if(len != 3)
    return -1;

  for(i = 0; i < 12; i++) {
    if(opencast_strnequal(check, what[0], 3))
      return i;
    what++;
  }

  return -1;
}

static int tzcompare(const void *m1, const void *m2)
{
  const struct tzinfo *tz1 = m1;
  const struct tzinfo *tz2 = m2;
  return strcmp(tz1->name, tz2->name);
}

static int checktz(const char *check, size_t len)
{
  if(len <= 4) {
    const struct tzinfo *what;
    struct tzinfo find;
    size_t i;
    /* RFC 5322 zone names are case-insensitive and the table is uppercase;
       uppercase the token before the case-sensitive bsearch (upstream's
       Curl_strntoupper copy, which the pinned revision regressed away). */
    for(i = 0; i < len; i++)
      find.name[i] = opencast_ascii_toupper(check[i]);
    find.name[len] = 0;
    what = bsearch(&find, tz, OPENCAST_ARRAYSIZE(tz), sizeof(tz[0]), tzcompare);
    if(what)
      return what->offset * 60;
  }

  return -1;
}

static void skip(const char **date)
{
  while(**date && !OPENCAST_ISALNUM(**date))
    (*date)++;
}

static void initwhen(struct when *w)
{
  w->wday = w->mon = w->mday = w->hour = w->min = w->sec = w->year = w->tzoff =
    -1;
}

#define LEAP_DAYS_BEFORE_1969 477

static int64_t time2epoch(struct when *w)
{
  static const int cumulative_days[12] = {
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334
  };
  int y = w->year - (w->mon <= 1);
  int leap_days = (y / 4) - (y / 100) + (y / 400) - LEAP_DAYS_BEFORE_1969;
  int64_t days = (int64_t)(w->year - 1970) * 365 + leap_days +
    cumulative_days[w->mon] + w->mday - 1;

  return (((days * 24 + w->hour) * 60 + w->min) * 60) + w->sec;
}

static int oneortwodigit(const char *date, const char **endp)
{
  int num = date[0] - '0';

  if(OPENCAST_ISDIGIT(date[1])) {
    *endp = &date[2];
    return (num * 10) + (date[1] - '0');
  }

  *endp = &date[1];
  return num;
}

static bool match_time(const char *date, struct when *w, char **endp)
{
  const char *p;
  int hh;
  int mm;
  int ss = 0;

  hh = oneortwodigit(date, &p);
  if((hh < 24) && (*p == ':') && OPENCAST_ISDIGIT(p[1])) {
    mm = oneortwodigit(&p[1], &p);
    if(mm < 60) {
      if((*p == ':') && OPENCAST_ISDIGIT(p[1])) {
        ss = oneortwodigit(&p[1], &p);
        if(ss <= 60)
          goto match;
      }
      else {
        goto match;
      }
    }
  }

  return false;

match:
  w->hour = hh;
  w->min = mm;
  w->sec = ss;
  *endp = (char *)p;
  return true;
}

#define NAME_LEN 12

static int datestring(const char **datep, struct when *w)
{
  size_t len = 0;
  const char *p = *datep;
  bool found = false;

  while(OPENCAST_ISALPHA(*p) && (len < NAME_LEN)) {
    p++;
    len++;
  }

  if(len != NAME_LEN) {
    if(w->wday == -1) {
      w->wday = checkday(*datep, len);
      if(w->wday != -1)
        found = true;
    }

    if(!found && (w->mon == -1)) {
      w->mon = checkmonth(*datep, len);
      if(w->mon != -1)
        found = true;
    }

    if(!found && (w->tzoff == -1)) {
      w->tzoff = checktz(*datep, len);
      if(w->tzoff != -1)
        found = true;
    }
  }

  if(!found)
    return PARSEDATE_FAIL;

  *datep += len;
  return PARSEDATE_OK;
}

static int datenum(
  const char *indate,
  const char **datep,
  struct when *w,
  enum assume *dignextp
)
{
  unsigned int val;
  char *end;
  const char *date = *datep;
  enum assume dignext = *dignextp;

  if((w->sec == -1) && match_time(date, w, &end)) {
    date = end;
  }
  else {
    bool found = false;
    int64_t lval;
    int num_digits;
    const char *p = *datep;

    if(opencast_str_number(&p, &lval, 99999999))
      return PARSEDATE_FAIL;

    num_digits = (int)(p - *datep);
    val = (unsigned int)lval;

    if((w->tzoff == -1) &&
       (num_digits == 4) &&
       (val <= 1400) &&
       (indate < date) &&
       (date[-1] == '+' || date[-1] == '-')) {
      found = true;
      w->tzoff = (int)(((val / 100 * 60) + (val % 100)) * 60);
      w->tzoff = date[-1] == '+' ? -w->tzoff : w->tzoff;
    }
    else if((num_digits == 8) && (w->year == -1) &&
            (w->mon == -1) && (w->mday == -1)) {
      found = true;
      w->year = (int)(val / 10000);
      w->mon = (int)(((val % 10000) / 100) - 1);
      w->mday = (int)(val % 100);
    }

    if(!found && (dignext == DATE_MDAY) && (w->mday == -1)) {
      if((val > 0) && (val < 32)) {
        w->mday = (int)val;
        found = true;
      }
      dignext = DATE_YEAR;
    }

    if(!found && (dignext == DATE_YEAR) && (w->year == -1)) {
      w->year = (int)val;
      found = true;
      if(w->year < 100) {
        if(w->year > 70)
          w->year += 1900;
        else
          w->year += 2000;
      }
      if(w->mday == -1)
        dignext = DATE_MDAY;
    }

    if(!found)
      return PARSEDATE_FAIL;

    date = p;
  }

  *datep = date;
  *dignextp = dignext;
  return PARSEDATE_OK;
}

static int datecheck(struct when *w)
{
  if(w->sec == -1)
    w->sec = w->min = w->hour = 0;

  if((w->mday == -1) || (w->mon == -1) || (w->year == -1))
    return PARSEDATE_FAIL;

  if(w->year < 1583)
    return PARSEDATE_FAIL;

  if((w->mday > 31) || (w->mon > 11) || (w->hour > 23) ||
     (w->min > 59) || (w->sec > 60))
    return PARSEDATE_FAIL;

  return PARSEDATE_OK;
}

static bool tzadjust(int64_t *tp, struct when *w)
{
  if(w->tzoff == -1)
    w->tzoff = 0;

  if((w->tzoff > 0) && (*tp > (INT64_MAX - w->tzoff)))
    return false;

  *tp += w->tzoff;
  return true;
}

static int parsedate(const char *date, int64_t *output)
{
  int64_t seconds;
  enum assume dignext = DATE_MDAY;
  const char *indate = date;
  int part = 0;
  int rc = 0;
  struct when w;

  initwhen(&w);

  while(*date && (part < 6)) {
    skip(&date);

    if(OPENCAST_ISALPHA(*date))
      rc = datestring(&date, &w);
    else if(OPENCAST_ISDIGIT(*date))
      rc = datenum(indate, &date, &w, &dignext);

    if(rc)
      return rc;

    part++;
  }

  rc = datecheck(&w);
  if(rc)
    return rc;

  seconds = time2epoch(&w);
  if(!tzadjust(&seconds, &w))
    return PARSEDATE_FAIL;

  *output = seconds;
  return PARSEDATE_OK;
}

bool OpenCastParseInternetDate(const char *input, int64_t *seconds_since_1970)
{
  int64_t parsed;

  if(!input || !seconds_since_1970)
    return false;

  if(parsedate(input, &parsed) != PARSEDATE_OK)
    return false;

  if(parsed < 0)
    return false;

  *seconds_since_1970 = parsed;
  return true;
}
