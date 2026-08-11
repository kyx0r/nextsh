#!/bin/sh
# Regenerate README from sh.1, the mdoc source of the manual.
# Run from the manual branch; copy the result over to main.
export current_date="$(date +"%b %e, %Y")"
sed "s/^\.Dd .*/.Dd ${current_date}/" ./sh.1 > ./sh.1.new && mv ./sh.1.new ./sh.1
mandoc -T ascii ./sh.1 > README
sed "s/.$(printf '\010')//g" ./README > ./README.new && mv ./README.new ./README
