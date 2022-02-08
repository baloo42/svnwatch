#!/bin/bash
#
# svnwatch - watch file or directory and git commit all changes as they happen
#
# Copyright (C) 2015  Patrick Lehner
#   with modifications and contributions by:
#   - Matthew McGowan
#   - Dominik D. Geyer
#   - Bernhard Strähle
#
#############################################################################
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################
#
#   Idea and original code taken from http://stackoverflow.com/a/965274 
#       (but heavily modified by now)
#
#   Requires the command 'inotifywait' to be available, which is part of
#   the inotify-tools (See https://github.com/rvoicilas/inotify-tools ),
#   and (obviously) svn.
#   Will check the availability of both commands using the `which` command
#   and will abort if either command (or `which`) is not found.
#

SLEEP_TIME=2
TIMEOUT=300
DATE_FMT="+%Y-%m-%d %H:%M:%S"
COMMITMSG="Scripted auto-commit on change (%d) by svnwatch.sh"

shelp () { # Print a message about how to use this script
    echo "svnwatch - watch file or directory and git commit all changes as they happen"
    echo ""
    echo "Usage:"
    echo "${0##*/} [-s <secs>] [-d <fmt>] [-m <msg>] <target>"
    echo ""
    echo "Where <target> is the file or folder which should be watched. The target needs"
    echo "to be in a SVN working copy, or in the case of a folder, it may also be the top"
    echo "folder of the working copy."
    echo ""
    echo " -s <secs>        after detecting a change to the watched file or directory,"
    echo "                  wait <secs> seconds until committing, to allow for more"
    echo "                  write actions of the same batch to finish; default is $SLEEP_TIME sec"
    echo " -d <fmt>         the format string used for the timestamp in the commit"
    echo "                  message; see 'man date' for details; default is "
    echo "                  \"+%Y-%m-%d %H:%M:%S\""
    echo " -m <msg>         the commit message used for each commit; all occurences of"
    echo "                  %d in the string will be replaced by the formatted date/time"
    echo "                  (unless the <fmt> specified by -d is empty, in which case %d"
    echo "                  is replaced by an empty string); the default message is:"
    echo "                  \"$COMMITMSG"
    echo " -u <user>        svn user"
    echo " -p <pw>          svn user password"
    echo ""
    echo "As indicated, several conditions are only checked once at launch of the"
    echo "script. You can make changes to the repo state and configurations even while"
    echo "the script is running, but that may lead to undefined and unpredictable (even"
    echo "destructive) behavior!"
    echo "It is therefore recommended to terminate the script before changin the repo's"
    echo "config and restarting it afterwards."
    echo ""
    echo "By default, svnwatch tries to use the binaries \"svn\" and \"inotifywait\","
    echo "expecting to find them in the PATH (it uses 'which' to check this and  will"
    echo "abort with an error if they cannot be found). If you want to use binaries"
    echo "that are named differently and/or located outside of your PATH, you can define"
    echo "replacements in the environment variables SW_SVN_BIN and SW_INW_BIN for svn"
    echo "and inotifywait, respectively."
}

stderr () {
    echo $1 >&2
}

while getopts d:hm:u:p:s: option # Process command line options 
do 
    case "${option}" in 
        d) DATE_FMT=${OPTARG};;
        h) shelp; exit;;
        m) COMMITMSG=${OPTARG};;
        u) SVN_USER=${OPTARG};;
	p) SVN_PASSWORD=${OPTARG};;
        s) SLEEP_TIME=${OPTARG};;
    esac
done

shift $((OPTIND-1)) # Shift the input arguments, so that the input file (last arg) is $1 in the code below

if [ $# -ne 1 ]; then # If no command line arguments are left (that's bad: no target was passed)
    shelp # print usage help
    exit # and exit
fi

is_command () { # Tests for the availability of a command
	which $1 &>/dev/null
}

# if custom bin names are given for git or inotifywait, use those; otherwise fall back to "svn" and "inotifywait"
if [ -z "$SW_SVN_BIN" ]; then SVN="svn"; else SVN="$SW_SVN_BIN"; fi
if [ -z "$SW_INW_BIN" ]; then INW="inotifywait"; else INW="$SW_INW_BIN"; fi

# Check availability of selected binaries and die if not met
for cmd in "$SVN" "$INW"; do
	is_command $cmd || { stderr "Error: Required command '$cmd' not found." ; exit 1; }
done
unset cmd

# Expand the path to the target to absolute path
IN=$(readlink -f "$1")

SVN_COMMIT_ARGS="--non-interactive"
if [ ! -z "$SVN_USER" ]; then SVN_COMMIT_ARGS="$SVN_COMMIT_ARGS --username $SVN_USER"; fi
if [ ! -z "$SVN_PASSWORD" ]; then SVN_COMMIT_ARGS="$SVN_COMMIT_ARGS --password $SVN_PASSWORD"; fi



if [ -d $1 ]; then # if the target is a directory
    TARGETDIR=$(sed -e "s/\/*$//" <<<"$IN") # dir to CD into before using svn commands: trim trailing slash, if any
    INCOMMAND="$INW --exclude=\"^.svn\" -qqr -t $TIMEOUT -e close_write,move,delete,create $TARGETDIR" # construct inotifywait-commandline
    SVN_ADD_ARGS="." # add "." (CWD) recursively to index
elif [ -f $1 ]; then # if the target is a single file
    TARGETDIR=$(dirname "$IN") # dir to CD into before using svn commands: extract from file name
    INCOMMAND="$INW -qq -e close_write,move,delete $IN" # construct inotifywait-commandline
    SVN_ADD_ARGS="$IN" # add only the selected file to index
else
    stderr "Error: The target is neither a regular file nor a directory."
    exit 1
fi

# Check if commit message needs any formatting (date splicing)
if ! grep "%d" > /dev/null <<< "$COMMITMSG"; then # if commitmsg didnt contain %d, grep returns non-zero
    DATE_FMT="" # empty date format (will disable splicing in the main loop)
    FORMATTED_COMMITMSG="$COMMITMSG" # save (unchanging) commit message
fi

cd $TARGETDIR # CD into right dir

# check that target dir is a svn working dir

svn status 2>&1 | grep W155007 > /dev/null
if [ $? -ne 1 ]; then stderr "Error: Target is not in a svn working dir"; exit 1; fi

# main program loop: wait for changes and commit them
while true; do
    $INCOMMAND # wait for changes
    sleep $SLEEP_TIME # wait some more seconds to give apps time to write out all changes
    if [ -n "$DATE_FMT" ]; then
        FORMATTED_COMMITMSG="$(sed "s/%d/$(date "$DATE_FMT")/" <<< "$COMMITMSG")" # splice the formatted date-time into the commit message
    fi
    cd $TARGETDIR # CD into right dir

    IFS=$'\n'

    stat=($($SVN status))

    if [[ ${#stat[@]} -ne 0 ]]; then
        # Do we have any file to delete?
        delete_files=($($SVN status | awk '/^[D!][[:space:]]/ {$1=""; print $0}' | cut -b 2-))
        if [[ ${#delete_files[@]} -ne 0 ]]; then
                for file in "${delete_files[@]}"; do
                	$SVN delete "$file"
                done
        fi

        # Do we have any files to add?
        add_files=($($SVN status | awk '/^[A?][[:space:]]/ {$1=""; print $0}' | cut -b 2-))
        if [[ ${#add_files[@]} -ne 0 ]]; then
                for file in "${add_files[@]}"; do
			$SVN add "$file"
                done
        fi

	$SVN update $SVN_COMMIT_ARGS
	$SVN commit $SVN_COMMIT_ARGS -m "$FORMATTED_COMMITMSG" # construct commit message and commit
   fi
   unset IFS
done

