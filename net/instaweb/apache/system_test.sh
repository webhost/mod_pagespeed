#!/bin/bash
# Copyright 2010 Google Inc. All Rights Reserved.
# Author: abliss@google.com (Adam Bliss)
#
# Runs all Apache-specific and general system tests.
#
# See automatic/system_test_helpers.sh for usage.
#
# Expects APACHE_DEBUG_PAGESPEED_CONF to point to our config file,
# APACHE_LOG to the log file.
#
# CACHE_FLUSH_TEST=on can be passed to test our cache.flush behavior
# NO_VHOST_MERGE=on can be passed to tell tests to assume
# that ModPagespeedInheritVHostConfig has been turned off.

if [ -z $APACHE_DEBUG_PAGESPEED_CONF ]; then
  APACHE_DEBUG_PAGESPEED_CONF=/usr/local/apache2/conf/pagespeed.conf
fi

if [ -z $APACHE_LOG ]; then
  APACHE_LOG=/usr/local/apache2/logs/error_log
fi

if [ -z $APACHE_DOC_ROOT ]; then
  APACHE_DOC_ROOT=/usr/local/apache2/htdocs/
fi

PSA_JS_LIBRARY_URL_PREFIX="mod_pagespeed_static"

CACHE_FLUSH_TEST=${CACHE_FLUSH_TEST:-off}
NO_VHOST_MERGE=${NO_VHOST_MERGE:-off}
SUDO=${SUDO:-}
# TODO(jkarlin): Should we just use a vhost instead?  If so, remember to update
# all scripts that use TEST_PROXY_ORIGIN.
PAGESPEED_TEST_HOST=${PAGESPEED_TEST_HOST:-modpagespeed.com}

# Extract secondary hostname when set. Currently it's only set when doing the
# cache flush test, but it can be used in other tests we run in that run.
# Note that we use $1 not $HOSTNAME as that is only set up later by _helpers.sh.
if [ "$CACHE_FLUSH_TEST" = "on" ]; then
  # Replace any trailing :<port> with :<secondary-port>.
  SECONDARY_HOSTNAME=${1/%:*/:$APACHE_SECONDARY_PORT}
  if [ "$SECONDARY_HOSTNAME" = "$1" ]; then
    SECONDARY_HOSTNAME=${1}:$APACHE_SECONDARY_PORT
  fi

  # To fetch from the secondary test root, we must set
  # http_proxy=${SECONDARY_HOSTNAME} during fetches.
  SECONDARY_TEST_ROOT=http://secondary.example.com/mod_pagespeed_test
else
  # Force the variable to be set albeit blank so tests don't fail.
  : ${SECONDARY_HOSTNAME:=}
fi

# Inform system/system_tests.sh and the rest of this script whether statistics
# are enabled by grepping the conf file.
statistics_enabled="0"
statistics_logging_enabled="0"
if egrep -q "^    # ModPagespeedStatistics off$" \
    $APACHE_DEBUG_PAGESPEED_CONF; then
  statistics_enabled="1"
  echo STATS is ON
  if egrep -q "^ ModPagespeedStatisticsLogging on$" \
     $APACHE_DEBUG_PAGESPEED_CONF; then
    statistics_logging_enabled="1"
  fi
fi

# The 'PURGE' method is implemented, but not yet working in ngx_pagespeed, so
# have to indicate here that we want to test both PURGE and GET.  In
# nginx_system_test.sh we currently specify only GET.
#
# TODO(jmarantz) Once that's implemented in nginx, we can eliminate this
# setting.
CACHE_PURGE_METHODS="PURGE GET"

# Run General system tests.
#
# We need to know the directory this file is located in.  Unfortunately,
# if we're 'source'd from a script in a different directory $(dirname $0) gives
# us the directory that *that* script is located in
this_dir=$(dirname "${BASH_SOURCE[0]}")
source "$this_dir/../system/system_test.sh" || exit 1

# TODO(jefftk): most of these tests aren't Apache-specific and should be
# slightly generalized and moved to system/ where other implementations (like
# ngx_pagespeed) can use them.

# Define a mechanism to start a test before the cache-flush and finish it
# after the cache-flush.  This mechanism is preferable to flushing cache
# within a test as that requires waiting 5 seconds for the poll, so we'd
# like to limit the number of cache flushes and exploit it on behalf of
# multiple tests.

# Variable holding a space-separated lists of bash functions to run after
# flushing cache.
post_cache_flush_test=""

# Adds a new function to run after cache flush.
function on_cache_flush() {
  post_cache_flush_test+=" $1"
}

# Called after cache-flush to run all the functions specified to
# on_cache_flush.
function run_post_cache_flush() {
  for test in $post_cache_flush_test; do
    $test
  done
}

rm -rf $OUTDIR
mkdir -p $OUTDIR

# Grab a timestamp now so that we can check that logging works.
# Also determine where the log file is.
if [ $statistics_logging_enabled = "1" ]; then
  MOD_PAGESPEED_LOG_DIR="$(
    sed -n 's/^ ModPagespeedLogDir //p' $APACHE_DEBUG_PAGESPEED_CONF |
    sed -n 's/\"//gp')"
  # Wipe the logs so we get a clean start.
  rm $MOD_PAGESPEED_LOG_DIR/*
  # The specific log file that the console will use.
  # If per-vhost stats is enabled, this is the main vhost suffix ":0".
  # If per-vhost stats is not enabled, this is the global suffix "global".
  MOD_PAGESPEED_STATS_LOG="${MOD_PAGESPEED_LOG_DIR}/stats_log_:0"
  START_TIME=$(date +%s)000 # We need this in milliseconds.
  sleep 2; # Make sure we're around long enough to log stats.
fi

# General system tests

start_test Check for correct default X-Mod-Pagespeed header format.
OUT=$($WGET_DUMP $EXAMPLE_ROOT/combine_css.html)
check_from "$OUT" egrep -q \
  '^X-Mod-Pagespeed: [0-9]+[.][0-9]+[.][0-9]+[.][0-9]+-[0-9]+'

start_test mod_pagespeed is running in Apache and writes the expected header.
echo $WGET_DUMP $EXAMPLE_ROOT/combine_css.html
HTML_HEADERS=$($WGET_DUMP $EXAMPLE_ROOT/combine_css.html)

start_test mod_pagespeed is defaulting to more than PassThrough
# Note: this is relying on lack of .htaccess in mod_pagespeed_test
check [ ! -f $APACHE_DOC_ROOT/mod_pagespeed_test/.htaccess ]
fetch_until $TEST_ROOT/bot_test.html 'grep -c \.pagespeed\.' 2

# Determine whether statistics are enabled or not.  If not, don't test them,
# but do an additional regression test that tries harder to get a cache miss.
if [ $statistics_enabled = "1" ]; then
  start_test 404s are served and properly recorded.
  NUM_404=$(scrape_stat resource_404_count)
  WGET_ERROR=$(check_not $WGET -O /dev/null $BAD_RESOURCE_URL 2>&1)
  check_from "$WGET_ERROR" fgrep -q "404 Not Found"

  # Check that the stat got bumped.
  check [ $(expr $(scrape_stat resource_404_count) - $NUM_404) -eq 1 ]

  start_test Non-local access to statistics fails.
  MACHINE_NAME=$(hostname)
  ALT_STAT_URL=$(echo $STATISTICS_URL | sed s#localhost#$MACHINE_NAME#)

  check_error_code 8 wget -q $ALT_STAT_URL >& $TEMPDIR/alt_stat_url.$$
  rm -f "$TEMPDIR/alt_stat_url.$$"



  # Even though we don't have a cookie, we will conservatively avoid
  # optimizing resources with Vary:Cookie set on the response, so we
  # will not get the instant response, of "body{background:#9370db}":
  # 24 bytes, but will get the full original text:
  #     "body {\n    background: MediumPurple;\n}\n"
  # This will happen whether or not we send a cookie.
  #
  # Testing this requires proving we'll never optimize something, which
  # can't be distinguished from the not-yet-optimized case, except by the
  # ipro_not_rewritable stat, so we loop by scraping that stat and seeing
  # when it changes.

  # Executes commands until ipro_no_rewrite_count changes.  The
  # command-line options are all passed to WGET_DUMP.  Leaves command
  # wget output in $IPRO_OUTPUT.
  function ipro_expect_no_rewrite() {
    ipro_no_rewrite_count_start=$(scrape_stat ipro_not_rewritable)
    ipro_no_rewrite_count=$ipro_no_rewrite_count_start
    iters=0
    while [ $ipro_no_rewrite_count -eq $ipro_no_rewrite_count_start ]; do
      if [ $iters -ne 0 ]; then
        sleep 0.1
        if [ $iters -gt 100 ]; then
          echo TIMEOUT
          exit 1
        fi
      fi
      IPRO_OUTPUT=$($WGET_DUMP "$@")
      ipro_no_rewrite_count=$(scrape_stat ipro_not_rewritable)
      iters=$((iters + 1))
    done
  }

  start_test ipro with vary:cookie with no cookie set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie/vary_cookie.css
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" egrep -q 'Vary: (Accept-Encoding,)?Cookie'

  start_test ipro with vary:cookie with cookie set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie/vary_cookie.css \
    --header=Cookie:cookie-data
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" egrep -q 'Vary: (Accept-Encoding,)?Cookie'

  start_test ipro with vary:cookie2 with no cookie2 set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie2/vary_cookie2.css
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" egrep -q 'Vary: (Accept-Encoding,)?Cookie2'

  start_test ipro with vary:cookie2 with cookie2 set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie2/vary_cookie2.css \
    --header=Cookie2:cookie2-data
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" egrep -q 'Vary: (Accept-Encoding,)?Cookie2'

  start_test authorized resources do not get cached and optimized.
  URL="$TEST_ROOT/auth/medium_purple.css"
  AUTH="Authorization:Basic dXNlcjE6cGFzc3dvcmQ="
  not_cacheable_start=$(scrape_stat ipro_recorder_not_cacheable)
  echo $WGET_DUMP --header="$AUTH" "$URL"
  OUT=$($WGET_DUMP --header="$AUTH" "$URL")
  check_from "$OUT" fgrep -q 'background: MediumPurple;'
  not_cacheable=$(scrape_stat ipro_recorder_not_cacheable)
  check [ $not_cacheable = $((not_cacheable_start + 1)) ]
  URL=""
  AUTH=""

  if [ "$SECONDARY_HOSTNAME" != "" ]; then
    function gunzip_grep_0ff() {
      gunzip - | fgrep -q "color:#00f"
      echo $?
    }

    start_test ipro with mod_deflate
    fetch_until -gzip $TEST_ROOT/ipro/mod_deflate/big.css gunzip_grep_0ff 0

    start_test ipro with reverse proxy of compressed content
    http_proxy=$SECONDARY_HOSTNAME \
        fetch_until -gzip http://ipro-proxy.example.com/big.css \
            gunzip_grep_0ff 0

    # Also test the .pagespeed. version, to make sure we didn't
    # accidentally gunzip stuff above when we shouldn't have.
    OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET -q -O - \
          http://ipro-proxy.example.com/A.big.css.pagespeed.cf.0.css)
    check_from "$OUT" fgrep -q "big{color:#00f}"
  fi
else
  start_test 404s are served.  Statistics are disabled so not checking them.
  OUT=$(check_not $WGET -O /dev/null $BAD_RESOURCE_URL 2>&1)
  check_from "$OUT" fgrep -q "404 Not Found"

  start_test 404s properly on uncached invalid resource.
  OUT=$(check_not $WGET -O /dev/null $BAD_RND_RESOURCE_URL 2>&1)
  check_from "$OUT" fgrep -q "404 Not Found"
fi

# Tests that an origin header with a Vary header other than Vary:Accept-Encoding
# loses that header when we are not respecting vary.
start_test Vary:User-Agent on resources is held by our cache.
URL="$TEST_ROOT/vary/no_respect/index.html"
fetch_until -save $URL 'grep -c \.pagespeed\.cf\.' 1

# Extract out the rewritten CSS file from the HTML saved by fetch_until
# above (see -save and definition of fetch_until).  Fetch that CSS
# file with headers and make sure the Vary is stripped.
CSS_URL=$(grep stylesheet $FETCH_UNTIL_OUTFILE | cut -d\" -f 4)
CSS_URL="$TEST_ROOT/vary/no_respect/$(basename $CSS_URL)"
echo CSS_URL=$CSS_URL
CSS_OUT=$($WGET_DUMP $CSS_URL)
check_from "$CSS_OUT" fgrep -q "Vary: Accept-Encoding"
check_not_from "$CSS_OUT" fgrep -q "User-Agent"


# Test that loopback route fetcher works with vhosts not listening on
# 127.0.0.1  Only run this during CACHE_FLUSH_TEST as that is when
# APACHE_TERTIARY_PORT is set.
if [ "${APACHE_TERTIARY_PORT:-}" != "" ]; then
  start_test IP choice for loopback fetches.
  HOST_NAME="loopbackfetch.example.com"
  URL="$HOST_NAME/mod_pagespeed_example/rewrite_images.html"
  http_proxy=127.0.0.2:$APACHE_TERTIARY_PORT \
    fetch_until $URL 'grep -c .pagespeed.ic' 2
fi
# Test /mod_pagespeed_message exists.
start_test Check if /mod_pagespeed_message page exists.
OUT=$($WGET --save-headers -q -O - $MESSAGE_URL | head -1)
check_200_http_response "$OUT"

# Test if the warning messages are colored in message_history page.
# We color the messages in message_history page to make it clearer to read.
# Red for Error messages. Brown for Warning messages.
# Orange for Fatal messages. Black by default.
# Won't test Error messages and Fatal messages in this test.
start_test Messages are colored in message_history
INJECT=$($CURL --silent $HOSTNAME/?PageSpeed=Warning_trigger)
OUT=$($WGET -q -O - $HOSTNAME/pagespeed_admin/message_history | \
  grep Warning_trigger)
check_from "$OUT" fgrep -q "color:brown;"

# Note: There is a similar test in system_test.sh
#
# This tests whether fetching "/" gets you "/index.html".  With async
# rewriting, it is not deterministic whether inline css gets
# rewritten.  That's not what this is trying to test, so we use
# ?PageSpeed=off.
start_test directory is mapped to index.html.
rm -rf $OUTDIR
mkdir -p $OUTDIR
check $WGET -q "$EXAMPLE_ROOT/?PageSpeed=off" \
  -O $OUTDIR/mod_pagespeed_example
check $WGET -q "$EXAMPLE_ROOT/index.html?PageSpeed=off" -O $OUTDIR/index.html
check diff $OUTDIR/index.html $OUTDIR/mod_pagespeed_example

start_test Request Headers affect MPS options

# Get the special file response_headers.html and test the result.
# This file has Apache request_t headers_out and err_headers_out modified
# according to the query parameter.  The modification happens in
# instaweb_handler when the handler == kGenerateResponseWithOptionsHandler.
# Possible query flags include: headers_out, headers_errout, headers_override,
# and headers_combine.
function response_header_test() {
    query=$1
    mps_on=$2
    comments_removed=$3
    rm -rf $OUTDIR
    mkdir -p $OUTDIR

    # Get the file
    echo $WGET -q -S -O - \
      "$TEST_ROOT/response_headers.html?$query" '>&' $OUTDIR/header_out
    check $WGET -q -S -O - \
      "$TEST_ROOT/response_headers.html?$query" >& $OUTDIR/header_out

    # Make sure that any MPS option headers were stripped
    check_not grep -q ^PageSpeed: $OUTDIR/header_out
    check_not grep -q ^ModPagespeed: $OUTDIR/header_out

    # Verify if MPS is on or off
    if [ $mps_on = "no" ]; then
      # Verify that PageSpeed was off
      check_not fgrep -q 'X-Mod-Pagespeed:' $OUTDIR/header_out
      check_not fgrep -q '<script' $OUTDIR/header_out
    else
      # Verify that PageSpeed was on
      check fgrep -q 'X-Mod-Pagespeed:' $OUTDIR/header_out
      check fgrep -q '<script' $OUTDIR/header_out
    fi

    # Verify if comments were stripped
    if [ $comments_removed = "no" ]; then
      # Verify that comments were not removed
      check fgrep -q '<!--' $OUTDIR/header_out
    else
      # Verify that comments were removed
      check_not fgrep -q '<!--' $OUTDIR/header_out
    fi
}

# headers_out =     MPS: off
# err_headers_out =
response_header_test headers_out no no

# headers_out =
# err_headers_out = MPS: on
response_header_test headers_errout no no

# Note: The next two tests will break if remove_comments gets into the
# CoreFilter set.

# headers_out     = MPS: off, Filters: -remove_comments
# err_headers_out = MPS: on,  Filters: +remove_comments
# err_headers should is processed after headers_out, and so it should override
# but disabling a filter trumps enabling one. The overriding is described in
# the code for build_context_for_request.
response_header_test headers_override yes no

# headers_out     = MPS: on
# err_headers_out = Filters: +remove_comments
response_header_test headers_combine yes yes

start_test Respect X-Forwarded-Proto when told to
FETCHED=$OUTDIR/x_forwarded_proto
URL=$TEST_ROOT/?PageSpeedFilters=add_base_tag
check $WGET_DUMP -O $FETCHED --header="X-Forwarded-Proto: https" $URL
# When enabled, we respect X-Forwarded-Proto and thus list base as https.
check fgrep -q '<base href="https://' $FETCHED


# Individual filter tests, in alphabetical order

# This is dependent upon having a /mod_pagespeed_beacon handler.
test_filter add_instrumentation beacons load.
check run_wget_with_args $PRIMARY_SERVER/mod_pagespeed_beacon?ets=load:13
check fgrep -q "204 No Content" $WGET_OUTPUT
check fgrep -q 'Cache-Control: max-age=0, no-cache' $WGET_OUTPUT

test_filter combine_css combines 4 CSS files into 1.
fetch_until $URL 'grep -c text/css' 1
check run_wget_with_args $URL
test_resource_ext_corruption $URL $combine_css_filename

test_filter extend_cache rewrites an image tag.
fetch_until $URL 'grep -c src.*91_WewrLtP' 1
check run_wget_with_args $URL
echo about to test resource ext corruption...
test_resource_ext_corruption $URL images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg

test_filter outline_javascript outlines large scripts, but not small ones.
check run_wget_with_args $URL
check egrep -q '<script.*large.*src=' $FETCHED       # outlined
check egrep -q '<script.*small.*var hello' $FETCHED  # not outlined
start_test compression is enabled for rewritten JS.
JS_URL=$(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED)
echo "JS_URL=\$\(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED\)=\"$JS_URL\""
JS_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $JS_URL 2>&1)
echo JS_HEADERS=$JS_HEADERS
check_200_http_response "$JS_HEADERS"
check_from "$JS_HEADERS" fgrep -qi 'Content-Encoding: gzip'
check_from "$JS_HEADERS" fgrep -qi 'Vary: Accept-Encoding'
check_from "$JS_HEADERS" egrep -qi '(Etag: W/"0")|(Etag: W/"0-gzip")'
check_from "$JS_HEADERS" fgrep -qi 'Last-Modified:'

# Test RetainComment directive.
test_filter remove_comments retains appropriate comments.
check run_wget_with_args $URL
check grep -q retained $FETCHED        # RetainComment directive

# Make sure that when in PreserveURLs mode that we don't rewrite URLs. This is
# non-exhaustive, the unit tests should cover the rest.
# Note: We block with psatest here because this is a negative test.  We wouldn't
# otherwise know how many wget attempts should be made.
start_test PreserveURLs on prevents URL rewriting
FILE=preserveurls/on/preserveurls.html
URL=$TEST_ROOT/$FILE
FETCHED=$OUTDIR/preserveurls.html
OUT=$($WGET_DUMP --header=X-PSA-Blocking-Rewrite:psatest $URL)
check_not_from "$OUT" fgrep -q .pagespeed.

# When PreserveURLs is off do a quick check to make sure that normal rewriting
# occurs.  This is not exhaustive, the unit tests should cover the rest.
start_test PreserveURLs off causes URL rewriting
FILE=preserveurls/off/preserveurls.html
URL=$TEST_ROOT/$FILE
FETCHED=$OUTDIR/preserveurls.html
# Check that style.css was inlined.
fetch_until $URL 'egrep -c big.css.pagespeed.' 1
# Check that introspection.js was inlined.
fetch_until $URL 'grep -c document\.write(\"External' 1
# Check that the image was optimized.
fetch_until $URL 'grep -c BikeCrashIcn\.png\.pagespeed\.' 1

# TODO(jkarlin): When ajax rewriting is in MPS check that it works with
# MPS.

# When Cache-Control: no-transform is in the response make sure that
# the URL is not rewritten and that the no-transform header remains
# in the resource.
start_test HonorNoTransform cache-control: no-transform
WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
FILE=no_transform/image.html
URL=$TEST_ROOT/$FILE
FETCHED=$OUTDIR/output
wget -O - $URL $WGET_ARGS > $FETCHED
# Make sure that the URL is not rewritten
check_not fgrep -q '.pagespeed.' $FETCHED
wget -O - -S $TEST_ROOT/no_transform/BikeCrashIcn.png $WGET_ARGS &> $FETCHED
# Make sure that the no-transfrom header is still there
check grep -q 'Cache-Control:.*no-transform' $FETCHED

# TODO(jkarlin): Now that IPRO is in place for apache we should test that we
# obey no-transform in that path.

start_test Split HTML
SPLIT_HTML_ATF="$TEST_ROOT/split_html/split.html?x_split=atf"
wget -O - $URL $SPLIT_HTML_ATF > $FETCHED
check grep -q 'loadXMLDoc("1")' $FETCHED
check grep -q "/$PSA_JS_LIBRARY_URL_PREFIX/blink" $FETCHED
check grep -q '<!--GooglePanel begin panel-id.0--><!--GooglePanel end panel-id.0-->' $FETCHED
check grep -q -v 'pagespeed_lazy_src' $FETCHED

SPLIT_HTML_BTF=$TEST_ROOT"/split_html/split.html?x_split=atf"
wget -O - $URL $SPLIT_HTML_BTF > $FETCHED
check grep -q 'panel-id.0' $FETCHED
check grep -q 'pagespeed_lazy_src' $FETCHED

# Depends upon "Header append Vary User-Agent" and ModPagespeedRespectVary.
start_test respect vary user-agent
URL=$TEST_ROOT/vary/index.html?PageSpeedFilters=inline_css
echo $WGET_DUMP $URL
OUT=$($WGET_DUMP $URL)
check_not_from "$OUT" fgrep "<style>"

# Tests that we get instant ipro rewrites with LoadFromFile and
# ModPagespeedInPlaceWaitForOptimized get us first-pass rewrites.
start_test instant ipro with InPlaceWaitForOptimized and LoadFromFile
echo $WGET_DUMP $TEST_ROOT/ipro/instant/wait/purple.css
OUT=$($WGET_DUMP $TEST_ROOT/ipro/instant/wait/purple.css)
check_from "$OUT" fgrep -q 'body{background:#9370db}'

start_test instant ipro with ModPagespeedInPlaceRewriteDeadline and LoadFromFile
echo $WGET_DUMP $TEST_ROOT/ipro/instant/deadline/purple.css
OUT=$($WGET_DUMP $TEST_ROOT/ipro/instant/deadline/purple.css)
check_from "$OUT" fgrep -q 'body{background:#9370db}'

# If ModPagespeedDisableRewriteOnNoTransform is turned off, verify that
# the rewriting applies even if Cache-control: no-transform is set.
start_test rewrite on Cache-control: no-transform
URL=$TEST_ROOT/disable_no_transform/index.html?PageSpeedFilters=inline_css
fetch_until -save -recursive $URL 'grep -c style' 2

start_test ModPagespeedShardDomain directive in .htaccess file
test_filter extend_cache
fetch_until -save $TEST_ROOT/shard/shard.html 'grep -c \.pagespeed\.' 4
check [ $(grep -ce href=\"http://shard1 $FETCH_FILE) = 2 ];
check [ $(grep -ce href=\"http://shard2 $FETCH_FILE) = 2 ];

start_test server-side includes
fetch_until -save $TEST_ROOT/ssi/ssi.shtml?PageSpeedFilters=combine_css \
    'grep -c \.pagespeed\.' 1
check [ $(grep -ce $combine_css_filename $FETCH_FILE) = 1 ];

start_test mod_rewrite
check $WGET_DUMP $TEST_ROOT/redirect/php/ -O $OUTDIR/redirect_php.html
check \
  [ $(grep -ce "href=\"/mod_pagespeed_test/" $OUTDIR/redirect_php.html) = 2 ];

start_test ModPagespeedLoadFromFile
URL=$TEST_ROOT/load_from_file/index.html?PageSpeedFilters=inline_css
fetch_until $URL 'grep -c blue' 1

# The "httponly" directory is disallowed.
fetch_until $URL 'fgrep -c web.httponly.example.css' 1

# Loading .ssp.css files from file is disallowed.
fetch_until $URL 'fgrep -c web.example.ssp.css' 1

# There's an exception "allow" rule for "exception.ssp.css" so it can be loaded
# directly from the filesystem.
fetch_until $URL 'fgrep -c file.exception.ssp.css' 1

start_test ModPagespeedLoadFromFileMatch
URL=$TEST_ROOT/load_from_file_match/index.html?PageSpeedFilters=inline_css
fetch_until $URL 'grep -c blue' 1

start_test Custom headers remain on HTML, but cache should be disabled.
URL=$TEST_ROOT/rewrite_compressed_js.html
echo $WGET_DUMP $URL
HTML_HEADERS=$($WGET_DUMP $URL)
check_from "$HTML_HEADERS" egrep -q "X-Extra-Header: 1"
# The extra header should only be added once, not twice.
check_not_from "$HTML_HEADERS" egrep -q "X-Extra-Header: 1, 1"
check_from "$HTML_HEADERS" egrep -q 'Cache-Control: max-age=0, no-cache'

start_test Make sure nostore on a subdirectory is retained
URL=$TEST_ROOT/nostore/nostore.html
HTML_HEADERS=$($WGET_DUMP $URL)
check_from "$HTML_HEADERS" egrep -q \
  'Cache-Control: max-age=0, no-cache, no-store'

start_test Custom headers remain on resources, but cache should be 1 year.
URL="$TEST_ROOT/compressed/hello_js.custom_ext.pagespeed.ce.HdziXmtLIV.txt"
echo $WGET_DUMP $URL
RESOURCE_HEADERS=$($WGET_DUMP $URL)
check_from "$RESOURCE_HEADERS"  egrep -q 'X-Extra-Header: 1'
# The extra header should only be added once, not twice.
check_not_from "$RESOURCE_HEADERS"  egrep -q 'X-Extra-Header: 1, 1'
check_from "$RESOURCE_HEADERS"  egrep -q 'Cache-Control: max-age=31536000'

start_test ModPagespeedModifyCachingHeaders
URL=$TEST_ROOT/retain_cache_control/index.html
OUT=$($WGET_DUMP $URL)
check_from "$OUT" grep -q "Cache-Control: private, max-age=3000"
check_from "$OUT" grep -q "Last-Modified:"

start_test ModPagespeedModifyCachingHeaders with DownstreamCaching enabled.
URL=$TEST_ROOT/retain_cache_control_with_downstream_caching/index.html
OUT=$($WGET_DUMP -S $URL)
check_not_from "$OUT" grep -q "Last-Modified:"
check_from "$OUT" grep -q "Cache-Control: private, max-age=3000"

test_filter combine_javascript combines 2 JS files into 1.
start_test combine_javascript with long URL still works
URL=$TEST_ROOT/combine_js_very_many.html?PageSpeedFilters=combine_javascript
fetch_until $URL 'grep -c src=' 4

start_test aris disables js combining for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/?\
PageSpeedFilters=combine_javascript"
fetch_until $URL 'grep -c src=' 2

start_test aris disables js combining only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html?\
PageSpeedFilters=combine_javascript"
fetch_until $URL 'grep -c src=' 1

test_filter inline_javascript inlines a small JS file

start_test no inlining of unauthorized resources
URL="$TEST_ROOT/unauthorized/inline_unauthorized_javascript.html?\
PageSpeedFilters=inline_javascript,debug"
OUTFILE=$OUTDIR/blocking_rewrite.out.html
$WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
check egrep -q 'script[[:space:]]src=' $OUTFILE
EXPECTED_COMMENT_LINE="<!--The preceding resource was not rewritten \
because its domain (www.gstatic.com) is not authorized-->"
check [ $(grep -o "$EXPECTED_COMMENT_LINE" $OUTFILE | wc -l) -eq 1 ]

if [ "$SECONDARY_HOSTNAME" != "" ]; then
  start_test inline_unauthorized_resources allows inlining
  HOST_NAME="http://unauthorizedresources.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
  URL+="inline_unauthorized_javascript.html?PageSpeedFilters=inline_javascript"
  http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $URL 'grep -c script[[:space:]]src=' 0

  start_test inline_unauthorized_resources does not allow rewriting
  URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
  URL+="inline_unauthorized_javascript.html?PageSpeedFilters=rewrite_javascript"
  OUTFILE=$OUTDIR/blocking_rewrite.out.html
  http_proxy=$SECONDARY_HOSTNAME \
      $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
  check egrep -q 'script[[:space:]]src=' $OUTFILE

  # Verify that we can control pagespeed settings via a response
  # header passed from an origin to a reverse proxy.
  start_test Honor response header direcives from origin
  URL="http://rproxy.rmcomments.example.com/"
  URL+="mod_pagespeed_example/remove_comments.html"
  echo http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL ...
  OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)
  check_from "$OUT" fgrep -q "remove_comments example"
  check_not_from "$OUT" fgrep -q "This comment will be removed"
fi

test_filter inline_css inlines a small CSS file

start_test no inlining of unauthorized resources
URL="$TEST_ROOT/unauthorized/inline_css.html?\
PageSpeedFilters=inline_css,debug"
OUTFILE=$OUTDIR/blocking_rewrite.out.html
$WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
check egrep -q 'link[[:space:]]rel=' $OUTFILE
EXPECTED_COMMENT_LINE="<!--The preceding resource was not rewritten \
because its domain (www.google.com) is not authorized-->"
check [ $(grep -o "$EXPECTED_COMMENT_LINE" $OUTFILE | wc -l) -eq 1 ]

if [ "$SECONDARY_HOSTNAME" != "" ]; then
  start_test inline_unauthorized_resources allows inlining
  HOST_NAME="http://unauthorizedresources.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
  URL+="inline_css.html?PageSpeedFilters=inline_css"
  http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $URL 'grep -c link[[:space:]]rel=' 0

  start_test inline_unauthorized_resources does not allow rewriting
  URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
  URL+="inline_css.html?PageSpeedFilters=rewrite_css"
  OUTFILE=$OUTDIR/blocking_rewrite.out.html
  http_proxy=$SECONDARY_HOSTNAME \
      $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
  check egrep -q 'link[[:space:]]rel=' $OUTFILE
fi

start_test UseExperimentalJsMinifier
URL="$TEST_ROOT/experimental_js_minifier/index.html"
URL+="?PageSpeedFilters=rewrite_javascript"
# External scripts rewritten.
fetch_until -save -recursive $URL 'grep -c src=.*\.pagespeed\.jm\.' 1
check_not grep "removed" $WGET_DIR/*   # No comments should remain.
check grep -q "preserved" $WGET_DIR/*  # Contents of <script src=> element kept.
ORIGINAL_HTML_SIZE=1484
check_file_size $FETCH_FILE -lt $ORIGINAL_HTML_SIZE  # Net savings
# Rewritten JS is cache-extended.
check grep -qi "Cache-control: max-age=31536000" $WGET_OUTPUT
check grep -qi "Expires:" $WGET_OUTPUT

start_test Source map tests
URL="$TEST_ROOT/experimental_js_minifier/index.html"
URL+="?PageSpeedFilters=rewrite_javascript,include_js_source_maps"
# All rewriting still happening as expected.
fetch_until -save -recursive $URL 'grep -c src=.*\.pagespeed\.jm\.' 1
check_not grep "removed" $WGET_DIR/*  # No comments should remain.
check_file_size $FETCH_FILE -lt $ORIGINAL_HTML_SIZE  # Net savings
check grep -qi "Cache-control: max-age=31536000" $WGET_OUTPUT
check grep -qi "Expires:" $WGET_OUTPUT

# No source map for inline JS
check_not grep sourceMappingURL $FETCH_FILE
# Yes source_map for external JS
check grep -q sourceMappingURL $WGET_DIR/script.js.pagespeed.*
SOURCE_MAP_URL=$(grep sourceMappingURL $WGET_DIR/script.js.pagespeed.* |
                 grep -o 'http://.*')
OUTFILE=$OUTDIR/source_map
check $WGET_DUMP -O $OUTFILE $SOURCE_MAP_URL
check grep -qi "Cache-control: max-age=31536000" $OUTFILE  # Long cache
check grep -q "script.js?PageSpeed=off" $OUTFILE  # Has source URL.
check grep -q '"mappings":' $OUTFILE  # Has mappings.

start_test IPRO source map tests
URL="$TEST_ROOT/experimental_js_minifier/script.js"
URL+="?PageSpeedFilters=rewrite_javascript,include_js_source_maps"
# Fetch until IPRO removes comments.
fetch_until -save $URL 'grep -c removed' 0
# Yes source_map for external JS
check grep -q sourceMappingURL $FETCH_FILE
SOURCE_MAP_URL=$(grep sourceMappingURL $FETCH_FILE | grep -o 'http://.*')
OUTFILE=$OUTDIR/source_map
check $WGET_DUMP -O $OUTFILE $SOURCE_MAP_URL
check grep -qi "Cache-control: max-age=31536000" $OUTFILE  # Long cache
check grep -q "script.js?PageSpeed=off" $OUTFILE  # Has source URL.
check grep -q '"mappings":' $OUTFILE  # Has mappings.

start_test aris disables js inlining for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/?\
PageSpeedFilters=inline_javascript"
fetch_until $URL 'grep -c src=' 1

start_test aris disables js inlining only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html?\
PageSpeedFilters=inline_javascript"
fetch_until $URL 'grep -c src=' 0

test_filter rewrite_javascript minifies JavaScript and saves bytes.
start_test aris disables js cache extention for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/?\
PageSpeedFilters=rewrite_javascript"
# first check something that should get rewritten to know we're done with
# rewriting
fetch_until -save $URL 'grep -c "src=\"../normal.js\""' 0
check [ $(grep -c "src=\"../introspection.js\"" $FETCH_FILE) = 1 ]

start_test aris disables js cache extension only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html?\
PageSpeedFilters=rewrite_javascript"
fetch_until -save $URL 'grep -c src=\"normal.js\"' 0
check [ $(grep -c src=\"introspection.js\" $FETCH_FILE) = 0 ]

# Check that no filter changes urls for introspective javascript if
# avoid_renaming_introspective_javascript is on
start_test aris disables url modification for introspective js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/?\
PageSpeedFilters=testing,core"
# first check something that should get rewritten to know we're done with
# rewriting
fetch_until -save $URL 'grep -c src=\"../normal.js\"' 0
check [ $(grep -c src=\"../introspection.js\" $FETCH_FILE) = 1 ]

start_test aris disables url modification only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html?\
PageSpeedFilters=testing,core"
fetch_until -save $URL 'grep -c src=\"normal.js\"' 0
check [ $(grep -c src=\"introspection.js\" $FETCH_FILE) = 0 ]

start_test HTML add_instrumentation lacks '&amp;' and contains CDATA
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.html\
?PageSpeedFilters=add_instrumentation
check [ $(grep -c "\&amp;" $WGET_OUTPUT) = 0 ]
check [ $(grep -c '//<\!\[CDATA\[' $WGET_OUTPUT) = 1 ]

start_test XHTML add_instrumentation also lacks '&amp;' and contains CDATA
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.xhtml\
?PageSpeedFilters=add_instrumentation
check [ $(grep -c "\&amp;" $WGET_OUTPUT) = 0 ]
check [ $(grep -c '//<\!\[CDATA\[' $WGET_OUTPUT) = 1 ]

start_test cache_partial_html enabled has no effect
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.html\
?PageSpeedFilters=cache_partial_html
check [ $(grep -c '<html>' $WGET_OUTPUT) = 1 ]
check [ $(grep -c '<body>' $WGET_OUTPUT) = 1 ]
check [ $(grep -c 'pagespeed.panelLoader' $WGET_OUTPUT) = 0 ]

start_test flush_subresources rewriter is not applied
URL="$TEST_ROOT/flush_subresources.html?\
PageSpeedFilters=flush_subresources,extend_cache_css,\
extend_cache_scripts"
# Fetch once with X-PSA-Blocking-Rewrite so that the resources get rewritten and
# property cache is updated with them.
wget -O - --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $TEMPDIR/flush.$$
# Fetch again. The property cache has the subresources this time but
# flush_subresources rewriter is not applied. This is a negative test case
# because this rewriter does not exist in mod_pagespeed yet.
check [ `wget -O - $URL | grep -o 'link rel="subresource"' | wc -l` = 0 ]
rm -f $TEMPDIR/flush.$$

start_test Respect custom options on resources.
IMG_NON_CUSTOM="$EXAMPLE_ROOT/images/xPuzzle.jpg.pagespeed.ic.fakehash.jpg"
IMG_CUSTOM="$TEST_ROOT/custom_options/xPuzzle.jpg.pagespeed.ic.fakehash.jpg"

# Identical images, but in the .htaccess file in the custom_options directory we
# additionally disable core-filter convert_jpeg_to_progressive which gives a
# larger file.
fetch_until $IMG_NON_CUSTOM 'wc -c' 98276 "" -le
fetch_until $IMG_CUSTOM 'wc -c' 102902 "" -le

# Test our handling of headers when a FLUSH event occurs.
# Skip if PHP is not installed to cater for admins who don't want it installed.
# Always fetch the first file so we can check if PHP is enabled.
start_test Headers are not destroyed by a flush event.
FILE=php_withoutflush.php
URL=$TEST_ROOT/$FILE
FETCHED=$WGET_DIR/$FILE
$WGET_DUMP $URL > $FETCHED
if grep -q '<?php' $FETCHED; then
  echo "*** Skipped because PHP is not installed. If you'd like to enable this"
  echo "*** test please run: sudo apt-get install php5-common php5"
else
  check [ $(grep -c '^X-Mod-Pagespeed:'               $FETCHED) = 1 ]
  check [ $(grep -c '^X-My-PHP-Header: without_flush' $FETCHED) = 1 ]
  check [ $(grep -c '^Content-Length: [0-9]'          $FETCHED) = 1 ]

  FILE=php_withflush.php
  URL=$TEST_ROOT/$FILE
  FETCHED=$WGET_DIR/$FILE
  $WGET_DUMP $URL > $FETCHED
  check [ $(grep -c '^X-Mod-Pagespeed:'               $FETCHED) = 1 ]
  check [ $(grep -c '^X-My-PHP-Header: with_flush'    $FETCHED) = 1 ]
  # 2.2 prefork returns no content length while 2.2 worker returns a real
  # content length. IDK why but skip this test because of that.
  # check [ $(grep -c '^Content-Length: [0-9]'          $FETCHED) = 1 ]
fi

start_test ModPagespeedMapProxyDomain
URL=$EXAMPLE_ROOT/proxy_external_resource.html
echo Rewrite HTML with reference to a proxyable image
fetch_until -save -recursive $URL?PageSpeedFilters=-inline_images \
    'grep -c 1.gif.pagespeed' 1

start_test OptimizeForBandwidth
# We use blocking-rewrite tests because we want to make sure we don't
# get rewritten URLs when we don't want them.
function test_optimize_for_bandwidth() {
  OUT=$($WGET -q -O - --header=X-PSA-Blocking-Rewrite:psatest \
    $TEST_ROOT/optimize_for_bandwidth/$1)
  check_from "$OUT" grep -q "$2"
  if [ "$#" -ge 3 ]; then
    check_from "$OUT" grep -q "$3"
  fi
}
test_optimize_for_bandwidth rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(arrow.png)}' \
  '<link rel="stylesheet" type="text/css" href="yellow.css">'
test_optimize_for_bandwidth inline_css/rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(arrow.png)}' \
  '<style>.yellow{background-color:#ff0}</style>'
test_optimize_for_bandwidth css_urls/rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(arrow.png)}' \
  '<link rel="stylesheet" type="text/css" href="A.yellow.css.pagespeed'
test_optimize_for_bandwidth image_urls/rewrite_image.html \
  '<img src=\"xarrow.png.pagespeed.'
test_optimize_for_bandwidth core_filters/rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(xarrow.png.pagespeed.' \
  '<style>.yellow{background-color:#ff0}</style>'

# To make sure that we can reconstruct the proxied content by going back
# to the origin, we must avoid hitting the output cache.
# Note that cache-flushing does not affect the cache of rewritten resources;
# only input-resources and metadata.  To avoid hitting that cache and force
# us to rewrite the resource from origin, we grab this resource from a
# virtual host attached to a different cache.
if [ "$SECONDARY_HOSTNAME" != "" ]; then
  SECONDARY_HOST="http://secondary.example.com/gstatic_images"
  PROXIED_IMAGE="$SECONDARY_HOST/$(basename $WGET_DIR/*1.gif.pagespeed*)"
  start_test $PROXIED_IMAGE expecting one year cache.

  # With the proper hash, we'll get a long cache lifetime.
  http_proxy=$SECONDARY_HOSTNAME fetch_until -save $PROXIED_IMAGE \
      "grep -c max-age=31536000" 1 --save-headers

  # With the wrong hash, we'll get a short cache lifetime (and also no output
  # cache hit.
  WRONG_HASH="0"
  PROXIED_IMAGE="$SECONDARY_HOST/1.gif.pagespeed.ce.$WRONG_HASH.jpg"
  start_test Fetching $PROXIED_IMAGE expecting short private cache.
  http_proxy=$SECONDARY_HOSTNAME fetch_until $PROXIED_IMAGE \
      "grep -c max-age=300,private" 1 --save-headers

  # Test fetching a pagespeed URL via Apache running as a reverse proxy, with
  # mod_pagespeed loaded, but disabled for the proxied domain. As reported in
  # Issue 582 this used to fail with a 403 (Forbidden).
  start_test Reverse proxy a pagespeed URL.
  PROXY_PATH="http://$PAGESPEED_TEST_HOST/mod_pagespeed_example/styles"
  ORIGINAL="${PROXY_PATH}/yellow.css"
  FILTERED="${PROXY_PATH}/A.yellow.css.pagespeed.cf.KM5K8SbHQL.css"

  # We should be able to fetch the original ...
  echo  http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $ORIGINAL
  OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $ORIGINAL 2>&1)
  check_200_http_response "$OUT"
  # ... AND the rewritten version.
  echo  http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $FILTERED
  OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $FILTERED 2>&1)
  check_200_http_response "$OUT"

  if [ "$NO_VHOST_MERGE" = "on" ]; then
    start_test PageSpeed Unplugged and Off
    SPROXY="http://localhost:$APACHE_SECONDARY_PORT"
    VHOST_MPS_OFF="http://mpsoff.example.com"
    VHOST_MPS_UNPLUGGED="http://mpsunplugged.example.com"
    SITE="mod_pagespeed_example"
    ORIGINAL="$SITE/styles/yellow.css"
    FILTERED="$SITE/styles/A.yellow.css.pagespeed.cf.KM5K8SbHQL.css"

    # PageSpeed unplugged does not serve .pagespeed. resources.
    http_proxy=$SPROXY check_not $WGET -O /dev/null \
        $VHOST_MPS_UNPLUGGED/$FILTERED
    # PageSpeed off does serve .pagespeed. resources.
    http_proxy=$SPROXY check $WGET -O /dev/null $VHOST_MPS_OFF/$FILTERED

    # PageSpeed unplugged doesn't rewrite HTML, even when asked via query.
    OUT=$(http_proxy=$SPROXY check $WGET -S -O - \
    $VHOST_MPS_UNPLUGGED/$SITE/?PageSpeed=on 2>&1)
    check_not_from "$OUT" grep "X-Mod-Pagespeed:"
    # PageSpeed off does rewrite HTML if asked.
    OUT=$(http_proxy=$SPROXY check $WGET -S -O - \
    $VHOST_MPS_OFF/$SITE/?PageSpeed=on 2>&1)
    check_from "$OUT" grep "X-Mod-Pagespeed:"
  fi

  start_test Embed image configuration in rewritten image URL.

  # The embedded configuration is placed between the "pagespeed" and "ic", e.g.
  # *xPuzzle.jpg.pagespeed.gp+jp+pj+js+rj+rp+rw+ri+cp+md+iq=73.ic.oFXPiLYMka.jpg
  # We use a regex matching "gp+jp+pj+js+rj+rp+rw+ri+cp+md+iq=73" rather than
  # spelling it out to avoid test regolds when we add image filter IDs.
  http_proxy=$SECONDARY_HOSTNAME fetch_until -save -recursive \
      http://embed-config-html.example.org/embed_config.html \
      'grep -c \.pagespeed\.' 3 --save-headers

  # with the default rewriters in vhost embed-config-resources.example.com
  # the image will be >200k.  But by enabling resizing & compression 73
  # as specified in the HTML domain, and transmitting that configuration via
  # image URL query param, the image file (including headers) is 8341 bytes.
  # We check against 10000 here so this test isn't sensitive to
  # image-compression tweaks (we have enough of those elsewhere).
  check_file_size "$WGET_DIR/256x192xPuz*.pagespeed.*iq=*.ic.*" -lt 10000

  # The CSS file gets rewritten with embedded options, and will have an
  # embedded image in it as well.
  check_file_size \
    "$WGET_DIR/*rewrite_css_images.css.pagespeed.*+ii+*+iq=*.cf.*" -lt 600

  # The JS file is rewritten but has no related options set, so it will
  # not get the embedded options between "pagespeed" and "jm".
  check_file_size "$WGET_DIR/rewrite_javascript.js.pagespeed.jm.*.js" -lt 500

  # One flaw in the above test is that it short-circuits the decoding
  # of the query-params because when Apache responds to the recursive
  # wget fetch of the image, it finds the rewritten resource in the
  # cache.  The two vhosts are set up with the same cache.  If they
  # had different caches we'd have a different problem, which is that
  # the first load of the image-rewrite from the resource vhost would
  # not be resized.  To make sure the decoding path works, we'll
  # "finish" this test below after performing a cache flush, saving
  # the encoded image and expected size.
  EMBED_CONFIGURATION_IMAGE="http://embed-config-resources.example.com/images/"
  EMBED_CONFIGURATION_IMAGE_TAIL=$(ls $WGET_DIR | grep 256x192xPuz | grep iq=)
  EMBED_CONFIGURATION_IMAGE+="$EMBED_CONFIGURATION_IMAGE_TAIL"
  EMBED_CONFIGURATION_IMAGE_LENGTH=$( \
    extract_headers "$WGET_DIR/$EMBED_CONFIGURATION_IMAGE_TAIL" | \
    scrape_content_length)

  # Grab the URL for the CSS file.
  EMBED_CONFIGURATION_CSS_LEAF=$(ls $WGET_DIR | \
      grep '\.pagespeed\..*+ii+.*+iq=.*\.cf\..*')
  EMBED_CONFIGURATION_CSS_LENGTH=$(\
    cat $WGET_DIR/$EMBED_CONFIGURATION_CSS_LEAF | scrape_content_length)
  EMBED_CONFIGURATION_CSS_URL="http://embed-config-resources.example.com/styles"
  EMBED_CONFIGURATION_CSS_URL+="/$EMBED_CONFIGURATION_CSS_LEAF"

  # Grab the URL for that embedded image; it should *also* have the embedded
  # configuration options in it, though wget/recursive will not have pulled
  # it to a file for us (wget does not parse CSS) so we'll have to request it.
  EMBED_CONFIGURATION_CSS_IMAGE_URL=$(egrep -o \
    'http://.*iq=[0-9]*\.ic\..*\.jpg' \
    $WGET_DIR/*rewrite_css_images.css.pagespeed.*+ii+*+iq=*.cf.*)
  # fetch that file and make sure it has the right cache-control
  CSS_IMAGE_HEADERS=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      $EMBED_CONFIGURATION_CSS_IMAGE_URL | head -10)
  check_from "$CSS_IMAGE_HEADERS" fgrep -q "Cache-Control: max-age=31536000"
  EMBED_CONFIGURATION_CSS_IMAGE_LENGTH=$(echo "$CSS_IMAGE_HEADERS" | \
    scrape_content_length)

  function embed_image_config_post_flush() {
    # Finish off the url-params-.pagespeed.-resource tests with a clear
    # cache.  We split the test like this to avoid having multiple
    # places where we flush cache, which requires sleeps since the
    # cache-flush is poll driven.
    start_test Embed image/css configuration decoding with clear cache.
    echo Looking for $EMBED_CONFIGURATION_IMAGE expecting \
        $EMBED_CONFIGURATION_IMAGE_LENGTH bytes
    http_proxy=$SECONDARY_HOSTNAME fetch_until "$EMBED_CONFIGURATION_IMAGE" \
        "wc -c" $EMBED_CONFIGURATION_IMAGE_LENGTH

    echo Looking for $EMBED_CONFIGURATION_CSS_IMAGE_URL expecting \
        $EMBED_CONFIGURATION_CSS_IMAGE_LENGTH bytes
    http_proxy=$SECONDARY_HOSTNAME fetch_until \
        "$EMBED_CONFIGURATION_CSS_IMAGE_URL" \
        "wc -c" $EMBED_CONFIGURATION_CSS_IMAGE_LENGTH

    echo Looking for $EMBED_CONFIGURATION_CSS_URL expecting \
        $EMBED_CONFIGURATION_CSS_LENGTH bytes
    http_proxy=$SECONDARY_HOSTNAME fetch_until \
        "$EMBED_CONFIGURATION_CSS_URL" \
        "wc -c" $EMBED_CONFIGURATION_CSS_LENGTH
  }
  on_cache_flush embed_image_config_post_flush

  start_test ModPagespeedMapProxyDomain for CDN setup
  # Test transitive ProxyMapDomain.  In this mode we have three hosts: cdn,
  # proxy, and origin.  Proxy runs MPS and fetches resources from origin,
  # optimizes them, and rewrites them to CDN for serving. The CDN is dumb and
  # has no caching so simply proxies all requests to proxy.  Origin serves out
  # images only.
  echo "Rewrite HTML with reference to proxyable image on CDN."
  PROXY_PM="http://proxy.pm.example.com"
  URL="$PROXY_PM/transitive_proxy.html"
  PDT_STATSDIR=$TEMPDIR/stats
  rm -rf $PDT_STATSDIR
  mkdir -p $PDT_STATSDIR
  PDT_OLDSTATS=$PDT_STATSDIR/blocking_rewrite_stats.old
  PDT_NEWSTATS=$PDT_STATSDIR/blocking_rewrite_stats.new
  PDT_PROXY_STATS_URL=$PROXY_PM/mod_pagespeed_statistics?PageSpeed=off
  http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP $PDT_PROXY_STATS_URL > $PDT_OLDSTATS

  # The image should be proxied from origin, compressed, and rewritten to cdn.
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save -recursive $URL \
    'fgrep -c cdn.pm.example.com/external/xPuzzle.jpg.pagespeed.ic' 1
  check_file_size "$WGET_DIR/xPuzzle*" -lt 241260

  # Make sure that the file was only rewritten once.
  http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP $PDT_PROXY_STATS_URL > $PDT_NEWSTATS
  check_stat $PDT_OLDSTATS $PDT_NEWSTATS image_rewrites 1

  # The js should be fetched locally and inlined.
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save -recursive $URL 'fgrep -c document.write' 1

  # Save the image URL so we can try to reconstruct it later.
  PDT_IMG_URL=`egrep -o \"[^\"]*xPuzzle[^\"]*\.pagespeed[^\"]*\" $FETCH_FILE | \
    sed -e 's/\"//g'`

  # This function will be called after the cache is flushed to test
  # reconstruction.
  function map_proxy_domain_cdn_reconstruct() {
    rm -rf $PDT_STATSDIR
    mkdir -p $PDT_STATSDIR
    http_proxy=$SECONDARY_HOSTNAME \
      $WGET_DUMP $PDT_PROXY_STATS_URL > $PDT_OLDSTATS
    echo "Make sure we can reconstruct the image."
    # Fetch the url until it is less than its original size (i.e. compressed).
    http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $PDT_IMG_URL "wc -c" 241260 "" "-lt"
    # Double check that we actually reconstructed.
    http_proxy=$SECONDARY_HOSTNAME \
      $WGET_DUMP $PDT_PROXY_STATS_URL > $PDT_NEWSTATS
    check_stat $PDT_OLDSTATS $PDT_NEWSTATS image_rewrites 1
  }
  on_cache_flush map_proxy_domain_cdn_reconstruct

  # See if mod_spdy is available
  SPDY_SUPPORT=$(http_proxy=$SECONDARY_HOSTNAME wget -q -O- spdy.example.com)
  if [ "$SPDY_SUPPORT" = "mod_spdy supported." ]; then
    echo "Testing fetching SSL with help of mod_spdy"
    # Now, try fetching a document from the spdyfetch.example.com vhost over SSL
    # Note that we cannot use the usual proxy trick, since it won't work with
    # SSL, but luckily we can still mess around with the Host: header and
    # X-Forwarded-Proto: headers directly and get what we want.
    # Even that, however, is not unconditional: wget >= 1.14 uses SNI, which
    # results in 400s if that doesn't match the Host:. Luckily, passing in
    # --secure-protocol=SSLv3 disables SNI.
    DATA=$(check wget -q -O - --no-check-certificate \
        --header="X-Forwarded-Proto: https" \
        --header="Host: spdyfetch.example.com"\
        --secure-protocol=SSLv3 \
        $HTTPS_EXAMPLE_ROOT/styles/A.blue.css.pagespeed.cf.0.css)
    check_from "$DATA" grep -q blue

    # Sanity-check that it fails for non-spdyfetch enabled code.
    echo "Sanity-check with mod_spdy fetch off"
    DATA=$(check_error_code 8 wget -q -O - --no-check-certificate \
        --header="X-Forwarded-Proto: https" \
        --header="Host: nospdyfetch.example.com"\
        $HTTPS_EXAMPLE_ROOT/styles/A.blue.css.pagespeed.cf.0.css)
  fi
fi

start_test ShowCache without URL gets a form, inputs, preloaded UA.
ADMIN_CACHE=$PRIMARY_SERVER/pagespeed_admin/cache
OUT=$($WGET_DUMP $ADMIN_CACHE)
check_from "$OUT" fgrep -q "<form>"
check_from "$OUT" fgrep -q "<input "
check_from "$OUT" fgrep -q "Cache-Control: max-age=0, no-cache"
# Preloaded user_agent value field leading with "Mozilla" set in
# ../automatic/system_test_helpers.sh to help test a "normal" flow.
check_from "$OUT" fgrep -q 'name=user_agent value="Mozilla'

start_test ShowCache with bogus URL gives a 404
OUT=$(check_error_code 8 $WGET -O - --save-headers \
  $PRIMARY_SERVER/pagespeed_cache?url=bogus_format 2>&1)
check_from "$OUT" fgrep -q "ERROR 404: Not Found"

start_test ShowCache with valid, present URL, with unique options.
options="PageSpeedImageInlineMaxBytes=6765"
fetch_until -save $EXAMPLE_ROOT/rewrite_images.html?$options \
    'grep -c Puzzle\.jpg\.pagespeed\.ic\.' 1
URL_TAIL=$(grep Puzzle $FETCH_UNTIL_OUTFILE | cut -d \" -f 2)
SHOW_CACHE_URL=$EXAMPLE_ROOT/$URL_TAIL
SHOW_CACHE_QUERY=$ADMIN_CACHE?url=$SHOW_CACHE_URL\&$options
OUT=$($WGET_DUMP $SHOW_CACHE_QUERY)

# TODO(jmarantz): I have seen this test fail in the 'apache_debug_leak_test'
# phase of checkin tests.  The failure is that we are able to rewrite the
# HTML image link for Puzzle.jpg, but when fetching the metadata cache entry
# it comes back as cache_ok:false.
#
# This should be investigated, especially if it happens again.  Wild
# guess: the shared-memory metadata cache might face an unexpected
# eviction as it is not a pure LRU.
#
# Another guess: I think we might be calling callbacks with updated
# metadata cache before writing the metadata cache entries to the cache
# in some flows, e.g. in ResourceReconstructCallback::HandleDone.  It's not
# obvious why that flow would affect this test, but the ordering
# of writing cache and calling callbacks deserves an audit.
check_from "$OUT" fgrep -q cache_ok:true
check_from "$OUT" fgrep -q mod_pagespeed_example/images/Puzzle.jpg

function show_cache_after_flush() {
  start_test ShowCache with same URL and matching options misses after flush
  OUT=$($WGET_DUMP $SHOW_CACHE_QUERY)
  check_from "$OUT" fgrep -q cache_ok:false
}

on_cache_flush show_cache_after_flush

start_test ShowCache with same URL but new options misses.
options="PageSpeedImageInlineMaxBytes=6766"
OUT=$($WGET_DUMP $ADMIN_CACHE?url=$SHOW_CACHE_URL\&$options)
check_from "$OUT" fgrep -q cache_ok:false

# TODO(sligocki): start_test ModPagespeedMaxSegmentLength

if [ "$CACHE_FLUSH_TEST" = "on" ]; then
  start_test add_instrumentation has added unload handler with \
      ModPagespeedReportUnloadTime enabled in APACHE_SECONDARY_PORT.
  URL="$SECONDARY_TEST_ROOT/add_instrumentation.html\
?PageSpeedFilters=add_instrumentation"
  echo http_proxy=$SECONDARY_HOSTNAME $WGET -O $WGET_OUTPUT $URL
  http_proxy=$SECONDARY_HOSTNAME $WGET -O $WGET_OUTPUT $URL
  check [ $(grep -o "<script" $WGET_OUTPUT|wc -l) = 3 ]
  check [ $(grep -c "pagespeed.addInstrumentationInit('/mod_pagespeed_beacon', 'beforeunload', '', 'http://secondary.example.com/mod_pagespeed_test/add_instrumentation.html');" $WGET_OUTPUT) = 1 ]
  check [ $(grep -c "pagespeed.addInstrumentationInit('/mod_pagespeed_beacon', 'load', '', 'http://secondary.example.com/mod_pagespeed_test/add_instrumentation.html');" $WGET_OUTPUT) = 1 ]

  if [ "$NO_VHOST_MERGE" = "on" ]; then
    start_test When ModPagespeedMaxHtmlParseBytes is not set, we do not insert \
        a redirect.
    OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      $SECONDARY_TEST_ROOT/large_file.html?PageSpeedFilters=)
    check_not_from "$OUT" fgrep -q "window.location="
    check_from "$OUT" fgrep -q "Lorem ipsum dolor sit amet"
  fi

  start_test Cache flushing works by touching cache.flush in cache directory.

  # If we write fixed values into the css file here, there is a risk that
  # we will end up seeing the 'right' value because an old process hasn't
  # invalidated things yet, rather than because it updated to what we expect
  # in the first run followed by what we expect in the second run.
  # So, we incorporate the timestamp into RGB colors, using hours
  # prefixed with 1 (as 0-123 fits the 0-255 range) to get a second value.
  # A one-second precision is good enough since there is a sleep 2 below.
  COLOR_SUFFIX=`date +%H,%M,%S\)`
  COLOR0=rgb\($COLOR_SUFFIX
  COLOR1=rgb\(1$COLOR_SUFFIX

  echo Clear out our existing state before we begin the test.
  echo $SUDO touch $MOD_PAGESPEED_CACHE/cache.flush
  $SUDO touch $MOD_PAGESPEED_CACHE/cache.flush
  echo $SUDO touch ${MOD_PAGESPEED_CACHE}_secondary/cache.flush
  $SUDO touch ${MOD_PAGESPEED_CACHE}_secondary/cache.flush
  echo $SUDO touch ${MOD_PAGESPEED_CACHE}_ipro_for_browser/cache.flush
  $SUDO touch ${MOD_PAGESPEED_CACHE}_ipro_for_browser/cache.flush
  sleep 1

  URL_PATH=cache_flush/cache_flush_test.html
  URL=$TEST_ROOT/$URL_PATH
  CSS_FILE=$APACHE_DOC_ROOT/mod_pagespeed_test/cache_flush/update.css
  TMP_CSS_FILE=$TEMPDIR/update.css.$$

  # First, write color 0 into the css file and make sure it gets inlined into
  # the html.
  echo "echo \".class myclass { color: $COLOR0; }\" > $CSS_FILE"
  echo ".class myclass { color: $COLOR0; }" >$TMP_CSS_FILE
  chmod ugo+r $TMP_CSS_FILE  # in case the user's umask doesn't allow o+r
  $SUDO cp $TMP_CSS_FILE $CSS_FILE
  fetch_until $URL "grep -c $COLOR0" 1

  # Also do the same experiment using a different VirtualHost.  It points
  # to the same htdocs, but uses a separate cache directory.
  SECONDARY_URL=$SECONDARY_TEST_ROOT/$URL_PATH
  http_proxy=$SECONDARY_HOSTNAME fetch_until $SECONDARY_URL "grep -c $COLOR0" 1

  # Track how many flushes were noticed by Apache processes up till
  # this point in time.  Note that each Apache process/vhost
  # separately detects the 'flush'.
  NUM_INITIAL_FLUSHES=$(scrape_stat cache_flush_count)

  # Now change the file to $COLOR1.
  echo echo ".class myclass { color: $COLOR1; }" ">" $CSS_FILE
  echo ".class myclass { color: $COLOR1; }" >$TMP_CSS_FILE
  $SUDO cp $TMP_CSS_FILE $CSS_FILE

  # We might have stale cache for 5 seconds, so the result might stay
  # $COLOR0, but we can't really test for that since the child process
  # handling this request might not have it in cache.
  # fetch_until $URL 'grep -c $COLOR0' 1

  # Flush the cache by touching a special file in the cache directory.  Now
  # css gets re-read and we get $COLOR1 in the output.  Sleep here to avoid
  # a race due to 1-second granularity of file-system timestamp checks.  For
  # the test to pass we need to see time pass from the previous 'touch'.
  sleep 2
  echo $SUDO touch $MOD_PAGESPEED_CACHE/cache.flush
  $SUDO touch $MOD_PAGESPEED_CACHE/cache.flush
  sleep 1
  fetch_until $URL "grep -c $COLOR1" 1

  # TODO(jmarantz): we can change this test to be more exacting now, since
  # to address Issue 568, we should only get one cache-flush bump every time
  # we touch the file.
  if [ $statistics_enabled -ne 0 ]; then
    NUM_FLUSHES=$(scrape_stat cache_flush_count)
    NUM_NEW_FLUSHES=$(expr $NUM_FLUSHES - $NUM_INITIAL_FLUSHES)
    echo NUM_NEW_FLUSHES = $NUM_FLUSHES - \
      $NUM_INITIAL_FLUSHES = $NUM_NEW_FLUSHES
    check [ $NUM_NEW_FLUSHES -ge 1 ]
    check [ $NUM_NEW_FLUSHES -lt 20 ]
  fi

  # However, the secondary cache might not have seen this cache-flush, but
  # due to the multiple child processes, each of which does polling separately,
  # we cannot guarantee it.  I think if we knew we were running a 'worker' mpm
  # with just 1 child process we could do this test.
  # fetch_until $SECONDARY_URL 'grep -c blue' 1

  # Now flush the secondary cache too so it can see the change to $COLOR1.
  echo $SUDO touch ${MOD_PAGESPEED_CACHE}_secondary/cache.flush
  $SUDO touch ${MOD_PAGESPEED_CACHE}_secondary/cache.flush
  sleep 1
  http_proxy=$SECONDARY_HOSTNAME fetch_until $SECONDARY_URL "grep -c $COLOR1" 1

  # Clean up update.css from mod_pagespeed_test so it doesn't leave behind
  # a stray file not under source control.
  echo $SUDO rm -f $CSS_FILE
  $SUDO rm -f $CSS_FILE
  rm -f $TMP_CSS_FILE

  # connection_refused.html references modpagespeed.com:1023/someimage.png.
  # mod_pagespeed will attempt to connect to that host and port to fetch the
  # input resource using serf.  We expect the connection to be refused.  Relies
  # on "ModPagespeedDomain modpagespeed.com:1023" in debug.conf.template.  Also
  # relies on running after a cache-flush to avoid bypassing the serf fetch,
  # since mod_pagespeed remembers fetch-failures in its cache for 5 minutes.
  # Because of the empty cache requirement, we conditionalize it on a single
  # value of NO_VHOST_MERGE, so it runs only once per apache_debug_smoke_test
  if [ \( $NO_VHOST_MERGE = "on" \) -a \( "${VIRTUALBOX_TEST:-}" = "" \) ]
  then
    start_test Connection refused handling

    # Monitor the Apache log starting now.  tail -F will catch log rotations.
    SERF_REFUSED_PATH=$TEMPDIR/instaweb_apache_serf_refused.$$
    rm -f $SERF_REFUSED_PATH
    echo APACHE_LOG = $APACHE_LOG
    tail --sleep-interval=0.1 -F $APACHE_LOG > $SERF_REFUSED_PATH &
    TAIL_PID=$!

    # Wait for tail to start.
    echo -n "Waiting for tail to start..."
    while [ ! -s $SERF_REFUSED_PATH ]; do
      sleep 0.1
      echo -n "."
    done
    echo "done!"

    # Actually kick off the request.
    echo $WGET_DUMP $TEST_ROOT/connection_refused.html
    echo checking...
    check $WGET_DUMP $TEST_ROOT/connection_refused.html > /dev/null
    echo check done
    # If we are spewing errors, this gives time to spew lots of them.
    sleep 1
    # Wait up to 10 seconds for the background fetch of someimage.png to fail.
    for i in {1..100}; do
      ERRS=$(grep -c "Serf status 111" $SERF_REFUSED_PATH || true)
      if [ $ERRS -ge 1 ]; then
        break;
      fi;
      echo -n "."
      sleep 0.1
    done;
    echo "."
    # Kill the log monitor silently.
    kill $TAIL_PID
    wait $TAIL_PID 2> /dev/null || true
    check [ $ERRS -ge 1 ]
    # Make sure we have the URL detail we expect because
    # ModPagespeedListOutstandingUrlsOnError is on in debug.conf.template.
    echo Check that ModPagespeedSerfListOutstandingUrlsOnError works
    check grep "URL http://modpagespeed.com:1023/someimage.png active for " \
        $SERF_REFUSED_PATH
  fi

  if [ "$NO_VHOST_MERGE" = "on" ]; then
    # Likewise, blocking rewrite tests are only run once.
    start_test Blocking rewrite enabled.
    # We assume that blocking_rewrite_test_dont_reuse_1.jpg will not be
    # rewritten on the first request since it takes significantly more time to
    # rewrite than the rewrite deadline and it is not already accessed by
    # another request earlier.
    BLOCKING_REWRITE_URL="$TEST_ROOT/blocking_rewrite.html?\
PageSpeedFilters=rewrite_images"
    OUTFILE=$OUTDIR/blocking_rewrite.out.html
    OLDSTATS=$OUTDIR/blocking_rewrite_stats.old
    NEWSTATS=$OUTDIR/blocking_rewrite_stats.new
    $WGET_DUMP $STATISTICS_URL > $OLDSTATS
    check $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest'\
      $BLOCKING_REWRITE_URL -O $OUTFILE
    $WGET_DUMP $STATISTICS_URL > $NEWSTATS
    check_stat $OLDSTATS $NEWSTATS image_rewrites 1
    check_stat $OLDSTATS $NEWSTATS cache_hits 0
    check_stat $OLDSTATS $NEWSTATS cache_misses 2
    # 2 cache inserts for image + 1 for HTML in IPRO flow.
    # Note: If we tune IPRO to exclude results for HTML, this will go back to 2.
    check_stat $OLDSTATS $NEWSTATS cache_inserts 3
    # TODO(sligocki): There is no stat num_rewrites_executed. Fix.
    #check_stat $OLDSTATS $NEWSTATS num_rewrites_executed 1

    start_test Blocking rewrite enabled using wrong key.
    BLOCKING_REWRITE_URL="$SECONDARY_TEST_ROOT/\
blocking_rewrite_another.html?PageSpeedFilters=rewrite_images"
    OUTFILE=$OUTDIR/blocking_rewrite.out.html
    http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: junk' \
      $BLOCKING_REWRITE_URL > $OUTFILE
    check [ $(grep -c "[.]pagespeed[.]" $OUTFILE) -lt 1 ]

    http_proxy=$SECONDARY_HOSTNAME fetch_until $BLOCKING_REWRITE_URL 'grep -c [.]pagespeed[.]' 1
  fi

  # http://code.google.com/p/modpagespeed/issues/detail?id=494 -- test
  # that fetching a css with embedded relative images from a different
  # VirtualHost, accessing the same content, and rewrite-mapped to the
  # primary domain, delivers results that are cached for a year, which
  # implies the hash matches when serving vs when rewriting from HTML.
  #
  # This rewrites the CSS, absolutifying the embedded relative image URL
  # reference based on the the main server host.
  start_test Relative images embedded in a CSS file served from a mapped domain
  DIR="mod_pagespeed_test/map_css_embedded"
  URL="http://www.example.com/$DIR/issue494.html"
  MAPPED_PREFIX="$DIR/A.styles.css.pagespeed.cf"
  http_proxy=$SECONDARY_HOSTNAME fetch_until $URL \
      "grep -c cdn.example.com/$MAPPED_PREFIX" 1
  MAPPED_CSS=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL | \
               grep -o "$MAPPED_PREFIX..*.css")

  # Now fetch the resource using a different host, which is mapped to the first
  # one.  To get the correct bytes, matching hash, and long TTL, we need to do
  # apply the domain mapping in the CSS resource fetch.
  URL="http://origin.example.com/$MAPPED_CSS"
  echo http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL
  CSS_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)
  check_from "$CSS_OUT" fgrep -q "Cache-Control: max-age=31536000"

  # Test ModPagespeedForbidFilters, which is set in pagespeed.conf for the VHost
  # forbidden.example.com, where we've forbidden remove_quotes, remove_comments,
  # collapse_whitespace, rewrite_css, and resize_images; we've also disabled
  # inline_css so the link doesn't get inlined since we test that it still has
  # all its quotes.
  FORBIDDEN_TEST_ROOT=http://forbidden.example.com/mod_pagespeed_test
  function test_forbid_filters() {
    QUERYP="$1"
    HEADER="$2"
    URL="$FORBIDDEN_TEST_ROOT/forbidden.html"
    OUTFILE="$TEMPDIR/test_forbid_filters.$$"
    echo http_proxy=$SECONDARY_HOSTNAME $WGET $HEADER $URL$QUERYP
    http_proxy=$SECONDARY_HOSTNAME $WGET -q -O $OUTFILE $HEADER $URL$QUERYP
    check egrep -q '<link rel="stylesheet' $OUTFILE
    check egrep -q '<!--'                  $OUTFILE
    check egrep -q '    <li>'              $OUTFILE
    rm -f $OUTFILE
  }
  start_test ModPagespeedForbidFilters baseline check.
  test_forbid_filters "" ""
  start_test ModPagespeedForbidFilters query parameters check.
  QUERYP="?PageSpeedFilters="
  QUERYP="${QUERYP}+remove_quotes,+remove_comments,+collapse_whitespace"
  test_forbid_filters $QUERYP ""
  start_test "ModPagespeedForbidFilters request headers check."
  HEADER="--header=PageSpeedFilters:"
  HEADER="${HEADER}+remove_quotes,+remove_comments,+collapse_whitespace"
  test_forbid_filters "" $HEADER

  start_test ModPagespeedForbidFilters disallows direct resource rewriting.
  FORBIDDEN_EXAMPLE_ROOT=http://forbidden.example.com/mod_pagespeed_example
  FORBIDDEN_STYLES_ROOT=$FORBIDDEN_EXAMPLE_ROOT/styles
  FORBIDDEN_IMAGES_ROOT=$FORBIDDEN_EXAMPLE_ROOT/images
  # .ce. is allowed
  ALLOWED="$FORBIDDEN_STYLES_ROOT/all_styles.css.pagespeed.ce.n7OstQtwiS.css"
  OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $ALLOWED 2>&1)
  check_200_http_response "$OUT"
  # .cf. is forbidden
  FORBIDDEN=$FORBIDDEN_STYLES_ROOT/A.all_styles.css.pagespeed.cf.UH8L-zY4b4.css
  OUT=$(http_proxy=$SECONDARY_HOSTNAME check_not $WGET -O /dev/null $FORBIDDEN \
    2>&1)
  check_from "$OUT" fgrep -q "404 Not Found"
  # The image will be optimized but NOT resized to the much smaller size,
  # so it will be >200k (optimized) rather than <20k (resized).
  # Use a blocking fetch to force all -allowed- rewriting to be done.
  RESIZED=$FORBIDDEN_IMAGES_ROOT/256x192xPuzzle.jpg.pagespeed.ic.8AB3ykr7Of.jpg
  HEADERS="$OUTDIR/headers.$$"
  http_proxy=$SECONDARY_HOSTNAME $WGET -q --server-response -O /dev/null \
    --header 'X-PSA-Blocking-Rewrite: psatest' $RESIZED >& $HEADERS
  LENGTH=$(grep '^ *Content-Length:' $HEADERS | sed -e 's/.*://')
  check test -n "$LENGTH"
  check test $LENGTH -gt 200000
  CCONTROL=$(grep '^ *Cache-Control:' $HEADERS | sed -e 's/.*://')
  check_from "$CCONTROL" grep -w max-age=300
  check_from "$CCONTROL" grep -w private

  start_test IPRO flow uses cache as expected.
  # TODO(sligocki): Use separate VHost instead to separate stats.
  STATS=$OUTDIR/blocking_rewrite_stats
  IPRO_ROOT=http://ipro.example.com/mod_pagespeed_test/ipro
  URL=$IPRO_ROOT/test_image_dont_reuse2.png
  IPRO_STATS_URL=http://ipro.example.com/mod_pagespeed_statistics?PageSpeed=off
  OUTFILE=$OUTDIR/ipro_output

  # Initial stats.
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.0

  # First IPRO request.
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.1

  # Resource not in cache the first time.
  check_stat $STATS.0 $STATS.1 cache_hits 0
  check_stat $STATS.0 $STATS.1 cache_misses 1
  check_stat $STATS.0 $STATS.1 ipro_served 0
  check_stat $STATS.0 $STATS.1 ipro_not_rewritable 0
  # So we run the ipro recorder flow and insert it into the cache.
  check_stat $STATS.0 $STATS.1 ipro_not_in_cache 1
  check_stat $STATS.0 $STATS.1 ipro_recorder_resources 1
  check_stat $STATS.0 $STATS.1 ipro_recorder_inserted_into_cache 1
  # Image doesn't get rewritten the first time.
  # TODO(sligocki): This should change to 1 when we get image rewrites started
  # in the Apache output filter flow.
  check_stat $STATS.0 $STATS.1 image_rewrites 0

  # Second IPRO request.
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
  # Wait for image rewrite to finish.
  http_proxy=$SECONDARY_HOSTNAME fetch_until "$IPRO_STATS_URL" \
    'get_stat image_ongoing_rewrites' 0
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.2

  # Resource is found in cache the second time.
  check_stat $STATS.1 $STATS.2 cache_hits 1
  check_stat $STATS.1 $STATS.2 ipro_served 1
  check_stat $STATS.1 $STATS.2 ipro_not_rewritable 0
  # So we don't run the ipro recorder flow.
  check_stat $STATS.1 $STATS.2 ipro_not_in_cache 0
  check_stat $STATS.1 $STATS.2 ipro_recorder_resources 0
  # Image gets rewritten on the second pass through this filter.
  # TODO(sligocki): This should change to 0 when we get image rewrites started
  # in the Apache output filter flow.
  check_stat $STATS.1 $STATS.2 image_rewrites 1

  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O $OUTFILE
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.3

  check_stat $STATS.2 $STATS.3 cache_hits 1
  check_stat $STATS.2 $STATS.3 ipro_served 1
  check_stat $STATS.2 $STATS.3 ipro_recorder_resources 0
  check_stat $STATS.2 $STATS.3 image_rewrites 0

  # Check that the IPRO served file didn't discard any Apache err_response_out
  # headers.
  check_from "$(extract_headers $OUTFILE)" grep -q "X-TestHeader: hello"

  start_test "IPRO flow doesn't copy uncacheable resources multiple times."
  URL=$IPRO_ROOT/nocache/test_image_dont_reuse.png

  # Initial stats.
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.0

  # First IPRO request.
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.1

  # Resource not in cache the first time.
  check_stat $STATS.0 $STATS.1 cache_hits 0
  check_stat $STATS.0 $STATS.1 cache_misses 1
  check_stat $STATS.0 $STATS.1 ipro_served 0
  check_stat $STATS.0 $STATS.1 ipro_not_rewritable 0
  # So we run the ipro recorder flow, but the resource is not cacheable.
  check_stat $STATS.0 $STATS.1 ipro_not_in_cache 1
  check_stat $STATS.0 $STATS.1 ipro_recorder_resources 1
  check_stat $STATS.0 $STATS.1 ipro_recorder_not_cacheable 1
  # Uncacheable, so no rewrites.
  check_stat $STATS.0 $STATS.1 image_rewrites 0
  check_stat $STATS.0 $STATS.1 image_ongoing_rewrites 0

  # Second IPRO request.
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.2

  check_stat $STATS.1 $STATS.2 cache_hits 0
  # Note: This should load a RecentFetchFailed record from cache, but that
  # is reported as a cache miss.
  check_stat $STATS.1 $STATS.2 cache_misses 1
  check_stat $STATS.1 $STATS.2 ipro_served 0
  check_stat $STATS.1 $STATS.2 ipro_not_rewritable 1
  # Important: We do not record this resource the second and third time
  # because we remember that it was not cacheable.
  check_stat $STATS.1 $STATS.2 ipro_not_in_cache 0
  check_stat $STATS.1 $STATS.2 ipro_recorder_resources 0
  check_stat $STATS.1 $STATS.2 image_rewrites 0
  check_stat $STATS.1 $STATS.2 image_ongoing_rewrites 0

  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.3

  # Same as second fetch.
  check_stat $STATS.2 $STATS.3 cache_hits 0
  check_stat $STATS.2 $STATS.3 cache_misses 1
  check_stat $STATS.2 $STATS.3 ipro_not_rewritable 1
  check_stat $STATS.2 $STATS.3 ipro_recorder_resources 0
  check_stat $STATS.2 $STATS.3 image_rewrites 0
  check_stat $STATS.2 $STATS.3 image_ongoing_rewrites 0

  # Check that IPRO served resources that don't specify a cache control
  # value are given the TTL specified by the ImplicitCacheTtlMs directive.
  start_test "IPRO respects ImplicitCacheTtlMs."
  HTML_URL=$IPRO_ROOT/no-cache-control-header/ipro.html
  RESOURCE_URL=$IPRO_ROOT/no-cache-control-header/test_image_dont_reuse.png
  RESOURCE_HEADERS=$OUTDIR/resource_headers
  OUTFILE=$OUTDIR/ipro_resource_output

  # Fetch the HTML to initiate rewriting and caching of the image.
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $HTML_URL -O $OUTFILE

  # First IPRO resource request after a short wait: it will never be optimized
  # because our non-load-from-file flow doesn't support that, but it will have
  # the full TTL.
  sleep 2
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $RESOURCE_URL -O $OUTFILE
  check_file_size "$OUTFILE" -gt 15000 # not optimized
  RESOURCE_MAX_AGE=$( \
    extract_headers $OUTFILE | \
    grep 'Cache-Control:' | tr -d '\r' | \
    sed -e 's/^ *Cache-Control: *//' | sed -e 's/^.*max-age=\([0-9]*\).*$/\1/')
  check test -n "$RESOURCE_MAX_AGE"
  check test $RESOURCE_MAX_AGE -eq 333

  # Second IPRO resource request after a short wait: it will still be optimized
  # and the TTL will be reduced.
  sleep 2
  http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $RESOURCE_URL -O $OUTFILE
  check_file_size "$OUTFILE" -lt 15000 # optimized
  RESOURCE_MAX_AGE=$( \
    extract_headers $OUTFILE | \
    grep 'Cache-Control:' | tr -d '\r' | \
    sed -e 's/^ *Cache-Control: *//' | sed -e 's/^.*max-age=\([0-9]*\).*$/\1/')
  check test -n "$RESOURCE_MAX_AGE"

  check test $RESOURCE_MAX_AGE -lt 333
  check test $RESOURCE_MAX_AGE -gt 300

  # Run all the tests that want to have cache-flush as part of the flow.
  run_post_cache_flush
fi

start_test Send custom fetch headers on resource re-fetches.
PLAIN_HEADER="header=value"
X_OTHER_HEADER="x-other=False"

URL="$PRIMARY_SERVER/mod_pagespeed_log_request_headers.js.pagespeed.jm.0.js"
WGET_OUT=$($WGET_DUMP $URL)
check_from "$WGET_OUT" grep "$PLAIN_HEADER"
check_from "$WGET_OUT" grep "$X_OTHER_HEADER"

start_test Send custom fetch headers on resource subfetches.
URL=$TEST_ROOT/custom_fetch_headers.html?PageSpeedFilters=inline_javascript
fetch_until -save $URL 'grep -c header=value' 1
check_from "$(cat $FETCH_FILE)" grep "$X_OTHER_HEADER"

# Check that statistics logging was functional during these tests
# if it was enabled.
if [ $statistics_logging_enabled = "1" ]; then
  start_test Statistics logging works.
  check ls $MOD_PAGESPEED_STATS_LOG
  check [ $(grep "timestamp: " $MOD_PAGESPEED_STATS_LOG | wc -l) -ge 1 ]
  # An array of all the timestamps that were logged.
  TIMESTAMPS=($(sed -n '/timestamp: /s/[^0-9]*//gp' $MOD_PAGESPEED_STATS_LOG))
  check [ ${#TIMESTAMPS[@]} -ge 1 ]
  for T in ${TIMESTAMPS[@]}; do
    check [ $T -ge $START_TIME ]
  done
  # Check a few arbitrary statistics to make sure logging is taking place.
  check [ $(grep "num_flushes: " $MOD_PAGESPEED_STATS_LOG | wc -l) -ge 1 ]
  # We are not outputing histograms.
  check [ $(grep "histogram#" $MOD_PAGESPEED_STATS_LOG | wc -l) -eq 0 ]
  check [ $(grep "image_ongoing_rewrites: " $MOD_PAGESPEED_STATS_LOG | wc -l) \
    -ge 1 ]

  start_test Statistics logging JSON handler works.
  JSON=$OUTDIR/console_json.json
  STATS_JSON_URL="$CONSOLE_URL?json&granularity=0&var_titles=num_\
flushes,image_ongoing_rewrites"
  echo "$WGET_DUMP $STATS_JSON_URL > $JSON"
  $WGET_DUMP $STATS_JSON_URL > $JSON
  # Each variable we ask for should show up once.
  check [ $(grep "\"num_flushes\": " $JSON | wc -l) -eq 1 ]
  check [ $(grep "\"image_ongoing_rewrites\": " $JSON | wc -l) -eq 1 ]
  check [ $(grep "\"timestamps\": " $JSON | wc -l) -eq 1 ]
  # An array of all the timestamps that the JSON handler returned.
  JSON_TIMESTAMPS=($(sed -rn 's/^\{"timestamps": \[(([0-9]+, )*[0-9]*)\].*}$/\1/;/^[0-9]+/s/,//gp' $JSON))
  # Check that we see the same timestamps that are in TIMESTAMPS.
  # We might have generated extra timestamps in the time between TIMESTAMPS
  # and JSON_TIMESTAMPS, so only loop through TIMESTAMPS.
  check [ ${#JSON_TIMESTAMPS[@]} -ge ${#TIMESTAMPS[@]} ]
  t=0
  while [ $t -lt ${#TIMESTAMPS[@]} ]; do
    check [ ${TIMESTAMPS[$t]} -eq ${JSON_TIMESTAMPS[$t]} ]
    t=$(($t+1))
  done


  start_test Statistics console is available.
  CONSOLE_URL=$PRIMARY_SERVER/pagespeed_console
  CONSOLE_HTML=$OUTDIR/console.html
  $WGET_DUMP $CONSOLE_URL > $CONSOLE_HTML
  check grep -q "console" $CONSOLE_HTML
fi

start_test ModPagespeedIf parsing
# $STATISTICS_URL ends in ?ModPagespeed=off, so we need & for now.
# If we remove the query from $STATISTICS_URL, s/&/?/.
readonly CONFIG_URL="$STATISTICS_URL&config"
readonly SPDY_CONFIG_URL="$STATISTICS_URL&spdy_config"

echo $WGET_DUMP $CONFIG_URL
CONFIG=$($WGET_DUMP $CONFIG_URL)
spdy_config_title="<title>PageSpeed SPDY Configuration</title>"
config_title="<title>PageSpeed Configuration</title>"
check_from "$CONFIG" fgrep -q "$config_title"
check_not_from "$CONFIG" fgrep -q "$spdy_config_title"
# Regular config should have a shard line:
check_from "$CONFIG" egrep -q "http://nonspdy.example.com/ Auth Shards:{http:"
check_from "$CONFIG" egrep -q "//s1.example.com/, http://s2.example.com/}"
# And "combine CSS" on.
check_from "$CONFIG" egrep -q "Combine Css"

echo $WGET_DUMP $SPDY_CONFIG_URL
SPDY_CONFIG=$($WGET_DUMP $SPDY_CONFIG_URL)
check_not_from "$SPDY_CONFIG" fgrep -q "$config_title"
check_from "$SPDY_CONFIG" fgrep -q "$spdy_config_title"

# SPDY config should have neither shards, nor combine CSS.
check_not_from "$SPDY_CONFIG" egrep -q "http://nonspdy.example.com"
check_not_from "$SPDY_CONFIG" egrep -q "s1.example.com"
check_not_from "$SPDY_CONFIG" egrep -q "s2.example.com"
check_not_from "$SPDY_CONFIG" egrep -q "Combine Css"

# Test ModPagespeedForbidAllDisabledFilters, which is set in pagespeed.conf
# for /mod_pagespeed_test/forbid_all_disabled/disabled/ where we've disabled
# remove_quotes, remove_comments, and collapse_whitespace (which are enabled
# by its parent directory's .htaccess file). We fetch 3 x 3 times, the first 3
# being for forbid_all_disabled, fordid_all_disabled/disabled, and
# forbid_all_disabled/disabled/cheat, to ensure that a subdirectory cannot
# circumvent the forbidden flag; and the second 3 being a normal fetch, a
# fetch using a query parameter to try to enable the forbidden filters, and a
# fetch using a request header to try to enable the forbidden filters.
function test_forbid_all_disabled() {
  QUERYP="$1"
  HEADER="$2"
  if [ -n "$QUERYP" ]; then
    INLINE_CSS=",-inline_css"
  else
    INLINE_CSS="?PageSpeedFilters=-inline_css"
  fi
  WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
  URL1=$TEST_ROOT/forbid_all_disabled/forbidden.html
  URL2=$TEST_ROOT/forbid_all_disabled/disabled/forbidden.html
  URL3=$TEST_ROOT/forbid_all_disabled/disabled/cheat/forbidden.html
  OUTFILE="$TEMPDIR/test_forbid_all_disabled.$$"
  # Fetch testing that forbidden filters stay disabled.
  echo $WGET $HEADER $URL1$QUERYP$INLINE_CSS
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL1$QUERYP$INLINE_CSS
  check     egrep -q '<link rel=stylesheet'  $OUTFILE
  check_not egrep -q '<!--'                  $OUTFILE
  check     egrep -q '^<li>'                 $OUTFILE
  echo $WGET $HEADER $URL2$QUERYP$INLINE_CSS
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL2$QUERYP$INLINE_CSS
  check     egrep -q '<link rel="stylesheet' $OUTFILE
  check     egrep -q '<!--'                  $OUTFILE
  check     egrep -q '    <li>'              $OUTFILE
  echo $WGET $HEADER $URL3$QUERYP$INLINE_CSS
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL3$QUERYP$INLINE_CSS
  check     egrep -q '<link rel="stylesheet' $OUTFILE
  check     egrep -q '<!--'                  $OUTFILE
  check     egrep -q '    <li>'              $OUTFILE
  # Fetch testing that enabling inline_css in disabled/.htaccess works.
  echo $WGET $HEADER $URL1
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL1
  check_not egrep -q '<style>.yellow'        $OUTFILE
  echo $WGET $HEADER $URL2
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL2
  check     egrep -q '<style>.yellow'        $OUTFILE
  echo $WGET $HEADER $URL3
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL3
  check     egrep -q '<style>.yellow'        $OUTFILE
  rm -f $OUTFILE
  WGET_ARGS=""
}
start_test ModPagespeedForbidAllDisabledFilters baseline check.
test_forbid_all_disabled "" ""
start_test ModPagespeedForbidAllDisabledFilters query parameters check.
QUERYP="?PageSpeedFilters="
QUERYP="${QUERYP}+remove_quotes,+remove_comments,+collapse_whitespace"
test_forbid_all_disabled $QUERYP ""
start_test ModPagespeedForbidAllDisabledFilters request headers check.
HEADER="--header=PageSpeedFilters:"
HEADER="${HEADER}+remove_quotes,+remove_comments,+collapse_whitespace"
test_forbid_all_disabled "" $HEADER

# Now check stuff on secondary host. The results will depend on whether
# ModPagespeedInheritVHostConfig is on or off. We run this only for some tests,
# since we don't always have the secondary port number available here.
if [ "$SECONDARY_HOSTNAME" != "" ]; then
  SECONDARY_STATS_URL=http://$SECONDARY_HOSTNAME/mod_pagespeed_statistics
  SECONDARY_CONFIG_URL=$SECONDARY_STATS_URL?config
  SECONDARY_SPDY_CONFIG_URL=$SECONDARY_STATS_URL?spdy_config

  if [ "$NO_VHOST_MERGE" = "on" ]; then
    start_test Config with VHost inheritance off
    echo $WGET_DUMP $SECONDARY_CONFIG_URL
    SECONDARY_CONFIG=$($WGET_DUMP $SECONDARY_CONFIG_URL)
    check_from "$SECONDARY_CONFIG" fgrep -q "$config_title"
    check_not_from "$SECONDARY_CONFIG" fgrep -q "$spdy_config_title"
    # No inherit, no sharding.
    check_not_from "$SECONDARY_CONFIG" egrep -q "http://nonspdy.example.com/"

    # Should not inherit the blocking rewrite key.
    check_not_from "$SECONDARY_CONFIG" egrep -q "blrw"

    echo $WGET_DUMP $SECONDARY_SPDY_CONFIG_URL
    SECONDARY_SPDY_CONFIG=$($WGET_DUMP $SECONDARY_SPDY_CONFIG_URL)
    check_not_from "$SECONDARY_SPDY_CONFIG" fgrep -q "$config_title"
    check_from "$SECONDARY_SPDY_CONFIG" \
      egrep -q "SPDY-specific configuration missing"
  else
    start_test Config with VHost inheritance on
    echo $WGET_DUMP $SECONDARY_CONFIG_URL
    SECONDARY_CONFIG=$($WGET_DUMP $SECONDARY_CONFIG_URL)
    check_from "$SECONDARY_CONFIG" fgrep -q "$config_title"
    check_not_from "$SECONDARY_CONFIG" fgrep -q "$spdy_config_title"
    # Sharding is applied in this host, thanks to global inherit flag.
    check_from "$SECONDARY_CONFIG" egrep -q "http://nonspdy.example.com/"

    # We should also inherit the blocking rewrite key.
    check_from "$SECONDARY_CONFIG" egrep -q "\(blrw\)[[:space:]]+psatest"

    echo $WGET_DUMP $SECONDARY_SPDY_CONFIG_URL
    SECONDARY_SPDY_CONFIG=$($WGET_DUMP $SECONDARY_SPDY_CONFIG_URL)
    check_not_from "$SECONDARY_SPDY_CONFIG" fgrep -q "$config_title"
    check_from "$SECONDARY_SPDY_CONFIG" fgrep -q "$spdy_config_title"
    # Disabling of combine CSS should get inherited.
    check_not_from "$SECONDARY_SPDY_CONFIG" egrep -q "Combine Css"
  fi
fi

if [ "$SECONDARY_HOSTNAME" != "" ]; then
  # Test that we work fine with an explicitly configured SHM metadata cache.
  start_test Using SHM metadata cache
  HOST_NAME="http://shmcache.example.com"
  URL="$HOST_NAME/mod_pagespeed_example/rewrite_images.html"
  http_proxy=$SECONDARY_HOSTNAME fetch_until $URL 'grep -c .pagespeed.ic' 2

  # Test max_cacheable_response_content_length.  There are two Javascript files
  # in the html file.  The smaller Javascript file should be rewritten while
  # the larger one shouldn't.
  start_test Maximum length of cacheable response content.
  HOST_NAME="http://max-cacheable-content-length.example.com"
  DIR_NAME="mod_pagespeed_test/max_cacheable_content_length"
  HTML_NAME="test_max_cacheable_content_length.html"
  URL=$HOST_NAME/$DIR_NAME/$HTML_NAME
  RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header \
      'X-PSA-Blocking-Rewrite: psatest' $URL)
  check_from     "$RESPONSE_OUT" fgrep -qi small.js.pagespeed.
  check_not_from "$RESPONSE_OUT" fgrep -qi large.js.pagespeed.

  # This test checks that the ModPagespeedXHeaderValue directive works.
  start_test ModPagespeedXHeaderValue directive

  RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      http://xheader.example.com/mod_pagespeed_example)
  check_from "$RESPONSE_OUT" fgrep -q "X-Mod-Pagespeed: UNSPECIFIED VERSION"

  # This test checks that the ModPagespeedDomainRewriteHyperlinks directive
  # can turn off.  See mod_pagespeed_test/rewrite_domains.html: it has
  # one <img> URL, one <form> URL, and one <a> url, all referencing
  # src.example.com.  Only the <img> url should be rewritten.
  start_test ModPagespeedRewriteHyperlinks off directive
  HOST_NAME="http://domain-hyperlinks-off.example.com"
  RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      $HOST_NAME/mod_pagespeed_test/rewrite_domains.html)
  MATCHES=$(echo "$RESPONSE_OUT" | fgrep -c http://dst.example.com)
  check [ $MATCHES -eq 1 ]

  # This test checks that the ModPagespeedDomainRewriteHyperlinks directive
  # can turn on.  See mod_pagespeed_test/rewrite_domains.html: it has
  # one <img> URL, one <form> URL, and one <a> url, all referencing
  # src.example.com.  They should all be rewritten to dst.example.com.
  start_test ModPagespeedRewriteHyperlinks on directive
  HOST_NAME="http://domain-hyperlinks-on.example.com"
  RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      $HOST_NAME/mod_pagespeed_test/rewrite_domains.html)
  MATCHES=$(echo "$RESPONSE_OUT" | fgrep -c http://dst.example.com)
  check [ $MATCHES -eq 4 ]

  # Test to make sure dynamically defined url-valued attributes are rewritten by
  # rewrite_domains.  See mod_pagespeed_test/rewrite_domains.html: in addition
  # to having one <img> URL, one <form> URL, and one <a> url it also has one
  # <span src=...> URL, one <hr imgsrc=...> URL, one <hr src=...> URL, and one
  # <blockquote cite=...> URL, all referencing src.example.com.  The first three
  # should be rewritten because of hardcoded rules, the span.src and hr.imgsrc
  # should be rewritten because of UrlValuedAttribute directives, the hr.src
  # should be left unmodified, and the blockquote.src should be rewritten as an
  # image because of a UrlValuedAttribute override.  The rewritten ones should
  # all be rewritten to dst.example.com.
  HOST_NAME="http://url-attribute.example.com"
  TEST="$HOST_NAME/mod_pagespeed_test"
  REWRITE_DOMAINS="$TEST/rewrite_domains.html"
  UVA_EXTEND_CACHE="$TEST/url_valued_attribute_extend_cache.html"
  UVA_EXTEND_CACHE+="?PageSpeedFilters=core,+left_trim_urls"

  start_test Rewrite domains in dynamically defined url-valued attributes.

  RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $REWRITE_DOMAINS)
  MATCHES=$(echo "$RESPONSE_OUT" | fgrep -c http://dst.example.com)
  check [ $MATCHES -eq 6 ]
  MATCHES=$(echo "$RESPONSE_OUT" | \
      fgrep -c '<hr src=http://src.example.com/hr-image>')
  check [ $MATCHES -eq 1 ]

  start_test Additional url-valued attributes are fully respected.

  function count_exact_matches() {
    # Needed because "fgrep -c" counts lines with matches, not pure matches.
    fgrep -o "$1" | wc -l
  }

  # There are nine resources that should be optimized.
  http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $UVA_EXTEND_CACHE 'count_exact_matches .pagespeed.' 10

  # Make sure <custom d=...> isn't modified at all, but that everything else is
  # recognized as a url and rewritten from ../foo to /foo.  This means that only
  # one reference to ../mod_pagespeed should remain, <custom d=...>.
  http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $UVA_EXTEND_CACHE 'grep -c d=.[.][.]/mod_pa' 1
  http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $UVA_EXTEND_CACHE 'fgrep -c ../mod_pa' 1

  # There are ten images that should be optimized, so grep including .ic.
  http_proxy=$SECONDARY_HOSTNAME \
      fetch_until $UVA_EXTEND_CACHE 'count_exact_matches .pagespeed.ic' 10

  # This test checks that the ModPagespeedClientDomainRewrite directive
  # can turn on.
  start_test ModPagespeedClientDomainRewrite on directive
  HOST_NAME="http://client-domain-rewrite.example.com"
  RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      $HOST_NAME/mod_pagespeed_test/rewrite_domains.html)
  MATCHES=$(echo "$RESPONSE_OUT" | grep -c pagespeed\.clientDomainRewriterInit)
  check [ $MATCHES -eq 1 ]

  # Verify rendered image dimensions test.
  start_test resize_rendered_image_dimensions with critical images beacon
  HOST_NAME="http://renderedimagebeacon.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/image_rewriting/image_resize_using_rendered_dimensions.html"
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save -recursive $URL 'fgrep -c "pagespeed_url_hash"' 2 \
    '--header=X-PSA-Blocking-Rewrite:psatest'
  check [ $(grep -c "^pagespeed\.CriticalImages\.Run" \
    $WGET_DIR/image_resize_using_rendered_dimensions.html) = 1 ];
  OPTIONS_HASH=$(\
    awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-3)}' \
    $WGET_DIR/image_resize_using_rendered_dimensions.html)
  NONCE=$(awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-1)}' \
          $WGET_DIR/image_resize_using_rendered_dimensions.html)

  # Send a beacon response using POST indicating that OptPuzzle.jpg is
  # critical and has rendered dimensions.
  BEACON_URL="$HOST_NAME/mod_pagespeed_beacon"
  BEACON_URL+="?url=http%3A%2F%2Frenderedimagebeacon.example.com%2Fmod_pagespeed_test%2F"
  BEACON_URL+="image_rewriting%2Fimage_resize_using_rendered_dimensions.html"
  BEACON_DATA="oh=$OPTIONS_HASH&n=$NONCE&ci=1344500982&rd=%7B%221344500982%22%3A%7B%22rw%22%3A150%2C%22rh%22%3A100%2C%22ow%22%3A256%2C%22oh%22%3A192%7D%7D"
  OUT=$(env http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP --post-data "$BEACON_DATA" "$BEACON_URL")
  check_from "$OUT" egrep -q "HTTP/1[.]. 204"
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save -recursive $URL \
    'fgrep -c 150x100xOptPuzzle.jpg.pagespeed.ic.' 1

  # Verify that downstream caches and rebeaconing interact correctly for images.
  start_test lazyload_images,rewrite_images with critical images beacon
  HOST_NAME="http://downstreamcacherebeacon.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/downstream_caching.html"
  URL+="?ModPagespeedFilters=lazyload_images"
  # 1. Even with blocking rewrite, we don't get an instrumented page when the
  # PS-ShouldBeacon header is missing.
  OUT1=$(http_proxy=$SECONDARY_HOSTNAME \
            $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL)
  check_not_from "$OUT1" egrep -q 'pagespeed\.CriticalImages\.Run'
  check_from "$OUT1" grep -q "Cache-Control: private, max-age=3000"
  # 2. We get an instrumented page if the correct key is present.
  OUT2=$(http_proxy=$SECONDARY_HOSTNAME \
            $WGET_DUMP --header="PS-ShouldBeacon: random_rebeaconing_key" $URL)
  check_from "$OUT2" egrep -q "pagespeed\.CriticalImages\.Run"
  check_from "$OUT2" grep -q "Cache-Control: max-age=0, no-cache"
  # 3. We do not get an instrumented page if the wrong key is present.
  OUT3=$(http_proxy=$SECONDARY_HOSTNAME \
            $WGET_DUMP --header="PS-ShouldBeacon: wrong_rebeaconing_key" $URL)
  check_not_from "$OUT3" egrep -q "pagespeed\.CriticalImages\.Run"
  check_from "$OUT3" grep -q "Cache-Control: private, max-age=3000"

  # Verify that downstream caches and rebeaconing interact correctly for css.
  test_filter prioritize_critical_css
  HOST_NAME="http://downstreamcacherebeacon.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/downstream_caching.html"
  URL+="?ModPagespeedFilters=prioritize_critical_css"
  # 1. Even with blocking rewrite, we don't get an instrumented page when the
  # PS-ShouldBeacon header is missing.
  OUT1=$(http_proxy=$SECONDARY_HOSTNAME \
            $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL)
  check_not_from "$OUT1" egrep -q 'pagespeed\.criticalCssBeaconInit'
  check_from "$OUT1" grep -q "Cache-Control: private, max-age=3000"

  # 2. We get an instrumented page if the correct key is present.
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save $URL 'grep -c criticalCssBeaconInit' 2 \
    "--header=PS-ShouldBeacon:random_rebeaconing_key --save-headers"
  check grep -q "Cache-Control: max-age=0, no-cache" $FETCH_UNTIL_OUTFILE

  # 3. We do not get an instrumented page if the wrong key is present.
  OUT3=$(http_proxy=$SECONDARY_HOSTNAME \
            $WGET_DUMP \
            --header 'PS-ShouldBeacon: wrong_rebeaconing_key' \
            --header 'X-PSA-Blocking-Rewrite: psatest' \
            $URL)
  check_not_from "$OUT3" egrep -q "pagespeed\.criticalCssBeaconInit"
  check_from "$OUT3" grep -q "Cache-Control: private, max-age=3000"

  # Verify that we can send a critical image beacon and that lazyload_images
  # does not try to lazyload the critical images.
  start_test lazyload_images,rewrite_images with critical images beacon
  HOST_NAME="http://imagebeacon.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/image_rewriting/rewrite_images.html"
  # There are 3 images on rewrite_images.html.  Since beaconing is on but we've
  # sent no beacon data, none should be lazy loaded.  Run until we see beaconing
  # on the page (should happen on first visit).
  http_proxy=$SECONDARY_HOSTNAME\
    fetch_until -save $URL \
    'fgrep -c "pagespeed.CriticalImages.Run"' 1
  check [ $(grep -c "pagespeed_lazy_src=" $FETCH_FILE) = 0 ];
  # We need the options hash and nonce to send a critical image beacon, so
  # extract it from injected beacon JS.
  OPTIONS_HASH=$(
    awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-3)}' $FETCH_FILE)
  NONCE=$(
    awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-1)}' $FETCH_FILE)
  # Send a beacon response using POST indicating that Puzzle.jpg is a critical
  # image.
  BEACON_URL="$HOST_NAME/mod_pagespeed_beacon"
  BEACON_URL+="?url=http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
  BEACON_URL+="image_rewriting%2Frewrite_images.html"
  BEACON_DATA="oh=$OPTIONS_HASH&n=$NONCE&ci=2932493096"
  OUT=$(env http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP --post-data "$BEACON_DATA" "$BEACON_URL")
  check_from "$OUT" egrep -q "HTTP/1[.]. 204"
  # Now 2 of the images should be lazyloaded, Puzzle.jpg should not be.
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save -recursive $URL 'fgrep -c pagespeed_lazy_src=' 2

  # Now test sending a beacon with a GET request, instead of POST. Indicate that
  # Puzzle.jpg and Cuppa.png are the critical images. In practice we expect only
  # POSTs to be used by the critical image beacon, but both code paths are
  # supported.  We add query params to URL to ensure that we get an instrumented
  # page without blocking.
  URL="$URL?id=4"
  http_proxy=$SECONDARY_HOSTNAME\
    fetch_until -save $URL \
    'fgrep -c "pagespeed.CriticalImages.Run"' 1
  check [ $(grep -c "pagespeed_lazy_src=" $FETCH_FILE) = 0 ];
  OPTIONS_HASH=$(
    awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-3)}' $FETCH_FILE)
  NONCE=$(
    awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-1)}' $FETCH_FILE)
  BEACON_URL="$HOST_NAME/mod_pagespeed_beacon"
  BEACON_URL+="?url=http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
  BEACON_URL+="image_rewriting%2Frewrite_images.html%3Fid%3D4"
  BEACON_DATA="oh=$OPTIONS_HASH&n=$NONCE&ci=2932493096"
  # Add the hash for Cuppa.png to BEACON_DATA, which will be used as the query
  # params for the GET.
  BEACON_DATA+=",2644480723"
  OUT=$(env http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP "$BEACON_URL&$BEACON_DATA")
  check_from "$OUT" egrep -q "HTTP/1[.]. 204"
  # Now only BikeCrashIcn.png should be lazyloaded.
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save -recursive $URL 'fgrep -c pagespeed_lazy_src=' 1

  test_filter prioritize_critical_css

  start_test no critical selectors chosen from unauthorized resources
  URL="$TEST_ROOT/unauthorized/prioritize_critical_css.html"
  URL+="?PageSpeedFilters=prioritize_critical_css,debug"
  fetch_until -save $URL 'fgrep -c pagespeed.criticalCssBeaconInit' 3
  # Except for the occurrence in html, the gsc-completion-selected string
  # should not occur anywhere else, i.e. in the selector list.
  check [ $(fgrep -c "gsc-completion-selected" $FETCH_FILE) -eq 1 ]
  # From the css file containing an unauthorized @import line,
  # a) no selectors from the unauthorized @ import (e.g .maia-display) should
  #    appear in the selector list.
  check_not fgrep -q "maia-display" $FETCH_FILE
  # b) no selectors from the authorized @ import (e.g .interesting_color) should
  #    appear in the selector list because it won't be flattened.
  check_not fgrep -q "interesting_color" $FETCH_FILE
  # c) selectors that don't depend on flattening should appear in the selector
  #    list.
  check [ $(fgrep -c "non_flattened_selector" $FETCH_FILE) -eq 1 ]
  EXPECTED_IMPORT_FAILURE_LINE="<!--Flattening failed: Cannot import \
http://www.google.com/css/maia.css as it is on an unauthorized domain-->"
  check [ $(grep -o "$EXPECTED_IMPORT_FAILURE_LINE" $FETCH_FILE | wc -l) -eq 1 ]
  EXPECTED_COMMENT_LINE="<!--The preceding resource was not rewritten \
because its domain (www.google.com) is not authorized-->"
  check [ $(grep -o "$EXPECTED_COMMENT_LINE" $FETCH_FILE | wc -l) -eq 1 ]

  start_test inline_unauthorized_resources allows unauthorized css selectors
  HOST_NAME="http://unauthorizedresources.example.com"
  URL="$HOST_NAME/mod_pagespeed_test/unauthorized/prioritize_critical_css.html"
  URL+="?PageSpeedFilters=prioritize_critical_css,debug"
  # gsc-completion-selected string should occur once in the html and once in the
  # selector list.
  http_proxy=$SECONDARY_HOSTNAME \
     fetch_until -save $URL 'fgrep -c gsc-completion-selected' 2
  # Verify that this page had beaconing javascript on it.
  check [ $(fgrep -c "pagespeed.criticalCssBeaconInit" $FETCH_FILE) -eq 3 ]
  # From the css file containing an unauthorized @import line,
  # a) no selectors from the unauthorized @ import (e.g .maia-display) should
  #    appear in the selector list.
  check_not fgrep -q "maia-display" $FETCH_FILE
  # b) no selectors from the authorized @ import (e.g .red) should
  #    appear in the selector list because it won't be flattened.
  check_not fgrep -q "interesting_color" $FETCH_FILE
  # c) selectors that don't depend on flattening should appear in the selector
  #    list.
  check [ $(fgrep -c "non_flattened_selector" $FETCH_FILE) -eq 1 ]
  # TODO(jmarantz): I have seen this test flake, and I suspect that it's
  # possible to achieve 2 occurrences of gsc-completion-selected before the
  # flattening is attempted.
  check grep -q "$EXPECTED_IMPORT_FAILURE_LINE" $FETCH_FILE

  # Test critical CSS beacon injection, beacon return, and computation.  This
  # requires UseBeaconResultsInFilters() to be true in rewrite_driver_factory.
  # NOTE: must occur after cache flush, which is why it's in this embedded
  # block.  The flush removes pre-existing beacon results from the pcache.
  test_filter prioritize_critical_css
  fetch_until -save $URL 'fgrep -c pagespeed.criticalCssBeaconInit' 1
  check [ $(fgrep -o ".very_large_class_name_" $FETCH_FILE | wc -l) -eq 36 ]
  CALL_PAT=".*criticalCssBeaconInit("
  SKIP_ARG="[^,]*,"
  CAPTURE_ARG="'\([^']*\)'.*"
  BEACON_PATH=$(sed -n "s/${CALL_PAT}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
  ESCAPED_URL=$( \
    sed -n "s/${CALL_PAT}${SKIP_ARG}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
  OPTIONS_HASH=$( \
    sed -n "s/${CALL_PAT}${SKIP_ARG}${SKIP_ARG}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
  NONCE=$( \
    sed -n "s/${CALL_PAT}${SKIP_ARG}${SKIP_ARG}${SKIP_ARG}${CAPTURE_ARG}/\1/p" \
    $FETCH_FILE)
  BEACON_URL="http://${HOSTNAME}${BEACON_PATH}?url=${ESCAPED_URL}"
  BEACON_DATA="oh=${OPTIONS_HASH}&n=${NONCE}&cs=.big,.blue,.bold,.foo"
  run_wget_with_args --post-data "$BEACON_DATA" "$BEACON_URL"
  # Now make sure we see the correct critical css rules.
  fetch_until $URL \
    'grep -c <style>[.]blue{[^}]*}</style>' 1
  fetch_until $URL \
    'grep -c <style>[.]big{[^}]*}</style>' 1
  fetch_until $URL \
    'grep -c <style>[.]blue{[^}]*}[.]bold{[^}]*}</style>' 1
  fetch_until -save $URL \
    'grep -c <style>[.]foo{[^}]*}</style>' 1
  # The last one should also have the other 3, too.
  check [ `grep -c '<style>[.]blue{[^}]*}</style>' $FETCH_UNTIL_OUTFILE` = 1 ]
  check [ `grep -c '<style>[.]big{[^}]*}</style>' $FETCH_UNTIL_OUTFILE` = 1 ]
  check [ `grep -c '<style>[.]blue{[^}]*}[.]bold{[^}]*}</style>' \
    $FETCH_UNTIL_OUTFILE` = 1 ]

  if [ -n "$APACHE_LOG" ]; then
    start_test Encoded absolute urls are not respected
    HOST_NAME="http://absolute-urls.example.com"

    # Monitor the Apache log; tail -F will catch log rotations.
    ABSOLUTE_URLS_LOG_PATH=/tmp/instaweb_apache_absolute_urls_log.$$
    echo APACHE_LOG = $APACHE_LOG
    tail --sleep-interval=0.1 -F $APACHE_LOG > $ABSOLUTE_URLS_LOG_PATH &
    TAIL_PID=$!

    # should fail; the example.com isn't us.
    http_proxy=$SECONDARY_HOSTNAME check_not $WGET_DUMP \
        "$HOST_NAME/,hexample.com.pagespeed.jm.0.js"

    REJECTED="Rejected absolute url reference"

    # Wait up to 10 seconds for failure.
    for i in {1..100}; do
      REJECTIONS=$(fgrep -c "$REJECTED" $ABSOLUTE_URLS_LOG_PATH || true)
      if [ $REJECTIONS -ge 1 ]; then
        break;
      fi;
      /bin/echo -n "."
      sleep 0.1
    done;
    /bin/echo "."

    # Kill the log monitor silently.
    kill $TAIL_PID
    wait $TAIL_PID 2> /dev/null || true

    check [ $REJECTIONS -eq 1 ]
  fi

  # TODO(sligocki): Following test only works with
  # filter_spec_method=query_params. Fix to work with any method and get rid
  # of this manual set.
  filter_spec_method="query_params"
  # Test for MaxCombinedCssBytes. The html used in the test, 'combine_css.html',
  # has 4 CSS files in the following order.
  #   yellow.css :   36 bytes
  #   blue.css   :   21 bytes
  #   big.css    : 4307 bytes
  #   bold.css   :   31 bytes
  # Because the threshold was chosen as '57', only the first two CSS files
  # are combined.
  test_filter combine_css Maximum size of combined CSS.
  QUERY_PARAM="PageSpeedMaxCombinedCssBytes=57"
  URL="$URL&$QUERY_PARAM"
  # Make sure that we have exactly 3 CSS files (after combination).
  fetch_until -save $URL 'grep -c text/css' 3
  # Now check that the 1st and 2nd CSS files are combined, but the 3rd
  # one is not.
  check [ $(grep -c 'styles/yellow.css+blue.css.pagespeed.' \
      $FETCH_UNTIL_OUTFILE) = 1 ]
  check [ $(grep -c 'styles/big.css\"' $FETCH_UNTIL_OUTFILE) = 1 ]
  check [ $(grep -c 'styles/bold.css\"' $FETCH_UNTIL_OUTFILE) = 1 ]

  # Test to make sure we have a sane Connection Header.  See
  # https://code.google.com/p/modpagespeed/issues/detail?id=664
  #
  # Note that this bug is dependent on seeing a resource for the
  # first time in the InPlaceResourceOptimization path, because
  # in that flow we are caching the response-headers from Apache.
  # The reponse-headers from Serf never seem to include the
  # Connection header.  So we have to pick a JS file that is
  # not otherwise used after cache is flushed in this block.
  start_test Sane Connection header
  URL="$TEST_ROOT/normal.js"
  fetch_until -save $URL 'grep -c W/\"PSA-aj-' 1 --save-headers
  CONNECTION=$(extract_headers $FETCH_UNTIL_OUTFILE | fgrep "Connection:")
  check_not_from "$CONNECTION" fgrep -qi "Keep-Alive, Keep-Alive"
  check_from "$CONNECTION" fgrep -qi "Keep-Alive"

  start_test Pass through headers when Cache-Control is set early on HTML.
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      http://issue809.example.com/mod_pagespeed_example/index.html \
      -O $TEMPDIR/issue809.http
  check_from "$(extract_headers $TEMPDIR/issue809.http)" \
      grep -q "Issue809: Issue809Value"

  start_test Pass through common headers from origin on combined resources.
  URL="http://issue809.example.com/mod_pagespeed_example/combine_css.html"
  http_proxy=$SECONDARY_HOSTNAME fetch_until -save "$URL" \
      "grep -c css.pagespeed.cc." 1

  # Extract out the rewritten CSS URL from the HTML saved by fetch_until
  # above (see -save and definition of fetch_until).  Fetch that CSS
  # file and look inside for the sprited image reference (ic.pagespeed.is...).
  CSS=$(grep stylesheet "$FETCH_UNTIL_OUTFILE" | cut -d\" -f 6)
  if [ ${CSS:0:7} != "http://" ]; then
    CSS="http://issue809.example.com/mod_pagespeed_example/$CSS"
  fi
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $CSS -O $TEMPDIR/combined.http
  check_from "$(extract_headers $TEMPDIR/combined.http)" \
      grep -q "Issue809: Issue809Value"

  # Test a scenario where a multi-domain installation is using a
  # single CDN for all hosts, and uses a subdirectory in the CDN to
  # distinguish hosts.  Some of the resources may already be mapped to
  # the CDN in the origin HTML, but we want to fetch them directly
  # from localhost.  If we do this successfully (see the MapOriginDomain
  # command in customhostheader.example.com in debug.conf.template), we will
  # inline a small image.
  start_test shared CDN short-circuit back to origin via host-header override
  URL="http://customhostheader.example.com/map_origin_host_header.html"
  http_proxy=$SECONDARY_HOSTNAME fetch_until -save "$URL" \
      "grep -c data:image/png;base64" 1

  # Optimize in-place images for browser. Ideal test matrix (not covered yet):
  # User-Agent:  Accept:  Image type   Result
  # -----------  -------  ----------   ----------------------------------
  #    IE         N/A     photo        image/jpeg, Cache-Control: private *
  #     :         N/A     synthetic    image/png,  no vary
  #  Old Opera     no     photo        image/jpeg, Vary: Accept
  #     :          no     synthetic    image/png,  no vary
  #     :         webp    photo        image/webp, Vary: Accept, Lossy
  #     :         webp    synthetic    image/png,  no vary
  #  Chrome or     no     photo        image/jpeg, Vary: Accept
  # Firefox or     no     synthetic    image/png,  no vary
  #  New Opera    webp    photo        image/webp, Vary: Accept, Lossy
  #     :         webp    synthetic    image/png,  no vary
  # TODO(jmaessen): * cases currently send Vary: Accept.  Fix (in progress).
  # TODO(jmaessen): Send image/webp lossless for synthetic and alpha-channel
  # images.  Will require reverting to Vary: Accept for these.  Stuff like
  # animated webp will have to remain unconverted still in IPRO mode, or switch
  # to cc: private, but right now animated webp support is still pending anyway.
  function test_ipro_for_browser_webp() {
    IN_UA_PRETTY="$1"; shift
    IN_UA="$1"; shift
    IN_ACCEPT="$1"; shift
    IMAGE_TYPE="$1"; shift
    OUT_CONTENT_TYPE="$1"; shift
    OUT_VARY="${1-}"; shift || true
    OUT_CC="${1-}"; shift || true

    # Remaining args are the expected headers (Name:Value), photo, or synthetic.
    if [ "$IMAGE_TYPE" = "photo" ]; then
      URL="http://ipro-for-browser.example.com/images/Puzzle.jpg"
    else
      URL="http://ipro-for-browser.example.com/images/Cuppa.png"
    fi
    TEST_ID="In-place optimize for "
    TEST_ID+="User-Agent:${IN_UA_PRETTY:-${IN_UA:-None}},"
    if [ -z "$IN_ACCEPT" ]; then
      TEST_ID+=" no accept, "
    else
      TEST_ID+=" Accept:$IN_ACCEPT, "
    fi
    TEST_ID+=" $IMAGE_TYPE.  Expect image/${OUT_CONTENT_TYPE}, "
    if [ -z "$OUT_VARY" ]; then
      TEST_ID+=" no vary, "
    else
      TEST_ID+=" Vary:${OUT_VARY}, "
    fi
    if [ -z "$OUT_CC" ]; then
      TEST_ID+=" cacheable."
    else
      TEST_ID+=" Cache-Control:${OUT_CC}."
    fi
    start_test $TEST_ID
    http_proxy=$SECONDARY_HOSTNAME \
      fetch_until -save $URL 'grep -c W/\"PSA-aj-' 1 \
          "--save-headers \
          ${IN_UA:+--user-agent $IN_UA} \
          ${IN_ACCEPT:+--header=Accept:image/$IN_ACCEPT}"
    check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
      fgrep -q "Content-Type: image/$OUT_CONTENT_TYPE"
    if [ -z "$OUT_VARY" ]; then
      check_not_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
        fgrep -q "Vary:"
    else
      check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
        fgrep -q "Vary: $OUT_VARY"
    fi
    check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
      grep -q "Cache-Control: ${OUT_CC:-max-age=[0-9]*}$"
    # TODO: check file type of webp.  Irrelevant for now.
  }

  ##############################################################################
  # Test with testing-only user agent strings.
  #                          UA           Accept Type  Out  Vary     CC
  test_ipro_for_browser_webp "None" ""    ""     photo jpeg "Accept"
  test_ipro_for_browser_webp "" "webp"    ""     photo jpeg "Accept"
  test_ipro_for_browser_webp "" "webp-la" ""     photo jpeg "Accept"
  test_ipro_for_browser_webp "None" ""    "webp" photo webp "Accept"
  test_ipro_for_browser_webp "" "webp"    "webp" photo webp "Accept"
  test_ipro_for_browser_webp "" "webp-la" "webp" photo webp "Accept"
  test_ipro_for_browser_webp "None" ""    ""     synth png
  test_ipro_for_browser_webp "" "webp"    ""     synth png
  test_ipro_for_browser_webp "" "webp-la" ""     synth png
  test_ipro_for_browser_webp "None" ""    "webp" synth png
  test_ipro_for_browser_webp "" "webp"    "webp" synth png
  test_ipro_for_browser_webp "" "webp-la" "webp" synth png
  ##############################################################################

  # Wordy UAs need to be stored in the WGETRC file to avoid death by quoting.
  OLD_WGETRC=$WGETRC
  WGETRC=$TEMPDIR/wgetrc-ua
  export WGETRC

  # IE 9 and later must re-validate Vary: Accept.  We should send CC: private.
  IE9_UA="Mozilla/5.0 (Windows; U; MSIE 9.0; WIndows NT 9.0; en-US))"
  IE11_UA="Mozilla/5.0 (Windows NT 6.1; WOW64; ***********; rv:11.0) like Gecko"
  echo "user_agent = $IE9_UA" > $WGETRC
  #                           (no accept)  Type  Out  Vary CC
  test_ipro_for_browser_webp "IE 9"  "" "" photo jpeg ""   "max-age=[0-9]*,private"
  test_ipro_for_browser_webp "IE 9"  "" "" synth png
  echo "user_agent = $IE11_UA" > $WGETRC
  test_ipro_for_browser_webp "IE 11" "" "" photo jpeg ""   "max-age=[0-9]*,private"
  test_ipro_for_browser_webp "IE 11" "" "" synth png

  # Older Opera did not support webp.
  OPERA_UA="Opera/9.80 (Windows NT 5.2; U; en) Presto/2.7.62 Version/11.01"
  echo "user_agent = $OPERA_UA" > $WGETRC
  #                                (no accept) Type  Out  Vary
  test_ipro_for_browser_webp "Old Opera" "" "" photo jpeg "Accept"
  test_ipro_for_browser_webp "Old Opera" "" "" synth png
  # Slightly newer opera supports only lossy webp, sends header.
  OPERA_UA="Opera/9.80 (Windows NT 6.0; U; en) Presto/2.8.99 Version/11.10"
  echo "user_agent = $OPERA_UA" > $WGETRC
  #                                           Accept Type  Out  Vary
  test_ipro_for_browser_webp "Newer Opera" "" "webp" photo webp "Accept"
  test_ipro_for_browser_webp "Newer Opera" "" "webp" synth png

  function test_decent_browsers() {
    echo "user_agent = $2" > $WGETRC
    #                          UA      Accept Type      Out  Vary
    test_ipro_for_browser_webp "$1" "" ""     photo     jpeg "Accept"
    test_ipro_for_browser_webp "$1" "" ""     synthetic  png
    test_ipro_for_browser_webp "$1" "" "webp" photo     webp "Accept"
    test_ipro_for_browser_webp "$1" "" "webp" synthetic  png
  }
  CHROME_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_1) AppleWebKit/537.36 "
  CHROME_UA+="(KHTML, like Gecko) Chrome/32.0.1700.102 Safari/537.36"
  test_decent_browsers "Chrome" "$CHROME_UA"
  FIREFOX_UA="Mozilla/5.0 (X11; U; Linux x86_64; zh-CN; rv:1.9.2.10) "
  FIREFOX_UA+="Gecko/20100922 Ubuntu/10.10 (maverick) Firefox/3.6.10"
  test_decent_browsers "Firefox" "$FIREFOX_UA"
  test_decent_browsers "New Opera" \
    "Opera/9.80 (Windows NT 6.0) Presto/2.12.388 Version/12.14"

  WGETRC=$OLD_WGETRC

  # Test RequestOptionOverride.
  start_test Request Option Override : Correct values are passed
  HOST_NAME="http://request-option-override.example.com"
  OPTS="?ModPagespeed=on"
  OPTS+="&ModPagespeedFilters=+collapse_whitespace,+remove_comments"
  OPTS+="&PageSpeedRequestOptionOverride=abc"
  URL="$HOST_NAME/mod_pagespeed_test/forbidden.html$OPTS"
  OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)"
  echo wget $URL
  check_not_from "$OUT" grep -q '<!--'

  start_test Request Option Override : Incorrect values are passed
  HOST_NAME="http://request-option-override.example.com"
  OPTS="?ModPagespeed=on"
  OPTS+="&ModPagespeedFilters=+collapse_whitespace,+remove_comments"
  OPTS+="&PageSpeedRequestOptionOverride=notabc"
  URL="$HOST_NAME/mod_pagespeed_test/forbidden.html$OPTS"
  OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)"
  echo wget $URL
  check_from "$OUT" grep -q '<!--'

  start_test Request Option Override : Correct values are passed as headers
  HOST_NAME="http://request-option-override.example.com"
  OPTS="--header=ModPagespeed:on"
  OPTS+=" --header=ModPagespeedFilters:+collapse_whitespace,+remove_comments"
  OPTS+=" --header=PageSpeedRequestOptionOverride:abc"
  URL="$HOST_NAME/mod_pagespeed_test/forbidden.html"
  echo wget $OPTS $URL
  OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $OPTS $URL)"
  check_not_from "$OUT" grep -q '<!--'

  start_test Request Option Override : Incorrect values are passed as headers
  HOST_NAME="http://request-option-override.example.com"
  OPTS="--header=ModPagespeed:on"
  OPTS+=" --header=ModPagespeedFilters:+collapse_whitespace,+remove_comments"
  OPTS+=" --header=PageSpeedRequestOptionOverride:notabc"
  URL="$HOST_NAME/mod_pagespeed_test/forbidden.html"
  echo wget $OPTS $URL
  OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $OPTS $URL)"
  check_from "$OUT" grep -q '<!--'
fi

start_test Issue 609 -- proxying non-.pagespeed content, and caching it locally
URL="$PRIMARY_SERVER/modpagespeed_http/not_really_a_font.woff"
echo $WGET_DUMP $URL ....
OUT1=$($WGET_DUMP $URL)
check_from "$OUT1" egrep -q "This is not really font data"
if [ $statistics_enabled = "1" ]; then
  OLDSTATS=$OUTDIR/proxy_fetch_stats.old
  NEWSTATS=$OUTDIR/proxy_fetch_stats.new
  $WGET_DUMP $STATISTICS_URL > $OLDSTATS
fi
OUT2=$($WGET_DUMP $URL)
check_from "$OUT2" egrep -q "This is not really font data"
if [ $statistics_enabled = "1" ]; then
  $WGET_DUMP $STATISTICS_URL > $NEWSTATS
  check_stat $OLDSTATS $NEWSTATS cache_hits 1
  check_stat $OLDSTATS $NEWSTATS cache_misses 0
fi

start_test Do not proxy content without a Content-Type header
# These tests depend on modpagespeed.com being configured to serve an example
# file with a content-type header on port 8091 and without one on port 8092.
# scripts/serve_proxying_tests.sh can do this.
URL="$PRIMARY_SERVER/content_type_absent/"
CONTENTS="This file should not be proxied"


OUT=$($CURL --include --silent $URL)
check_from "$OUT" fgrep -q "403 Forbidden"
check_from "$OUT" fgrep -q \
    "Missing Content-Type required for proxied resource"
check_not_from "$OUT" fgrep -q "$CONTENTS"

start_test But do proxy content if the Content-Type header is present.
URL="$PRIMARY_SERVER/content_type_present/"
CONTENTS="This file should be proxied"


OUT=$($CURL --include --silent $URL)
check_from "$OUT" fgrep -q "200 OK"
check_from "$OUT" fgrep -q "$CONTENTS"

start_test proxying from external domain should optimize images in-place.
# Keep fetching this until it's headers include the string "PSA-aj" which
# means rewriting has finished.
URL="$PRIMARY_SERVER/modpagespeed_http/Puzzle.jpg"
fetch_until -save $URL "grep -c PSA-aj" 1 "--save-headers"

# We should see the origin etag in the wget output due to -save.  Note that
# the cache-control will start at 5 minutes -- the default on modpagespeed.com,
# and descend as time expires from when we strobed the image.  However, we
# provide a non-trivial etag with the content hash, but we'll just match the
# common prefix.
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'Etag: W/"PSA-aj-'

# Ideally this response should not have a 'chunked' encoding, because
# once we were able to optimize it, we know its length.
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'Content-Length:'
check_not_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
    fgrep -q 'Transfer-Encoding: chunked'

# Now add set jpeg compression to 75 and we expect 73238, but will test for 90k.
# Note that wc -c will include the headers.
start_test Proxying image from another domain, customizing image compression.
URL+="?PageSpeedJpegRecompressionQuality=75"
fetch_until -save $URL "wc -c" 90000 "--save-headers" "-lt"
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'Etag: W/"PSA-aj-'

echo Ensure that rewritten images strip cookies present at origin
check_not_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -qi 'Set-Cookie'
$WGET -O $FETCH_UNTIL_OUTFILE --save-headers \
  http://$PAGESPEED_TEST_HOST/do_not_modify/Puzzle.jpg
ORIGINAL_HEADERS=$(extract_headers $FETCH_UNTIL_OUTFILE)
check_from "$ORIGINAL_HEADERS" fgrep -q -i 'Set-Cookie'

start_test proxying HTML from external domain should not work
URL="$PRIMARY_SERVER/modpagespeed_http/evil.html"
OUT=$(check_error_code 8 $WGET_DUMP $URL)
check_not_from "$OUT" fgrep -q 'Set-Cookie:'

start_test Fetching the HTML directly from the origin is fine including cookie.
URL="http://$PAGESPEED_TEST_HOST/do_not_modify/evil.html"
OUT=$($WGET_DUMP $URL)
check_from "$OUT" fgrep -q -i 'Set-Cookie: test-cookie'

start_test IPRO-optimized resources should have fixed size, not chunked.
URL="$EXAMPLE_ROOT/images/Puzzle.jpg"
URL+="?PageSpeedJpegRecompressionQuality=75"
fetch_until -save $URL "wc -c" 90000 "--save-headers" "-lt"
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'Content-Length:'
CONTENT_LENGTH=$(extract_headers $FETCH_UNTIL_OUTFILE | \
  awk '/Content-Length:/ {print $2}')
check [ "$CONTENT_LENGTH" -lt 90000 ];
check_not_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
    fgrep -q 'Transfer-Encoding: chunked'

start_test IPRO 304 with etags
# Reuses $URL and $FETCH_UNTIL_OUTFILE from previous test.
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'Etag:'
ETAG=$(extract_headers $FETCH_UNTIL_OUTFILE | awk '/Etag:/ {print $2}')
echo $WGET_DUMP --header "If-None-Match: $ETAG" $URL
OUTFILE=$OUTDIR/etags
# Note: -o gets debug info which is the only place that 304 message is sent.
check_not $WGET -o $OUTFILE -O /dev/null --header "If-None-Match: $ETAG" $URL
check fgrep -q "awaiting response... 304" $OUTFILE

if [ "$SECONDARY_HOSTNAME" != "" ]; then
  start_test Downstream cache integration caching headers.
  URL="http://downstreamcacheresource.example.com/mod_pagespeed_example/images/"
  URL+="xCuppa.png.pagespeed.ic.0.png"
  OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --save-headers $URL)
  check_from "$OUT" egrep -iq $'^Cache-Control: .*\r$'
  check_from "$OUT" egrep -iq $'^Expires: .*\r$'
  check_from "$OUT" egrep -iq $'^Last-Modified: .*\r$'
fi

# Test handling of large HTML files. We first test with a cold cache, and verify
# that we bail out of parsing and insert a script redirecting to
# ?PageSpeed=off. This should also insert an entry into the property cache so
# that the next time we fetch the file it will not be parsed at all.
echo TEST: Handling of large files.
# Add a timestamp to the URL to ensure it's not in the property cache.
FILE="max_html_parse_size/large_file.html?value=$(date +%s)"
URL=$TEST_ROOT/$FILE
# Enable a filter that will modify something on this page, since we testing that
# this page should not be rewritten.
WGET_EC="$WGET_DUMP --header=PageSpeedFilters:rewrite_images"
echo $WGET_EC $URL
LARGE_OUT=$($WGET_EC $URL)
check_from "$LARGE_OUT" grep -q window.location=".*&PageSpeed=off"

# The file should now be in the property cache so make sure that the page is no
# longer parsed. Use fetch_until because we need to wait for a potentially
# non-blocking write to the property cache from the previous test to finish
# before this will succeed.
fetch_until -save $URL 'grep -c window.location=".*&PageSpeed=off"' 0
check_not fgrep -q pagespeed.ic $FETCH_FILE

function scrape_secondary_stat {
  http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
    http://secondary.example.com/mod_pagespeed_statistics/ | \
    scrape_pipe_stat "$1"
}

if [ $statistics_enabled = "1" ]; then
  start_test CompressedCache is racking up savings on the root vhost
  original_size=$(scrape_stat compressed_cache_original_size)
  compressed_size=$(scrape_stat compressed_cache_compressed_size)
  echo original_size=$original_size compressed_size=$compressed_size
  check [ "$compressed_size" -lt "$original_size" ];
  check [ "$compressed_size" -gt 0 ];
  check [ "$original_size" -gt 0 ];

  if [ "$SECONDARY_HOSTNAME" != "" ]; then
    start_test CompressedCache is turned off for the secondary vhost
    original_size=$(scrape_secondary_stat compressed_cache_original_size)
    compressed_size=$(scrape_secondary_stat compressed_cache_compressed_size)
    check [ "$compressed_size" -eq 0 ];
    check [ "$original_size" -eq 0 ];
  fi
else
  echo skipping CompressedCache test because stats is $statistics_enabled
fi

# Check all the pagespeed_admin pages, both in its default location and an
# alternate.
start_test pagespeed_admin and alternate_admin_path
function check_admin_banner() {
  path="$1"
  title="$2"
  tmpfile=$TEMPDIR/admin.html
  echo $WGET_DUMP $PRIMARY_SERVER/$path '>' $tmpfile ...
  $WGET_DUMP $PRIMARY_SERVER/$path > $tmpfile
  check fgrep -q "<title>PageSpeed $title</title>" $tmpfile
  rm -f $tmpfile
}
for admin_path in pagespeed_admin pagespeed_global_admin alt/admin/path; do
  check_admin_banner $admin_path/statistics "Statistics"
  check_admin_banner $admin_path/config "Configuration"
  check_admin_banner $admin_path/spdy_config "SPDY Configuration"
  check_admin_banner $admin_path/histograms "Histograms"
  check_admin_banner $admin_path/cache "Caches"
  check_admin_banner $admin_path/console "Console"
  check_admin_banner $admin_path/message_history "Message History"
done


# TODO(matterbury): Uncomment these lines when the test is fixed.
:<< COMMENTING_BLOCK
start_test ModPagespeedIf application
# Without SPDY, we should combine things
OUT=$($WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' \
    $EXAMPLE_ROOT/combine_css.html)
check_from "$OUT" egrep -q ',Mcc'

# Despite combine_css being disabled in <ModPagespeedIf>, we still
# expect it with SPDY since it's turned on in mod_pagespeed_example/.htaccess.
# However, since rewrite_css is off, the result should be rewritten by
# cc and not also cf or ce.
OUT=$($WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' \
  --header 'X-PSA-Optimize-For-SPDY: true' \
  $EXAMPLE_ROOT/combine_css.html)
check_not_from "$OUT" egrep -q ',Mcc'
check_from "$OUT" egrep -q '.pagespeed.cc'

# Now test resource fetch. Since we've disabled extend_cache and
# rewrite_images for spdy, we should not see rewritten resources there,
# while we will in the other normal case.
OUT=$($WGET_DUMP  --header 'X-PSA-Blocking-Rewrite: psatest' \
    $EXAMPLE_ROOT/styles/A.rewrite_css_images.css.pagespeed.cf.rnLTdExmOm.css)
check_from "$OUT" grep -q 'png.pagespeed.'

OUT=$($WGET_DUMP  --header 'X-PSA-Blocking-Rewrite: psatest' \
    --header 'X-PSA-Optimize-For-SPDY: true' \
    $EXAMPLE_ROOT/styles/A.rewrite_css_images.css.pagespeed.cf.rnLTdExmOm.css)
check_not_from "$OUT" grep -q 'png.pagespeed.'
COMMENTING_BLOCK

start_test Base config has purging disabled.  Check error message syntax.
OUT=$($WGET_DUMP "$HOSTNAME/pagespeed_admin/cache?purge=*")
check_from "$OUT" fgrep -q "ModPagespeedEnableCachePurge on"

# Cleanup
rm -rf $OUTDIR

check_failures_and_exit
