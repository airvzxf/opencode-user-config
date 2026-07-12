#!/bin/bash
# Note: Using #!/bin/bash instead of #!/usr/bin/env bash (less portable)

# Example of a script with common shellcheck errors

echo "Enter a filename:"
read filename

# SC2086: Double quote to prevent globbing and word splitting.
if [ -f $filename ]; then
  echo "File exists."
else
  echo "File does not exist."
fi

# SC2006: Use $(...) notation instead of legacy backticks `...`.
current_date=`date`
echo "Current date: $current_date"

# SC2155: Declare and assign separately to avoid masking return values.
export PATH=$PATH:/custom/bin

# SC2250: Prefer braces for variable expansion (optional, but recommended).
echo "Filename is $filename"
