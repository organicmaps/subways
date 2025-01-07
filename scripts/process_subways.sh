#!/usr/bin/env bash
#set -euxo pipefail

if [ $# -gt 0 -a \( "${1-}" = "-h" -o "${1-}" = '--help' \) ]; then
  cat << EOF
This script updates a planet or an extract, processes metro networks in it
and produces a set of HTML files with validation results.

Usage: $0 [<local/planet.osm.pbf | http://mirror.osm.ru/planet.osm.pbf>]

In more detail, the script does the following:
  - If \$PLANET is a remote file, downloads it.
  - If \$BBOX variable is set, proceeds with this setting for the planet clipping. Otherwise uses \$POLY:
    unless \$POLY variable is set and the file exists, generates a *.poly file with union of bboxes of all cities having metro.
  - Makes an extract of the \$PLANET using the *.poly file.
  - Updates the extract.
  - Filters railway infrastructure from the extract.
  - Uses filtered file for validation and generates a bunch of output files.
  - Copies results onto remote server, if it is set up.

During this procedure, as many steps are skipped as possible. Namely:
  - Generation of metro extract is skipped if \$PLANET_METRO variable is set and the file exists.
  - Update with osmupdate is skipped if \$SKIP_PLANET_UPDATE or \$SKIP_FILTERING is set.
  - Filtering is skipped if \$SKIP_FILTERING is set and \$FILTERED_DATA is set and the file exists.

Generated files \$POLY, \$PLANET_METRO, \$FILTERED_DATA are deleted if the corresponding
variable is not defined or is null, otherwise they are kept.
The \$PLANET file from remote URL is saved to a tempfile and is removed at the end.

Environment variable reference:
  - PLANET: path to a local or remote pbf source file (the entire planet or an extract)
  - PLANET_METRO: path to a local pbf file with extract of cities having metro
    It's used instead of \$PLANET if exists otherwise it's created first
  - PLANET_UPDATE_SERVER: server to get replication data from. Defaults to https://planet.openstreetmap.org/replication/
  - CITIES_INFO_URL: http(s) or "file://" URL to a CSV file with reference information about rapid transit systems. A default value is hammered into python code.
  - CITY: name of a city/country to process
  - BBOX: bounding box of an extract; x1,y1,x2,y2. Has precedence over \$POLY
  - POLY: *.poly file with [multi]polygon comprising cities with metro
    If neither \$BBOX nor \$POLY is set, then \$POLY is generated
  - SKIP_PLANET_UPDATE: skip \$PLANET_METRO file update. Any non-empty string is True
  - SKIP_FILTERING: skip filtering railway data. Any non-empty string is True
  - FILTERED_DATA: path to filtered data. Defaults to \$TMPDIR/subways.osm
  - MAPSME: file name for maps.me json output
  - GTFS: file name for GTFS output
  - DUMP: directory/file name to dump YAML city data. Do not set to omit dump
  - GEOJSON: directory/file name to dump GeoJSON data. Do not set to omit dump
  - ELEMENTS_CACHE: file name to elements cache. Allows OSM xml processing phase
  - CITY_CACHE: json file with good cities obtained on previous validation runs
  - RECOVERY_PATH: file with some data collected at previous validation runs that
    may help to recover some simple validation errors
  - PYTHON: python 3 executable
  - GIT_PULL: set to 1 to update the scripts
  - TMPDIR: path to temporary files
  - HTML_DIR: target path for generated HTML files
  - DUMP_CITY_LIST: file name to save sorted list of cities, with [bad] mark for bad cities
  - SERVER: server name and path to upload HTML files (e.g. ilya@osmz.ru:/var/www/)
  - SERVER_KEY: rsa key to supply for uploading the files
  - REMOVE_HTML: set to 1 to remove \$HTML_DIR after uploading
  - QUIET: set to any non-empty value to use WARNING log level in process_subways.py. Default is INFO.
EOF
  exit
fi


function activate_venv_at_path() {
  path=$1

  if [ ! -d "$path/".venv ]; then
    "${PYTHON:-python3}" -m venv "$path"/.venv
  fi

  source "$path"/.venv/bin/activate

  if [ -f "$path"/requirements.txt ]; then
    pip install --upgrade pip
    pip install -r "$path"/requirements.txt
  fi
}


function check_osmium() {
  if ! which osmium > /dev/null; then
    echo "Please install osmium-tool"
    exit 1
  fi
}


function check_poly() {
  # Checks or generates *.poly file covering cities where
  # there is a metro; does this only once during script run.

  if [ -z "${POLY_CHECKED-}" ]; then
    if [ -n "${BBOX-}" ]; then
      # If BBOX is set, then exclude POLY at all from processing
      POLY=""
    else
      if [ -z "${POLY-}" ]; then
        NEED_TO_REMOVE_POLY=1
      fi

      if [ -z "${POLY-}" -o ! -f "${POLY-}" ]; then
        POLY=${POLY:-$(mktemp "$TMPDIR/all-metro.XXXXXXXX.poly")}
        activate_venv_at_path "$SUBWAYS_REPO_PATH/tools/make_poly"
        python "$SUBWAYS_REPO_PATH"/tools/make_poly/make_all_metro_poly.py \
            ${CITIES_INFO_URL:+--cities-info-url "$CITIES_INFO_URL"} > "$POLY"
        deactivate
      fi
    fi
    POLY_CHECKED=1
  fi
}

# "readlink -f" echoes canonicalized absolute path to a file/directory
SUBWAYS_REPO_PATH="$(readlink -f $(dirname "$0")/..)"

if [ ! -f "$SUBWAYS_REPO_PATH/scripts/process_subways.py" ]; then
  echo "Please clone the subways repo to $SUBWAYS_REPO_PATH"
  exit 2
fi

# Contains 'subways' dir and is required by the main validator python script
# as well as by some tools
export PYTHONPATH="$SUBWAYS_REPO_PATH"

# Downloading the latest version of the subways script
if [ -n "${GIT_PULL-}" ]; then (
  pushd "$SUBWAYS_REPO_PATH"
  git pull origin master
  popd
) fi


TMPDIR="${TMPDIR:-"$SUBWAYS_REPO_PATH"}"
mkdir -p "$TMPDIR"

if [ -z "${FILTERED_DATA-}" ]; then
  FILTERED_DATA="$TMPDIR/subways.osm"
  NEED_TO_REMOVE_FILTERED_DATA=1
fi

if [ -z "${SKIP_FILTERING-}" -o ! -f "$FILTERED_DATA" ]; then
  NEED_FILTER=1
fi


if [ -n "${NEED_FILTER-}" ]; then

  # If $PLANET_METRO file doesn't exist, create it

  if [ -n "${PLANET_METRO-}" ]; then
    EXT=${PLANET_METRO##*.}
    if [ ! "$EXT" = "osm" -a ! "$EXT" == "xml" -a ! "$EXT" = "o5m" ]; then
      echo "Only o5m/xml/osm file formats are supported for filtering."
      exit 3
    fi
  fi

  if [ ! -f "${PLANET_METRO-}" ]; then
    check_osmium
    check_poly

    PLANET="${PLANET:-${1-}}"
    EXT="${PLANET##*.}"
    if [ ! "$EXT" = "pbf" -a ! "$EXT" = "o5m" ]; then
      echo "Cannot process '$PLANET' planet file."
      echo "Only pbf/o5m source planet files are supported."
      exit 4
    fi

    if [ "${PLANET:0:7}" = "http://" -o \
         "${PLANET:0:8}" = "https://" -o \
         "${PLANET:0:6}" = "ftp://" ]; then
      PLANET_TEMP=$(mktemp "$TMPDIR/planet.XXXXXXXX.$EXT")
      wget -O "$PLANET_TEMP" "$PLANET"
      PLANET="$PLANET_TEMP"
    elif [ ! -f "$PLANET" ]; then
      echo "Cannot find planet file '$PLANET'";
      exit 5
    fi

    if [ -z "${PLANET_METRO-}" ]; then
      PLANET_METRO=$(mktemp "$TMPDIR/planet-metro.XXXXXXXX.osm.pbf")
      NEED_TO_REMOVE_PLANET_METRO=1
    fi

    if [ "$PLANET" = "$PLANET_METRO" ]; then
      echo "PLANET_METRO parameter shouldn't point to PLANET."
      exit 6
    fi

    osmium extract "$PLANET" \
        ${BBOX:+"--bbox=$BBOX"} ${POLY:+"--polygon=$POLY"} -O -o "$PLANET_METRO"
  fi
fi

if [ -n "${PLANET_TEMP-}" ]; then
  rm "$PLANET_TEMP"
fi

# Updating the planet-metro file

# If there's no need to filter, then update is also unnecessary
if [ -z "${SKIP_PLANET_UPDATE-}" -a -n "${NEED_FILTER-}" ]; then
  check_osmium
  check_poly
  PLANET_UPDATE_SERVER=${PLANET_UPDATE_SERVER:-https://planet.openstreetmap.org/replication/hour/}
  PLANET_METRO_ABS="$(cd "$(dirname "$PLANET_METRO")"; pwd)/$(basename "$PLANET_METRO")"
  PLANET_METRO_ABS_NEW="$PLANET_METRO_ABS.new.osm.pbf"
  mkdir -p $TMPDIR/osmupdate_temp/

  activate_venv_at_path "$SUBWAYS_REPO_PATH/scripts"
  OSMUPDATE_ERRORS=$(pyosmium-up-to-date \
                                 "$PLANET_METRO_ABS" \
                                 --server $PLANET_UPDATE_SERVER \
                                 --tmpdir $TMPDIR/osmupdate_temp/temp \
                                 -o "$PLANET_METRO_ABS_NEW" 2>&1 || :)
  deactivate
  if [ -n "$OSMUPDATE_ERRORS" ]; then
    echo "osmupdate failed: $OSMUPDATE_ERRORS"
    exit 7
  fi

  # Since updating adds things outside the area, trim those again.
  osmium extract "$PLANET_METRO_ABS_NEW" \
      ${BBOX:+"--bbox=$BBOX"} ${POLY:+"--polygon=$POLY"} -O -o "$PLANET_METRO_ABS"
  rm -f "$PLANET_METRO_ABS_NEW"
fi

# Filtering planet-metro

if [ -n "${NEED_FILTER-}" ]; then
  check_osmium
  QRELATIONS="r/route,route_master=subway,light_rail,monorail,train r/public_transport=stop_area,stop_area_group"
  QNODES="n/railway=station,subway_entrance,train_station_entrance n/station=subway,light_rail,monorail n/subway=yes n/light_rail=yes n/monorail=yes n/train=yes"
  osmium tags-filter "$PLANET_METRO" $QRELATIONS $QNODES -o "$FILTERED_DATA" -O
fi

if [ -n "${NEED_TO_REMOVE_PLANET_METRO-}" ]; then
  rm $PLANET_METRO
fi
if [ -n "${NEED_TO_REMOVE_POLY-}" ]; then
  rm $POLY
fi

# Running the validation
if [ -n "${DUMP-}" ]; then
  mkdir -p "$DUMP"
fi

if [ -n "${DUMP-}" ]; then
   mkdir -p "$DUMP"
fi

VALIDATION="$TMPDIR/validation.json"

activate_venv_at_path "$SUBWAYS_REPO_PATH/scripts"
python "$SUBWAYS_REPO_PATH/scripts/process_subways.py" ${QUIET:+-q} \
    -x "$FILTERED_DATA" -l "$VALIDATION" \
    ${CITIES_INFO_URL:+--cities-info-url "$CITIES_INFO_URL"} \
    ${MAPSME:+--output-mapsme "$MAPSME"} \
    ${FMK:+--output-fmk "$FMK"} \
    ${GTFS:+--output-gtfs "$GTFS"} \
    ${CITY:+-c "$CITY"} \
    ${DUMP:+-d "$DUMP"} \
    ${GEOJSON:+-j "$GEOJSON"} \
    ${DUMP_CITY_LIST:+--dump-city-list "$DUMP_CITY_LIST"} \
    ${ELEMENTS_CACHE:+-i "$ELEMENTS_CACHE"} \
    ${CITY_CACHE:+--cache "$CITY_CACHE"} \
    ${RECOVERY_PATH:+-r "$RECOVERY_PATH"}
deactivate


if [ -n "${NEED_TO_REMOVE_FILTERED_DATA-}" ]; then
  rm "$FILTERED_DATA"
fi

# Preparing HTML files

if [ -z "${HTML_DIR-}" ]; then
  HTML_DIR="$SUBWAYS_REPO_PATH/html"
  REMOVE_HTML=1
fi

mkdir -p $HTML_DIR
rm -f "$HTML_DIR"/*.html

activate_venv_at_path "$SUBWAYS_REPO_PATH/tools/v2h"
python "$SUBWAYS_REPO_PATH/tools/v2h/validation_to_html.py" \
    ${CITIES_INFO_URL:+--cities-info-url "$CITIES_INFO_URL"} \
    "$VALIDATION" "$HTML_DIR"
deactivate

# Uploading files to the server

if [ -n "${SERVER-}" ]; then
  scp -q ${SERVER_KEY+-i "$SERVER_KEY"} "$HTML_DIR"/* "$SERVER"
  if [ -n "${REMOVE_HTML-}" ]; then
    rm -r "$HTML_DIR"
  fi
fi

