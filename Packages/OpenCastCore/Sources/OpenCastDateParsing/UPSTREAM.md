# OpenCastDateParsing Upstream

- Upstream project: curl
- Upstream revision: `d169ad68faa5ed5ba2375e7502307a6262466d88` (`curl-8_21_0-97-gd169ad68fa`)
- Upstream source:
  - `https://github.com/curl/curl/blob/d169ad68faa5ed5ba2375e7502307a6262466d88/lib/parsedate.c`
  - `https://github.com/curl/curl/blob/d169ad68faa5ed5ba2375e7502307a6262466d88/lib/parsedate.h`
  - `https://github.com/curl/curl/blob/d169ad68faa5ed5ba2375e7502307a6262466d88/COPYING`
  - `https://github.com/curl/curl/blob/d169ad68faa5ed5ba2375e7502307a6262466d88/tests/libtest/lib517.c`
- Local files:
  - `OpenCastCurlParsedDate.c` is derived from curl's `lib/parsedate.c`.
  - `include/OpenCastDateParsing.h` is a small OpenCast wrapper API and is not copied from curl.
  - `LICENSE-curl.txt` is copied from curl's `COPYING`.
- Local modifications:
  - Extracted the parser into a standalone C file instead of depending on curl internals.
  - Replaced curl helper macros/functions with local ASCII, decimal parsing, and string-copy helpers.
  - Added the `OpenCastParseInternetDate` entry point.
  - Return failure for parse errors, pre-1970 results, and results outside `int64_t` range so RSS parsing never receives a fabricated epoch.
  - `checktz` uppercases the zone token before the `bsearch` against the uppercase `tz[]` table. The pinned revision compares with plain `strcmp` and no case normalization, so lowercase/mixed-case RFC 5322 zone names (`gmt`, `Est`, `z`) fail the whole parse; earlier curl used `Curl_strntoupper`/`strncasecompare` here. Deviation kept until upstream restores case-insensitive zone matching.
